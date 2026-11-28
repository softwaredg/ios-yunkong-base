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
    /// - Returns: Helper 是否已在 11019 健康听口（waitHealthy 时）；失败则调用方应软恢复，勿盲目 exit。
    @discardableResult
    static func spawnDeferredRelaunch(delayMs: UInt32 = 1500, waitHealthy: Bool = true) -> Bool {
        if ProcessRole.isHelper {
            let ok = HelperLauncher.spawnReplacementHelper(waitHealthy: waitHealthy)
            if !waitHealthy, delayMs > 0 { usleep(delayMs * 1000) }
            return ok
        }
        if BaseRuntime.shared.isRunning {
            if Thread.isMainThread {
                BaseRuntime.shared.stop()
            } else {
                DispatchQueue.main.sync { BaseRuntime.shared.stop() }
            }
            // 给内核一点时间释放 11019，否则 Helper bind 失败后主进程又 exit → Wi‑Fi 整晚空窗
            usleep(400_000)
        }
        let ok = HelperLauncher.spawnReplacementHelper(waitHealthy: waitHealthy)
        if !waitHealthy, delayMs > 0 { usleep(delayMs * 1000) }
        if ok {
            AppRunLog.shared.append("看门狗：Helper 已听口，可安全退出主进程")
        } else {
            AppRunLog.shared.append("看门狗：Helper 未就绪（waitHealthy=\(waitHealthy ? 1 : 0)）")
        }
        return ok
    }
}
