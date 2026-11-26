import Foundation
import UIKit
import Darwin

/// 非商业本地基座运行时：HTTP + /video + /control，licenseRequired=false
final class BaseRuntime {
    static let shared = BaseRuntime()

    let port: UInt16 = 11019
    /// 官方 USB usbmux Connect 目标端口（phonebase-usb-v1）
    let usbPort: UInt16 = 11021
    private(set) var isRunning = false
    var onStatus: ((String) -> Void)?

    private let server: LocalHTTPServer
    private let usbServer: LocalHTTPServer
    private let publisher: FramePublisher
    private let controlHub: ControlHub
    private let capture: DisplayCapture
    private let injector: TouchInjector
    private var geometryRevision = 1
    /// 缓存屏幕尺寸 / 名称，避免 HTTP 线程碰 UIKit
    private let screenWidth: Int
    private let screenHeight: Int
    private let cachedName: String
    private let cachedDeviceId: String
    private let hidReady: Bool
    private let encodeW: Int
    private let encodeH: Int
    private var orientationObserver: NSObjectProtocol?
    private var orientationPoll: DispatchSourceTimer?
    private var lastPublishedOrientation = 1
    /// 探活会狂 accept：运行日志按 key 强节流；日常 HTTP 探测不再逐条记
    private var lastConnLogAt: [String: Date] = [:]
    private let connLogMinInterval: TimeInterval = 120
    /// memory-guard 硬重启连击：达到阈值则 hard exit，交给 ProcessWatchdog
    private var memHardStreak = 0
    /// 护栏降质粘性：足迹降回软阈以下才允许 PC 升画质
    private var memoryGuardSticky = false
    /// ≥800MB 一票否决：跳过软重启直接硬退
    private let memVetoBytes: UInt64 = 800 * 1024 * 1024

    private init() {
        let size = DeviceIdentity.screenSize()
        screenWidth = size.width
        screenHeight = size.height
        cachedName = DeviceIdentity.displayName
        cachedDeviceId = DeviceIdentity.deviceId
        // CARenderServer 按 IOSurface 像素画；尺寸必须=竖屏物理像素（见 DeviceIdentity.screenSize）
        encodeW = size.width
        encodeH = size.height
        publisher = FramePublisher(width: encodeW, height: encodeH)
        let inj = TouchInjectors.best()
        injector = inj
        hidReady = (inj as? IOHIDTouchInjector)?.isAvailable == true
        controlHub = ControlHub(
            deviceId: cachedDeviceId,
            width: encodeW,
            height: encodeH,
            revision: geometryRevision,
            injector: inj,
            textAvailable: hidReady,
            keyboardAvailable: hidReady
        )
        capture = DisplayCapture(width: encodeW, height: encodeH)
        server = LocalHTTPServer(port: port)
        server.bonjourName = cachedName
        server.bonjourTXT = [
            "protocol": "lan-phonebase",
            "version": "1.0",
            "deviceId": cachedDeviceId,
            "port": String(port),
        ]
        usbServer = LocalHTTPServer(port: usbPort)
        usbServer.advertiseBonjour = false

        let wire: (LocalHTTPServer) -> Void = { [weak self] srv in
            guard let self else { return }
            let listenPort = srv === self.usbServer ? self.usbPort : self.port
            srv.onInfo = { [weak self] in self?.infoJSON(listenPort: listenPort) ?? Data() }
            srv.onHealth = { [weak self] in
                let n = (self?.server.acceptCount ?? 0) + (self?.usbServer.acceptCount ?? 0)
                return Data("{\"ok\":true,\"protocol\":\"lan-phonebase\",\"version\":\"1.0\",\"accept\":\(n)}".utf8)
            }
            srv.onAccepted = { [weak self] count, ip in
                guard let self else { return }
                let tag = listenPort == self.usbPort ? "USB" : "LAN"
                // 探活/info 也会 accept：只刷新顶栏，不写运行日志（避免刷屏）
                self.onStatus?("有连接 #\(count) \(tag)")
            }
            srv.onVideoConnect = { [weak self] session, query in
                guard let self else { return }
                let tag = listenPort == self.usbPort ? "USB" : "LAN"
                let profile = VideoStreamProfile.from(query: query, defaults: VideoSettingsStore.shared.defaults)
                let preview = (query["preview"] == "1" || query["preview"]?.lowercased() == "true")
                let kind = preview ? "预览" : "大窗"
                self.appendConnLogThrottled("视频通道 \(kind) · \(tag)", key: "video|\(tag)|\(kind)")
                self.publisher.attach(session, profile: profile)
            }
            srv.onControlConnect = { [weak self] session in
                guard let self else { return }
                let tag = listenPort == self.usbPort ? "USB" : "LAN"
                self.appendConnLogThrottled("控制通道已连接 · \(tag)", key: "control|\(tag)")
                self.controlHub.attach(session)
            }
            srv.onControlAPI = { [weak self] path, query in
                self?.handleControlAPI(path: path, query: query) ?? Data(#"{"ok":false}"#.utf8)
            }
            srv.onVideoSettings = { [weak self] method, query, body in
                self?.handleVideoSettings(method: method, query: query, body: body)
                    ?? Data(#"{"ok":false}"#.utf8)
            }
            srv.onClipboardText = {
                let text = UIPasteboard.general.string ?? ""
                if text.utf8.count > 256_000 {
                    return Data(#"{"ok":false,"error":"CLIPBOARD_TOO_LARGE"}"#.utf8)
                }
                let body: [String: Any] = ["ok": true, "text": text]
                return (try? JSONSerialization.data(withJSONObject: body))
                    ?? Data(#"{"ok":false,"error":"CLIPBOARD_UNAVAILABLE"}"#.utf8)
            }
            srv.onRunLog = { [weak self] method, path in
                self?.handleRunLog(method: method, path: path)
                    ?? Data(#"{"ok":false,"error":"no-handler"}"#.utf8)
            }
        }
        wire(server)
        wire(usbServer)

        publisher.onTimestampUs = { [weak self] ts in
            self?.controlHub.latestFrameTimestampUs = ts
        }
        capture.onPixelBuffer = { [weak self] buffer, pts in
            self?.publisher.encode(buffer: buffer, presentationTime: pts)
        }

        MemoryGuard.shared.onSoftLimit = { [weak self] bytes in
            self?.degradeForMemory(bytes: bytes)
        }
        MemoryGuard.shared.onOverLimit = { [weak self] bytes in
            self?.handleMemoryHard(bytes: bytes)
        }
        MemoryGuard.shared.onRecovered = { [weak self] in
            self?.memoryGuardSticky = false
            self?.memHardStreak = 0
            self?.notify("内存护栏恢复 · 允许升画质")
        }
        MemoryGuard.shared.start()
        InterfaceOrientationWatch.bootstrap()
    }

    /// 软阈值：先降前景画质 + releaseUnusedMemory，避免一上来 softRestart 空转。
    private func degradeForMemory(bytes: UInt64, resetHardStreak: Bool = true) {
        memoryGuardSticky = true
        let cur = VideoSettingsStore.shared.defaults
        let need =
            cur.frameRate > 20 ||
            cur.bitrateBps > 2_000_000 ||
            cur.maxDimension == 0 ||
            cur.maxDimension > 720
        if need {
            let degraded = VideoStreamProfile(
                profile: "foreground",
                maxDimension: 720,
                frameRate: 20,
                bitrateBps: 2_000_000
            )
            _ = VideoSettingsStore.shared.apply(degraded)
            publisher.applyDefaultsFromSettings()
            notify("内存偏高 · 已降画质 20fps/2Mbps/720 footprint=\(bytes)")
        } else {
            notify("内存偏高 · 画质已是低档 footprint=\(bytes)")
        }
        releaseUnusedMemory(reason: "soft-limit")
        if resetHardStreak { memHardStreak = 0 }
        refreshMemoryGuardSticky()
    }

    /// 对齐样板 releaseUnusedMemory：拆池、清编码器积压、向 malloc 施压。
    private func releaseUnusedMemory(reason: String) {
        capture.stop(releasePool: true)
        capture.releasePixelBufferPool()
        publisher.discardPendingFrames()
        publisher.recycleEncoder(reason: "releaseUnused-\(reason)")
        malloc_zone_pressure_relief(nil, 0)
        URLCache.shared.removeAllCachedResponses()
        notify("releaseUnusedMemory · \(reason) footprint=\(MemoryGuard.physFootprint())")
        if isRunning {
            capture.start()
            setStreamingActive(true)
            publisher.requestKeyframe()
        }
    }

    private func refreshMemoryGuardSticky() {
        if MemoryGuard.physFootprint() < MemoryGuard.shared.softLimitBytes {
            memoryGuardSticky = false
        }
    }

    private func isEncodeUpgrade(_ next: VideoStreamProfile, from cur: VideoStreamProfile) -> Bool {
        if next.bitrateBps > cur.bitrateBps { return true }
        if next.frameRate > cur.frameRate { return true }
        if cur.maxDimension > 0, next.maxDimension == 0 { return true }
        if cur.maxDimension > 0, next.maxDimension > cur.maxDimension { return true }
        return false
    }

    private func hardExitForMemory(bytes: UInt64, reason: String) {
        notify("内存仍高 · 硬重启并由看门狗拉起 footprint=\(bytes) reason=\(reason)")
        MemoryGuard.shared.noteRestart(reason: reason)
        ProcessWatchdog.spawnDeferredRelaunch(delayMs: 1500)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            exit(0)
        }
    }

    /// 硬阈值：降质 + 真回收 softRestart；仍超或 ≥800MB → hard exit。
    private func handleMemoryHard(bytes: UInt64) {
        degradeForMemory(bytes: bytes, resetHardStreak: false)
        if bytes >= memVetoBytes {
            hardExitForMemory(bytes: bytes, reason: "memory-guard-veto-800")
            return
        }
        memHardStreak += 1
        // soft 路径先不 noteRestart，避免 15s 节流把后续硬退挡掉；硬退或软成功再记
        _ = softRestart(
            reason: "memory-guard",
            detail: "footprint=\(bytes) streak=\(memHardStreak)",
            note: false
        )
        let after = MemoryGuard.physFootprint()
        if after >= MemoryGuard.shared.limitBytes || memHardStreak >= 2 {
            hardExitForMemory(bytes: after, reason: "memory-guard-hard")
            return
        }
        MemoryGuard.shared.noteRestart(reason: "memory-guard-soft-ok")
        refreshMemoryGuardSticky()
    }

    private func handleRunLog(method: String, path: String) -> Data {
        if method == "POST", path == "/api/run-log/clear" {
            AppRunLog.shared.clear()
            return jsonOK(["cleared": true])
        }
        if method == "GET", path == "/api/run-log" {
            let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            return jsonOK([
                "version": ver,
                "text": AppRunLog.shared.snapshot(),
            ])
        }
        return Data(#"{"ok":false,"error":"not-found"}"#.utf8)
    }

    private func handleVideoSettings(method: String, query: [String: String], body: Data?) -> Data {
        if method == "GET", query.isEmpty, body == nil || body?.isEmpty == true {
            return jsonOK(VideoSettingsStore.shared.status)
        }
        var patch: [String: Any] = [:]
        if let body, !body.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        {
            patch = obj
        }
        for (k, v) in query { patch[k] = v }
        let cur = VideoSettingsStore.shared.defaults
        let next = VideoStreamProfile.from(json: patch, current: cur)
        refreshMemoryGuardSticky()
        let underPressure =
            memoryGuardSticky || MemoryGuard.physFootprint() >= MemoryGuard.shared.softLimitBytes
        if underPressure, isEncodeUpgrade(next, from: cur) {
            let fp = MemoryGuard.physFootprint()
            notify(
                "拒绝升画质 · 内存护栏中 footprint=\(fp) want=\(next.frameRate)fps/\(next.bitrateBps / 1000)kbps"
            )
            var out = VideoSettingsStore.shared.status
            out["ok"] = false
            out["rejected"] = true
            out["reason"] = "memory-guard"
            out["footprint"] = fp
            return (try? JSONSerialization.data(withJSONObject: out)) ?? Data(#"{"ok":false}"#.utf8)
        }
        let applied = VideoSettingsStore.shared.apply(next)
        DispatchQueue.main.async { [weak self] in
            self?.publisher.applyDefaultsFromSettings()
            self?.notify("画质已更新 · \(applied.frameRate)fps · \(applied.bitrateBps / 1000)kbps")
        }
        var out = VideoSettingsStore.shared.status
        out["ok"] = true
        return (try? JSONSerialization.data(withJSONObject: out)) ?? Data(#"{"ok":true}"#.utf8)
    }

    /// 对齐官方 soft restart：拆池 + 重建 capture/encoder，WS 不断
    @discardableResult
    func softRestart(reason: String, detail: String? = nil, note: Bool = true) -> Bool {
        if note {
            MemoryGuard.shared.noteRestart(reason: reason)
        }
        guard isRunning else {
            let ok = start(notifyStatus: true)
            notify("重启(\(reason)) → \(ok ? "已启动" : "失败")")
            return ok
        }
        releaseUnusedMemory(reason: reason)
        var msg = "已重启 · \(reason)"
        if let detail, !detail.isEmpty { msg += " · \(detail)" }
        notify(msg)
        return true
    }

    private func handleControlAPI(path: String, query: [String: String]) -> Data {
        switch path {
        case "/api/control/stop":
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return jsonOK(["action": "stop"])
        case "/api/control/restart":
            // hard=1 → exit，由 ProcessWatchdog 拉起（对齐崩溃路径）
            if query["hard"] == "1" || query["mode"] == "hard" {
                MemoryGuard.shared.noteRestart(reason: "control-hard")
                ProcessWatchdog.spawnDeferredRelaunch(delayMs: 1200)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    exit(0)
                }
                return jsonOK(["action": "restart", "mode": "hard"])
            }
            DispatchQueue.main.async { [weak self] in
                _ = self?.softRestart(reason: "control")
            }
            return jsonOK(["action": "restart", "mode": "soft"])
        case "/api/control/memory-guard":
            if let raw = query["enabled"] {
                let on = raw == "1" || raw.lowercased() == "true" || raw.lowercased() == "yes"
                MemoryGuard.shared.setEnabled(on)
            }
            return jsonOK(MemoryGuard.shared.status)
        default:
            return Data(#"{"ok":false,"error":"unknown"}"#.utf8)
        }
    }

    private func jsonOK(_ extra: [String: Any]) -> Data {
        var body: [String: Any] = ["ok": true]
        for (k, v) in extra { body[k] = v }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data(#"{"ok":true}"#.utf8)
    }

    private func startListeners() throws {
        try server.start()
        do {
            try usbServer.start()
        } catch {
            // USB 口失败不阻断 Wi‑Fi；数据线模式不可用
            NSLog("[Runtime] USB listen %u failed: %@", usbPort, "\(error)")
            usbServer.stop()
        }
    }

    @discardableResult
    func start(notifyStatus: Bool = true) -> Bool {
        guard !isRunning else { return true }
        let retired = PortOccupancy.retireOtherLocals()
        if !retired.killed.isEmpty {
            usleep(200_000)
        }
        do {
            try startListeners()
            capture.start()
            isRunning = true
            BackgroundKeepAlive.shared.start()
            setStreamingActive(true)
            if notifyStatus {
                notify(startupMessage(retired: retired.killed, extra: nil))
            }
            publisher.requestKeyframe()
            startOrientationWatch()
            return true
        } catch {
            let freed = PortOccupancy.freePort(port)
            _ = PortOccupancy.freePort(usbPort)
            usleep(200_000)
            do {
                try startListeners()
                capture.start()
                isRunning = true
                BackgroundKeepAlive.shared.start()
                setStreamingActive(true)
                if notifyStatus {
                    notify(startupMessage(retired: retired.killed + freed.killed, extra: "二次清理后启动 ✓"))
                }
                publisher.requestKeyframe()
                startOrientationWatch()
                return true
            } catch {
                if notifyStatus {
                    notify("启动失败: \(error)\n请点「释放端口占用」；若仍失败请卸载 Direct/旧基座后重开")
                }
                return false
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        stopOrientationWatch()
        capture.stop()
        publisher.detachAll()
        controlHub.detachAll()
        server.stop()
        usbServer.stop()
        isRunning = false
        BackgroundKeepAlive.shared.stop()
        notify("服务已停止")
    }

    private func startOrientationWatch() {
        stopOrientationWatch()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.publishCurrentOrientation()
        }
        // 后台时 orientation 通知常丢；轮询物理朝向（跟前台横屏 App，不是本 App 的 scene）
        let poll = DispatchSource.makeTimerSource(queue: .main)
        poll.schedule(deadline: .now() + 0.5, repeating: 0.75)
        poll.setEventHandler { [weak self] in self?.publishCurrentOrientation() }
        poll.resume()
        orientationPoll = poll
        publishCurrentOrientation()
    }

    private func stopOrientationWatch() {
        orientationPoll?.cancel()
        orientationPoll = nil
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
            self.orientationObserver = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    private func publishCurrentOrientation() {
        // FBS 跟前台 App 界面朝向；无则 UIDevice（巨魔环境默认有 FBS）
        let next = InterfaceOrientationWatch.currentRaw(fallbackLast: lastPublishedOrientation)
        guard next != lastPublishedOrientation else { return }
        lastPublishedOrientation = next
        controlHub.publishOrientation(next)
        geometryRevision += 1
        NSLog("[Runtime] orientation=%d", next)
    }

    func setStreamingActive(_ active: Bool) {
        capture.setActive(active)
        publisher.setPublisherOnline(active && isRunning)
        if active && isRunning {
            publisher.requestKeyframe()
        }
    }

    /// 同步文本到已连接的 PC 控制通道（写电脑剪贴板）
    func pushClipboardToPC(_ text: String) {
        controlHub.broadcastClipboard(text)
    }

    private func startupMessage(retired: [String], extra: String?) -> String {
        let ips = LanAddress.ipv4List().joined(separator: ", ")
        var msg = "服务已启动 · \(ips.isEmpty ? "无IP" : ips):\(port)"
        msg += "\nUSB=\(usbPort) (phonebase-usb-v1)"
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        msg += "\nbuild=\(ver)(\(build))"
        msg += "\ncapture=\(capture.backendName) encode=\(encodeW)x\(encodeH)"
        msg += "\ndeviceId=\(cachedDeviceId)"
        msg += "\nmemoryGuard=\(MemoryGuard.shared.automatic ? "on" : "off")"
        let vs = VideoSettingsStore.shared.defaults
        msg += "\nvideo=\(vs.frameRate)fps/\(vs.bitrateBps / 1000)kbps"
        if let extra, !extra.isEmpty { msg += "\n\(extra)" }
        if !retired.isEmpty {
            msg += "\n已结束旧版：\(retired.joined(separator: ", "))"
        }
        if !capture.lastError.isEmpty {
            msg += "\ncaptureErr=\(capture.lastError)"
        }
        return msg
    }

    private func notify(_ text: String) {
        AppRunLog.shared.append(text)
        onStatus?(text)
    }

    /// 同类事件至少间隔 connLogMinInterval，避免刷屏。
    private func appendConnLogThrottled(_ line: String, key: String) {
        let now = Date()
        if let last = lastConnLogAt[key], now.timeIntervalSince(last) < connLogMinInterval {
            return
        }
        lastConnLogAt[key] = now
        if lastConnLogAt.count > 24 {
            let cutoff = now.addingTimeInterval(-connLogMinInterval * 3)
            lastConnLogAt = lastConnLogAt.filter { $0.value >= cutoff }
        }
        AppRunLog.shared.append(line)
    }

    private func infoJSON(listenPort: UInt16) -> Data {
        let w = screenWidth
        let h = screenHeight
        let viaUsb = listenPort == usbPort
        var body: [String: Any] = [
            "protocol": "lan-phonebase",
            "version": "1.0",
            "deviceId": cachedDeviceId,
            "name": cachedName,
            "port": Int(listenPort),
            "streaming": capture.isActive,
            "captureBackend": capture.backendName,
            "captureState": capture.isActive ? "capturing" : "idle",
            "captureError": capture.lastError,
            "frames": capture.renderedFrames,
            "poolBusySkips": capture.poolBusySkips,
            "memoryGuardSticky": memoryGuardSticky,
            "width": w,
            "height": h,
            "controlAvailable": true,
            "homeAvailable": true,
            "textAvailable": hidReady,
            "keyboardAvailable": hidReady,
            "wallVideo": true,
            "licenseRequired": false,
            // 能力宣告：Wi‑Fi info 也带上，便于桌面识别可 USB
            "usbSupported": true,
            "usbProtocol": "phonebase-usb-v1",
            "usbPort": Int(usbPort),
            "encoder": publisher.encoderStats,
            "videoSettings": VideoSettingsStore.shared.status,
            "memoryGuard": MemoryGuard.shared.status,
            "release": [
                "product": "local",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
                "buildId": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            ],
            "geometry": [
                "width": w,
                "height": h,
                "sourceWidth": w,
                "sourceHeight": h,
                "orientation": lastPublishedOrientation,
                "revision": geometryRevision,
                "changedAtUs": Int(Date().timeIntervalSince1970 * 1_000_000),
            ],
        ]
        if viaUsb {
            body["usbTransport"] = true
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
    }
}
