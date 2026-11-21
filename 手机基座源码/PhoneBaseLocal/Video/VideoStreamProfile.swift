import Foundation

/// 对齐官方 wall/foreground 画质档：`/video?profile=wall&maxDimension=&frameRate=` + `/api/video-settings`
struct VideoStreamProfile: Hashable {
    var profile: String // foreground | wall
    var maxDimension: Int // 0 = 全分辨率
    var frameRate: Int
    var bitrateBps: Int

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
        return "fg:\(frameRate)@\(bitrateBps)"
    }

    var isWall: Bool { profile == "wall" }

    var bitrateMbps: Int { max(1, (bitrateBps + 500_000) / 1_000_000) }

    static func from(query: [String: String], defaults: VideoStreamProfile) -> VideoStreamProfile {
        let rawProfile = (query["profile"] ?? "foreground").lowercased()
        if rawProfile != "wall" {
            return defaults
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
            next.maxDimension = 0
        }
        if let d = intVal(json["maxDimension"]) {
            next.maxDimension = next.profile == "wall" ? clamp(d, 128, 1280) : 0
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

    /// 在源尺寸上按 maxDimension 等比缩小（偶数）
    func encodeSize(sourceW: Int, sourceH: Int) -> (Int, Int) {
        let w0 = max(2, sourceW - (sourceW % 2))
        let h0 = max(2, sourceH - (sourceH % 2))
        guard isWall, maxDimension > 0 else { return (w0, h0) }
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

    var defaults: VideoStreamProfile {
        lock.lock(); defer { lock.unlock() }
        return effectiveProfileLocked()
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
        ]
    }

    @discardableResult
    func apply(_ next: VideoStreamProfile) -> VideoStreamProfile {
        lock.lock()
        let mbps = clamp(next.bitrateMbps, minBitrateMbps, maxBitrateMbps)
        let fps = clamp(next.frameRate, 5, maxFrameRate)
        if next.frameRate > 0 {
            requestedFrameRate = fps
        }
        _defaults = VideoStreamProfile(
            profile: "foreground",
            maxDimension: 0,
            frameRate: fps,
            bitrateBps: mbps * 1_000_000
        )
        generation += 1
        let out = effectiveProfileLocked()
        lock.unlock()
        return out
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
        let base = _defaults
        let br = max(400_000, base.bitrateBps * networkBitratePermille / 1000)
        let minBps = minBitrateMbps * 1_000_000
        let maxBps = maxBitrateMbps * 1_000_000
        return VideoStreamProfile(
            profile: "foreground",
            maxDimension: 0,
            frameRate: base.frameRate,
            bitrateBps: min(maxBps, max(minBps, br))
        )
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        min(hi, max(lo, v))
    }
}
