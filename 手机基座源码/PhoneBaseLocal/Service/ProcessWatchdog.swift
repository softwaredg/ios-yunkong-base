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
    /// Helper：拉替身续服。主进程：先停听再 spawn Helper（否则口被本进程占着 Helper 绑不上）。
    static func spawnDeferredRelaunch(delayMs: UInt32 = 1500) {
        if ProcessRole.isHelper {
            _ = HelperLauncher.spawnReplacementHelper()
            if delayMs > 0 { usleep(delayMs * 1000) }
            return
        }
        if BaseRuntime.shared.isRunning {
            if Thread.isMainThread {
                BaseRuntime.shared.stop()
            } else {
                DispatchQueue.main.sync { BaseRuntime.shared.stop() }
            }
            usleep(150_000)
        }
        // 不等待健康：随后本进程会 exit，Helper 起来后自行占口
        _ = HelperLauncher.spawnReplacementHelper()
        if delayMs > 0 { usleep(delayMs * 1000) }
    }
}
