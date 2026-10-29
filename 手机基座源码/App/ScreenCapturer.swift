import Foundation
import ReplayKit
import CoreMedia
import CoreVideo
import UIKit

/// Opens and starts capturing automatically — no Broadcast button.
final class ScreenCapturer {
    var onPixelBuffer: ((CVPixelBuffer, UInt64) -> Void)?
    var onError: ((String) -> Void)?
    var onInfo: ((String) -> Void)?

    private var running = false
    private var snapshotTimer: Timer?

    func start() {
        guard !running else { return }
        running = true
        if startReplayKit() { return }
        startWindowSnapshotFallback()
    }

    func stop() {
        running = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        let rec = RPScreenRecorder.shared()
        if rec.isRecording {
            rec.stopCapture { _ in }
        }
    }

    private func startReplayKit() -> Bool {
        let rec = RPScreenRecorder.shared()
        guard rec.isAvailable else {
            onInfo?("ReplayKit 不可用，改用窗口快照")
            startWindowSnapshotFallback()
            return true
        }
        rec.isMicrophoneEnabled = false
        rec.startCapture { [weak self] sample, type, error in
            if let error {
                DispatchQueue.main.async {
                    self?.onInfo?("ReplayKit 中断：\(error.localizedDescription)，改用快照")
                    self?.startWindowSnapshotFallback()
                }
                return
            }
            guard type == .video, let pb = CMSampleBufferGetImageBuffer(sample) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let us = UInt64(max(0, pts.seconds * 1_000_000))
            self?.onPixelBuffer?(pb, us)
        } completionHandler: { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.onInfo?("ReplayKit 未能启动（\(error.localizedDescription)），改用快照采屏")
                    self?.startWindowSnapshotFallback()
                } else {
                    self?.onInfo?("已自动采屏，电脑直接扫即可")
                }
            }
        }
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
