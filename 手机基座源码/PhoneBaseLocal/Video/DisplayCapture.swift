import Foundation
import UIKit
import CoreVideo
import CoreMedia
import IOSurface
import Darwin

/// 系统级全屏采集（对齐 Direct `PBCapture`）：
/// `CARenderServerRenderDisplay` + IOSurface CVPixelBufferPool。
/// 对齐样板：dirty-skip + encode-rate pacing。
final class DisplayCapture: NSObject {
    enum Backend: String {
        case direct
        case demo
    }

    private let width: Int
    private let height: Int
    private var displayLink: CADisplayLink?
    private var frameIndex: Int64 = 0
    private(set) var isActive = false
    private var wantsFrames = true
    private(set) var backend: Backend = .demo
    private(set) var lastError: String = ""
    private(set) var renderedFrames: Int = 0
    private(set) var failedFrames: Int = 0

    private var pool: CVPixelBufferPool?
    private var renderDisplay: RenderDisplayFn?
    private var dirtyFrameCount: DirtyCountFn?
    private let displayName = "LCD" as CFString
    /// 对齐样板 poolBusySkips：池分配失败时跳帧计数
    private(set) var poolBusySkips: Int = 0
    private(set) var unchangedSkips: Int = 0
    private(set) var pacingSkips: Int = 0
    private var lastDirtyCount: UInt64 = 0
    private var hasDirtyCount = false
    private var forceFrame = false
    private var targetFrameRate: Int = 60
    private var nextDueUs: UInt64 = 0
    private var lastAcceptedUs: UInt64 = 0

    var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?

    private typealias RenderDisplayFn = @convention(c) (
        UInt32, CFString?, IOSurfaceRef?, Int32, Int32
    ) -> Int32
    private typealias DirtyCountFn = @convention(c) (UInt32) -> UInt64

    init(width: Int, height: Int) {
        self.width = max(2, width - (width % 2))
        self.height = max(2, height - (height % 2))
        super.init()
        resolvePrivateAPIs()
        _ = preparePool()
    }

    var backendName: String { backend.rawValue }

    func setTargetFrameRate(_ fps: Int) {
        targetFrameRate = max(5, min(60, fps))
        nextDueUs = 0
    }

    /// 关键帧 / 护栏后强制出一帧（绕过 dirty-skip）
    func requestForceFrame() {
        forceFrame = true
    }

    func start() {
        stop(releasePool: false)
        if pool == nil { _ = preparePool() }
        isActive = true
        wantsFrames = true
        frameIndex = 0
        nextDueUs = 0
        forceFrame = true
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
        NSLog("[Capture] start backend=%@ %dx%d fps=%d", backendName, width, height, targetFrameRate)
    }

    func stop(releasePool: Bool = false) {
        displayLink?.invalidate()
        displayLink = nil
        isActive = false
        if releasePool {
            pool = nil
        }
    }

    /// softRestart / 内存护栏：拆掉 IOSurface 池，迫使下次 start 重建
    func releasePixelBufferPool() {
        pool = nil
        NSLog(
            "[Capture] releasePixelBufferPool poolBusy=%d unchanged=%d pacing=%d",
            poolBusySkips, unchangedSkips, pacingSkips
        )
    }

    func setActive(_ active: Bool) {
        wantsFrames = active
        isActive = active && displayLink != nil
        if active { forceFrame = true }
    }

    @objc private func tick() {
        guard wantsFrames else { return }
        let nowUs = machContinuousUs()
        let fps = UInt64(max(5, targetFrameRate))
        let intervalUs = 1_000_000 / fps
        if !forceFrame, nextDueUs > 0, nowUs < nextDueUs {
            pacingSkips += 1
            return
        }

        if backend == .direct, let renderDisplay {
            if !forceFrame, shouldSkipUnchanged() {
                unchangedSkips += 1
                return
            }
            if let buffer = renderServerFrame(renderDisplay) {
                acceptFrame(buffer, nowUs: nowUs, intervalUs: intervalUs)
                return
            }
            failedFrames += 1
            if let demo = renderDemoFrame() {
                acceptFrame(demo, nowUs: nowUs, intervalUs: intervalUs)
            }
            return
        }

        if let demo = renderDemoFrame() {
            acceptFrame(demo, nowUs: nowUs, intervalUs: intervalUs)
        } else {
            failedFrames += 1
        }
    }

    private func acceptFrame(_ buffer: CVPixelBuffer, nowUs: UInt64, intervalUs: UInt64) {
        forceFrame = false
        frameIndex += 1
        renderedFrames += 1
        lastAcceptedUs = nowUs
        nextDueUs = nowUs &+ intervalUs
        let pts = CMTime(value: frameIndex, timescale: 60)
        onPixelBuffer?(buffer, pts)
    }

    private func shouldSkipUnchanged() -> Bool {
        guard let dirtyFrameCount else { return false }
        let cur = dirtyFrameCount(0)
        if !hasDirtyCount {
            hasDirtyCount = true
            lastDirtyCount = cur
            return false
        }
        if cur == lastDirtyCount {
            return true
        }
        lastDirtyCount = cur
        return false
    }

    private func machContinuousUs() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let t = mach_absolute_time()
        return t * UInt64(info.numer) / UInt64(info.denom) / 1000
    }

    private func resolvePrivateAPIs() {
        let path = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            lastError = "dlopen QuartzCore failed"
            backend = .demo
            return
        }
        if let sym = dlsym(handle, "CARenderServerRenderDisplay") {
            renderDisplay = unsafeBitCast(sym, to: RenderDisplayFn.self)
        }
        if let sym = dlsym(handle, "CARenderServerGetDirtyFrameCount") {
            dirtyFrameCount = unsafeBitCast(sym, to: DirtyCountFn.self)
        }
        if renderDisplay != nil {
            backend = .direct
            lastError = ""
        } else {
            backend = .demo
            lastError = "CARenderServerRenderDisplay missing"
        }
    }

    @discardableResult
    private func preparePool() -> Bool {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey as String: true,
        ]
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        var p: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            attrs as CFDictionary,
            &p
        )
        guard status == kCVReturnSuccess, let p else {
            lastError = "CVPixelBufferPoolCreate \(status)"
            pool = nil
            return false
        }
        pool = p
        return true
    }

    private func renderServerFrame(_ render: RenderDisplayFn) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        let aux: [String: Any] = [kCVPixelBufferPoolAllocationThresholdKey as String: 5]
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, aux as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            lastError = "pool alloc \(status)"
            poolBusySkips += 1
            return nil
        }
        guard let surfaceUnmanaged = CVPixelBufferGetIOSurface(buffer) else {
            lastError = "no IOSurface"
            return nil
        }
        let surface = surfaceUnmanaged.takeUnretainedValue()
        let rc = render(0, displayName, surface, 0, 0)
        if rc != 0 {
            lastError = "RenderDisplay rc=\(rc)"
            let rc2 = render(0, "Main" as CFString, surface, 0, 0)
            if rc2 != 0 {
                lastError = "RenderDisplay rc=\(rc)/\(rc2)"
                return nil
            }
        }
        lastError = ""
        return buffer
    }

    private func renderDemoFrame() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer
        )
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let t = CGFloat(frameIndex % 200) / 200
        context.setFillColor(UIColor(red: 0.18, green: 0.62, blue: 0.48, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: 80 + t * 400, y: 200 + sin(t * .pi * 2) * 80, width: 120, height: 120))
        UIGraphicsPushContext(context)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = "PhoneBase Local\n\(backendName)\nframe \(frameIndex)" as NSString
        text.draw(
            in: CGRect(x: 40, y: 520, width: width - 80, height: 200),
            withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 28, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
        )
        UIGraphicsPopContext()
        return buffer
    }
}
