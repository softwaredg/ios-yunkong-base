import Foundation
import CoreMedia
import CoreVideo
import UIKit

/// Window snapshot → TVH4. Private CARender is disabled until it stops emitting black/garbage.
final class ScreenCapturer {
    var onPixelBuffer: ((CVPixelBuffer, UInt64) -> Void)?
    var onError: ((String) -> Void)?
    var onInfo: ((String) -> Void)?

    private var running = false
    private var snapshotTimer: Timer?
    private var frameIndex: UInt64 = 0

    func start() {
        guard !running else { return }
        running = true
        frameIndex = 0
        onInfo?("窗口快照推流（保证有画面）· TVH4")
        startWindowSnapshotFallback()
    }

    func stop() {
        running = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    private func emitFrame(_ pb: CVPixelBuffer, ptsUs: UInt64) {
        onPixelBuffer?(pb, ptsUs)
    }

    private func startWindowSnapshotFallback() {
        snapshotTimer?.invalidate()
        let scale = UIScreen.main.scale
        let bounds = UIScreen.main.bounds
        let width = max(2, Int(bounds.width * scale))
        let height = max(2, Int(bounds.height * scale))
        onInfo?("自动快照推流 \(width)×\(height) · 请保持 App 在前台")
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.captureWindow(width: width, height: height, pointSize: bounds.size, scale: scale)
        }
        if let snapshotTimer {
            RunLoop.main.add(snapshotTimer, forMode: .common)
        }
    }

    private func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let w = ws.windows.first(where: \.isKeyWindow) ?? ws.windows.first {
                return w
            }
        }
        return nil
    }

    private func captureWindow(width: Int, height: Int, pointSize: CGSize, scale: CGFloat) {
        guard running else { return }
        frameIndex &+= 1
        let idx = frameIndex

        // Render in point space at screen scale, then copy into CVPixelBuffer.
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pointSize, format: format)
        let image = renderer.image { rc in
            // Animated backdrop — guarantees non-constant bitstream even if hierarchy fails.
            let hue = CGFloat(idx % 90) / 90.0
            UIColor(hue: hue, saturation: 0.55, brightness: 0.35, alpha: 1).setFill()
            rc.fill(CGRect(origin: .zero, size: pointSize))

            if let window = self.keyWindow() {
                window.drawHierarchy(in: CGRect(origin: .zero, size: pointSize), afterScreenUpdates: true)
            }

            let title = "云控快照 #\(idx)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            title.draw(at: CGPoint(x: 16, y: 48), withAttributes: attrs)
            let sub = "TVH4 window-snapshot" as NSString
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
            ]
            sub.draw(at: CGPoint(x: 16, y: 78), withAttributes: subAttrs)
        }

        guard let cg = image.cgImage else { return }
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
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        let us = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        emitFrame(pb, ptsUs: us)
    }
}
