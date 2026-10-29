import Foundation
import UIKit

/// phonebase-control → IOHID 能力面（Broadcast 目标仅日志桩）。
protocol IOHIDControlling: AnyObject {
    func pointer(action: String, x: Double, y: Double)
    func tap(x: Double, y: Double)
    func doubleTap(x: Double, y: Double)
    func longPress(x: Double, y: Double)
    func multiTouch(action: String, x: Double, y: Double, count: Int)
    func drag(x0: Double, y0: Double, x1: Double, y1: Double, duration: Double, curve: Bool)
    func pinch(x: Double, y: Double, w: Double, h: Double, scale: Double, angle: Double, duration: Double)
    func stylus(action: String, x: Double, y: Double, azimuth: Double, altitude: Double, pressure: Double)
    func hardwareButton(_ button: String, action: String) -> Bool
    func injectText(_ text: String)
    func injectKey(_ key: String, action: String)
    func releaseEveryKeys()
    func setKeepAliveInterval(_ seconds: Double)
}

final class LogIOHIDController: IOHIDControlling {
    func pointer(action: String, x: Double, y: Double) { NSLog("[IOHID] pointer %@ %.3f %.3f", action, x, y) }
    func tap(x: Double, y: Double) { NSLog("[IOHID] tap %.3f %.3f", x, y) }
    func doubleTap(x: Double, y: Double) { NSLog("[IOHID] doubleTap") }
    func longPress(x: Double, y: Double) { NSLog("[IOHID] longPress") }
    func multiTouch(action: String, x: Double, y: Double, count: Int) { NSLog("[IOHID] multitouch %@ %d", action, count) }
    func drag(x0: Double, y0: Double, x1: Double, y1: Double, duration: Double, curve: Bool) { NSLog("[IOHID] drag") }
    func pinch(x: Double, y: Double, w: Double, h: Double, scale: Double, angle: Double, duration: Double) { NSLog("[IOHID] pinch") }
    func stylus(action: String, x: Double, y: Double, azimuth: Double, altitude: Double, pressure: Double) { NSLog("[IOHID] stylus %@", action) }
    func hardwareButton(_ button: String, action: String) -> Bool { NSLog("[IOHID] button %@ %@", button, action); return true }
    func injectText(_ text: String) { NSLog("[IOHID] text len=%d", text.utf8.count) }
    func injectKey(_ key: String, action: String) { NSLog("[IOHID] key %@ %@", key, action) }
    func releaseEveryKeys() { NSLog("[IOHID] releaseKeys") }
    func setKeepAliveInterval(_ seconds: Double) { NSLog("[IOHID] keepalive %.1f", seconds) }
}
