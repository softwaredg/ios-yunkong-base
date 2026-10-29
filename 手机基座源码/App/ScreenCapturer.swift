import Foundation
import CoreMedia
import CoreVideo
import UIKit

/// Prefers private QuartzCore/IOSurface capture (no ReplayKit consent alert).
/// Falls back to key-window snapshot only if private symbols are unavailable.
final class ScreenCapturer {
    var onPixelBuffer: ((CVPixelBuffer, UInt64) -> Void)?
    var onError: ((String) -> Void)?
    var onInfo: ((String) -> Void)?

    private var running = false
    private var snapshotTimer: Timer?
    private var usingPrivate = false

    func start() {
        guard !running else { return }
        running = true
        if startPrivateCapture() { return }
        onInfo?("私有采屏不可用，改用窗口快照（仅本 App 画面）")
        startWindowSnapshotFallback()
    }

    func stop() {
        running = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        if usingPrivate {
            PrivateScreenCapture.shared().stop()
            usingPrivate = false
        }
    }

    private func startPrivateCapture() -> Bool {
        let cap = PrivateScreenCapture.shared()
        guard cap.isAvailable() else { return false }
        usingPrivate = true
        cap.setPreferredFPS(20)
        cap.start(handler: { [weak self] pb, ptsUs in
            guard let self, self.running else { return }
            self.onPixelBuffer?(pb, ptsUs)
        })
        onInfo?("已自动采屏（无弹窗）· TVH4 直推")
        return true
    }

    private func startWindowSnapshotFallback() {
        snapshotTimer?.invalidate()
        let scale = UIScreen.main.scale
        let bounds = UIScreen.main.bounds
        let width = max(2, Int(bounds.width * scale))
        let height = max(2, Int(bounds.height * scale))
        onInfo?("自动快照推流 \(width)×\(height)（保持本 App 在前台效果最好）")
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.captureWindow(width: width, height: height)
        }
        if let snapshotTimer {
            RunLoop.main.add(snapshotTimer, forMode: .common)
        }
    }

    private func captureWindow(width: Int, height: Int) {
        guard running else { return }
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb
        ) == kCVReturnSuccess, let pb else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        var window: UIWindow?
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            window = ws.windows.first(where: \.isKeyWindow) ?? ws.windows.first
            if window != nil { break }
        }
        guard let window else { return }
        UIGraphicsPushContext(ctx)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / window.bounds.width, y: -(CGFloat(height) / window.bounds.height))
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        UIGraphicsPopContext()

        let us = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        onPixelBuffer?(pb, us)
    }
}
