import Foundation
import CoreVideo

/// Capture → H.264 → TVH4 off the main thread (MainActor 4MB copies were ~2fps).
final class FramePipeline: @unchecked Sendable {
    let encoder = H264Encoder()
    private let tcpVideo: TcpVideoHub
    private weak var service: LocalService?
    private let lock = NSLock()
    private(set) var frameCount: UInt64 = 0
    private(set) var lastEncodedAt: Date = .distantPast
    private var started = false
    private var forceKeyOnce = false

    init(tcpVideo: TcpVideoHub) {
        self.tcpVideo = tcpVideo
    }

    /// New TVH4 client: skip cached IDR, so force a fresh one on the next capture.
    func requestKeyframe() {
        lock.lock()
        forceKeyOnce = true
        lock.unlock()
    }

    func attach(service: LocalService?) {
        lock.lock()
        self.service = service
        lock.unlock()
    }

    func wire() {
        let video = tcpVideo
        encoder.onParameterSets = { [weak self] sps, pps in
            video.setConfiguration(TVH4.annexBConfig(sps: sps, pps: pps))
            guard let self else { return }
            self.lock.lock()
            let svc = self.service
            self.lock.unlock()
            svc?.publishConfiguration(sps: sps, pps: pps)
        }
        encoder.onFrame = { [weak self] avcc, key, ts in
            video.sendFrame(annexB: TVH4.avccToAnnexB(avcc), keyframe: key, ptsUs: ts)
            guard let self else { return }
            self.lock.lock()
            self.lastEncodedAt = Date()
            let svc = self.service
            self.lock.unlock()
            svc?.publishFrame(avcc: avcc, keyframe: key, timestampUs: ts)
        }
    }

    func resetEncoder() {
        lock.lock()
        encoder.stop()
        frameCount = 0
        lastEncodedAt = .distantPast
        started = false
        lock.unlock()
        tcpVideo.clearCachedFrames()
        wire()
    }

    /// PC wall/focus prefs (HTTP or TVHC).
    func setEncode(fps: Int, bitrateMbps: Int) {
        let f = max(5, min(60, fps))
        let mbps = max(1, min(20, bitrateMbps))
        encoder.configure(fps: Int32(f), bitrateBps: Int32(mbps) * 1_000_000)
    }

    func handle(pixelBuffer pb: CVPixelBuffer, ptsUs: UInt64) {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        lock.lock()
        let svc = service
        let n = frameCount
        if !started {
            started = true
            // Defaults; PC may override via /api/video-settings or TVHC.
            encoder.configure(fps: 30, bitrateBps: 2_500_000)
        }
        frameCount = n + 1
        let force = forceKeyOnce
        if force { forceKeyOnce = false }
        lock.unlock()
        svc?.updateGeometry(width: w, height: h)
        encoder.encode(pixelBuffer: pb, ptsUs: ptsUs, forceKeyframe: force)
    }

    var encodedFrameCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return frameCount
    }

    var lastEncodeDate: Date {
        lock.lock(); defer { lock.unlock() }
        return lastEncodedAt
    }
}
