import Foundation
import Darwin
import UIKit // mobile Helper 用 UIApplication.open；root 模式勿碰 UIApplication.shared

/// 仅在 Helper 进程运行：监视主 App / 装后标记；投屏由本进程 BaseRuntime 常驻。
final class HelperSupervisor {
    static let shared = HelperSupervisor()

    private var queue: DispatchQueue?
    /// 父进程退出后稍等再拉起（覆盖安装落盘）
    private let updateInitialDelayUs: useconds_t = 3_000_000
    private let retryUs: useconds_t = 3_000_000
    private let windowSec: TimeInterval = 180
    /// 装后拉起最多 3 个窗口（约 3×(3s+3min)），避免失败后永久空转
    private let maxPullWindows = 3
    private var lastUiPullAt: Date = .distantPast
    private var uiPullPending = true

    func start() {
        guard ProcessRole.isHelper else { return }
        if queue != nil { return }
        let q = DispatchQueue(label: "cn.iosmirror.base.helper-supervisor")
        queue = q
        q.async { [weak self] in
            self?.runLoop()
        }
    }

    private func runLoop() {
        let parent = ProcessRole.parentPid
        var armed = false
        var pullWindows = 0
        NSLog(
            "[HelperSupervisor] watch parent=%d marker=%d expect=%@",
            parent, UpdateMarker.exists ? 1 : 0, ProcessRole.expectVersion
        )
        while true {
            // 装后标记：父进程退出后拉主 UI 完成升级
            let shouldArm = UpdateMarker.exists
            if shouldArm && !armed {
                armed = true
                pullWindows = 0
                NSLog("[HelperSupervisor] marker → post-update")
            } else if !shouldArm && armed {
                armed = false
                pullWindows = 0
                NSLog("[HelperSupervisor] marker cleared → disarm")
            }
            let parentGone = parent > 1 && kill(parent, 0) != 0
            if armed && (parentGone || parent <= 1) {
                let expect = ProcessRole.expectVersion
                pullWindows += 1
                NSLog("[HelperSupervisor] pull main window=%d expect=%@", pullWindows, expect)
                AppRunLog.shared.append("Supervisor 装后拉起 window=\(pullWindows) expect=\(expect)")
                usleep(updateInitialDelayUs)
                guard UpdateMarker.exists else {
                    armed = false
                    pullWindows = 0
                    continue
                }
                let ok = pullMainUntilReady(expectVersion: expect)
                if ok || pullWindows >= maxPullWindows {
                    UpdateMarker.clear()
                    armed = false
                    NSLog(
                        "[HelperSupervisor] done ok=%d windows=%d",
                        ok ? 1 : 0, pullWindows
                    )
                } else {
                    NSLog("[HelperSupervisor] window failed, will retry")
                    usleep(retryUs)
                }
                continue
            }

            // 日常：应开服且主 UI 不在 → 限频拉回界面（投屏已由 Helper 续服，不依赖主 UI）
            if !armed, ServeIntent.shouldServe, !HelperLauncher.isMainAppAlive() {
                if uiPullPending, Date().timeIntervalSince(lastUiPullAt) >= 60 {
                    lastUiPullAt = Date()
                    uiPullPending = false
                    AppRunLog.shared.append("Supervisor：主 UI 不在，拉回界面（Helper 继续服役）")
                    fireLaunchMain()
                }
            } else {
                uiPullPending = true
            }

            usleep(500_000)
        }
    }

    @discardableResult
    private func pullMainUntilReady(expectVersion: String) -> Bool {
        let deadline = Date().addingTimeInterval(windowSec)
        var n = 0
        while Date() < deadline {
            n += 1
            fireLaunchMain()
            if HelperLauncher.isMainAppAlive() {
                usleep(800_000)
                fireLaunchMain()
                NSLog("[HelperSupervisor] main alive after %d expect=%@", n, expectVersion)
                return true
            }
            if n >= 2, HelperLauncher.tipaHealthy(expectVersion: "") {
                fireLaunchMain()
            }
            NSLog("[HelperSupervisor] attempt %d", n)
            usleep(retryUs)
        }
        fireLaunchMain()
        return HelperLauncher.isMainAppAlive()
    }

    private func fireLaunchMain() {
        let bid = ProcessRole.mainBundleId
        openApplication(bid)
        openPhonebaseURL()
    }

    private func openPhonebaseURL() {
        guard let url = URL(string: "phonebase://relaunch") else { return }
        if getuid() != 0 {
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:]) { _ in sem.signal() }
            }
            _ = sem.wait(timeout: .now() + 2)
        }
        guard let workspace = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return }
        let selDefault = NSSelectorFromString("defaultWorkspace")
        guard workspace.responds(to: selDefault),
              let ws = workspace.perform(selDefault)?.takeUnretainedValue() as? NSObject
        else { return }
        let sel = NSSelectorFromString("openSensitiveURL:withOptions:")
        if ws.responds(to: sel) {
            _ = ws.perform(sel, with: url, with: nil)
        }
    }

    private func openApplication(_ bundleId: String) {
        guard let workspace = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return }
        let selDefault = NSSelectorFromString("defaultWorkspace")
        guard workspace.responds(to: selDefault),
              let ws = workspace.perform(selDefault)?.takeUnretainedValue() as? NSObject
        else { return }
        let selOpen = NSSelectorFromString("openApplicationWithBundleID:")
        guard ws.responds(to: selOpen) else { return }
        _ = ws.perform(selOpen, with: bundleId)
    }
}
