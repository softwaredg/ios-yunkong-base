import Foundation
import Darwin

/// 主 App 拉起 / 停止包内独立 `PhoneBaseHelper`。
enum HelperLauncher {
    private static let helperName = ProcessRole.helperExecutableName

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

    /// 确保 Helper 在跑；已在跑则只武装 post-update 环境（通过标记文件）。
    @discardableResult
    static func ensureRunning(postUpdate: Bool = false, expectVersion: String = "") -> Bool {
        if postUpdate {
            UpdateMarker.write(expectVersion: expectVersion)
        }
        if tipaHealthy(expectVersion: "") {
            NSLog("[HelperLauncher] service already healthy")
            return true
        }
        // 先清旧 helper，再拉新的
        terminateHelpers(except: getpid())
        return spawnHelper(
            postUpdate: postUpdate || UpdateMarker.exists,
            expectVersion: expectVersion,
            waitHealthy: true
        )
    }

    static func armPostUpdate(expectVersion: String) {
        UpdateMarker.write(expectVersion: expectVersion)
        // 服务已在跑时只写标记；HelperSupervisor 见标记会拉主 App
        if tipaHealthy(expectVersion: "") {
            AppRunLog.shared.append("已武装装后拉起（服务仍在）expect=\(expectVersion)")
            return
        }
        _ = ensureRunning(postUpdate: true, expectVersion: expectVersion)
        AppRunLog.shared.append("已武装 Helper 装后拉起 expect=\(expectVersion)")
    }

    /// Helper 硬退出前：立刻再 spawn 一份自己（不因 healthy 短路、不等待端口）。
    @discardableResult
    static func spawnReplacementHelper(expectVersion: String = "") -> Bool {
        UpdateMarker.write(expectVersion: expectVersion.isEmpty ? TipaSelfUpdate.localVersion : expectVersion)
        return spawnHelper(postUpdate: true, expectVersion: expectVersion, waitHealthy: false)
    }

    static func terminateHelper() {
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
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if tipaHealthy(expectVersion: "") { return true }
            usleep(400_000)
        }
        AppRunLog.shared.append("Helper 已 spawn，等待服务就绪…")
        return true
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
            if expectVersion.isEmpty {
                healthy = true
                return
            }
            let release = obj["release"] as? [String: Any]
            let ver = (release?["version"] as? String) ?? ""
            if ver.isEmpty {
                healthy = true
            } else {
                healthy = TipaSelfUpdate.cmpVer(ver, expectVersion) >= 0
            }
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
