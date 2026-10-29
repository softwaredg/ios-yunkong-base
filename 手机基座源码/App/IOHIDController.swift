import Foundation
import CoreGraphics

/// App-only：开源 IOHID（STHIDEventGenerator）全能力入口。
final class IOHIDController: IOHIDControlling {
    private let bridge = IOHIDBridge.shared()

    func pointer(action: String, x: Double, y: Double) {
        bridge.pointerAction(action, x: x, y: y)
    }

    func tap(x: Double, y: Double) { bridge.tap(atX: x, y: y) }
    func doubleTap(x: Double, y: Double) { bridge.doubleTap(atX: x, y: y) }
    func longPress(x: Double, y: Double) { bridge.longPress(atX: x, y: y) }

    func multiTouch(action: String, x: Double, y: Double, count: Int) {
        bridge.multiTouchAction(action, x: x, y: y, count: UInt(max(1, count)))
    }

    func drag(x0: Double, y0: Double, x1: Double, y1: Double, duration: Double, curve: Bool) {
        bridge.drag(fromX: x0, fromY: y0, toX: x1, toY: y1, duration: duration, curve: curve)
    }

    func pinch(x: Double, y: Double, w: Double, h: Double, scale: Double, angle: Double, duration: Double) {
        bridge.pinch(atX: x, y: y, width: w, height: h, scale: CGFloat(scale), angle: CGFloat(angle), duration: duration)
    }

    func stylus(action: String, x: Double, y: Double, azimuth: Double, altitude: Double, pressure: Double) {
        bridge.stylusAction(action, x: x, y: y, azimuth: CGFloat(azimuth), altitude: CGFloat(altitude), pressure: CGFloat(pressure))
    }

    func hardwareButton(_ button: String, action: String) -> Bool {
        bridge.hardwareButton(button, action: action)
    }

    func injectText(_ text: String) { bridge.injectText(text) }
    func injectKey(_ key: String, action: String) { bridge.injectKey(key, action: action) }
    func releaseEveryKeys() { bridge.releaseEveryKeys() }
    func setKeepAliveInterval(_ seconds: Double) { bridge.setKeepAliveInterval(seconds) }
}
