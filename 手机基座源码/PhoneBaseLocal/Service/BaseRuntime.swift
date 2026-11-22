import Foundation
import UIKit

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
                let tag = listenPort == self?.usbPort ? "USB" : "LAN"
                self?.notify("有连接 #\(count) \(tag) from \(ip)")
            }
            srv.onVideoConnect = { [weak self] session, query in
                guard let self else { return }
                let profile = VideoStreamProfile.from(query: query, defaults: VideoSettingsStore.shared.defaults)
                self.publisher.attach(session, profile: profile)
            }
            srv.onControlConnect = { [weak self] session in
                self?.controlHub.attach(session)
            }
            srv.onControlAPI = { [weak self] path, query in
                self?.handleControlAPI(path: path, query: query) ?? Data(#"{"ok":false}"#.utf8)
            }
            srv.onVideoSettings = { [weak self] method, query, body in
                self?.handleVideoSettings(method: method, query: query, body: body)
                    ?? Data(#"{"ok":false}"#.utf8)
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

        MemoryGuard.shared.onOverLimit = { [weak self] bytes in
            self?.softRestart(reason: "memory-guard", detail: "footprint=\(bytes)")
        }
        MemoryGuard.shared.start()
        InterfaceOrientationWatch.bootstrap()
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
        let next = VideoStreamProfile.from(json: patch, current: VideoSettingsStore.shared.defaults)
        let applied = VideoSettingsStore.shared.apply(next)
        DispatchQueue.main.async { [weak self] in
            self?.publisher.applyDefaultsFromSettings()
            self?.notify("画质已更新 · \(applied.frameRate)fps · \(applied.bitrateBps / 1000)kbps")
        }
        // 对齐商业 Kc：返回完整 phonebase-video-settings v1 字段
        var out = VideoSettingsStore.shared.status
        out["ok"] = true
        return (try? JSONSerialization.data(withJSONObject: out)) ?? Data(#"{"ok":true}"#.utf8)
    }

    /// 对齐官方 soft restart：重建 capture/encoder，WS 不断
    @discardableResult
    func softRestart(reason: String, detail: String? = nil) -> Bool {
        MemoryGuard.shared.noteRestart(reason: reason)
        guard isRunning else {
            let ok = start(notifyStatus: true)
            notify("重启(\(reason)) → \(ok ? "已启动" : "失败")")
            return ok
        }
        capture.stop()
        publisher.recycleEncoder(reason: reason)
        capture.start()
        setStreamingActive(true)
        publisher.requestKeyframe()
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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
