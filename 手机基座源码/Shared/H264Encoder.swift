import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreGraphics

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
    /// Cap long edge so SE-class phones can hold ~30fps (full 750×1334 encode was ~3fps).
    private let maxSide = 720

    private var inflight = false
    private var pending: (Unmanaged<CVPixelBuffer>, UInt64, Bool)?
    private let inflightLock = NSLock()

    func configure(fps: Int32, bitrateBps: Int32) {
        targetFps = max(5, fps)
        targetBitrate = max(500_000, bitrateBps)
    }

    func start(width: Int32, height: Int32, fps: Int32, bitrateBps: Int32) throws {
        configure(fps: fps, bitrateBps: bitrateBps)
        try startSession(width: width, height: height)
    }

    private func startSession(width: Int32, height: Int32) throws {
        stopSessionOnly()
        var sess: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
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
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFps as CFNumber)
        let dur = max(1, targetFps * 2) as CFNumber
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: dur)
        VTCompressionSessionPrepareToEncodeFrames(sess)
    }

    /// Latest-wins. Copy/scale happens on encoder queue so capture timer stays at 30Hz.
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
            guard let copy = Self.copyPixelBuffer(src, maxSide: maxSide) else { continue }

            let w = Int32(CVPixelBufferGetWidth(copy))
            let h = Int32(CVPixelBufferGetHeight(copy))
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
                imageBuffer: copy,
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

    /// Copy (+ optional downscale) so capture IOSurface can be rendered again immediately.
    private static func copyPixelBuffer(_ src: CVPixelBuffer, maxSide: Int) -> CVPixelBuffer? {
        let sw = CVPixelBufferGetWidth(src)
        let sh = CVPixelBufferGetHeight(src)
        let longEdge = max(sw, sh)
        let scale = longEdge > maxSide ? CGFloat(maxSide) / CGFloat(longEdge) : 1
        let dw = max(2, Int((CGFloat(sw) * scale).rounded(.toNearestOrAwayFromZero)))
        let dh = max(2, Int((CGFloat(sh) * scale).rounded(.toNearestOrAwayFromZero)))
        let fmt = kCVPixelFormatType_32BGRA
        var dst: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, dw, dh, fmt, attrs as CFDictionary, &dst
        ) == kCVReturnSuccess, let dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }

        if scale == 1, CVPixelBufferGetPixelFormatType(src) == fmt,
           let s = CVPixelBufferGetBaseAddress(src),
           let d = CVPixelBufferGetBaseAddress(dst) {
            let srcRow = CVPixelBufferGetBytesPerRow(src)
            let dstRow = CVPixelBufferGetBytesPerRow(dst)
            let rowBytes = min(srcRow, dstRow)
            for y in 0..<dh {
                memcpy(d.advanced(by: y * dstRow), s.advanced(by: y * srcRow), rowBytes)
            }
            return dst
        }

        guard let destBase = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let destStride = CVPixelBufferGetBytesPerRow(dst)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(
            data: destBase,
            width: dw,
            height: dh,
            bitsPerComponent: 8,
            bytesPerRow: destStride,
            space: cs,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(src, options: nil, imageOut: &cgImage)
        if let cgImage {
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dw, height: dh))
            return dst
        }

        // Fallback without VTCreateCGImage: nearest-neighbor from BGRA base.
        guard let s = CVPixelBufferGetBaseAddress(src) else { return nil }
        let srcRow = CVPixelBufferGetBytesPerRow(src)
        let srcFmt = CVPixelBufferGetPixelFormatType(src)
        guard srcFmt == kCVPixelFormatType_32BGRA || srcFmt == kCVPixelFormatType_32ARGB else { return nil }
        for y in 0..<dh {
            let sy = min(sh - 1, Int(CGFloat(y) / scale))
            let dRow = destBase.advanced(by: y * destStride)
            let sRow = s.advanced(by: sy * srcRow)
            for x in 0..<dw {
                let sx = min(sw - 1, Int(CGFloat(x) / scale))
                memcpy(dRow.advanced(by: x * 4), sRow.advanced(by: sx * 4), 4)
            }
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
