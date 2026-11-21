import Foundation
import Darwin

/// 对齐官方 Direct 拉 Helper：旁路 watchdog 进程，主进程崩了再拉起本 App。
enum ProcessWatchdog {
    private static let roleKey = "PHONEBASE_ROLE"
    private static let parentKey = "PHONEBASE_PARENT_PID"
    private static let throttleSec: useconds_t = 2_000_000

    /// 若自身是 watchdog 则进入守护循环且永不返回 true；否则拉起守护子进程。
    @discardableResult
    static func bootstrapIfNeeded() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env[roleKey] == "watchdog" {
            runWatchdog(parentPid: Int32(env[parentKey] ?? "") ?? 0)
        }
        spawnWatchdog()
        return false
    }

    private static func spawnWatchdog() {
        guard let exec = Bundle.main.executablePath else { return }
        var pid: pid_t = 0
        let parent = String(getpid())
        var argv = cStringArray([exec])
        defer { freeCStringArray(argv) }
        var envList: [String] = []
        for (k, v) in ProcessInfo.processInfo.environment where k != roleKey && k != parentKey {
            envList.append("\(k)=\(v)")
        }
        envList.append("\(roleKey)=watchdog")
        envList.append("\(parentKey)=\(parent)")
        var envp = cStringArray(envList)
        defer { freeCStringArray(envp) }

        let rc = argv.withUnsafeMutableBufferPointer { argBuf in
            envp.withUnsafeMutableBufferPointer { envBuf in
                posix_spawn(&pid, exec, nil, nil, argBuf.baseAddress, envBuf.baseAddress)
            }
        }
        if rc == 0 {
            NSLog("[Watchdog] spawned pid=%d for parent=%@", pid, parent)
        } else {
            NSLog("[Watchdog] spawn failed rc=%d", rc)
        }
    }

    private static func runWatchdog(parentPid: pid_t) -> Never {
        NSLog("[Watchdog] watching parent=%d", parentPid)
        guard parentPid > 1 else { exit(0) }
        while true {
            if kill(parentPid, 0) != 0 {
                NSLog("[Watchdog] parent %d gone → relaunch", parentPid)
                usleep(throttleSec)
                relaunchApp()
                exit(0)
            }
            usleep(500_000)
        }
    }

    private static func relaunchApp() {
        let bid = Bundle.main.bundleIdentifier ?? "cn.iosmirror.base"
        if openApplication(bid) { return }
        guard let exec = Bundle.main.executablePath else { return }
        var pid: pid_t = 0
        var argv = cStringArray([exec])
        defer { freeCStringArray(argv) }
        // 必须去掉 watchdog 角色，否则子进程会当守护进程空转
        var envList: [String] = []
        for (k, v) in ProcessInfo.processInfo.environment where k != roleKey && k != parentKey {
            envList.append("\(k)=\(v)")
        }
        var envp = cStringArray(envList)
        defer { freeCStringArray(envp) }
        let rc = argv.withUnsafeMutableBufferPointer { argBuf in
            envp.withUnsafeMutableBufferPointer { envBuf in
                posix_spawn(&pid, exec, nil, nil, argBuf.baseAddress, envBuf.baseAddress)
            }
        }
        NSLog("[Watchdog] posix_spawn relaunch pid=%d rc=%d", pid, rc)
    }

    private static func openApplication(_ bundleId: String) -> Bool {
        guard let workspace = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return false
        }
        let selDefault = NSSelectorFromString("defaultWorkspace")
        guard workspace.responds(to: selDefault),
              let ws = workspace.perform(selDefault)?.takeUnretainedValue() as? NSObject
        else { return false }
        let selOpen = NSSelectorFromString("openApplicationWithBundleID:")
        guard ws.responds(to: selOpen) else { return false }
        _ = ws.perform(selOpen, with: bundleId)
        NSLog("[Watchdog] openApplication %@", bundleId)
        return true
    }

    private static func cStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }

    private static func freeCStringArray(_ arr: [UnsafeMutablePointer<CChar>?]) {
        for p in arr where p != nil { free(p) }
    }
}
