import Foundation
import Darwin

/// 清掉占用 11019 的 Direct 助手 / 旧基座。
/// Direct 宿主会拉起 LanCaptureHelper，必须先停服务再杀宿主，并循环确认。
enum PortOccupancy {
    struct Result {
        var killed: [String] = []
        var notes: [String] = []
        var seen: [String] = []
        var occupantHint: String = ""
        var portFree: Bool = false
    }

    /// TrollStore 覆盖安装 tipa 后旧进程常仍占端口：启动前结束其它 PhoneBaseLocal。
    @discardableResult
    static func retireOtherLocals() -> Result {
        var out = Result()
        let selfPid = getpid()
        out.notes.append("selfPid=\(selfPid)")
        for round in 1...4 {
            let siblings = listProcesses().filter {
                $0.pid != selfPid && $0.pid > 1 && isLocalBase($0.name)
            }
            if round == 1 {
                out.seen = siblings.map { "\($0.name)(\($0.pid))" }
            }
            if siblings.isEmpty {
                out.notes.append(round == 1 ? "无其它本地基座进程" : "第\(round)轮已清干净")
                break
            }
            for p in siblings {
                killPid(p.pid, name: p.name, into: &out)
            }
            usleep(150_000)
        }
        let uniq = Array(NSOrderedSet(array: out.killed)).compactMap { $0 as? String }
        out.killed = uniq
        if !out.killed.isEmpty {
            out.notes.append("已结束旧版：\(out.killed.joined(separator: ", "))")
        }
        return out
    }

    static func freePort(_ port: UInt16 = 11019) -> Result {
        var out = Result()
        let selfPid = getpid()
        out.notes.append("selfPid=\(selfPid)")
        out.occupantHint = probeOccupant(port: port)

        // 1) 让 Direct 助手自行停监听（若实现了该接口）
        let stopMsg = requestControlStop(port: port)
        if !stopMsg.isEmpty { out.notes.append(stopMsg) }
        usleep(200_000)

        // 2) 多轮：先宿主后助手，防止拉起
        for round in 1...8 {
            let procs = listProcesses()
            let conflicts = procs.filter { $0.pid != selfPid && $0.pid > 1 && isConflict($0.name) }
            if round == 1 {
                out.seen = conflicts.map { "\($0.name)(\($0.pid))" }
            }

            let hosts = conflicts.filter { isHost($0.name) }
            let helpers = conflicts.filter { !isHost($0.name) }
            for p in hosts + helpers {
                killPid(p.pid, name: p.name, into: &out)
            }

            for name in ["PhoneBaseDirect", "DirectPhoneBase", "LanCaptureHelper", "PhoneBase"] {
                let r = runKillall(name)
                if !r.isEmpty, round == 1 { out.notes.append(r) }
            }

            usleep(220_000)
            if canBind(port: port) {
                out.notes.append("第\(round)轮后端口已空")
                break
            }
            if round == 8 {
                let left = listProcesses()
                    .filter { $0.pid != selfPid && isConflict($0.name) }
                    .map { "\($0.name)(\($0.pid))" }
                if !left.isEmpty {
                    out.notes.append("仍存活：\(left.joined(separator: ", "))")
                }
                out.notes.append("Direct 可能被系统/宿主反复拉起，请在 TrollStore 卸载 Direct")
            }
        }

        out.portFree = canBind(port: port)
        if out.seen.isEmpty {
            out.notes.append("未枚举到冲突进程名")
        } else if out.killed.isEmpty {
            out.notes.append("见过但未能结束：\(out.seen.joined(separator: ", "))")
        } else {
            // 去重展示
            let uniq = Array(NSOrderedSet(array: out.killed)).compactMap { $0 as? String }
            out.killed = uniq
            out.notes.append("见过：\(out.seen.joined(separator: ", "))")
        }
        out.notes.append(out.portFree ? "端口 \(port) 已可绑定" : "端口 \(port) 仍被占用")
        return out
    }

    private static func isHost(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("phonebasedirect")
            || lower.hasPrefix("directphone")
            || lower == "phonebase"
    }

    private static func isLocalBase(_ name: String) -> Bool {
        name.lowercased().hasPrefix("phonebaselocal")
    }

    private static func isConflict(_ name: String) -> Bool {
        let lower = name.lowercased()
        if isLocalBase(name) { return true }
        if lower.hasPrefix("phonebasedirect") { return true }
        if lower.hasPrefix("direct") { return true }
        if lower.hasPrefix("lancapture") { return true }
        if lower == "phonebase" { return true }
        return false
    }

    private static func requestControlStop(port: UInt16) -> String {
        var parts: [String] = []
        for path in ["/api/control/stop", "/api/control/restart"] {
            guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { continue }
            for method in ["POST", "GET"] {
                var req = URLRequest(url: url, timeoutInterval: 1.2)
                req.httpMethod = method
                let sem = DispatchSemaphore(value: 0)
                var code = 0
                URLSession.shared.dataTask(with: req) { _, resp, _ in
                    code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    sem.signal()
                }.resume()
                _ = sem.wait(timeout: .now() + 1.5)
                if code > 0 {
                    parts.append("\(method) \(path) → \(code)")
                }
            }
        }
        return parts.isEmpty ? "" : "管控停服：\(parts.joined(separator: ", "))"
    }

    private static func probeOccupant(port: UInt16) -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/info") else { return "" }
        var req = URLRequest(url: url, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var text = ""
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let d = data,
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let proto = obj["protocol"] ?? ""
                let lic = obj["licenseRequired"] ?? ""
                let licProto = obj["licenseProtocol"] ?? ""
                let cap = obj["captureBackend"] ?? ""
                let name = obj["name"] ?? ""
                let bid = obj["buildId"] ?? ""
                text = "占用方 HTTP \(code) protocol=\(proto) license=\(lic)/\(licProto) capture=\(cap) build=\(bid) name=\(name)"
                if String(describing: lic).contains("1")
                    || String(describing: licProto).lowercased().contains("commercial")
                    || String(describing: cap).lowercased().contains("direct") {
                    text += " ← Direct 商业基座"
                }
            } else {
                let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let short = body.count > 80 ? String(body.prefix(80)) + "…" : body
                text = "占用方 HTTP \(code) \(short)"
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return text
    }

    private static func killPid(_ pid: pid_t, name: String, into out: inout Result) {
        _ = Darwin.kill(pid, SIGTERM)
        usleep(80_000)
        if Darwin.kill(pid, 0) == 0 {
            _ = Darwin.kill(pid, SIGKILL)
            usleep(60_000)
        }
        if Darwin.kill(pid, 0) != 0 {
            out.killed.append("\(name)(\(pid))")
        } else {
            out.notes.append("kill \(name)(\(pid)) 仍存活 errno=\(errno)")
        }
    }

    private struct Proc {
        var pid: pid_t
        var name: String
    }

    private static func listProcesses() -> [Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 || size == 0 {
            return []
        }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: count)
        if sysctl(&mib, u_int(mib.count), &buf, &size, nil, 0) != 0 {
            return []
        }
        let n = size / MemoryLayout<kinfo_proc>.stride
        var list: [Proc] = []
        list.reserveCapacity(n)
        for i in 0..<n {
            let kp = buf[i]
            let pid = kp.kp_proc.p_pid
            var comm = kp.kp_proc.p_comm
            let name = withUnsafePointer(to: &comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }
            if !name.isEmpty {
                list.append(Proc(pid: pid, name: name))
            }
        }
        return list
    }

    private static func runKillall(_ name: String) -> String {
        if name.lowercased().hasPrefix("phonebaselocal") { return "" }
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/usr/bin/killall"),
            strdup("-9"),
            strdup(name),
            nil,
        ]
        defer { argv.forEach { if let p = $0 { free(p) } } }
        let rc = argv.withUnsafeMutableBufferPointer { ptr -> Int32 in
            posix_spawn(&pid, "/usr/bin/killall", nil, nil, ptr.baseAddress, nil)
        }
        if rc != 0 { return "" }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return "killall -9 \(name) status=\(status)"
    }

    private static func canBind(port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return ok == 0
    }
}
