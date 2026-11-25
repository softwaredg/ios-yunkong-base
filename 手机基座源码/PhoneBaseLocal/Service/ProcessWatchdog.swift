import Foundation
import Darwin

/// 旁路 watchdog：主进程崩了 / 被巨魔覆盖杀掉后，尽量再拉起本 App。
/// 独立进程组，降低与主进程一同被 jetsam / killpg 清掉的概率。
/// 巨魔自更新：安装前 `prepareForSelfUpdate` 写标记；父进程死后延迟 + 长窗口重试 open。
enum ProcessWatchdog {
    private static let roleKey = "PHONEBASE_ROLE"
    private static let parentKey = "PHONEBASE_PARENT_PID"
    private static let postUpdateKey = "PHONEBASE_POST_UPDATE"
    private static let expectVerKey = "PHONEBASE_EXPECT_VER"

    /// 崩溃恢复：短等后有限次重试
    private static let crashInitialDelayUs: useconds_t = 2_000_000
    private static let crashRetryUs: useconds_t = 1_500_000
    private static let crashAttempts = 4

    /// 自更新：先等巨魔写完再拉，窗口对齐 PC agent tipa relaunch（~90s）
    private static let updateInitialDelayUs: useconds_t = 5_000_000
    private static let updateRetryUs: useconds_t = 2_500_000
    private static let updateWindowSec: TimeInterval = 90

    /// 若自身是 watchdog 则进入守护循环且永不返回；否则拉起守护子进程。
    @discardableResult
    static func bootstrapIfNeeded() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env[roleKey] == "watchdog" {
            let parent = Int32(env[parentKey] ?? "") ?? 0
            let postUpdate = (env[postUpdateKey] == "1") || markerExists()
            let expect = env[expectVerKey] ?? readMarkerVersion() ?? ""
            runWatchdog(parentPid: parent, postUpdate: postUpdate, expectVersion: expect)
        }
        spawnWatchdog(postUpdate: false, expectVersion: "")
        return false
    }

    /// 跳转巨魔安装前调用：写标记并（再）拉起带 post-update 的 watchdog。
    static func prepareForSelfUpdate(expectVersion: String) {
        writeMarker(expectVersion: expectVersion)
        spawnWatchdog(postUpdate: true, expectVersion: expectVersion)
        NSLog("[Watchdog] armed post-update expect=%@", expectVersion)
        AppRunLog.shared.append("已武装装后自动拉起 expect=\(expectVersion)")
    }

    private static func markerURL() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("phonebase-post-update.flag")
    }

    private static func writeMarker(expectVersion: String) {
        let body = "\(expectVersion)\n\(Date().timeIntervalSince1970)\n"
        try? body.write(to: markerURL(), atomically: true, encoding: .utf8)
    }

    private static func markerExists() -> Bool {
        FileManager.default.fileExists(atPath: markerURL().path)
    }

    private static func readMarkerVersion() -> String? {
        guard let text = try? String(contentsOf: markerURL(), encoding: .utf8) else { return nil }
        let v = text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v : nil
    }

    private static func clearMarker() {
        try? FileManager.default.removeItem(at: markerURL())
    }

    private static func spawnWatchdog(postUpdate: Bool, expectVersion: String) {
        guard let exec = Bundle.main.executablePath else { return }
        var pid: pid_t = 0
        let parent = String(getpid())
        var argv = cStringArray([exec])
        defer { freeCStringArray(argv) }
        var envList: [String] = []
        for (k, v) in ProcessInfo.processInfo.environment
            where k != roleKey && k != parentKey && k != postUpdateKey && k != expectVerKey
        {
            envList.append("\(k)=\(v)")
        }
        envList.append("\(roleKey)=watchdog")
        envList.append("\(parentKey)=\(parent)")
        if postUpdate {
            envList.append("\(postUpdateKey)=1")
            if !expectVersion.isEmpty {
                envList.append("\(expectVerKey)=\(expectVersion)")
            }
        }
        var envp = cStringArray(envList)
        defer { freeCStringArray(envp) }

        // iOS SDK: posix_spawnattr_t is an opaque pointer — must start as nil, not ().
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        defer { posix_spawnattr_destroy(&attr) }

        let rc = argv.withUnsafeMutableBufferPointer { argBuf in
            envp.withUnsafeMutableBufferPointer { envBuf in
                posix_spawn(&pid, exec, nil, &attr, argBuf.baseAddress, envBuf.baseAddress)
            }
        }
        if rc == 0 {
            NSLog(
                "[Watchdog] spawned pid=%d parent=%@ postUpdate=%d",
                pid, parent, postUpdate ? 1 : 0
            )
        } else {
            NSLog("[Watchdog] spawn failed rc=%d", rc)
        }
    }

    private static func runWatchdog(parentPid: pid_t, postUpdate: Bool, expectVersion: String) -> Never {
        var armed = postUpdate
        NSLog(
            "[Watchdog] watching parent=%d postUpdate=%d expect=%@",
            parentPid, armed ? 1 : 0, expectVersion
        )
        guard parentPid > 1 else { exit(0) }
        while true {
            if !armed && markerExists() {
                armed = true
                NSLog("[Watchdog] marker seen → post-update mode")
            }
            if kill(parentPid, 0) != 0 {
                NSLog("[Watchdog] parent %d gone → relaunch (postUpdate=%d)", parentPid, armed ? 1 : 0)
                if armed || markerExists() {
                    relaunchAfterUpdate(expectVersion: expectVersion.isEmpty ? (readMarkerVersion() ?? "") : expectVersion)
                } else {
                    relaunchAfterCrash()
                }
                clearMarker()
                exit(0)
            }
            usleep(500_000)
        }
    }

    private static func relaunchAfterCrash() {
        usleep(crashInitialDelayUs)
        let bid = Bundle.main.bundleIdentifier ?? "cn.iosmirror.base"
        for i in 0 ..< crashAttempts {
            openApplication(bid)
            relaunchViaSpawn()
            NSLog("[Watchdog] crash relaunch attempt %d", i + 1)
            usleep(crashRetryUs)
        }
    }

    /// 巨魔覆盖安装：父进程会先被杀，包可能还在写盘 —— 先等再反复 open。
    private static func relaunchAfterUpdate(expectVersion: String) {
        usleep(updateInitialDelayUs)
        let bid = Bundle.main.bundleIdentifier ?? "cn.iosmirror.base"
        let deadline = Date().addingTimeInterval(updateWindowSec)
        var n = 0
        while Date() < deadline {
            n += 1
            openApplication(bid)
            // 装到一半时 posix_spawn 旧路径可能失败；成功则新进程会顶替，无妨多试
            if n == 1 || n % 3 == 0 {
                relaunchViaSpawn()
            }
            NSLog("[Watchdog] post-update relaunch attempt %d expect=%@", n, expectVersion)
            usleep(updateRetryUs)
        }
        // 最后再 open 一次
        openApplication(bid)
        NSLog("[Watchdog] post-update window done attempts=%d", n)
    }

    private static func relaunchViaSpawn() {
        guard let exec = Bundle.main.executablePath else { return }
        var pid: pid_t = 0
        var argv = cStringArray([exec])
        defer { freeCStringArray(argv) }
        // 必须去掉 watchdog 角色，否则子进程会当守护进程空转
        var envList: [String] = []
        for (k, v) in ProcessInfo.processInfo.environment
            where k != roleKey && k != parentKey && k != postUpdateKey && k != expectVerKey
        {
            envList.append("\(k)=\(v)")
        }
        var envp = cStringArray(envList)
        defer { freeCStringArray(envp) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        defer { posix_spawnattr_destroy(&attr) }
        let rc = argv.withUnsafeMutableBufferPointer { argBuf in
            envp.withUnsafeMutableBufferPointer { envBuf in
                posix_spawn(&pid, exec, nil, &attr, argBuf.baseAddress, envBuf.baseAddress)
            }
        }
        NSLog("[Watchdog] posix_spawn relaunch pid=%d rc=%d", pid, rc)
    }

    @discardableResult
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
