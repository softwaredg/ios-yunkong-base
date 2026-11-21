import Foundation
import CoreVideo
import CoreMedia
import CoreImage

final class FramePublisher {
    private let sourceW: Int
    private let sourceH: Int
    private let lock = NSLock()
    private let encodeQueue = DispatchQueue(label: "cn.local.phonebase.publish.encode", qos: .userInteractive)
    private var clients: [Client] = []
    private var lanes: [String: Lane] = [:]
    private var frameSerial: Int64 = 0
    private var pendingEncode: (CVPixelBuffer, CMTime)?
    private var encodeScheduled = false
    var onTimestampUs: ((UInt64) -> Void)?

    /// 兼容 info.encoder；tryLock 避免与 encode 死锁堵死 /api/info
    var encoderStats: [String: Any] {
        guard lock.`try`() else {
            return ["ready": false, "busy": true, "width": sourceW, "height": sourceH]
        }
        defer { lock.unlock() }
        if let lane = lanes.values.first(where: { !$0.profile.isWall }) ?? lanes.values.first {
            var s = lane.encoder.stats
            s["lane"] = lane.profile.key
            s["clients"] = clients.count
            return s
        }
        return [
            "ready": false,
            "width": sourceW,
            "height": sourceH,
            "clients": clients.count,
        ]
    }

    private final class Client {
        let session: WebSocketSession
        var profile: VideoStreamProfile
        /// 对齐官方 _dropUntilKeyframe：发送背压后只等关键帧，期间丢弃 delta
        var congested = false
        var lastKeyRequestMs: UInt64 = 0
        /// 对齐 discardUnsentVideo：尚未开写的出站视频帧可整帧丢弃/替换
        var pendingVideo: Data?
        var pendingIsKeyframe = false
        var healthySinceMs: UInt64 = 0
        init(session: WebSocketSession, profile: VideoStreamProfile) {
            self.session = session
            self.profile = profile
        }
    }

    private final class Lane {
        let profile: VideoStreamProfile
        let encodeW: Int
        let encodeH: Int
        let encoder: H264Encoder
        var lastConfig: Data?
        var lastEmitSerial: Int64 = 0
        private(set) var started = false
        weak var owner: FramePublisher?

        init(profile: VideoStreamProfile, sourceW: Int, sourceH: Int, owner: FramePublisher) {
            self.profile = profile
            let size = profile.encodeSize(sourceW: sourceW, sourceH: sourceH)
            self.encodeW = size.0
            self.encodeH = size.1
            self.encoder = H264Encoder(
                width: encodeW,
                height: encodeH,
                bitrateBps: profile.bitrateBps,
                frameRate: profile.frameRate
            )
            self.owner = owner
            let key = profile.key
            encoder.onConfig = { [weak self] avcC in
                self?.lastConfig = avcC
                self?.owner?.broadcastConfig(avcC, laneKey: key)
            }
            encoder.onFrame = { [weak self] avcc, keyframe, ts in
                self?.owner?.broadcastFrame(avcc: avcc, keyframe: keyframe, timestampUs: ts, laneKey: key)
            }
            // 注意：禁止在 FramePublisher.lock 内 start（VT 回调会再抢锁 → 死锁）
        }

        func startIfNeeded() {
            guard !started else { return }
            started = true
            try? encoder.start()
        }
    }

    init(width: Int, height: Int) {
        sourceW = max(2, width - (width % 2))
        sourceH = max(2, height - (height % 2))
    }

    func attach(_ session: WebSocketSession, profile: VideoStreamProfile? = nil) {
        let p = profile ?? VideoSettingsStore.shared.defaults
        lock.lock()
        let client = Client(session: session, profile: p)
        clients.append(client)
        let lane = ensureLaneLocked(p)
        let cfg = lane?.lastConfig
        lock.unlock()

        lane?.startIfNeeded()
        session.sendText(#"{"type":"publisher","online":true}"#)
        if let cfg {
            _ = session.sendBinary(PHB1.packet(flags: .configuration, timestampUs: 0, payload: cfg))
        } else {
            lane?.encoder.resetConfigFlag()
        }
        lane?.encoder.forceKeyFrame()

        session.onClose = { [weak self, weak session] in
            guard let self, let session else { return }
            var stopped: [Lane] = []
            self.lock.lock()
            self.clients.removeAll { $0.session === session }
            stopped = self.pruneLanesLocked()
            self.lock.unlock()
            stopped.forEach { $0.encoder.stop() }
        }
    }

    func detachAll() {
        lock.lock()
        let copy = clients
        clients.removeAll()
        let oldLanes = Array(lanes.values)
        lanes.removeAll()
        lock.unlock()
        copy.forEach { $0.session.close() }
        oldLanes.forEach { $0.encoder.stop() }
    }

    func setPublisherOnline(_ online: Bool) {
        let json = #"{"type":"publisher","online":\#(online ? "true" : "false")}"#
        lock.lock()
        let copy = clients
        if !online {
            for lane in lanes.values {
                lane.lastConfig = nil
                lane.encoder.resetConfigFlag()
            }
        }
        lock.unlock()
        copy.forEach { _ = $0.session.sendText(json) }
    }

    func encode(buffer: CVPixelBuffer, presentationTime: CMTime) {
        // 采集在主线程；缩放+双路编码挪到 encodeQueue，latest-wins，避免墙流拖死大窗/主线程
        lock.lock()
        pendingEncode = (buffer, presentationTime)
        let needSchedule = !encodeScheduled
        if needSchedule { encodeScheduled = true }
        lock.unlock()
        guard needSchedule else { return }
        encodeQueue.async { [weak self] in self?.drainEncode() }
    }

    private func drainEncode() {
        while true {
            lock.lock()
            guard let pending = pendingEncode else {
                encodeScheduled = false
                lock.unlock()
                return
            }
            pendingEncode = nil
            frameSerial += 1
            let serial = frameSerial
            let active = Dictionary(grouping: clients, by: { $0.profile.key })
            var work: [Lane] = []
            var toStart: [Lane] = []
            for (key, group) in active {
                let existed = lanes[key] != nil
                guard let lane = lanes[key] ?? ensureLaneLocked(group[0].profile) else { continue }
                if !existed { toStart.append(lane) }
                let fps = max(5, lane.profile.frameRate)
                let stride = max(1, Int((60.0 / Double(fps)).rounded()))
                let due = serial - lane.lastEmitSerial >= Int64(stride) || lane.lastEmitSerial == 0
                if due {
                    lane.lastEmitSerial = serial
                    work.append(lane)
                }
            }
            // 大窗优先：先 foreground 再 wall，减少双开时墙流抢 VT/缩放把大窗拖卡
            work.sort { a, b in
                let aw = a.profile.isWall
                let bw = b.profile.isWall
                if aw != bw { return !aw && bw }
                return a.profile.key < b.profile.key
            }
            lock.unlock()

            // start 必须在 unlock 之后，否则 VT 回调抢锁死锁 → /api/info 永久卡住
            toStart.forEach { $0.startIfNeeded() }
            work.forEach { $0.startIfNeeded() }

            let buffer = pending.0
            let presentationTime = pending.1
            for lane in work {
                let buf: CVPixelBuffer
                if CVPixelBufferGetWidth(buffer) == lane.encodeW,
                   CVPixelBufferGetHeight(buffer) == lane.encodeH
                {
                    buf = buffer
                } else if let scaled = PixelBufferScaler.scale(buffer, width: lane.encodeW, height: lane.encodeH) {
                    buf = scaled
                } else {
                    continue
                }
                lane.encoder.encode(buffer: buf, presentationTime: presentationTime)
            }
        }
    }

    func requestKeyframe() {
        lock.lock()
        let all = Array(lanes.values)
        lock.unlock()
        all.forEach { $0.encoder.forceKeyFrame() }
    }

    func recycleEncoder(reason: String) {
        NSLog("[Publisher] recycleEncoder %@", reason)
        lock.lock()
        let profiles = Array(Set(clients.map(\.profile)))
        let old = Array(lanes.values)
        lanes.removeAll()
        var fresh: [Lane] = []
        for p in profiles {
            if let lane = ensureLaneLocked(p) { fresh.append(lane) }
        }
        if fresh.isEmpty, let lane = ensureLaneLocked(VideoSettingsStore.shared.defaults) {
            fresh.append(lane)
        }
        lock.unlock()
        fresh.forEach { $0.startIfNeeded() }
        old.forEach { $0.encoder.stop() }
        requestKeyframe()
    }

    func applyDefaultsFromSettings() {
        let d = VideoSettingsStore.shared.defaults
        lock.lock()
        for c in clients where !c.profile.isWall {
            c.profile = d
        }
        lock.unlock()
        // 用户改 /api/video-settings：重建前景车道（profile.key 含码率/帧率）
        recycleEncoder(reason: "video-settings")
    }

    /// ABR 热更新：前景跟 settings；墙流按自身档位 × permille（小窗背压也要降峰）
    private func applyEffectiveBitrateToLanesLocked() {
        let permille = VideoSettingsStore.shared.networkBitratePermilleValue()
        let d = VideoSettingsStore.shared.defaults
        for lane in lanes.values {
            if lane.profile.isWall {
                let br = max(400_000, lane.profile.bitrateBps * permille / 1000)
                lane.encoder.updateRate(bitrateBps: br, frameRate: lane.profile.frameRate)
            } else {
                lane.encoder.updateRate(bitrateBps: d.bitrateBps, frameRate: d.frameRate)
            }
        }
    }

    /// 对齐官方 networkBitratePermille：有客户端背压则降码率，恢复后抬回
    private func refreshNetworkBitrateLocked(nowMs: UInt64) {
        let anyCongested = clients.contains(where: \.congested)
        let cur = VideoSettingsStore.shared.networkBitratePermilleValue()
        if anyCongested {
            let next = max(400, cur - 150)
            if next != cur {
                VideoSettingsStore.shared.setNetworkBitratePermille(next)
                applyEffectiveBitrateToLanesLocked()
            }
            return
        }
        // 连续健康 ≥2s 再抬升，避免抖动
        if clients.contains(where: { $0.healthySinceMs != 0 && nowMs &- $0.healthySinceMs >= 2000 }), cur < 1000 {
            let next = min(1000, cur + 100)
            VideoSettingsStore.shared.setNetworkBitratePermille(next)
            applyEffectiveBitrateToLanesLocked()
        }
    }

    /// 对齐 discardUnsentVideo：发送前丢掉未开写的旧视频帧；关键帧清空积压
    private func enqueueOrSend(_ client: Client, packet: Data, keyframe: Bool, lane: Lane?) {
        if keyframe {
            client.pendingVideo = nil
            client.pendingIsKeyframe = false
        } else if client.pendingVideo != nil {
            // 旧 delta 未发出 → 丢弃（官方 offset==0 的 video 帧）
            client.pendingVideo = nil
            client.pendingIsKeyframe = false
        }
        if client.session.sendBinary(packet) {
            client.congested = false
            if client.healthySinceMs == 0 {
                client.healthySinceMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
            }
            return
        }
        client.congested = true
        client.healthySinceMs = 0
        // 发不动：只挂起最新一帧，等待下一轮或自然关键帧
        client.pendingVideo = packet
        client.pendingIsKeyframe = keyframe
        // 墙流优先等自然 1s GOP，避免每秒 force IDR 造成小窗规律卡顿；≥2s 仍堵再兜底
        requestKeyframeIfNeeded(client, lane: lane, urgent: keyframe)
    }

    private func requestKeyframeIfNeeded(_ client: Client, lane: Lane?, urgent: Bool) {
        let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        let waitMs: UInt64 = client.profile.isWall ? 2000 : 1000
        guard urgent || nowMs &- client.lastKeyRequestMs >= waitMs else { return }
        client.lastKeyRequestMs = nowMs
        lane?.encoder.forceKeyFrame()
    }

    @discardableResult
    private func ensureLaneLocked(_ profile: VideoStreamProfile) -> Lane? {
        if let existing = lanes[profile.key] { return existing }
        let lane = Lane(profile: profile, sourceW: sourceW, sourceH: sourceH, owner: self)
        lanes[profile.key] = lane
        NSLog(
            "[Publisher] lane %@ %dx%d fps=%d br=%d",
            profile.key, lane.encodeW, lane.encodeH, profile.frameRate, profile.bitrateBps
        )
        return lane
    }

    /// 返回需要 stop 的车道（调用方在 unlock 后 stop）
    private func pruneLanesLocked() -> [Lane] {
        let live = Set(clients.map(\.profile.key))
        let drop = lanes.keys.filter { !live.contains($0) }
        var stopped: [Lane] = []
        for k in drop {
            if let lane = lanes.removeValue(forKey: k) {
                stopped.append(lane)
            }
        }
        return stopped
    }

    private func broadcastConfig(_ avcC: Data, laneKey: String) {
        lock.lock()
        let targets = clients.filter { $0.profile.key == laneKey }
        lock.unlock()
        let packet = PHB1.packet(flags: .configuration, timestampUs: 0, payload: avcC)
        for c in targets {
            _ = c.session.sendBinary(packet)
        }
    }

    private func broadcastFrame(avcc: Data, keyframe: Bool, timestampUs: UInt64, laneKey: String) {
        onTimestampUs?(timestampUs)
        let packet = PHB1.packet(flags: keyframe ? .keyframe : .delta, timestampUs: timestampUs, payload: avcc)
        lock.lock()
        let targets = clients.filter { $0.profile.key == laneKey }
        let lane = lanes[laneKey]
        let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        for c in targets {
            // 先尝试刷出挂起帧（discardUnsent 后只留最新）
            if let pending = c.pendingVideo {
                if c.session.sendBinary(pending) {
                    c.pendingVideo = nil
                    c.pendingIsKeyframe = false
                    c.congested = false
                    if c.healthySinceMs == 0 { c.healthySinceMs = nowMs }
                } else {
                    c.congested = true
                    c.healthySinceMs = 0
                }
            }
            if c.congested && !keyframe {
                // discardUnsent：背压期间丢掉未发出的旧 delta，避免排队变旧画面
                if c.pendingVideo != nil, !c.pendingIsKeyframe {
                    c.pendingVideo = nil
                }
                // dropUntilKeyframe：等自然 GOP；墙流 ≥2s / 前景 ≥1s 仍堵再 force
                requestKeyframeIfNeeded(c, lane: lane, urgent: false)
                continue
            }
            enqueueOrSend(c, packet: packet, keyframe: keyframe, lane: lane)
        }
        refreshNetworkBitrateLocked(nowMs: nowMs)
        lock.unlock()
    }
}

enum PixelBufferScaler {
    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    static func scale(_ src: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        let w = max(2, width - (width % 2))
        let h = max(2, height - (height % 2))
        var dst: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let st = CVPixelBufferCreate(
            kCFAllocatorDefault, w, h,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &dst
        )
        guard st == kCVReturnSuccess, let dst else { return nil }
        let image = CIImage(cvPixelBuffer: src)
        let sx = CGFloat(w) / CGFloat(CVPixelBufferGetWidth(src))
        let sy = CGFloat(h) / CGFloat(CVPixelBufferGetHeight(src))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        ci.render(scaled, to: dst)
        return dst
    }
}
