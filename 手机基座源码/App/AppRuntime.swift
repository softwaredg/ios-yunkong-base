import Foundation
import UIKit
import Combine
import Darwin
import CoreVideo

/// Filled from MainActor, read after a short wait on the NW queue (control ack).
private final class ControlReplyBox: @unchecked Sendable {
    var value: [String: Any]?
}

@MainActor
final class AppRuntime: ObservableObject {
    @Published var running = false
    @Published var capturing = false
    @Published var status = "正在自动启动…"
    @Published var lastError: String?
    @Published var lanIP: String = "获取中…"
    @Published var hidReady = false
    @Published var memoryMB: Int = 0
    @Published var restartCount: Int = 0

    let port: UInt16 = 11019
    let deviceId: String
    let deviceName: String

    /// Soft Jetsam guard — restart capture/service before iOS kills the process.
    private let memoryLimitBytes: UInt64 = 220 * 1024 * 1024
    private let memoryRestartCooldown: TimeInterval = 45

    private var service: LocalService?
    private let tcpVideo = TcpVideoHub()
    private lazy var pipeline: FramePipeline = FramePipeline(tcpVideo: tcpVideo)
    private let capturer = ScreenCapturer()
    private let hid: IOHIDControlling = IOHIDController()
    private var keepAliveWatchTimer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var lastStallRecoverAt: Date = .distantPast
    private var captureStartedAt: Date = .distantPast
    private var ipTimer: Timer?
    private var memoryTimer: Timer?
    private var stallTimer: Timer?
    private var serviceRetryTimer: Timer?
    private var lastMemoryRestartAt: Date = .distantPast
    private var lastReason: String = ""
    private var startedOnce = false
    /// UI process only — TVH4/capture run in `--helper` sibling (DirectPhoneBase model).
    private var uiShellOnly = false

    init() {
        if let saved = UserDefaults.standard.string(forKey: "deviceId"), !saved.isEmpty {
            deviceId = saved
        } else {
            let id = "ios-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
            deviceId = String(id)
            UserDefaults.standard.set(deviceId, forKey: "deviceId")
        }
        deviceName = UIDevice.current.name
        // 实际能否注入取决于巨魔 entitlement；编译期已链上开源 IOHID。
        hidReady = true
        PortHandoff.saveIdentity(deviceId: deviceId, deviceName: "云控基座·\(deviceName)")
        UIApplication.shared.isIdleTimerDisabled = true
        // Don't wait for first paint — start listeners ASAP.
        Task { @MainActor in self.autoStart() }
    }

    func autoStart() {
        guard !startedOnce else {
            ensureRunning(reason: "ensure")
            return
        }
        startedOnce = true
        refreshLanIP()

        if !HelperLauncher.isHelperProcess() {
            // UI shell: spawn helper that owns ports/capture (survives app background).
            uiShellOnly = true
            status = "正在拉起推流助手…"
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = HelperLauncher.ensureHelperRunning()
                Task { @MainActor in
                    self.running = ok
                    self.capturing = ok
                    self.status = ok ? "助手推流中（切后台保持）" : "助手拉起失败，请重开 App"
                    self.startUIStatusPoll()
                }
            }
            return
        }

        // Helper process path.
        HotspotKeepAlive.register()
        BackgroundKeepAlive.shared().start()
        beginStickyBackgroundTask()
        startService()
        startCapture()
        ipTimer?.invalidate()
        ipTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLanIP() }
        }
        if let ipTimer { RunLoop.main.add(ipTimer, forMode: .common) }
        memoryTimer?.invalidate()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMemoryAndMaybeRestart() }
        }
        if let memoryTimer { RunLoop.main.add(memoryTimer, forMode: .common) }
        stallTimer?.invalidate()
        stallTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkEncodeStallAndRecover() }
        }
        if let stallTimer { RunLoop.main.add(stallTimer, forMode: .common) }
        keepAliveWatchTimer?.invalidate()
        keepAliveWatchTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                BackgroundKeepAlive.shared().start()
                self?.beginStickyBackgroundTask()
            }
        }
        if let keepAliveWatchTimer { RunLoop.main.add(keepAliveWatchTimer, forMode: .common) }
    }

    /// Called when scene becomes active / user returns to app.
    func ensureRunning(reason: String = "foreground") {
        refreshLanIP()
        if uiShellOnly {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = HelperLauncher.ensureHelperRunning()
                Task { @MainActor in self.refreshFromHelperInfo() }
            }
            return
        }
        BackgroundKeepAlive.shared().start()
        if service == nil || !running {
            status = "自动恢复服务（\(reason)）…"
            startService()
        }
        if !capturing {
            startCapture()
        }
    }

    /// UI may suspend; helper keeps :11019/:5909. Re-check helper on background.
    func enterBackground() {
        if uiShellOnly {
            DispatchQueue.global(qos: .utility).async {
                _ = HelperLauncher.ensureHelperRunning()
            }
            return
        }
        BackgroundKeepAlive.shared().start()
        beginStickyBackgroundTask()
    }

    private func startUIStatusPoll() {
        ipTimer?.invalidate()
        ipTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLanIP()
                self?.refreshFromHelperInfo()
            }
        }
        if let ipTimer { RunLoop.main.add(ipTimer, forMode: .common) }
    }

    private func refreshFromHelperInfo() {
        guard uiShellOnly else { return }
        let port = Int(self.port)
        DispatchQueue.global(qos: .utility).async {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/info")!)
            req.timeoutInterval = 1.5
            let task = URLSession.shared.dataTask(with: req) { data, _, _ in
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    Task { @MainActor in
                        self.running = false
                        self.capturing = false
                        self.status = "助手未响应，正在重拉…"
                        DispatchQueue.global().async { _ = HelperLauncher.ensureHelperRunning() }
                    }
                    return
                }
                let mode = obj["captureMode"] as? String ?? ""
                let streaming = obj["streaming"] as? Bool ?? false
                let mem = (obj["memory"] as? [String: Any])?["serviceFootprintBytes"] as? Int ?? 0
                let restarts = (obj["recovery"] as? [String: Any])?["restartCount"] as? Int ?? 0
                Task { @MainActor in
                    self.running = true
                    self.capturing = streaming || mode == "private-full"
                    self.memoryMB = mem / (1024 * 1024)
                    self.restartCount = restarts
                    self.status = "助手推流中 · \(mode.isEmpty ? "?" : mode)"
                }
            }
            task.resume()
        }
    }

    /// Soft restart: tear down HTTP/TVH4/encoder/capture and bring them back.
    func restartService(reason: String) {
        lastReason = reason
        restartCount += 1
        service?.updateRecovery(
            automatic: true,
            state: "restarting",
            restartCount: restartCount,
            lastReason: reason,
            footprint: ProcessMemory.footprintBytes(),
            resident: ProcessMemory.residentBytes()
        )
        status = "正在重启服务… (\(restartCount))"
        capturer.stop()
        capturing = false
        pipeline.resetEncoder()
        tcpVideo.stop()
        service?.stop()
        service = nil
        running = false
        // Brief pause so :11019/:5909 can leave TIME_WAIT before rebind.
        let n = restartCount
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.startService()
            self.startCapture()
            self.status = "已自动重启 · \(reason) · #\(n)"
        }
    }

    func refreshLanIP() {
        let ips = Self.wifiIPv4()
        lanIP = ips.first ?? "未连 Wi‑Fi（无局域网 IP）"
    }

    private static func wifiIPv4() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") { out.append(ip) }
        }
        return out
    }

    private func startService() {
        if service != nil {
            running = true
            serviceRetryTimer?.invalidate()
            serviceRetryTimer = nil
            return
        }
        let screen = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        let info = LocalService.DeviceInfo(
            deviceId: deviceId,
            name: "云控基座·\(deviceName)",
            port: port,
            width: Int(screen.width * scale),
            height: Int(screen.height * scale),
            streaming: true,
            controlAvailable: true,
            homeAvailable: true
        )
        let svc = LocalService(info: info)
        svc.memoryLimitBytes = memoryLimitBytes
        // @Sendable: must run on LocalService's NW queue without hopping to MainActor
        // (otherwise /api/info deadlocks whenever main is busy with capture).
        svc.memoryStatsProvider = { @Sendable in
            (ProcessMemory.footprintBytes(), ProcessMemory.residentBytes())
        }
        svc.onRestartRequested = { [weak self] in
            Task { @MainActor in self?.restartService(reason: "api-restart") }
        }
        svc.onControlJSON = { [weak self] obj in
            guard let self else { return nil }
            // handleControl is MainActor-isolated; prefer assumeIsolated when already
            // on main, else hop without sync-wait from the NW queue.
            if Thread.isMainThread {
                return MainActor.assumeIsolated { self.handleControl(obj) }
            }
            let box = ControlReplyBox()
            let gate = DispatchSemaphore(value: 0)
            Task { @MainActor in
                box.value = self.handleControl(obj)
                gate.signal()
            }
            _ = gate.wait(timeout: .now() + 1.5)
            return box.value
        }
        do {
            try svc.start()
            try tcpVideo.start(port: TcpVideoHub.defaultPort)
            service = svc
            running = true
            lastError = nil
            serviceRetryTimer?.invalidate()
            serviceRetryTimer = nil
            let hid = hidReady ? "IOHID 就绪" : "IOHID 不可用"
            status = "已自动开服务 · TVH4 :\(TcpVideoHub.defaultPort) · 控制 :\(port) · \(hid)"
            pipeline.attach(service: svc)
            pipeline.wire()
        } catch {
            lastError = error.localizedDescription
            status = "服务启动失败，2 秒后自动重试"
            running = false
            scheduleServiceRetry()
        }
    }

    private func scheduleServiceRetry() {
        serviceRetryTimer?.invalidate()
        serviceRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.status = "自动重试启动服务…"
                self?.startService()
            }
        }
    }

    private func checkMemoryAndMaybeRestart() {
        let footprint = ProcessMemory.footprintBytes()
        let resident = ProcessMemory.residentBytes()
        memoryMB = Int(max(footprint, resident) / (1024 * 1024))
        service?.updateRecovery(
            automatic: true,
            state: footprint >= memoryLimitBytes ? "high" : "normal",
            restartCount: restartCount,
            lastReason: lastReason,
            footprint: footprint,
            resident: resident
        )
        guard footprint >= memoryLimitBytes || resident >= memoryLimitBytes else { return }
        let now = Date()
        guard now.timeIntervalSince(lastMemoryRestartAt) >= memoryRestartCooldown else { return }
        lastMemoryRestartAt = now
        restartService(reason: "memory \(memoryMB)MB≥\(memoryLimitBytes / (1024 * 1024))MB")
    }

    private func startCapture() {
        capturer.onInfo = { [weak self] msg in
            Task { @MainActor in self?.status = msg }
        }
        capturer.onError = { [weak self] msg in
            Task { @MainActor in
                self?.lastError = msg
                self?.capturing = false
            }
        }
        capturer.onModeChange = { [weak self] mode in
            Task { @MainActor in self?.service?.captureMode = mode.rawValue }
        }
        capturer.onPixelBuffer = { [weak self] pb, ts in
            guard let self else { return }
            // Capture already detached; encoder is latest-wins on its own queue.
            self.pipeline.handle(pixelBuffer: pb, ptsUs: ts)
            if self.pipeline.encodedFrameCount == 1 {
                let w = CVPixelBufferGetWidth(pb)
                let h = CVPixelBufferGetHeight(pb)
                Task { @MainActor in
                    self.status = "推流 \(w)×\(h) · TVH4/\(TcpVideoHub.defaultPort)"
                    self.capturing = true
                }
            }
        }
        pipeline.attach(service: service)
        pipeline.wire()
        capturer.start()
        service?.captureMode = capturer.mode.rawValue
        capturing = true
        captureStartedAt = Date()
    }

    /// Cold start sometimes emits one IDR then stalls; soft-reset capture/encoder without dropping HTTP.
    private func checkEncodeStallAndRecover() {
        guard running, capturing else { return }
        let now = Date()
        guard now.timeIntervalSince(lastStallRecoverAt) >= 8 else { return }
        let frames = pipeline.encodedFrameCount
        let lastEnc = pipeline.lastEncodeDate
        let noEncodeYet = frames == 0 && now.timeIntervalSince(captureStartedAt) >= 3
        let stalledAfterEncode =
            frames > 0 &&
            (lastEnc == .distantPast || now.timeIntervalSince(lastEnc) >= 2.5)
        guard noEncodeYet || stalledAfterEncode else { return }
        lastStallRecoverAt = now
        status = "检测到推流停顿，采屏自愈…"
        capturer.softHealCapture(reason: "encode-stall")
        pipeline.resetEncoder()
        capturing = true
        captureStartedAt = Date()
        status = "已自愈推流 · TVH4 :\(TcpVideoHub.defaultPort)"
    }

    /// phonebase-control JSON → 开源 IOHID 全能力
    private func handleControl(_ obj: [String: Any]) -> [String: Any]? {
        let type = obj["type"] as? String ?? ""
        let seq = obj["seq"] as? Int ?? 0
        func ack(_ ok: Bool, _ error: String? = nil) -> [String: Any] {
            var r: [String: Any] = ["type": "ack", "seq": seq, "ok": ok]
            if let error { r["error"] = error }
            return r
        }
        func norm(_ x: Double, _ y: Double) -> Bool { x >= 0 && x <= 1 && y >= 0 && y <= 1 }

        switch type {
        case "keepalive":
            return nil
        case "pointer":
            let action = obj["action"] as? String ?? ""
            if action == "cancel" {
                hid.pointer(action: "cancel", x: 0.5, y: 0.5)
                return ack(true)
            }
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double, norm(x, y) else {
                return ack(false, "bad coords")
            }
            hid.pointer(action: action, x: x, y: y)
            return ack(true)
        case "tap":
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double, norm(x, y) else {
                return ack(false, "bad coords")
            }
            hid.tap(x: x, y: y)
            return ack(true)
        case "doubleTap":
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double, norm(x, y) else {
                return ack(false, "bad coords")
            }
            hid.doubleTap(x: x, y: y)
            return ack(true)
        case "longPress":
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double, norm(x, y) else {
                return ack(false, "bad coords")
            }
            hid.longPress(x: x, y: y)
            return ack(true)
        case "multitouch":
            let action = obj["action"] as? String ?? "tap"
            let count = obj["count"] as? Int ?? 2
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double, norm(x, y) else {
                return ack(false, "bad coords")
            }
            hid.multiTouch(action: action, x: x, y: y, count: count)
            return ack(true)
        case "drag":
            guard let x0 = obj["x0"] as? Double, let y0 = obj["y0"] as? Double,
                  let x1 = obj["x1"] as? Double, let y1 = obj["y1"] as? Double,
                  norm(x0, y0), norm(x1, y1)
            else { return ack(false, "bad coords") }
            let duration = (obj["duration"] as? Double) ?? 0.25
            let curve = (obj["curve"] as? Bool) ?? false
            hid.drag(x0: x0, y0: y0, x1: x1, y1: y1, duration: duration, curve: curve)
            return ack(true)
        case "pinch":
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double, norm(x, y) else {
                return ack(false, "bad coords")
            }
            let w = (obj["w"] as? Double) ?? 0.4
            let h = (obj["h"] as? Double) ?? 0.4
            let scale = (obj["scale"] as? Double) ?? 0.5
            let angle = (obj["angle"] as? Double) ?? 0
            let duration = (obj["duration"] as? Double) ?? 0.35
            hid.pinch(x: x, y: y, w: w, h: h, scale: scale, angle: angle, duration: duration)
            return ack(true)
        case "stylus":
            let action = obj["action"] as? String ?? "tap"
            guard let x = obj["x"] as? Double, let y = obj["y"] as? Double, norm(x, y) else {
                return ack(false, "bad coords")
            }
            hid.stylus(
                action: action, x: x, y: y,
                azimuth: (obj["azimuth"] as? Double) ?? 0,
                altitude: (obj["altitude"] as? Double) ?? (Double.pi / 4),
                pressure: (obj["pressure"] as? Double) ?? 0.5
            )
            return ack(true)
        case "button", "home":
            let button: String = {
                if type == "home" { return "home" }
                return (obj["button"] as? String) ?? ""
            }()
            let action = (obj["action"] as? String) ?? "press"
            guard !button.isEmpty, hid.hardwareButton(button, action: action) else {
                return ack(false, "unsupported button")
            }
            return ack(true)
        case "text":
            let text = obj["text"] as? String ?? ""
            guard !text.isEmpty, text.utf8.count <= 4096 else { return ack(false, "bad text") }
            hid.injectText(text)
            return ack(true)
        case "key":
            let key = obj["key"] as? String ?? ""
            guard !key.isEmpty else { return ack(false, "bad key") }
            hid.injectKey(key, action: (obj["action"] as? String) ?? "press")
            return ack(true)
        case "keysRelease":
            hid.releaseEveryKeys()
            return ack(true)
        case "hidKeepAlive":
            hid.setKeepAliveInterval((obj["interval"] as? Double) ?? 0)
            return ack(true)
        default:
            return nil
        }
    }

    private func beginStickyBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "tvh4-keepalive") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.bgTask)
                    self.bgTask = .invalid
                }
                BackgroundKeepAlive.shared().start()
                self.beginStickyBackgroundTask()
            }
        }
    }
}
