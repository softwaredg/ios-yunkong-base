import Foundation
import Darwin

// 与样板 / TrollStore spawnRoot 一致：persona 99 + uid/gid 0，装 tipa 时不被 BKSTerminate 一并带走
private let POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE: UInt32 = 1
@_silgen_name("posix_spawnattr_set_persona_np")
private func posix_spawnattr_set_persona_np(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>,
    _ personaId: uid_t,
    _ flags: UInt32
) -> Int32
@_silgen_name("posix_spawnattr_set_persona_uid_np")
private func posix_spawnattr_set_persona_uid_np(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>,
    _ uid: uid_t
) -> Int32
@_silgen_name("posix_spawnattr_set_persona_gid_np")
private func posix_spawnattr_set_persona_gid_np(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>,
    _ gid: gid_t
) -> Int32

/// 主 App 拉起 / 停止包内独立 `PhoneBaseHelper`。
/// tipa 0.2.73 test marker: verify persona root relaunch
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
        // 标记只由 armPostUpdate 写，避免取消安装 clear 后被 ensureRunning 写回
        // 装前武装 / pending：只要求 Helper 在听；装后正常 ensure 才按本机版本踢旧进程
        let healthyExpect = (postUpdate || expect == "pending") ? "" : expect
        // 必须是 Helper 进程在听，且主进程未占口
        if !BaseRuntime.shared.isRunning, isHelperAlive(), tipaHealthy(expectVersion: healthyExpect) {
            NSLog("[HelperLauncher] helper already healthy expect=%@", expect)
            return true
        }
        // 主进程占口时禁止 spawn（调用方应先 stop）；否则 waitHealthy 会把主进程探活当成 Helper 成功
        if BaseRuntime.shared.isRunning {
            NSLog("[HelperLauncher] refuse spawn: in-process BaseRuntime holds port")
            AppRunLog.shared.append("拒绝拉 Helper：主进程仍占 11019")
            return false
        }
        // 先清旧 helper，再拉新的
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
        // 已在 Helper 内：只写标记，Supervisor 本进程会拉主 App；切勿 stop 自己
        if ProcessRole.isHelper {
            AppRunLog.shared.append("已武装装后拉起（本进程即 Helper）expect=\(expect)")
            return
        }
        // 装后拉起只要求 Helper 进程在（Supervisor 已跑）；听口与否不挡武装
        if !BaseRuntime.shared.isRunning, isHelperAlive() {
            AppRunLog.shared.append("已武装装后拉起（Helper 仍在）expect=\(expect)")
            return
        }
        // 主进程占口时先停，再 spawn Helper，否则 Helper 绑不上 11019 / 没有 Supervisor
        if BaseRuntime.shared.isRunning {
            AppRunLog.shared.append("装前武装：主进程让出口给 Helper")
            if Thread.isMainThread {
                BaseRuntime.shared.stop()
            } else {
                DispatchQueue.main.sync { BaseRuntime.shared.stop() }
            }
            usleep(200_000)
        }
        _ = ensureRunning(postUpdate: true, expectVersion: expect)
        let alive = isHelperAlive()
        AppRunLog.shared.append("已武装 Helper 装后拉起 expect=\(expect) alive=\(alive ? 1 : 0)")
        // 仅当 Helper 进程也不在时，才回退主进程开服（标记仍保留，装后可能需手动打开）
        if !alive {
            AppRunLog.shared.append("Helper 武装失败，恢复主进程开服（装后请手动打开）")
            if Thread.isMainThread {
                _ = BaseRuntime.shared.start(notifyStatus: true)
            } else {
                DispatchQueue.main.sync { _ = BaseRuntime.shared.start(notifyStatus: true) }
            }
        }
    }

    /// Helper / 主进程硬退出前：再 spawn 替身（不写装后标记、不拉主 UI）。
    /// 对齐样板 `scheduleRestart`→听口完成再 `shutdown`：waitHealthy 时必须 11019 通才算移交成功。
    /// expectVersion=pending → 只校验 lan-phonebase，不卡版本字段（避免误杀刚起来的 Helper）。
    @discardableResult
    static func spawnReplacementHelper(waitHealthy: Bool = false) -> Bool {
        gate.lock()
        defer { gate.unlock() }
        return spawnHelper(
            postUpdate: false,
            expectVersion: "pending",
            waitHealthy: waitHealthy,
            // 硬移交：短超时；日常 ensure 用默认 15s
            healthyTimeoutSec: 5,
            killIfUnhealthy: !waitHealthy
        )
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
    private static func spawnHelper(
        postUpdate: Bool,
        expectVersion: String,
        waitHealthy: Bool,
        // 默认 8s：UI 点启动不能卡半分钟；失败尽快主进程兜底
        healthyTimeoutSec: TimeInterval = 8,
        killIfUnhealthy: Bool = true
    ) -> Bool {
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
            && k != ProcessRole.forceServeKey && k != ProcessRole.homeKey
        {
            envList.append("\(k)=\(v)")
        }
        envList.append("\(ProcessRole.roleKey)=helper")
        envList.append("\(ProcessRole.parentKey)=\(getpid())")
        // 钉死主容器 HOME，避免 Helper 读不到 should-serve / 日志写到别处
        if let home = ProcessRole.dataHomePath, !home.isEmpty {
            envList.removeAll { $0.hasPrefix("HOME=") }
            envList.append("HOME=\(home)")
            envList.append("\(ProcessRole.homeKey)=\(home)")
        }
        if postUpdate {
            envList.append("\(ProcessRole.postUpdateKey)=1")
            if !expectVersion.isEmpty {
                envList.append("\(ProcessRole.expectVerKey)=\(expectVersion)")
            }
        } else if waitHealthy {
            // 日常开服：强制 Helper 听口，勿因 flag 路径不一致跳过
            envList.append("\(ProcessRole.forceServeKey)=1")
        }
        var envp = cStringArray(envList)
        defer { freeCStringArray(envp) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        // 仅装前武装：persona 99 + root，躲过巨魔 BKSTerminate(bundleId)
        // 日常 Helper 必须 mobile——UIKit 开服不能跑在 uid=0
        var personaTag = "mobile"
        if postUpdate {
            let personaRc = posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE)
            let uidRc = posix_spawnattr_set_persona_uid_np(&attr, 0)
            let gidRc = posix_spawnattr_set_persona_gid_np(&attr, 0)
            personaTag = "99/root"
            if personaRc != 0 || uidRc != 0 || gidRc != 0 {
                AppRunLog.shared.append(
                    "Helper persona 设置异常 persona=\(personaRc) uid=\(uidRc) gid=\(gidRc)，仍尝试 spawn"
                )
            }
        }

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
        NSLog("[HelperLauncher] spawned helper pid=%d persona=%@", pid, personaTag)
        AppRunLog.shared.append(
            "已 spawn Helper pid=\(pid) persona=\(personaTag) postUpdate=\(postUpdate ? 1 : 0)"
        )
        guard waitHealthy else { return true }

        // 装后 root Helper 不开 11019：活过 0.8s 即武装成功
        if postUpdate {
            usleep(800_000)
            let alive = kill(pid, 0) == 0
            if alive {
                AppRunLog.shared.append("装后 Helper 存活 pid=\(pid)（root 无 UIKit，只负责拉起）")
                return true
            }
            AppRunLog.shared.append("装后 Helper 立刻退出 pid=\(pid)，武装失败")
            return false
        }

        // 日常 ensure：按版本探活；硬退移交（pending）只要求协议通。
        let probeExpect: String = {
            if expectVersion == "pending" { return "" }
            if expectVersion.isEmpty { return TipaSelfUpdate.localVersion }
            return expectVersion
        }()
        let timeout = max(2, healthyTimeoutSec)
        var lastReason = "pending"
        func waitWindow(_ sec: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(sec)
            while Date() < deadline {
                if kill(pid, 0) != 0 {
                    lastReason = "exited"
                    AppRunLog.shared.append("Helper pid=\(pid) 已退出，健康检查中止")
                    return false
                }
                // 主进程仍占口时 Helper 不可能听上：立刻失败，交给调用方软续服
                if BaseRuntime.shared.isRunning {
                    lastReason = "main-holds-port"
                    AppRunLog.shared.append(
                        "Helper 健康检查中止：主进程仍在听口 pid=\(pid) expect=\(probeExpect.isEmpty ? "any" : probeExpect)"
                    )
                    if killIfUnhealthy {
                        kill(pid, SIGTERM)
                        usleep(50_000)
                        kill(pid, SIGKILL)
                    }
                    return false
                }
                let probe = tipaProbe(expectVersion: probeExpect)
                lastReason = probe.reason
                if probe.ok { return true }
                usleep(200_000)
            }
            let last = tipaProbe(expectVersion: probeExpect)
            lastReason = last.reason
            return last.ok
        }

        if waitWindow(timeout) { return true }

        // alive 但口不通：再给短窗（3s），随后交给主进程兜底，避免卡死在「正在拉起」
        let aliveAfter = kill(pid, 0) == 0
        if aliveAfter, lastReason != "exited", lastReason != "main-holds-port" {
            let extra: TimeInterval = 3
            AppRunLog.shared.append(
                "Helper 首轮探活未过 reason=\(lastReason) expect=\(probeExpect.isEmpty ? "any" : probeExpect) → 再等 \(Int(extra))s"
            )
            if waitWindow(extra) { return true }
        }

        let alive = kill(pid, 0) == 0
        let finalReason = tipaProbe(expectVersion: probeExpect).reason
        AppRunLog.shared.append(
            "Helper 已 spawn，但健康检查超时 expect=\(probeExpect.isEmpty ? "any" : probeExpect) alive=\(alive ? 1 : 0) kill=\(killIfUnhealthy ? 1 : 0) wallSec=\(Int(timeout)) reason=\(finalReason)"
        )
        // 硬退移交失败时留给调用方 terminate+主进程续服，避免此处误杀后口空窗
        if alive, killIfUnhealthy {
            kill(pid, SIGTERM)
            usleep(50_000)
            kill(pid, SIGKILL)
        }
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
        tipaProbe(expectVersion: expectVersion).ok
    }

    /// 探 11019 `/api/info`；reason 供超时日志（conn-refused / http-N / bad-proto / ver-…）。
    static func tipaProbe(expectVersion: String) -> (ok: Bool, reason: String) {
        guard let url = URL(string: "http://127.0.0.1:11019/api/info") else {
            return (false, "bad-url")
        }
        var req = URLRequest(url: url, timeoutInterval: 1.2)
        req.setValue("close", forHTTPHeaderField: "Connection")
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var reason = "no-response"
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err {
                let ns = err as NSError
                if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCannotConnectToHost
                    || ns.code == NSURLErrorNetworkConnectionLost {
                    reason = "conn-refused"
                } else {
                    reason = "err-\(ns.code)"
                }
                return
            }
            guard let http = resp as? HTTPURLResponse else {
                reason = "no-http"
                return
            }
            guard http.statusCode == 200, let data, !data.isEmpty else {
                reason = "http-\(http.statusCode)"
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                reason = "bad-json"
                return
            }
            let proto = (obj["protocol"] as? String) ?? ""
            if proto != "lan-phonebase" {
                reason = "bad-proto:\(proto.isEmpty ? "?" : proto)"
                return
            }
            if expectVersion.isEmpty || expectVersion == "pending" {
                ok = true
                reason = "ok"
                return
            }
            let release = obj["release"] as? [String: Any]
            let ver = (release?["version"] as? String) ?? ""
            guard !ver.isEmpty else {
                reason = "no-version"
                return
            }
            if TipaSelfUpdate.cmpVer(ver, expectVersion) >= 0 {
                ok = true
                reason = "ok"
            } else {
                reason = "ver-\(ver)<\(expectVersion)"
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 1.8)
        return (ok, reason)
    }

    private static func cStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }

    private static func freeCStringArray(_ arr: [UnsafeMutablePointer<CChar>?]) {
        for p in arr where p != nil { free(p) }
    }
}
