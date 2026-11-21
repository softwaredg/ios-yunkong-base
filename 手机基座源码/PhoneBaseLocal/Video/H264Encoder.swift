import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class H264Encoder {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private var bitrateBps: Int
    private var frameRate: Int
    private let queue: DispatchQueue
    private var sentConfig = false
    private var forceNextKeyFrame = false
    private var recreateNeeded = false
    /// 60fps 时 async 堆积会追帧发糊；只编最新一帧
    private var pendingBuffer: CVPixelBuffer?
    private var pendingPts = CMTime.invalid
    private var drainScheduled = false

    private(set) var ready = false
    private(set) var encodeAttempts: Int = 0
    private(set) var encodeErrors: Int = 0
    private(set) var outputFrames: Int = 0
    private(set) var lastEncodeStatus: OSStatus = 0
    private(set) var lastCallbackStatus: OSStatus = 0

    var onConfig: ((Data) -> Void)?
    var onFrame: ((_ avcc: Data, _ keyframe: Bool, _ timestampUs: UInt64) -> Void)?

    /// kVTInvalidSessionErr
    private static let vtInvalidSession: OSStatus = -12903

    init(width: Int, height: Int, bitrateBps: Int = 6_000_000, frameRate: Int = 60) {
        self.width = Int32(max(2, width - (width % 2)))
        self.height = Int32(max(2, height - (height % 2)))
        self.bitrateBps = max(400_000, bitrateBps)
        self.frameRate = max(5, min(60, frameRate))
        self.queue = DispatchQueue(
            label: "cn.local.phonebase.local.encoder.\(width)x\(height).\(UUID().uuidString.prefix(6))"
        )
    }

    var stats: [String: Any] {
        [
            "ready": ready,
            "width": Int(width),
            "height": Int(height),
            "bitrateBps": bitrateBps,
            "frameRate": frameRate,
            "encodeAttempts": encodeAttempts,
            "encodeErrors": encodeErrors,
            "outputFrames": outputFrames,
            "lastEncodeStatus": Int(lastEncodeStatus),
            "lastCallbackStatus": Int(lastCallbackStatus),
            "sentConfig": sentConfig,
        ]
    }

    func updateRate(bitrateBps: Int, frameRate: Int) {
        queue.async {
            let br = max(400_000, bitrateBps)
            let fr = max(5, min(60, frameRate))
            let bitrateChanged = br != self.bitrateBps
            let fpsChanged = fr != self.frameRate
            self.bitrateBps = br
            self.frameRate = fr
            // 对齐官方 applyBitrateBps：会话仍在时热更新码率/峰值，避免整会话重建尖峰
            guard let sess = self.session else { return }
            if bitrateChanged {
                self.applyBitrateLocked(sess, bitrateBps: br)
            }
            if fpsChanged {
                VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fr as CFNumber)
                // 官方：MaxKeyFrameInterval = fps，Duration = 1s
                VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fr as CFNumber)
                VTSessionSetProperty(
                    sess,
                    key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                    value: NSNumber(value: 1.0)
                )
            }
        }
    }

    /// 官方 applyBitrateBps：AverageBitRate + DataRateLimits=[bitrate/8, 1]
    private func applyBitrateLocked(_ sess: VTCompressionSession, bitrateBps: Int) {
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateBps as CFNumber)
        let limits: [NSNumber] = [NSNumber(value: bitrateBps / 8), NSNumber(value: 1)]
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
    }

    func forceKeyFrame() {
        queue.async { self.forceNextKeyFrame = true }
    }

    func start() throws {
        queue.sync { self.openSessionLocked() }
    }

    func stop() {
        queue.sync { self.closeSessionLocked() }
    }

    func resetConfigFlag() {
        queue.async {
            self.sentConfig = false
            self.forceNextKeyFrame = true
        }
    }

    func encode(buffer: CVPixelBuffer, presentationTime: CMTime) {
        queue.async {
            self.pendingBuffer = buffer
            self.pendingPts = presentationTime
            guard !self.drainScheduled else { return }
            self.drainScheduled = true
            while let buf = self.pendingBuffer {
                self.pendingBuffer = nil
                let pts = self.pendingPts
                self.encodeOneLocked(buffer: buf, presentationTime: pts)
            }
            self.drainScheduled = false
        }
    }

    private func encodeOneLocked(buffer: CVPixelBuffer, presentationTime: CMTime) {
        encodeAttempts += 1
        if recreateNeeded || session == nil {
            openSessionLocked()
        }
        guard let session else {
            encodeErrors += 1
            lastEncodeStatus = -1
            return
        }

        let bw = CVPixelBufferGetWidth(buffer)
        let bh = CVPixelBufferGetHeight(buffer)
        if bw != Int(width) || bh != Int(height) {
            encodeErrors += 1
            lastEncodeStatus = -2
            if encodeErrors <= 5 || encodeErrors % 50 == 0 {
                NSLog("[H264] size mismatch buf=%dx%d sess=%dx%d", bw, bh, width, height)
            }
            return
        }

        var props: CFDictionary?
        if forceNextKeyFrame || !sentConfig {
            forceNextKeyFrame = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: buffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: props,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        lastEncodeStatus = status
        if status != noErr {
            encodeErrors += 1
            if status == Self.vtInvalidSession {
                recreateNeeded = true
                closeSessionLocked()
            }
            if encodeErrors <= 5 || encodeErrors % 50 == 0 {
                NSLog("[H264] EncodeFrame status=%d attempts=%d", status, encodeAttempts)
            }
        }
    }

    private func openSessionLocked() {
        closeSessionLocked()
        var sess: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &sess
        )
        guard status == noErr, let sess else {
            lastEncodeStatus = status
            ready = false
            NSLog("[H264] VTCompressionSessionCreate failed status=%d size=%dx%d", status, width, height)
            return
        }
        // 官方 PBVideoEncoder：RealTime + 不重排 + MaxFrameDelayCount=0
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        // DataRateLimits=[bitrate/8, 1]：约 1s 窗口峰值 ≈ 平均码率
        applyBitrateLocked(sess, bitrateBps: bitrateBps)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)
        // 1s GOP：Interval=fps，Duration=1.0s（避免更长 GOP 的更大 IDR 尖峰）
        VTSessionSetProperty(
            sess,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: frameRate as CFNumber
        )
        VTSessionSetProperty(
            sess,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: 1.0)
        )
        VTCompressionSessionPrepareToEncodeFrames(sess)
        session = sess
        sentConfig = false
        forceNextKeyFrame = true
        recreateNeeded = false
        ready = true
        NSLog(
            "[H264] encoder ready %dx%d br=%d fps=%d gop=1s dataRateLimits=%dB/1s",
            width, height, bitrateBps, frameRate, bitrateBps / 8
        )
    }

    private func closeSessionLocked() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        ready = false
    }

    fileprivate func noteCallbackStatus(_ status: OSStatus) {
        lastCallbackStatus = status
        if status != noErr {
            encodeErrors += 1
            if status == Self.vtInvalidSession {
                recreateNeeded = true
            }
        }
    }

    fileprivate func handle(sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampUs = UInt64(max(0, pts.seconds * 1_000_000))

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer, length > 0
        else { return }

        let avcc = Data(bytes: dataPointer, count: length)
        let key = isKeyframe || Self.avccContainsIdr(avcc)

        if !sentConfig {
            var avcC: Data?
            if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                avcC = Self.avcC(from: format)
            }
            if avcC == nil {
                avcC = Self.avcC(fromAvccBitstream: avcc)
            }
            if let avcC {
                sentConfig = true
                onConfig?(avcC)
                NSLog("[H264] avcC ready bytes=%d", avcC.count)
            } else {
                // Wait for a keyframe that carries SPS/PPS.
                forceNextKeyFrame = true
                return
            }
        }

        outputFrames += 1
        onFrame?(avcc, key, timestampUs)
    }

    private static func avccContainsIdr(_ data: Data) -> Bool {
        forEachNal(data) { type, _ in type == 5 }
    }

    private static func avcC(fromAvccBitstream data: Data) -> Data? {
        var sps: Data?
        var pps: Data?
        forEachNal(data) { type, nal in
            if type == 7 { sps = nal }
            if type == 8 { pps = nal }
            return false
        }
        guard let sps, let pps, sps.count >= 4 else { return nil }
        var out = Data()
        out.append(1)
        out.append(sps[1])
        out.append(sps[2])
        out.append(sps[3])
        out.append(0xFF)
        out.append(0xE1)
        var spsLen = UInt16(sps.count).bigEndian
        withUnsafeBytes(of: &spsLen) { out.append(contentsOf: $0) }
        out.append(sps)
        out.append(1)
        var ppsLen = UInt16(pps.count).bigEndian
        withUnsafeBytes(of: &ppsLen) { out.append(contentsOf: $0) }
        out.append(pps)
        return out
    }

    @discardableResult
    private static func forEachNal(_ data: Data, _ body: (UInt8, Data) -> Bool) -> Bool {
        var i = 0
        while i + 4 <= data.count {
            let n = Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            i += 4
            guard n > 0, i + n <= data.count else { return false }
            let type = data[i] & 0x1f
            if body(type, data.subdata(in: i ..< (i + n))) { return true }
            i += n
        }
        return false
    }

    private static func avcC(from format: CMFormatDescription) -> Data? {
        var spsCount = 0
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        var nalHeaderLength: Int32 = 0

        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: &nalHeaderLength
        )
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        )
        guard spsStatus == noErr, ppsStatus == noErr, let spsPointer, let ppsPointer, spsSize >= 4 else { return nil }

        var out = Data()
        out.append(1)
        out.append(spsPointer[1])
        out.append(spsPointer[2])
        out.append(spsPointer[3])
        out.append(0xFF)
        out.append(0xE1)
        var spsLen = UInt16(spsSize).bigEndian
        withUnsafeBytes(of: &spsLen) { out.append(contentsOf: $0) }
        out.append(UnsafeBufferPointer(start: spsPointer, count: spsSize))
        out.append(1)
        var ppsLen = UInt16(ppsSize).bigEndian
        withUnsafeBytes(of: &ppsLen) { out.append(contentsOf: $0) }
        out.append(UnsafeBufferPointer(start: ppsPointer, count: ppsSize))
        return out
    }
}

private func compressionCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let ref = outputCallbackRefCon else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(ref).takeUnretainedValue()
    encoder.noteCallbackStatus(status)
    guard status == noErr, let sampleBuffer else { return }
    encoder.handle(sampleBuffer: sampleBuffer)
}
