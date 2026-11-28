import Foundation

/// 对齐官方 wall/foreground 画质档：`/video?profile=wall&maxDimension=&frameRate=` + `/api/video-settings`
struct VideoStreamProfile: Hashable {
    var profile: String // foreground | wall
    var maxDimension: Int // 0 = 全分辨率
    var frameRate: Int
    var bitrateBps: Int

    /// 对齐样板大窗：全分辨率 6Mbps@60；内存靠 MemoryGuard 临时降质，不永久砍默认。
    static let foregroundDefault = VideoStreamProfile(
        profile: "foreground",
        maxDimension: 0,
        frameRate: 60,
        bitrateBps: 6_000_000
    )

    var key: String {
        if profile == "wall" {
            return "wall:\(maxDimension)@\(frameRate)@\(bitrateBps)"
        }
        return "fg:\(maxDimension)@\(frameRate)@\(bitrateBps)"
    }

    var isWall: Bool { profile == "wall" }

    var bitrateMbps: Int { max(1, (bitrateBps + 500_000) / 1_000_000) }

    static func from(query: [String: String], defaults: VideoStreamProfile) -> VideoStreamProfile {
        let rawProfile = (query["profile"] ?? "foreground").lowercased()
        if rawProfile != "wall" {
            var next = defaults
            next.profile = "foreground"
            if let dim = Int(query["maxDimension"] ?? ""), dim > 0 {
                next.maxDimension = clamp(dim, 128, 1280)
            }
            if let fps = Int(query["frameRate"] ?? ""), fps > 0 {
                next.frameRate = clamp(fps, 5, 60)
            }
            if let mbps = Double(query["bitrateMbps"] ?? "") {
                next.bitrateBps = clamp(Int(mbps * 1_000_000), 400_000, 20_000_000)
            } else if let bps = Int(query["bitrateBps"] ?? "") {
                next.bitrateBps = clamp(bps, 400_000, 20_000_000)
            }
            return next
        }
        let dim = clamp(Int(query["maxDimension"] ?? "") ?? 384, 128, 1280)
        let fps = Int(query["frameRate"] ?? "") ?? 15
        let frameRate = fps >= 20 ? 20 : 15
        let bitrate: Int
        if let mbps = Double(query["bitrateMbps"] ?? "") {
            bitrate = Int(mbps * 1_000_000)
        } else if let bps = Int(query["bitrateBps"] ?? "") {
            bitrate = bps
        } else {
            bitrate = dim >= 768 ? 4_000_000 : dim >= 512 ? 2_500_000 : 1_500_000
        }
        return VideoStreamProfile(
            profile: "wall",
            maxDimension: dim,
            frameRate: frameRate,
            bitrateBps: clamp(bitrate, 400_000, 20_000_000)
        )
    }

    static func from(json: [String: Any], current: VideoStreamProfile) -> VideoStreamProfile {
        var next = current
        if let p = json["profile"] as? String, p.lowercased() == "wall" {
            next.profile = "wall"
        } else if json["profile"] != nil {
            next.profile = "foreground"
        }
        if let d = intVal(json["maxDimension"]) {
            if next.profile == "wall" {
                next.maxDimension = clamp(d, 128, 1280)
            } else {
                next.maxDimension = d > 0 ? clamp(d, 128, 1280) : 0
            }
        }
        if let f = intVal(json["frameRate"]) {
            next.frameRate = clamp(f, 5, 60)
        }
        if let mbps = numVal(json["bitrateMbps"]) {
            next.bitrateBps = clamp(Int(mbps * 1_000_000), 400_000, 20_000_000)
        } else if let bps = intVal(json["bitrateBps"]) {
            next.bitrateBps = clamp(bps, 400_000, 20_000_000)
        }
        return next
    }

    var json: [String: Any] {
        [
            "profile": profile,
            "maxDimension": maxDimension,
            "frameRate": frameRate,
            "bitrateBps": bitrateBps,
            "bitrateMbps": bitrateMbps,
        ]
    }

    /// 在源尺寸上按 maxDimension 等比缩小（偶数）；墙流与前景大窗共用。
    func encodeSize(sourceW: Int, sourceH: Int) -> (Int, Int) {
        let w0 = max(2, sourceW - (sourceW % 2))
        let h0 = max(2, sourceH - (sourceH % 2))
        guard maxDimension > 0 else { return (w0, h0) }
        let longEdge = max(w0, h0)
        if longEdge <= maxDimension { return (w0, h0) }
        let scale = Double(maxDimension) / Double(longEdge)
        var w = Int((Double(w0) * scale).rounded(.down))
        var h = Int((Double(h0) * scale).rounded(.down))
        w = max(2, w - (w % 2))
        h = max(2, h - (h % 2))
        return (w, h)
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        min(hi, max(lo, v))
    }

    private static func intVal(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func numVal(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}

/// 全局默认（foreground /api/video-settings）；墙流以 WS query 为准
/// 字段对齐官方 `phonebase-video-settings` v1（商业端 Kc 校验）
final class VideoSettingsStore {
    static let shared = VideoSettingsStore()
    private let lock = NSLock()
    private var _defaults = VideoStreamProfile.foregroundDefault
    /// 0 = 自动（跟 frameRate）；>0 为用户请求值
    private var requestedFrameRate = 0
    private var maxFrameRate = 60
    private var minBitrateMbps = 1
    private var maxBitrateMbps = 20
    /// 1000 = 100%；发送背压时下调（对齐官方 networkBitratePermille）
    private var networkBitratePermille = 1000
    private var generation = 1
    /// 样板 trimmedForPressure：只压 effective，不改用户 requested
    private var pressureTrimmed = false
    private static let udKey = "local.videoSettings.foreground.v1"
    private static let udTrimKey = "local.videoSettings.pressureTrimmed"

    private init() {
        loadPersisted()
    }

    var defaults: VideoStreamProfile {
        lock.lock(); defer { lock.unlock() }
        return effectiveProfileLocked()
    }

    /// 用户请求档（未套 trim）
    var requested: VideoStreamProfile {
        lock.lock(); defer { lock.unlock() }
        return _defaults
    }

    var isPressureTrimmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return pressureTrimmed
    }

    var status: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let p = effectiveProfileLocked()
        return [
            "supported": true,
            "protocol": "phonebase-video-settings",
            "version": 1,
            "requestedFrameRate": requestedFrameRate,
            "frameRate": p.frameRate,
            "maxFrameRate": maxFrameRate,
            "bitrateMbps": p.bitrateMbps,
            "bitrateBps": p.bitrateBps,
            "minBitrateMbps": minBitrateMbps,
            "maxBitrateMbps": maxBitrateMbps,
            "networkBitratePermille": networkBitratePermille,
            "generation": generation,
            "profile": p.profile,
            "maxDimension": p.maxDimension,
            "pressureTrimmed": pressureTrimmed,
            "requested": _defaults.json,
        ]
    }

    @discardableResult
    func apply(_ next: VideoStreamProfile) -> VideoStreamProfile {
        lock.lock()
        // 用 bitrateBps 落盘，避免 bitrateMbps(Int 四舍五入) 把 4.5M 抬成 5M
        let minBps = minBitrateMbps * 1_000_000
        let maxBps = maxBitrateMbps * 1_000_000
        let bps = clamp(next.bitrateBps, minBps, maxBps)
        let fps = clamp(next.frameRate, 5, maxFrameRate)
        if next.frameRate > 0 {
            requestedFrameRate = fps
        }
        // 0 = 全分辨率（样板默认）；勿把 0 当成「未设置」而沿用旧 720 上限
        let dim: Int
        if next.maxDimension > 0 {
            dim = clamp(next.maxDimension, 128, 1280)
        } else {
            dim = 0
        }
        _defaults = VideoStreamProfile(
            profile: "foreground",
            maxDimension: dim,
            frameRate: fps,
            bitrateBps: bps
        )
        generation += 1
        persistLocked()
        let out = effectiveProfileLocked()
        lock.unlock()
        return out
    }

    /// 对齐样板 effectiveProfileLocked：trim 时封顶，不改 requested
    func setPressureTrimmed(_ on: Bool) {
        lock.lock()
        let changed = pressureTrimmed != on
        pressureTrimmed = on
        if changed { generation += 1 }
        persistLocked()
        lock.unlock()
    }

    /// 拥塞反馈：permille∈[400,1000]
    func setNetworkBitratePermille(_ permille: Int) {
        lock.lock()
        let next = clamp(permille, 400, 1000)
        let changed = next != networkBitratePermille
        networkBitratePermille = next
        if changed { generation += 1 }
        lock.unlock()
    }

    func networkBitratePermilleValue() -> Int {
        lock.lock(); defer { lock.unlock() }
        return networkBitratePermille
    }

    private func effectiveProfileLocked() -> VideoStreamProfile {
        var base = _defaults
        if pressureTrimmed {
            let dim = base.maxDimension == 0 ? 720 : min(base.maxDimension, 720)
            base = VideoStreamProfile(
                profile: "foreground",
                maxDimension: dim,
                frameRate: min(base.frameRate, 30),
                bitrateBps: min(base.bitrateBps, 3_000_000)
            )
        }
        let br = max(400_000, base.bitrateBps * networkBitratePermille / 1000)
        let minBps = minBitrateMbps * 1_000_000
        let maxBps = maxBitrateMbps * 1_000_000
        return VideoStreamProfile(
            profile: "foreground",
            maxDimension: base.maxDimension,
            frameRate: base.frameRate,
            bitrateBps: min(maxBps, max(minBps, br))
        )
    }

    private func persistLocked() {
        UserDefaults.standard.set(pressureTrimmed, forKey: Self.udTrimKey)
        UserDefaults.standard.set(_defaults.json, forKey: Self.udKey)
    }

    private func loadPersisted() {
        pressureTrimmed = UserDefaults.standard.bool(forKey: Self.udTrimKey)
        guard let obj = UserDefaults.standard.dictionary(forKey: Self.udKey) else { return }
        let loaded = VideoStreamProfile.from(json: obj, current: .foregroundDefault)
        _defaults = loaded
        if loaded.frameRate > 0 { requestedFrameRate = loaded.frameRate }
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        min(hi, max(lo, v))
    }
}
