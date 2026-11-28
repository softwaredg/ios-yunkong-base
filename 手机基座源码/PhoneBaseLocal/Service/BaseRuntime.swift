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
    /// memory-guard 软续服连击：多次仍超硬阈才硬退；≥800MB 一票否决
    private var memHardStreak = 0
    private let memSoftBeforeHard = 5
    /// ≥800MB 一票否决：跳过软重启直接硬退
    private let memVetoBytes: UInt64 = 800 * 1024 * 1024
    private var memMetricsTimer: DispatchSourceTimer?
    private var lastMemMetricsAt: Date?

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

        MemoryGuard.shared.onTrim = { [weak self] bytes in
            self?.handleMemoryTrim(bytes: bytes)
        }
        MemoryGuard.shared.onOverLimit = { [weak self] bytes in
            self?.handleMemoryHard(bytes: bytes)
        }
        MemoryGuard.shared.onRecovered = { [weak self] in
            self?.memHardStreak = 0
            VideoSettingsStore.shared.setPressureTrimmed(false)
            self?.syncCaptureRateFromSettings()
            self?.publisher.applyDefaultsFromSettings()
            self?.notify("内存护栏恢复 · 允许升画质")
        }
        MemoryGuard.shared.start()
        // start() 之后再同步两端 trim 标记（看门狗拉起后继续有效档封顶）
        if MemoryGuard.shared.trimmedForPressure {
            VideoSettingsStore.shared.setPressureTrimmed(true)
        } else if VideoSettingsStore.shared.isPressureTrimmed {
            MemoryGuard.shared.setTrimmedForPressure(true)
        }
        syncCaptureRateFromSettings()
        startMemMetricsTimer()
        InterfaceOrientationWatch.bootstrap()
    }

    /// 长连诊断：clients/lanes/footprint，便于确认泄漏是否收敛
    private func startMemMetricsTimer() {
        if memMetricsTimer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in self?.logMemMetricsIfDue() }
        t.resume()
        memMetricsTimer = t
    }

    private func logMemMetricsIfDue() {
        guard isRunning else { return }
        let now = Date()
        if let last = lastMemMetricsAt, now.timeIntervalSince(last) < 60 { return }
        lastMemMetricsAt = now
        let counts = publisher.sessionCounts
        let fp = MemoryGuard.physFootprint()
        AppRunLog.shared.append(
            "mem · footprint=\(fp) clients=\(counts.clients) lanes=\(counts.lanes) poolBusy=\(capture.poolBusySkips)"
        )
    }

    /// 样板 trimmedForPressure：只压有效档一次，不刷 soft 日志。
    private func handleMemoryTrim(bytes: UInt64) {
        let already = VideoSettingsStore.shared.isPressureTrimmed
        VideoSettingsStore.shared.setPressureTrimmed(true)
        MemoryGuard.shared.setTrimmedForPressure(true)
        publisher.applyDefaultsFromSettings()
        syncCaptureRateFromSettings()
        if already {
            return
        }
        notify("内存偏高 · 已压画质(有效档) 30fps/3Mbps/720 footprint=\(bytes)")
        releaseUnusedMemory(reason: "trim")
        memHardStreak = 0
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
            syncCaptureRateFromSettings()
            capture.start()
            setStreamingActive(true)
            capture.requestForceFrame()
            publisher.requestKeyframe()
        }
    }

    private func syncCaptureRateFromSettings() {
        // 采集固定 60Hz；各路编码在 FramePublisher 按 lane.frameRate 对 60 抽帧。
        // 若采集也跟 settings 限到 30，再 stride=60/30，大窗会变成约 15fps（实测 ~12）。
        capture.setTargetFrameRate(60)
    }

    private var trimmedForPressure: Bool {
        MemoryGuard.shared.trimmedForPressure || VideoSettingsStore.shared.isPressureTrimmed
    }

    private func isEncodeUpgrade(_ next: VideoStreamProfile, from cur: VideoStreamProfile) -> Bool {
        if next.bitrateBps > cur.bitrateBps { return true }
        if next.frameRate > cur.frameRate { return true }
        if cur.maxDimension > 0, next.maxDimension == 0 { return true }
        if cur.maxDimension > 0, next.maxDimension > cur.maxDimension { return true }
        return false
    }

    private func hardExitForMemory(bytes: UInt64, reason: String) {
        MemoryGuard.shared.markRestarting()
        notify(
            "内存仍高 · 硬重启并由看门狗拉起 footprint=\(bytes) reason=\(reason) streak=\(memHardStreak)"
        )
        MemoryGuard.shared.noteRestart(reason: reason)
        // 对齐样板 scheduleRestart → 听口完成再 shutdownWithCode：
        // 必须等 Helper 真正听 11019 再 exit；失败则清掉僵 Helper，主进程续服（勿盲退留空窗）。
        let handed = ProcessWatchdog.spawnDeferredRelaunch(delayMs: 800, waitHealthy: true)
        if handed {
            AppRunLog.shared.append(
                "硬重启移交成功 · Helper 已听 11019 · 主进程退出 reason=\(reason) footprint=\(bytes)"
            )
            AppRunLog.shared.flush()
            exit(0)
        }
        let tipaOk = HelperLauncher.tipaHealthy(expectVersion: "")
        AppRunLog.shared.append(
            "硬重启移交失败 · 主进程软恢复续服 reason=\(reason) footprint=\(bytes) streak=\(memHardStreak) tipaHealthy=\(tipaOk ? 1 : 0)"
        )
        AppRunLog.shared.flush()
        HelperLauncher.terminateHelper()
        usleep(200_000)
        MemoryGuard.shared.markWaitingIdle()
        memHardStreak = 0
        if isRunning {
            _ = softRestart(reason: "memory-guard-hard-fallback", note: false)
        } else {
            let ok = start(notifyStatus: true)
            notify(ok ? "硬重启回退 · 主进程已续服" : "硬重启回退失败 · 请手动打开基座")
        }
    }

    /// 硬阈：release 软续服（不断听口）→ 多次仍超 / 800MB veto 才硬退。
    private func handleMemoryHard(bytes: UInt64) {
        if !VideoSettingsStore.shared.isPressureTrimmed {
            handleMemoryTrim(bytes: bytes)
        }
        if bytes >= memVetoBytes {
            hardExitForMemory(bytes: bytes, reason: "memory-guard-veto-800")
            return
        }
        if injector.controlInputPending {
            MemoryGuard.shared.markWaitingIdle()
            return
        }
        memHardStreak += 1
        releaseUnusedMemory(reason: "memory-guard")
        let after = MemoryGuard.physFootprint()
        if after >= memVetoBytes {
            hardExitForMemory(bytes: after, reason: "memory-guard-veto-800")
            return
        }
        // 软续服优先：拆池/重建编码器但保持 HTTP/WS，避免客户长空窗
        MemoryGuard.shared.noteRestart(reason: "memory-guard-soft-ok")
        notify("已软续服 · memory-guard · footprint=\(bytes)→\(after) streak=\(memHardStreak)")
        logMemMetricsIfDue()
        if after < MemoryGuard.shared.memoryLimitBytes {
            memHardStreak = 0
            return
        }
        if memHardStreak >= memSoftBeforeHard {
            hardExitForMemory(bytes: after, reason: "memory-guard-hard")
        }
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
        let cur = VideoSettingsStore.shared.requested
        let next = VideoStreamProfile.from(json: patch, current: cur)
        let underPressure =
            trimmedForPressure
            || MemoryGuard.physFootprint() >= MemoryGuard.shared.trimThresholdBytes
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
        let prev = VideoSettingsStore.shared.defaults
        let applied = VideoSettingsStore.shared.apply(next)
        let unchanged =
            applied.frameRate == prev.frameRate
            && applied.bitrateBps == prev.bitrateBps
            && applied.maxDimension == prev.maxDimension
        if !unchanged {
            DispatchQueue.main.async { [weak self] in
                self?.publisher.applyDefaultsFromSettings()
                self?.syncCaptureRateFromSettings()
                self?.notify("画质已更新 · \(applied.frameRate)fps · \(applied.bitrateBps / 1000)kbps")
            }
        }
        var out = VideoSettingsStore.shared.status
        out["ok"] = true
        out["unchanged"] = unchanged
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
            // hard=1 → 先把服务交给 Helper，确认听口后再 exit；失败则软恢复。
            if query["hard"] == "1" || query["mode"] == "hard" {
                MemoryGuard.shared.markRestarting()
                MemoryGuard.shared.noteRestart(reason: "control-hard")
                let handed = ProcessWatchdog.spawnDeferredRelaunch(delayMs: 800, waitHealthy: true)
                if handed {
                    AppRunLog.shared.append("control-hard：Helper 已听口，主进程即将退出")
                    AppRunLog.shared.flush()
                    DispatchQueue.main.async { exit(0) }
                    return jsonOK(["action": "restart", "mode": "hard", "handedOff": true])
                }
                AppRunLog.shared.append("control-hard：Helper 未就绪，改为软重启")
                HelperLauncher.terminateHelper()
                usleep(200_000)
                MemoryGuard.shared.markWaitingIdle()
                DispatchQueue.main.async { [weak self] in
                    _ = self?.softRestart(reason: "control-hard-fallback")
                }
                return jsonOK(["action": "restart", "mode": "soft", "handedOff": false])
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
            syncCaptureRateFromSettings()
            capture.start()
            isRunning = true
            BackgroundKeepAlive.shared.start()
            setStreamingActive(true)
            if notifyStatus {
                notify(startupMessage(retired: retired.killed, extra: nil))
            }
            capture.requestForceFrame()
            publisher.requestKeyframe()
            startOrientationWatch()
            return true
        } catch {
            let freed = PortOccupancy.freePort(port)
            _ = PortOccupancy.freePort(usbPort)
            usleep(200_000)
            do {
                try startListeners()
                syncCaptureRateFromSettings()
                capture.start()
                isRunning = true
                BackgroundKeepAlive.shared.start()
                setStreamingActive(true)
                if notifyStatus {
                    notify(startupMessage(retired: retired.killed + freed.killed, extra: "二次清理后启动 ✓"))
                }
                capture.requestForceFrame()
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
            "unchangedSkips": capture.unchangedSkips,
            "pacingSkips": capture.pacingSkips,
            "trimmedForPressure": trimmedForPressure,
            "memoryGuardSticky": trimmedForPressure,
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
