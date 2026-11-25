import Foundation
import Darwin
import UIKit

/// 仅在 Helper 进程运行：监视主 App / 装后标记，负责把主 App 拉回前台。
final class HelperSupervisor {
    static let shared = HelperSupervisor()

    private var queue: DispatchQueue?
    private let updateInitialDelayUs: useconds_t = 20_000_000
    private let retryUs: useconds_t = 3_000_000
    private let windowSec: TimeInterval = 180

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
        var armed = ProcessRole.postUpdateArmed
        NSLog(
            "[HelperSupervisor] watch parent=%d armed=%d expect=%@",
            parent, armed ? 1 : 0, ProcessRole.expectVersion
        )
        while true {
            if !armed && UpdateMarker.exists {
                armed = true
                NSLog("[HelperSupervisor] marker → post-update")
            }
            let parentGone = parent > 1 && kill(parent, 0) != 0
            if armed && (parentGone || parent <= 1) {
                let expect = ProcessRole.expectVersion
                NSLog("[HelperSupervisor] pull main expect=%@", expect)
                usleep(updateInitialDelayUs)
                _ = pullMainUntilReady(expectVersion: expect)
                UpdateMarker.clear()
                armed = false
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
            // 服务应已在本 helper；再确认主 App 被打开后版本标记可清
            if HelperLauncher.tipaHealthy(expectVersion: expectVersion) {
                // 再 open 一次确保 UI 到前台
                fireLaunchMain()
                NSLog("[HelperSupervisor] healthy after %d", n)
                return true
            }
            NSLog("[HelperSupervisor] attempt %d", n)
            usleep(retryUs)
        }
        fireLaunchMain()
        return false
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
