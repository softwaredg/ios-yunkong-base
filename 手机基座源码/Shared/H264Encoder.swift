import Foundation
import VideoToolbox
import CoreMedia

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

    func start(width: Int32, height: Int32, fps: Int32, bitrateBps: Int32) throws {
        stop()
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
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateBps as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        let dur = max(1, fps * 2) as CFNumber
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: dur)
        VTCompressionSessionPrepareToEncodeFrames(sess)
    }

    func encode(pixelBuffer: CVPixelBuffer, ptsUs: UInt64, forceKeyframe: Bool = false) {
        queue.async {
            guard let session = self.session else { return }
            var props: CFDictionary?
            if forceKeyframe {
                props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            }
            let pts = CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000)
            VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: props,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
        }
    }

    func stop() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        sps = nil
        pps = nil
        sentConfig = false
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
