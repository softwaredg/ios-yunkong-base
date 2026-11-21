import Foundation
import UIKit

protocol TouchInjector: AnyObject {
    func pointer(action: String, x: Double, y: Double)
    func pressHome()
    /// 双击 Home → 多任务/App Switcher
    func pressAppSwitcher()
    func injectText(_ text: String)
    func injectKey(_ key: String)
}

enum TouchInjectors {
    /// 优先 IOHID；符号/权限不足时退回仅日志。
    static func best() -> TouchInjector {
        if let hid = IOHIDTouchInjector.makeIfPossible() {
            return hid
        }
        NSLog("[Touch] using LogTouchInjector (no IOHID)")
        return LogTouchInjector()
    }
}

/// 默认实现：仅日志。系统级注入见 `IOHIDTouchInjector`。
final class LogTouchInjector: TouchInjector {
    func pointer(action: String, x: Double, y: Double) {
        NSLog("[Touch] %@ (%.4f, %.4f)", action, x, y)
    }

    func pressHome() {
        NSLog("[Touch] home")
    }

    func pressAppSwitcher() {
        NSLog("[Touch] app-switcher")
    }

    func injectText(_ text: String) {
        NSLog("[Touch] text len=%d", text.utf8.count)
    }

    func injectKey(_ key: String) {
        NSLog("[Touch] key %@", key)
    }
}
