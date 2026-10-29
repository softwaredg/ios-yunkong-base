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

    init(tcpVideo: TcpVideoHub) {
        self.tcpVideo = tcpVideo
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

    func handle(pixelBuffer pb: CVPixelBuffer, ptsUs: UInt64) {
        let w = Int32(CVPixelBufferGetWidth(pb))
        let h = Int32(CVPixelBufferGetHeight(pb))
        lock.lock()
        let svc = service
        let n = frameCount
        if !started {
            started = true
            lock.unlock()
            try? encoder.start(width: w, height: h, fps: 30, bitrateBps: 4_000_000)
            lock.lock()
        }
        frameCount = n + 1
        let force = (n % 30) == 0
        lock.unlock()
        svc?.updateGeometry(width: Int(w), height: Int(h))
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
