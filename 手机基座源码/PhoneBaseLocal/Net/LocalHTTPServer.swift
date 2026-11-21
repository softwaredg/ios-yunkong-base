import Foundation
import Darwin
import CommonCrypto

/// BSD socket HTTP 服务。
final class LocalHTTPServer {
    private let port: UInt16
    private var listenFd: Int32 = -1
    private var running = false
    /// 每连接并发处理，避免一个慢连接堵住后续 /api/info 探测
    private let queue = DispatchQueue(label: "cn.local.phonebase.local.http", attributes: .concurrent)
    private let acceptQueue = DispatchQueue(label: "cn.local.phonebase.local.accept")
    private var bonjour: NetService?

    private(set) var acceptCount: Int = 0
    private(set) var lastClient: String = ""
    var onAccepted: ((Int, String) -> Void)?

    var onInfo: (() -> Data)?
    var onHealth: (() -> Data)?
    /// path + query → JSON body；对齐官方 /api/control/*
    var onControlAPI: ((String, [String: String]) -> Data)?
    /// GET/POST /api/video-settings；body 为 POST JSON（可空）
    var onVideoSettings: ((String, [String: String], Data?) -> Data)?
    var onVideoConnect: ((WebSocketSession, [String: String]) -> Void)?
    var onControlConnect: ((WebSocketSession) -> Void)?

    var bonjourName: String = "PhoneBaseLocal"
    var bonjourTXT: [String: String] = [:]
    /// USB 口（11021）不发 Bonjour，避免和 Wi‑Fi 11019 抢名
    var advertiseBonjour: Bool = true

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        stop()

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw ServerError.socket }
        listenFd = fd

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        // 关闭 Nagle，尽快回包
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))

        let bindOk = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOk == 0 else {
            Darwin.close(fd)
            listenFd = -1
            throw ServerError.bind(errno)
        }
        guard Darwin.listen(fd, 64) == 0 else {
            Darwin.close(fd)
            listenFd = -1
            throw ServerError.listen(errno)
        }

        running = true
        acceptCount = 0
        NSLog("[HTTP] BSD listen ready port=%u fd=%d", port, fd)
        acceptQueue.async { [weak self] in self?.acceptLoop() }
        if advertiseBonjour {
            DispatchQueue.main.async { [weak self] in self?.publishBonjour() }
        }
    }

    func stop() {
        running = false
        bonjour?.stop()
        bonjour = nil
        if listenFd >= 0 {
            Darwin.close(listenFd)
            listenFd = -1
        }
    }

    private func publishBonjour() {
        let name = String(bonjourName.prefix(48))
        let svc = NetService(domain: "local.", type: "_phonebase._tcp.", name: name, port: Int32(port))
        var dict: [String: Data] = [:]
        for (k, v) in bonjourTXT { dict[k] = Data(v.utf8) }
        svc.setTXTRecord(NetService.data(fromTXTRecord: dict))
        svc.publish()
        bonjour = svc
    }

    private func acceptLoop() {
        while running {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(self.listenFd, $0, &len)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                if !running { break }
                usleep(20_000)
                continue
            }

            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))

            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr.sin_addr, &host, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: host)
            acceptCount += 1
            lastClient = ip
            let n = acceptCount
            DispatchQueue.main.async { [weak self] in self?.onAccepted?(n, ip) }

            // 每连接独立线程，彻底避开 GCD 队列被 WebSocket/慢连接拖死
            Thread.detachNewThread { [weak self] in
                self?.handleClient(fd: client, peer: ip)
            }
        }
    }

    private func handleClient(fd: Int32, peer: String) {
        var transferred = false
        defer {
            if !transferred { Darwin.close(fd) }
        }

        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(3)

        while Date() < deadline {
            let n = Darwin.recv(fd, &tmp, tmp.count, 0)
            if n > 0 {
                buf.append(contentsOf: tmp.prefix(Int(n)))
                if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buf.subdata(in: buf.startIndex..<range.lowerBound)
                    var leftover = buf.subdata(in: range.upperBound..<buf.endIndex)
                    leftover = readBodyIfNeeded(fd: fd, headerData: headerData, body: leftover)
                    transferred = route(fd: fd, headerData: headerData, leftover: leftover)
                    return
                }
                if buf.count > 64 * 1024 { return }
                continue
            }
            if n == 0 {
                // 对端关闭；若已有部分数据也试着回
                break
            }
            let err = errno
            if err == EINTR { continue }
            // 超时或其它：若已收到完整头就处理，否则用探针回包证明本进程在听
            break
        }

        if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
            let headerData = buf.subdata(in: buf.startIndex..<range.lowerBound)
            var leftover = buf.subdata(in: range.upperBound..<buf.endIndex)
            leftover = Self.readBodyIfNeeded(fd: fd, headerData: headerData, body: leftover)
            transferred = route(fd: fd, headerData: headerData, leftover: leftover)
            return
        }

        // 没读到完整 HTTP：仍回一个明确 JSON，便于判断「本进程是否接到了连接」
        let json = "{\"ok\":false,\"error\":\"no-http-request\",\"peer\":\"\(peer)\",\"bytes\":\(buf.count),\"accept\":\(acceptCount)}"
        respond(fd: fd, status: 408, contentType: "application/json", body: Data(json.utf8))
    }

    private func readBodyIfNeeded(fd: Int32, headerData: Data, body: Data) -> Data {
        Self.readBodyIfNeeded(fd: fd, headerData: headerData, body: body)
    }

    private static func contentLength(from headerData: Data) -> Int {
        guard let header = String(data: headerData, encoding: .utf8) else { return 0 }
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return max(0, Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0)
            }
        }
        return 0
    }

    private static func readBodyIfNeeded(fd: Int32, headerData: Data, body: Data) -> Data {
        let need = contentLength(from: headerData)
        guard need > 0, need <= 64 * 1024 else { return body }
        var out = body
        var tmp = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(1.5)
        while out.count < need, Date() < deadline {
            let n = Darwin.recv(fd, &tmp, min(tmp.count, need - out.count), 0)
            if n > 0 {
                out.append(contentsOf: tmp.prefix(n))
                continue
            }
            if n == 0 { break }
            if errno == EINTR { continue }
            break
        }
        return out
    }

    @discardableResult
    private func route(fd: Int32, headerData: Data, leftover: Data) -> Bool {
        guard let header = String(data: headerData, encoding: .utf8) else { return false }
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return false }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return false }
        let method = String(parts[0])
        let rawTarget = String(parts[1])
        let path = rawTarget.split(separator: "?").first.map(String.init) ?? rawTarget
        let query = Self.parseQuery(rawTarget)

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            if let idx = line.firstIndex(of: ":") {
                let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let upgrade = headers["upgrade"]?.lowercased() == "websocket"
        if upgrade && (path == "/video" || path == "/control") {
            return acceptWebSocket(fd: fd, path: path, query: query, headers: headers, leftover: leftover)
        }

        if method == "GET" && path == "/api/info" {
            respond(fd: fd, status: 200, contentType: "application/json", body: onInfo?() ?? Data("{}".utf8))
        } else if method == "GET" && path == "/api/health" {
            respond(fd: fd, status: 200, contentType: "application/json", body: onHealth?() ?? Data("{}".utf8))
        } else if (method == "GET" || method == "POST")
                    && (path == "/api/control/stop"
                        || path == "/api/control/restart"
                        || path == "/api/control/memory-guard")
        {
            let body = onControlAPI?(path, query) ?? Data(#"{"ok":false,"error":"no-handler"}"#.utf8)
            respond(fd: fd, status: 200, contentType: "application/json", body: body)
        } else if (method == "GET" || method == "POST") && path == "/api/video-settings" {
            let bodyData = leftover.isEmpty ? nil : leftover
            let body = onVideoSettings?(method, query, bodyData)
                ?? Data(#"{"ok":false,"error":"no-handler"}"#.utf8)
            respond(fd: fd, status: 200, contentType: "application/json", body: body)
        } else if method == "OPTIONS" {
            respond(fd: fd, status: 204, contentType: "text/plain", body: Data())
        } else {
            respond(fd: fd, status: 404, contentType: "text/plain", body: Data("not found".utf8))
        }
        return false
    }

    private static func parseQuery(_ target: String) -> [String: String] {
        guard let q = target.split(separator: "?").dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let k = kv.first.map(String.init), !k.isEmpty else { continue }
            let v = kv.count > 1 ? String(kv[1]) : "1"
            out[k] = v.removingPercentEncoding ?? v
        }
        return out
    }

    private func acceptWebSocket(
        fd: Int32,
        path: String,
        query: [String: String],
        headers: [String: String],
        leftover: Data
    ) -> Bool {
        guard let key = headers["sec-websocket-key"] else { return false }
        let accept = WebSocketHandshake.acceptKey(clientKey: key)
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
        let data = Data(response.utf8)
        _ = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.send(fd, base, data.count, 0)
        }
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
        let session = WebSocketSession(socketFd: fd, queue: queue)
        session.takeOwnership()
        _ = leftover
        session.start()
        if path == "/video" {
            onVideoConnect?(session, query)
        } else {
            onControlConnect?(session)
        }
        return true
    }

    private func respond(fd: Int32, status: Int, contentType: String, body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 408: reason = "Request Timeout"
        default: reason = "ERR"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "X-PhoneBase: local\r\n"
        header += "\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        _ = packet.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.send(fd, base, packet.count, 0)
        }
    }

    enum ServerError: Error {
        case socket
        case bind(Int32)
        case listen(Int32)
    }
}

enum WebSocketHandshake {
    static func acceptKey(clientKey: String) -> String {
        let magic = clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        let data = Data(magic.utf8)
        data.withUnsafeBytes { buf in
            _ = CC_SHA1(buf.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest).base64EncodedString()
    }
}
