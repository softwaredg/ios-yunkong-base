import Foundation
import Darwin

/// 主 App 拉起 / 停止包内独立 `PhoneBaseHelper`。
enum HelperLauncher {
    private static let helperName = ProcessRole.helperExecutableName
    private static let gate = NSLock()

    static var helperPath: String? {
        Bundle.main.bundlePath + "/" + helperName
    }

    static func isHelperAlive() -> Bool {
        let selfPid = getpid()
        return PortOccupancy.listProcessNames()
            .contains { $0.pid != selfPid && isHelperName($0.name) }
    }

    static func isHelperName(_ name: String) -> Bool {
        name.lowercased().hasPrefix("phonebasehelper")
    }

    /// 主 UI 进程是否在跑（装后 Supervisor 用它判断拉起是否成功）。
    static func isMainAppAlive() -> Bool {
        let selfPid = getpid()
        return PortOccupancy.listProcessNames().contains { p in
            guard p.pid != selfPid, p.pid > 1 else { return false }
            let n = p.name.lowercased()
            return n.hasPrefix("iosyunkong") || n.hasPrefix("phonebaselocal")
        }
    }

    /// 确保 Helper 在跑且版本 ≥ 本机；已满足则直接返回。
    /// - Note: 装 tipa 后旧 Helper 仍占口时，必须按版本踢掉再 spawn，否则会一直跑旧二进制。
    @discardableResult
    static func ensureRunning(postUpdate: Bool = false, expectVersion: String = "") -> Bool {
        gate.lock()
        defer { gate.unlock() }
        let expect = expectVersion.isEmpty ? TipaSelfUpdate.localVersion : expectVersion
        if postUpdate {
            UpdateMarker.write(expectVersion: expect, baselineLocal: TipaSelfUpdate.localVersion)
        }
        // pending 只表示「装后拉起」，探活不按版本卡死
        let healthyExpect = (expect == "pending") ? "" : expect
        if tipaHealthy(expectVersion: healthyExpect) {
            NSLog("[HelperLauncher] service already healthy expect=%@", expect)
            return true
        }
        // 先清旧 helper，再拉新的
        // 注意：不要因残留 UpdateMarker 就带 postUpdate 环境，否则取消安装后普通退出也会被拉回前台
        terminateHelpers(except: getpid())
        return spawnHelper(
            postUpdate: postUpdate,
            expectVersion: expect,
            waitHealthy: true
        )
    }

    static func armPostUpdate(expectVersion: String) {
        // expect 必须是目标新版本；空则用 pending 哨兵，避免写成 local 导致装前就被 resume 清掉
        let expect = expectVersion.isEmpty ? "pending" : expectVersion
        UpdateMarker.write(expectVersion: expect, baselineLocal: TipaSelfUpdate.localVersion)
        // 装前必须保留现有 Helper（装后靠它拉主 App）；只写标记，不因版本杀掉
        if tipaHealthy(expectVersion: "") {
            AppRunLog.shared.append("已武装装后拉起（服务仍在）expect=\(expect)")
            return
        }
        _ = ensureRunning(postUpdate: true, expectVersion: expect)
        AppRunLog.shared.append("已武装 Helper 装后拉起 expect=\(expect)")
    }

    /// Helper 硬退出前：立刻再 spawn 替身（不写装后标记、不拉主 UI）。
    @discardableResult
    static func spawnReplacementHelper() -> Bool {
        gate.lock()
        defer { gate.unlock() }
        return spawnHelper(postUpdate: false, expectVersion: "", waitHealthy: false)
    }

    static func terminateHelper() {
        gate.lock()
        defer { gate.unlock() }
        // 先礼貌停服
        _ = httpControlStop()
        usleep(200_000)
        terminateHelpers(except: getpid())
    }

    private static func terminateHelpers(except selfPid: pid_t) {
        for p in PortOccupancy.listProcessNames() where p.pid != selfPid && isHelperName(p.name) {
            kill(p.pid, SIGTERM)
            usleep(50_000)
            kill(p.pid, SIGKILL)
            NSLog("[HelperLauncher] killed helper %@(%d)", p.name, p.pid)
        }
    }

    @discardableResult
    private static func spawnHelper(postUpdate: Bool, expectVersion: String, waitHealthy: Bool) -> Bool {
        guard let exec = helperPath, FileManager.default.isExecutableFile(atPath: exec)
                || FileManager.default.fileExists(atPath: exec)
        else {
            NSLog("[HelperLauncher] missing helper at %@", helperPath ?? "?")
            AppRunLog.shared.append("缺少 PhoneBaseHelper，无法拉起服务")
            return false
        }
        var pid: pid_t = 0
        var argv = cStringArray([exec])
        defer { freeCStringArray(argv) }
        var envList: [String] = []
        for (k, v) in ProcessInfo.processInfo.environment
            where k != ProcessRole.roleKey && k != ProcessRole.parentKey
            && k != ProcessRole.postUpdateKey && k != ProcessRole.expectVerKey
        {
            envList.append("\(k)=\(v)")
        }
        envList.append("\(ProcessRole.roleKey)=helper")
        envList.append("\(ProcessRole.parentKey)=\(getpid())")
        if postUpdate {
            envList.append("\(ProcessRole.postUpdateKey)=1")
            if !expectVersion.isEmpty {
                envList.append("\(ProcessRole.expectVerKey)=\(expectVersion)")
            }
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
        if rc != 0 {
            NSLog("[HelperLauncher] spawn failed rc=%d", rc)
            AppRunLog.shared.append("拉起 Helper 失败 rc=\(rc)")
            return false
        }
        NSLog("[HelperLauncher] spawned helper pid=%d", pid)
        guard waitHealthy else { return true }
        // 版本替换场景必须按 expect 探活，避免旧 Helper 仍占口被当成成功
        let probeExpect: String = {
            if expectVersion == "pending" { return "" }
            if expectVersion.isEmpty { return TipaSelfUpdate.localVersion }
            return expectVersion
        }()
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if tipaHealthy(expectVersion: probeExpect) { return true }
            usleep(400_000)
        }
        AppRunLog.shared.append("Helper 已 spawn，但健康检查超时 expect=\(probeExpect.isEmpty ? "any" : probeExpect)")
        return false
    }

    private static func httpControlStop() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11019/api/control/stop") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 1.5)
        req.httpMethod = "POST"
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 500
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return ok
    }

    static func tipaHealthy(expectVersion: String) -> Bool {
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
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            // 避免把 Direct 等其它占口进程当成我们的 Helper
            let proto = (obj["protocol"] as? String) ?? ""
            if proto != "lan-phonebase" { return }
            if expectVersion.isEmpty || expectVersion == "pending" {
                healthy = true
                return
            }
            let release = obj["release"] as? [String: Any]
            let ver = (release?["version"] as? String) ?? ""
            // 有明确期望版本时，缺版本字段不能算通过（否则旧/外来进程会挡住替换）
            guard !ver.isEmpty else { return }
            healthy = TipaSelfUpdate.cmpVer(ver, expectVersion) >= 0
        }.resume()
        _ = sem.wait(timeout: .now() + 1.8)
        return healthy
    }

    private static func cStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }

    private static func freeCStringArray(_ arr: [UnsafeMutablePointer<CChar>?]) {
        for p in arr where p != nil { free(p) }
    }
}
