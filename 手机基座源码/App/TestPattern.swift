import CoreVideo
import UIKit

enum TestPattern {
    static func make(width: Int, height: Int, index: UInt64) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let w = CGFloat(width)
        let h = CGFloat(height)
        let phase = CGFloat(index % 60) / 60.0
        ctx.setFillColor(UIColor(hue: phase, saturation: 0.7, brightness: 0.35, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(UIColor.systemBlue.cgColor)
        let barX = CGFloat(Int(index * 12) % width)
        ctx.fill(CGRect(x: barX, y: 0, width: 40, height: h))
        let text = "PhoneBase Local \(index)" as NSString
        UIGraphicsPushContext(ctx)
        text.draw(at: CGPoint(x: 40, y: h / 2), withAttributes: [
            .font: UIFont.boldSystemFont(ofSize: 36),
            .foregroundColor: UIColor.white,
        ])
        UIGraphicsPopContext()
        return pb
    }
}
