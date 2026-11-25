import Foundation
import Darwin

/// 兼容入口：主 App 不再同包自 spawn；装后/崩溃拉起交给 PhoneBaseHelper。
enum ProcessWatchdog {
    @discardableResult
    static func bootstrapIfNeeded() -> Bool { false }

    static func prepareForSelfUpdate(expectVersion: String) {
        HelperLauncher.armPostUpdate(expectVersion: expectVersion)
    }

    /// BaseRuntime 硬退出前调用。
    static func spawnDeferredRelaunch(delayMs: UInt32 = 1500) {
        let expect = TipaSelfUpdate.localVersion
        UpdateMarker.write(expectVersion: expect)
        if ProcessRole.isHelper {
            // 当前 helper 即将 exit：先拉替身，再留给系统回收本进程
            _ = HelperLauncher.spawnReplacementHelper(expectVersion: expect)
            if delayMs > 0 { usleep(delayMs * 1000) }
        } else {
            HelperLauncher.armPostUpdate(expectVersion: expect)
        }
    }
}
