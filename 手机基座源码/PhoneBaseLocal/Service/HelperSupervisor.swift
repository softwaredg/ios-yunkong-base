import Foundation
import Darwin
import UIKit

/// 仅在 Helper 进程运行：监视主 App / 装后标记，负责把主 App 拉回前台。
final class HelperSupervisor {
    static let shared = HelperSupervisor()

    private var queue: DispatchQueue?
    /// 父进程退出后稍等再拉起（覆盖安装落盘）
    private let updateInitialDelayUs: useconds_t = 3_000_000
    private let retryUs: useconds_t = 3_000_000
    private let windowSec: TimeInterval = 180
    /// 装后拉起最多 3 个窗口（约 3×(3s+3min)），避免失败后永久空转
    private let maxPullWindows = 3

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
            // 只认标记文件：用户点「稍后」清标记后必须解除武装，避免普通退出被拉回
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
                // 等待期间用户可能取消：再确认一次标记
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
            }
            // 主 UI 普通退出：Helper 继续跑服务，不强行把 UI 拉回前台
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
            // 装后本 Helper 仍是旧二进制，/api/info 版本会对不上 expect；
            // 以主 UI 进程存活为准，再补一次 open 把界面拉到前台。
            if HelperLauncher.isMainAppAlive() {
                usleep(800_000)
                fireLaunchMain()
                NSLog("[HelperSupervisor] main alive after %d expect=%@", n, expectVersion)
                return true
            }
            // 兜底：无版本要求的健康探活（主进程名枚举失败时）
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
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { _ in sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 2)
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
