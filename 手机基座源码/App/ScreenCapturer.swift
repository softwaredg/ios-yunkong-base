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
    private var watchdogTimer: Timer?
    private var usingPrivate = false
    private var lastFrameAt = Date.distantPast
    private var fallbackStarted = false

    func start() {
        guard !running else { return }
        running = true
        fallbackStarted = false
        lastFrameAt = Date.distantPast
        // CARender/IOSurface on this tipa path was producing encodeable black/garbage
        // frames (PC saw traffic, no picture). Prefer key-window snapshot so the
        // small/big windows always show real pixels; private capture can be
        // re-enabled once render is verified non-blank end-to-end.
        onInfo?("窗口快照推流（保证有画面）· TVH4")
        startWindowSnapshotFallback()
        if startPrivateCapture() {
            // Private only upgrades the stream when it emits non-blank frames.
            // Blank handler stops private; snapshot already running.
            startWatchdog()
        }
    }

    func stop() {
        running = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if usingPrivate {
            PrivateScreenCapture.shared().stop()
            usingPrivate = false
        }
    }

    private func emitFrame(_ pb: CVPixelBuffer, ptsUs: UInt64) {
        lastFrameAt = Date()
        onPixelBuffer?(pb, ptsUs)
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self, self.running, !self.fallbackStarted else { return }
            if Date().timeIntervalSince(self.lastFrameAt) > 1.5 {
                self.fallbackStarted = true
                self.onInfo?("私有采屏无帧，改用窗口快照兜底")
                self.startWindowSnapshotFallback()
            }
        }
        if let watchdogTimer { RunLoop.main.add(watchdogTimer, forMode: .common) }
    }

    private func startPrivateCapture() -> Bool {
        let cap = PrivateScreenCapture.shared()
        guard cap.isAvailable() else { return false }
        usingPrivate = true
        cap.setPreferredFPS(15)
        // Empty CARender surfaces still produce H.264 traffic (black) — fall back.
        cap.setBlankHandler { [weak self] in
            guard let self, self.running else { return }
            self.onInfo?("私有采屏为空帧，已停用（保持窗口快照）")
            PrivateScreenCapture.shared().stop()
            self.usingPrivate = false
        }
        cap.start(handler: { [weak self] pb, ptsUs in
            guard let self, self.running, self.usingPrivate else { return }
            // Snapshot already feeds the encoder; ignore private until proven useful.
            // (Blank frames never reach here; first real frame can later replace snapshot.)
            self.snapshotTimer?.invalidate()
            self.snapshotTimer = nil
            self.fallbackStarted = true
            self.emitFrame(pb, ptsUs: ptsUs)
        })
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
        emitFrame(pb, ptsUs: us)
    }
}
