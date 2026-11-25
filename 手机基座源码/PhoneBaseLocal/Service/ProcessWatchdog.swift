import Foundation
import Darwin
import UIKit

/// 旁路 watchdog：主进程崩了 / jetsam / 巨魔覆盖后，尽量再拉起本 App。
///
/// 巨魔装完常出现：看门狗还在，但 `openApplication` 一次不够（安装未注册完 / 巨魔占前台）。
/// 因此装后路径改为：长等待 → 多通道拉起 → 以本机 11019 /api/info 健康为准，最长约 3 分钟。
enum ProcessWatchdog {
    private static let roleKey = "PHONEBASE_ROLE"
    private static let parentKey = "PHONEBASE_PARENT_PID"
    private static let postUpdateKey = "PHONEBASE_POST_UPDATE"
    private static let expectVerKey = "PHONEBASE_EXPECT_VER"
    private static let delayMsKey = "PHONEBASE_DELAY_MS"

    private static let crashInitialDelayUs: useconds_t = 2_000_000
    private static let crashRetryUs: useconds_t = 2_000_000
    private static let crashWindowSec: TimeInterval = 45

    /// 巨魔覆盖写盘 + 重新注册通常需要十余秒，太早 open 会失败
    private static let updateInitialDelayUs: useconds_t = 20_000_000
    private static let updateRetryUs: useconds_t = 3_000_000
    private static let updateWindowSec: TimeInterval = 180

    @discardableResult
    static func bootstrapIfNeeded() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let role = env[roleKey] ?? ""

        if role == "relauncher" {
            let delayMs = UInt32(env[delayMsKey] ?? "") ?? 2000
            let expect = env[expectVerKey] ?? readMarkerVersion() ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                runRelauncher(delayMs: delayMs, expectVersion: expect, postUpdate: true)
            }
            return true
        }

        if role == "watchdog" {
            let parent = Int32(env[parentKey] ?? "") ?? 0
            let postUpdate = (env[postUpdateKey] == "1") || markerExists()
            let expect = env[expectVerKey] ?? readMarkerVersion() ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                runWatchdog(parentPid: parent, postUpdate: postUpdate, expectVersion: expect)
            }
            return true
        }

        spawnChild(role: "watchdog", postUpdate: false, expectVersion: "", parentPid: getpid())
        // 主进程启动时若上次看门狗留了尝试记录，写进运行日志方便排查
        absorbAttemptLog()
        return false
    }

    /// 跳转巨魔前：武装 watchdog + 定时 relauncher（不依赖“父进程已死”的判定时机）。
    static func prepareForSelfUpdate(expectVersion: String) {
        writeMarker(expectVersion: expectVersion)
        spawnChild(role: "watchdog", postUpdate: true, expectVersion: expectVersion, parentPid: getpid())
        // 25s 后不管父进程怎样都开始拉；覆盖「父进程很晚才死 / 看门狗误判」
        spawnChild(
            role: "relauncher",
            postUpdate: true,
            expectVersion: expectVersion,
            parentPid: 0,
            delayMs: 25_000
        )
        NSLog("[Watchdog] armed post-update expect=%@", expectVersion)
        AppRunLog.shared.append("已武装装后自动拉起 expect=\(expectVersion)")
    }

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

    private static func attemptLogURL() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("phonebase-watchdog-attempts.log")
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

    private static func noteAttempt(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let row = "[\(stamp)] \(line)\n"
        let url = attemptLogURL()
        if let data = row.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url)
            {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
        NSLog("[Watchdog] %@", line)
    }

    private static func absorbAttemptLog() {
        let url = attemptLogURL()
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return }
        let tail = text.split(separator: "\n").suffix(6).joined(separator: "\n")
        AppRunLog.shared.append("看门狗上次尝试：\n\(tail)")
        try? FileManager.default.removeItem(at: url)
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
        }
        if !expectVersion.isEmpty {
            envList.append("\(expectVerKey)=\(expectVersion)")
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
            NSLog("[Watchdog] spawned role=%@ pid=%d parent=%d delayMs=%u", role, pid, parentPid, delayMs)
        } else {
            NSLog("[Watchdog] spawn role=%@ failed rc=%d", role, rc)
        }
    }

    private static func runRelauncher(delayMs: UInt32, expectVersion: String, postUpdate: Bool) -> Never {
        noteAttempt("relauncher sleep \(delayMs)ms expect=\(expectVersion)")
        if delayMs > 0 { usleep(delayMs * 1000) }
        if postUpdate {
            // 再给巨魔一点写盘时间
            usleep(5_000_000)
            _ = pullUntilHealthy(expectVersion: expectVersion, windowSec: updateWindowSec)
        } else {
            let bid = Bundle.main.bundleIdentifier ?? "cn.iosmirror.base"
            for i in 1 ... 10 {
                fireLaunch(bid)
                if tipaHealthy(expectVersion: expectVersion) { break }
                noteAttempt("relauncher attempt \(i)")
                usleep(1_500_000)
            }
        }
        exit(0)
    }

    private static func runWatchdog(parentPid: pid_t, postUpdate: Bool, expectVersion: String) -> Never {
        var armed = postUpdate
        noteAttempt("watch parent=\(parentPid) postUpdate=\(armed) expect=\(expectVersion)")
        guard parentPid > 1 else { exit(0) }
        while true {
            if !armed && markerExists() {
                armed = true
                noteAttempt("marker → post-update mode")
            }
            if kill(parentPid, 0) != 0 {
                noteAttempt("parent \(parentPid) gone postUpdate=\(armed)")
                if armed || markerExists() {
                    let expect = expectVersion.isEmpty ? (readMarkerVersion() ?? "") : expectVersion
                    usleep(updateInitialDelayUs)
                    _ = pullUntilHealthy(expectVersion: expect, windowSec: updateWindowSec)
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
            fireLaunch(bid)
            if tipaHealthy(expectVersion: "") {
                noteAttempt("crash relaunch healthy after \(n)")
                return
            }
            usleep(crashRetryUs)
        }
        fireLaunch(bid)
    }

    /// 直到本机 tipa HTTP 健康或超时。
    @discardableResult
    private static func pullUntilHealthy(expectVersion: String, windowSec: TimeInterval) -> Bool {
        let bid = Bundle.main.bundleIdentifier ?? "cn.iosmirror.base"
        let deadline = Date().addingTimeInterval(windowSec)
        var n = 0
        while Date() < deadline {
            n += 1
            fireLaunch(bid)
            if tipaHealthy(expectVersion: expectVersion) {
                noteAttempt("healthy after attempt \(n) expect=\(expectVersion)")
                clearMarker()
                return true
            }
            noteAttempt("pull attempt \(n) not healthy yet")
            usleep(updateRetryUs)
        }
        fireLaunch(bid)
        noteAttempt("pull window done attempts=\(n) healthy=\(tipaHealthy(expectVersion: expectVersion))")
        return tipaHealthy(expectVersion: expectVersion)
    }

    private static func fireLaunch(_ bundleId: String) {
        openApplication(bundleId)
        openPhonebaseURL()
        relaunchViaSpawn()
    }

    private static func openPhonebaseURL() {
        guard let url = URL(string: "phonebase://relaunch") else { return }
        // 主线程 open，旁路进程也有 UIApplication
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                NSLog("[Watchdog] open phonebase:// ok=%d", ok ? 1 : 0)
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 2)
        // 再走 LS openSensitiveURL
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

    /// 本机 11019 能返回 info 即视为已拉起（可选校验 release.version）。
    private static func tipaHealthy(expectVersion: String) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11019/api/info") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 1.2)
        req.setValue("close", forHTTPHeaderField: "Connection")
        let sem = DispatchSemaphore(value: 0)
        var healthy = false
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, let data, !data.isEmpty else {
                return
            }
            if expectVersion.isEmpty {
                healthy = true
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                healthy = true
                return
            }
            let release = obj["release"] as? [String: Any]
            let ver = (release?["version"] as? String)
                ?? (obj["appVersion"] as? String)
                ?? ""
            if ver.isEmpty {
                healthy = true
            } else {
                healthy = (ver == expectVersion) || ver.compare(expectVersion, options: .numeric) != .orderedAscending
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 1.8)
        return healthy
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
        return true
    }

    private static func cStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }

    private static func freeCStringArray(_ arr: [UnsafeMutablePointer<CChar>?]) {
        for p in arr where p != nil { free(p) }
    }
}
