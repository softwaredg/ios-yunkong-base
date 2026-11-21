import Foundation
import UIKit
import CoreVideo
import CoreMedia
import IOSurface
import Darwin

/// 系统级全屏采集（对齐 Direct `PBCapture`）：
/// `CARenderServerRenderDisplay` + IOSurface CVPixelBufferPool。
/// 无私有符号 / 权限不足时回退演示图案，保证协议通路可测。
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
    private let displayName = "LCD" as CFString

    var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?

    private typealias RenderDisplayFn = @convention(c) (
        UInt32, CFString?, IOSurfaceRef?, Int32, Int32
    ) -> Int32

    init(width: Int, height: Int) {
        self.width = max(2, width - (width % 2))
        self.height = max(2, height - (height % 2))
        super.init()
        resolvePrivateAPIs()
        _ = preparePool()
    }

    var backendName: String { backend.rawValue }

    func start() {
        stop()
        if pool == nil { _ = preparePool() }
        isActive = true
        wantsFrames = true
        frameIndex = 0
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
        NSLog("[Capture] start backend=%@ %dx%d", backendName, width, height)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isActive = false
    }

    func setActive(_ active: Bool) {
        wantsFrames = active
        isActive = active && displayLink != nil
    }

    @objc private func tick() {
        guard wantsFrames else { return }
        frameIndex += 1
        let pts = CMTime(value: frameIndex, timescale: 60)

        if backend == .direct, let renderDisplay {
            // dirty-skip 会在滑动动画里漏帧 → 一点卡；静帧省电以后再说
            if let buffer = renderServerFrame(renderDisplay) {
                renderedFrames += 1
                onPixelBuffer?(buffer, pts)
                return
            }
            failedFrames += 1
            // Keep WS alive with demo while diagnosing private-API failures.
            if let demo = renderDemoFrame() { onPixelBuffer?(demo, pts) }
            return
        }

        if let demo = renderDemoFrame() {
            renderedFrames += 1
            onPixelBuffer?(demo, pts)
        } else {
            failedFrames += 1
        }
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
            return nil
        }
        guard let surfaceUnmanaged = CVPixelBufferGetIOSurface(buffer) else {
            lastError = "no IOSurface"
            return nil
        }
        let surface = surfaceUnmanaged.takeUnretainedValue()
        // Direct helper: CARenderServerRenderDisplay(…, "LCD", surface, …)
        let rc = render(0, displayName, surface, 0, 0)
        if rc != 0 {
            lastError = "RenderDisplay rc=\(rc)"
            // One alternate display name used on some builds.
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
