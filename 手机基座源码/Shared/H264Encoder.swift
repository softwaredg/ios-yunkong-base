import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import Accelerate

/// VideoToolbox H.264 encoder → AVCC length-prefixed NALs (+ SPS/PPS for TVH4 config).
final class H264Encoder {
    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "cn.iosmirror.base.encoder")
    /// AVCC frame payload, keyframe, pts µs
    var onFrame: ((Data, Bool, UInt64) -> Void)?
    /// Called once with SPS + PPS (raw parameter sets, not avcC).
    var onParameterSets: ((Data, Data) -> Void)?

    private var sps: Data?
    private var pps: Data?
    private var sentConfig = false
    private var targetFps: Int32 = 30
    private var targetBitrate: Int32 = 4_000_000
    /// No downscale for phone logical sizes (≤720 long edge). User wants full resolution.
    private let maxSide = 720

    private var inflight = false
    private var pending: (Unmanaged<CVPixelBuffer>, UInt64, Bool)?
    private let inflightLock = NSLock()

    func configure(fps: Int32, bitrateBps: Int32) {
        targetFps = max(1, fps)
        targetBitrate = max(100_000, bitrateBps)
        applySessionRate()
    }

    private func applySessionRate() {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFps as CFNumber)
        let dur = max(15, targetFps * 2) as CFNumber
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: dur)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)
        // No DataRateLimits — hard cap was starving P-frames into ~150B black holes in Chrome.
    }

    func start(width: Int32, height: Int32, fps: Int32, bitrateBps: Int32) throws {
        configure(fps: fps, bitrateBps: bitrateBps)
        try startSession(width: width, height: height)
    }

    private func startSession(width: Int32, height: Int32) throws {
        stopSessionOnly()
        var sess: VTCompressionSession?
        // String keys — Swift constants are @available(iOS 17.4) for app extensions.
        let encSpec: [String: Any] = [
            "EnableHardwareAcceleratedVideoEncoder": true,
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer, let refcon else { return }
                let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
                encoder.handle(sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &sess
        )
        guard status == noErr, let sess else {
            throw NSError(domain: "H264Encoder", code: Int(status))
        }
        session = sess
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // Baseline + HW. Main fell back to ~3fps software on device; web skip-black handles bad P.
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFps as CFNumber)
        // Interval is frames; Duration caps wall-clock. 1s IDRs ate the bitrate (~4fps).
        let dur = max(15, targetFps * 2) as CFNumber
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: dur)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(sess)
    }

    /// Latest-wins. vImage scale on encoder queue (not CG) — capture timer stays at 30Hz.
    func encode(pixelBuffer: CVPixelBuffer, ptsUs: UInt64, forceKeyframe: Bool = false) {
        let retained = Unmanaged.passRetained(pixelBuffer)
        inflightLock.lock()
        if let old = pending {
            old.0.release()
        }
        pending = (retained, ptsUs, forceKeyframe)
        let start = !inflight
        if start { inflight = true }
        inflightLock.unlock()
        if start { queue.async { self.drainEncodeQueue() } }
    }

    private func drainEncodeQueue() {
        while true {
            inflightLock.lock()
            let next = pending
            pending = nil
            if next == nil {
                inflight = false
                inflightLock.unlock()
                return
            }
            inflightLock.unlock()

            let (retained, ptsUs, force) = next!
            let src = retained.takeRetainedValue()
            guard let frame = prepareFrame(src) else { continue }

            let w = Int32(CVPixelBufferGetWidth(frame))
            let h = Int32(CVPixelBufferGetHeight(frame))
            if session == nil {
                do { try startSession(width: w, height: h) } catch {
                    NSLog("[H264] start failed %@", error.localizedDescription)
                    continue
                }
            }

            guard let session else { continue }
            var props: CFDictionary?
            if force {
                props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            }
            let pts = CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000)
            let st = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: frame,
                presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: props,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
            if st != noErr {
                NSLog("[H264] EncodeFrame status=%d", st)
            }
        }
    }

    /// Downscale with Accelerate when needed; reuse one pool buffer.
    private func prepareFrame(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let sw = CVPixelBufferGetWidth(src)
        let sh = CVPixelBufferGetHeight(src)
        let longEdge = max(sw, sh)
        if longEdge <= maxSide { return src }

        let scale = CGFloat(maxSide) / CGFloat(longEdge)
        let dw = max(2, (Int((CGFloat(sw) * scale).rounded(.toNearestOrAwayFromZero)) / 2) * 2)
        let dh = max(2, (Int((CGFloat(sh) * scale).rounded(.toNearestOrAwayFromZero)) / 2) * 2)
        // Fresh buffer each frame — VT retains asynchronously; pooling would race.
        var dst: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, dw, dh, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &dst
        ) == kCVReturnSuccess, let dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        guard let s = CVPixelBufferGetBaseAddress(src),
              let d = CVPixelBufferGetBaseAddress(dst) else { return nil }
        var srcBuf = vImage_Buffer(
            data: s,
            height: vImagePixelCount(sh),
            width: vImagePixelCount(sw),
            rowBytes: CVPixelBufferGetBytesPerRow(src)
        )
        var dstBuf = vImage_Buffer(
            data: d,
            height: vImagePixelCount(dh),
            width: vImagePixelCount(dw),
            rowBytes: CVPixelBufferGetBytesPerRow(dst)
        )
        // ponytail: kvImageNoFlags is fine for mirror; upgrade to HighQuality if aliasing shows
        let err = vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else {
            NSLog("[H264] vImageScale err=%d", err)
            return nil
        }
        return dst
    }

    func stop() {
        inflightLock.lock()
        if let old = pending {
            old.0.release()
            pending = nil
        }
        inflight = false
        inflightLock.unlock()
        stopSessionOnly()
        sps = nil
        pps = nil
        sentConfig = false
    }

    private func stopSessionOnly() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        if sps == nil || pps == nil {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            if count >= 2 {
                var spsPtr: UnsafePointer<UInt8>?
                var spsSize = 0
                var ppsPtr: UnsafePointer<UInt8>?
                var ppsSize = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let spsPtr, let ppsPtr {
                    sps = Data(bytes: spsPtr, count: spsSize)
                    pps = Data(bytes: ppsPtr, count: ppsSize)
                }
            }
        }
        if !sentConfig, let sps, let pps {
            onParameterSets?(sps, pps)
            sentConfig = true
        }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let dataPointer, length > 0 else { return }
        let data = Data(bytes: dataPointer, count: length)
        var isKeyframe = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            isKeyframe = !notSync
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let us = UInt64(max(0, pts.seconds * 1_000_000))
        onFrame?(data, isKeyframe, us)
    }
}
