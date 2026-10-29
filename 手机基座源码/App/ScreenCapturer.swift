import Foundation
import CoreMedia
import CoreVideo
import UIKit

/// Prefers private full-display capture (DirectPhoneBase / CARender path).
/// Window snapshot is last-resort foreground-only fallback — never the product path.
final class ScreenCapturer {
    enum Mode: String {
        case privateFull = "private-full"
        case snapshotFallback = "snapshot-fallback"
        case idle = "idle"
    }

    var onPixelBuffer: ((CVPixelBuffer, UInt64) -> Void)?
    var onError: ((String) -> Void)?
    var onInfo: ((String) -> Void)?
    var onModeChange: ((Mode) -> Void)?

    private(set) var mode: Mode = .idle {
        didSet { if oldValue != mode { onModeChange?(mode) } }
    }

    private var running = false
    private var snapshotTimer: Timer?
    private var usingPrivate = false
    private var frameIndex: UInt64 = 0
    private var lastPrivateFrameAt = Date.distantPast
    private var privateHealAttempts = 0

    func start() {
        guard !running else { return }
        running = true
        frameIndex = 0
        lastPrivateFrameAt = .distantPast
        privateHealAttempts = 0
        if startPrivateCapture() {
            mode = .privateFull
            onInfo?("全屏采屏（可后台）· Direct 路线 · TVH4")
            // Give private path longer to settle; heal surfaces before snapshot fallback.
            schedulePrivateWatchdog()
            return
        }
        onInfo?("私有采屏不可用，窗口快照（需前台）")
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
        mode = .idle
    }

    /// Soft-heal capture only (no HTTP/TVH4 tear-down) — mirrors LanCaptureHelper restart.
    func softHealCapture(reason: String) {
        guard running else { return }
        onInfo?("采屏自愈：\(reason)")
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        if usingPrivate {
            PrivateScreenCapture.shared().restartSurfaces()
            lastPrivateFrameAt = .distantPast
            schedulePrivateWatchdog()
            mode = .privateFull
            return
        }
        PrivateScreenCapture.shared().stop()
        usingPrivate = false
        if startPrivateCapture() {
            mode = .privateFull
            onInfo?("全屏采屏已恢复 · TVH4")
            schedulePrivateWatchdog()
        } else {
            startWindowSnapshotFallback()
        }
    }

    private func emitFrame(_ pb: CVPixelBuffer, ptsUs: UInt64) {
        onPixelBuffer?(pb, ptsUs)
    }

    private func schedulePrivateWatchdog() {
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self, self.running, self.usingPrivate else { return }
            if Date().timeIntervalSince(self.lastPrivateFrameAt) > 2.5 {
                self.privateHealAttempts += 1
                if self.privateHealAttempts <= 3 {
                    self.onInfo?("全屏无帧，重建 IOSurface（#\(self.privateHealAttempts)）")
                    PrivateScreenCapture.shared().restartSurfaces()
                    self.schedulePrivateWatchdog()
                    return
                }
                self.onInfo?("全屏采屏仍无帧，前台改用窗口快照")
                PrivateScreenCapture.shared().stop()
                self.usingPrivate = false
                self.startWindowSnapshotFallback()
            }
        }
    }

    private func startPrivateCapture() -> Bool {
        let cap = PrivateScreenCapture.shared()
        guard cap.isAvailable() else { return false }
        usingPrivate = true
        cap.setPreferredFPS(15)
        cap.setBlankHandler { [weak self] in
            guard let self, self.running, self.usingPrivate else { return }
            self.privateHealAttempts += 1
            if self.privateHealAttempts <= 3 {
                self.onInfo?("全屏空帧，重建采屏（#\(self.privateHealAttempts)）")
                PrivateScreenCapture.shared().restartSurfaces()
                self.schedulePrivateWatchdog()
                return
            }
            self.onInfo?("全屏采屏为空，前台改用窗口快照")
            PrivateScreenCapture.shared().stop()
            self.usingPrivate = false
            self.startWindowSnapshotFallback()
        }
        cap.start(handler: { [weak self] pb, ptsUs in
            guard let self, self.running, self.usingPrivate else { return }
            self.lastPrivateFrameAt = Date()
            self.privateHealAttempts = 0
            self.snapshotTimer?.invalidate()
            self.snapshotTimer = nil
            if self.mode != .privateFull { self.mode = .privateFull }
            self.emitFrame(pb, ptsUs: ptsUs)
        })
        return true
    }

    private func startWindowSnapshotFallback() {
        mode = .snapshotFallback
        snapshotTimer?.invalidate()
        let scale = UIScreen.main.scale
        let bounds = UIScreen.main.bounds
        let width = max(2, Int(bounds.width * scale))
        let height = max(2, Int(bounds.height * scale))
        onInfo?("窗口快照 \(width)×\(height) · 后台无法采其它 App")
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
        guard running, !usingPrivate else { return }
        frameIndex &+= 1
        let idx = frameIndex

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pointSize, format: format)
        let image = renderer.image { rc in
            let hue = CGFloat(idx % 90) / 90.0
            UIColor(hue: hue, saturation: 0.55, brightness: 0.35, alpha: 1).setFill()
            rc.fill(CGRect(origin: .zero, size: pointSize))
            if let window = self.keyWindow() {
                window.drawHierarchy(in: CGRect(origin: .zero, size: pointSize), afterScreenUpdates: true)
            }
            let title = "前台快照 #\(idx)（切后台需全屏采屏）" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 18, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            title.draw(at: CGPoint(x: 12, y: 44), withAttributes: attrs)
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
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        emitFrame(pb, ptsUs: UInt64(Date().timeIntervalSince1970 * 1_000_000))
    }
}
