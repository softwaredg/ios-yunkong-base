import Foundation
import Darwin

/// 旁路 watchdog：主进程崩了 / jetsam / 巨魔覆盖后，尽量再拉起本 App。
///
/// 关键约束：
/// - 守护循环必须在**后台队列**跑，主线程要留给 UIApplication + 音频保活，否则子进程秒挂起。
/// - `exit(0)` 前再 spawn 一次性 relauncher，不依赖长驻看门狗是否还活着。
enum ProcessWatchdog {
    private static let roleKey = "PHONEBASE_ROLE"
    private static let parentKey = "PHONEBASE_PARENT_PID"
    private static let postUpdateKey = "PHONEBASE_POST_UPDATE"
    private static let expectVerKey = "PHONEBASE_EXPECT_VER"
    private static let delayMsKey = "PHONEBASE_DELAY_MS"

    private static let crashInitialDelayUs: useconds_t = 2_000_000
    private static let crashRetryUs: useconds_t = 2_000_000
    /// jetsam 后 SpringBoard 可能短暂拒开，拉长窗口
    private static let crashWindowSec: TimeInterval = 45

    private static let updateInitialDelayUs: useconds_t = 5_000_000
    private static let updateRetryUs: useconds_t = 2_500_000
    private static let updateWindowSec: TimeInterval = 90

    /// - Returns: `true` = 本进程是 watchdog/relauncher（主进程勿启服务，但须保活 runloop）
    @discardableResult
    static func bootstrapIfNeeded() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let role = env[roleKey] ?? ""

        if role == "relauncher" {
            let delayMs = UInt32(env[delayMsKey] ?? "") ?? 2000
            DispatchQueue.global(qos: .userInitiated).async {
                runRelauncher(delayMs: delayMs)
            }
            return true
        }

        if role == "watchdog" {
            let parent = Int32(env[parentKey] ?? "") ?? 0
            let postUpdate = (env[postUpdateKey] == "1") || markerExists()
            let expect = env[expectVerKey] ?? readMarkerVersion() ?? ""
            // 绝不能在主线程 usleep：否则无音频保活、立刻被挂起，父进程死后无人拉起
            DispatchQueue.global(qos: .userInitiated).async {
                runWatchdog(parentPid: parent, postUpdate: postUpdate, expectVersion: expect)
            }
            return true
        }

        spawnChild(role: "watchdog", postUpdate: false, expectVersion: "", parentPid: getpid())
        return false
    }

    /// 跳转巨魔安装前：写标记并拉起 post-update watchdog。
    static func prepareForSelfUpdate(expectVersion: String) {
        writeMarker(expectVersion: expectVersion)
        spawnChild(role: "watchdog", postUpdate: true, expectVersion: expectVersion, parentPid: getpid())
        NSLog("[Watchdog] armed post-update expect=%@", expectVersion)
        AppRunLog.shared.append("已武装装后自动拉起 expect=\(expectVersion)")
    }

    /// 主动 `exit` 前调用：spawn 短命 relauncher，不依赖长驻看门狗。
    static func spawnDeferredRelaunch(delayMs: UInt32 = 1500) {
        spawnChild(
            role: "relauncher",
            postUpdate: false,
            expectVersion: "",
            parentPid: 0,
            delayMs: delayMs
        )
        NSLog("[Watchdog] spawned deferred relauncher delayMs=%u", delayMs)
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
        let v = text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v : nil
    }

    private static func clearMarker() {
        try? FileManager.default.removeItem(at: markerURL())
    }

    private static func spawnChild(
        role: String,
        postUpdate: Bool,
        expectVersion: String,
        parentPid: pid_t,
        delayMs: UInt32 = 0
    ) {
        guard let exec = Bundle.main.executablePath else { return }
        var pid: pid_t = 0
        var argv = cStringArray([exec])
        defer { freeCStringArray(argv) }
        var envList: [String] = []
        for (k, v) in ProcessInfo.processInfo.environment
            where k != roleKey && k != parentKey && k != postUpdateKey
            && k != expectVerKey && k != delayMsKey
        {
            envList.append("\(k)=\(v)")
        }
        envList.append("\(roleKey)=\(role)")
        if parentPid > 0 {
            envList.append("\(parentKey)=\(parentPid)")
        }
        if postUpdate {
            envList.append("\(postUpdateKey)=1")
            if !expectVersion.isEmpty {
                envList.append("\(expectVerKey)=\(expectVersion)")
            }
        }
        if delayMs > 0 {
            envList.append("\(delayMsKey)=\(delayMs)")
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
        if rc == 0 {
            NSLog("[Watchdog] spawned role=%@ pid=%d parent=%d", role, pid, parentPid)
        } else {
            NSLog("[Watchdog] spawn role=%@ failed rc=%d", role, rc)
        }
    }

    private static func runRelauncher(delayMs: UInt32) -> Never {
        NSLog("[Watchdog] relauncher sleep %u ms", delayMs)
        if delayMs > 0 { usleep(delayMs * 1000) }
        let bid = Bundle.main.bundleIdentifier ?? "cn.iosmirror.base"
        for i in 1 ... 8 {
            openApplication(bid)
            if i == 1 || i == 4 { relaunchViaSpawn() }
            NSLog("[Watchdog] relauncher attempt %d", i)
            usleep(1_500_000)
        }
        exit(0)
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
                    relaunchAfterUpdate(
                        expectVersion: expectVersion.isEmpty ? (readMarkerVersion() ?? "") : expectVersion
                    )
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
        let deadline = Date().addingTimeInterval(crashWindowSec)
        var n = 0
        while Date() < deadline {
            n += 1
            openApplication(bid)
            if n == 1 || n % 3 == 0 { relaunchViaSpawn() }
            NSLog("[Watchdog] crash relaunch attempt %d", n)
            usleep(crashRetryUs)
        }
        openApplication(bid)
    }

    private static func relaunchAfterUpdate(expectVersion: String) {
        usleep(updateInitialDelayUs)
        let bid = Bundle.main.bundleIdentifier ?? "cn.iosmirror.base"
        let deadline = Date().addingTimeInterval(updateWindowSec)
        var n = 0
        while Date() < deadline {
            n += 1
            openApplication(bid)
            if n == 1 || n % 3 == 0 { relaunchViaSpawn() }
            NSLog("[Watchdog] post-update relaunch attempt %d expect=%@", n, expectVersion)
            usleep(updateRetryUs)
        }
        openApplication(bid)
        NSLog("[Watchdog] post-update window done attempts=%d", n)
    }

    private static func relaunchViaSpawn() {
        guard let exec = Bundle.main.executablePath else { return }
        var pid: pid_t = 0
        var argv = cStringArray([exec])
        defer { freeCStringArray(argv) }
        var envList: [String] = []
        for (k, v) in ProcessInfo.processInfo.environment
            where k != roleKey && k != parentKey && k != postUpdateKey
            && k != expectVerKey && k != delayMsKey
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
