import Foundation
import Darwin

/// 兼容入口：主 App 不再同包自 spawn；装后/崩溃拉起交给 PhoneBaseHelper。
enum ProcessWatchdog {
    @discardableResult
    static func bootstrapIfNeeded() -> Bool { false }

    static func prepareForSelfUpdate(expectVersion: String) {
        HelperLauncher.armPostUpdate(expectVersion: expectVersion)
    }

    /// BaseRuntime 硬退出前调用（内存守卫 / control hard）。
    /// Helper 只拉替身续服；不写装后标记，避免误把主 UI 拉回前台。
    static func spawnDeferredRelaunch(delayMs: UInt32 = 1500) {
        if ProcessRole.isHelper {
            _ = HelperLauncher.spawnReplacementHelper()
            if delayMs > 0 { usleep(delayMs * 1000) }
        } else {
            // 主 UI 进程不应再跑 BaseRuntime；兜底仍拉 Helper 续服
            _ = HelperLauncher.ensureRunning()
        }
    }
}
