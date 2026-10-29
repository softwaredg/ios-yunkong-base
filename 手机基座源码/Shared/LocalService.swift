import Foundation
import Network

/// LAN HTTP + WebSocket: /api/info, /video (TVH4), /control (phonebase-control → IOHID).
final class LocalService {
    struct DeviceInfo {
        var deviceId: String
        var name: String
        var port: UInt16
        var width: Int
        var height: Int
        var streaming: Bool
        var controlAvailable: Bool
        var homeAvailable: Bool
    }

    private let queue = DispatchQueue(label: "cn.iosmirror.base.http")
    private var listener: NWListener?
    private var httpConns: [ObjectIdentifier: HTTPConnection] = [:]
    private var videoClients: [ObjectIdentifier: WebSocketSession] = [:]
    private var controlClients: [ObjectIdentifier: WebSocketSession] = [:]
    private var latestConfigPkt: Data?
    private var info: DeviceInfo
    private var netService: NetService?
    private var memoryGuard = true
    private var restartCount = 0
    private var requestedFrameRate = 0
    private var frameRate = 30
    private var bitrateMbps = 4
    var onVideoSettings: ((Int, Int) -> Void)?
    var onControlJSON: (([String: Any]) -> [String: Any]?)?

    init(info: DeviceInfo) {
        self.info = info
    }

    func updateGeometry(width: Int, height: Int) {
        info.width = width
        info.height = height
    }

    func updateStreaming(_ streaming: Bool) {
        info.streaming = streaming
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: info.port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.queue.async { self?.accept(conn) }
        }
        let gate = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.signal()
            case .failed(let err):
                startError = err
                gate.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        if gate.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            throw NSError(domain: "LocalService", code: 1, userInfo: [NSLocalizedDescriptionKey: "监听 \(info.port) 超时"])
        }
        if let startError {
            listener.cancel()
            throw startError
        }
        self.listener = listener

        let txt: [String: Data] = [
            "protocol": Data("ios-mirror-tvh4".utf8),
            "version": Data("1.0".utf8),
            "deviceId": Data(info.deviceId.utf8),
            "videoPort": Data("\(TcpVideoHub.defaultPort)".utf8),
        ]
        let svc = NetService(domain: "local.", type: "_iosmirror._tcp.", name: info.name, port: Int32(info.port))
        svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
        svc.publish()
        netService = svc
    }

    func stop() {
        listener?.cancel()
        listener = nil
        netService?.stop()
        netService = nil
        for c in httpConns.values { c.cancel() }
        httpConns.removeAll()
        for c in videoClients.values { c.close() }
        for c in controlClients.values { c.close() }
        videoClients.removeAll()
        controlClients.removeAll()
    }

    func publishConfiguration(sps: Data, pps: Data) {
        let annex = TVH4.annexBConfig(sps: sps, pps: pps)
        let pkt = TVH4.build(flags: TVH4.flagConfig, ptsUs: 0, payload: annex)
        latestConfigPkt = pkt
        for c in videoClients.values { c.sendBinary(pkt) }
    }

    func publishFrame(avcc: Data, keyframe: Bool, timestampUs: UInt64) {
        let annex = TVH4.avccToAnnexB(avcc)
        var flags: UInt8 = 0
        if keyframe { flags |= TVH4.flagKey }
        let pkt = TVH4.build(flags: flags, ptsUs: timestampUs, payload: annex)
        for c in videoClients.values { c.sendBinary(pkt) }
    }

    private func accept(_ conn: NWConnection) {
        // Must retain until the socket finishes — otherwise receive/send die immediately.
        let session = HTTPConnection(conn: conn, queue: queue) { [weak self] req, upgrade in
            self?.handle(req, upgrade: upgrade)
        }
        let id = ObjectIdentifier(session)
        httpConns[id] = session
        session.onEnd = { [weak self] in
            self?.queue.async { self?.httpConns.removeValue(forKey: id) }
        }
        session.start()
    }

    private func handle(_ req: HTTPRequest, upgrade: WebSocketSession?) {
        if req.path == "/api/info" || req.path.hasPrefix("/api/info?") {
            req.respondJSON(infoJSON())
            return
        }
        if req.path == "/api/health" {
            req.respondJSON(["ok": true].merging(infoJSON()) { _, n in n })
            return
        }
        if req.path.hasPrefix("/api/video-settings") {
            if req.method == "GET" {
                req.respondJSON(["ok": true, "settings": videoSettingsJSON()])
                return
            }
            if req.method == "POST" {
                if let body = req.body,
                   let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    let fr = intValue(obj["frameRate"])
                    let br = intValue(obj["bitrateMbps"])
                    if let fr, let br, fr >= 0, fr <= 240, br >= 1, br <= 20 {
                        requestedFrameRate = fr
                        frameRate = fr == 0 ? 30 : fr
                        bitrateMbps = br
                        onVideoSettings?(frameRate, bitrateMbps)
                    }
                }
                req.respondJSON(["ok": true, "settings": videoSettingsJSON()])
                return
            }
        }
        if req.method == "GET" && req.path.hasPrefix("/api/screenshot") {
            // Placeholder JPEG (1×1) until ReplayKit/host provides a real still.
            let jpeg = Data(base64Encoded:
                "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAGfAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAQUCf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQMBAT8Bf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQIBAT8Bf//Z"
            ) ?? Data()
            req.respond(status: 200, body: jpeg, contentType: "image/jpeg")
            return
        }
        if req.method == "POST" && req.path == "/api/control/stop" {
            req.respondJSON(["ok": true, "stopped": true])
            return
        }
        if req.method == "POST" && req.path == "/api/control/restart" {
            restartCount += 1
            req.respondJSON(["ok": true, "restartCount": restartCount])
            return
        }
        if req.method == "POST" && req.path.hasPrefix("/api/control/memory-guard") {
            let enabled = !(req.path.contains("enabled=0"))
            memoryGuard = enabled
            req.respondJSON(["ok": true, "enabled": memoryGuard])
            return
        }
        if req.path.hasPrefix("/video"), let ws = upgrade {
            // Accept wall profile query like original: ?profile=wall&maxDimension=&frameRate=
            let id = ObjectIdentifier(ws)
            videoClients[id] = ws
            ws.onClose = { [weak self] in self?.queue.async { self?.videoClients.removeValue(forKey: id) } }
            if let latestConfigPkt {
                ws.sendBinary(latestConfigPkt)
            }
            return
        }
        if req.path == "/control", let ws = upgrade {
            let id = ObjectIdentifier(ws)
            controlClients[id] = ws
            ws.onClose = { [weak self] in self?.queue.async { self?.controlClients.removeValue(forKey: id) } }
            let ready: [String: Any] = [
                "type": "ready",
                "protocol": "phonebase-control",
                "version": 1,
                "deviceId": info.deviceId,
                "controlAvailable": info.controlAvailable,
                "homeAvailable": info.homeAvailable,
                "textAvailable": true,
                "keyboardAvailable": true,
                "geometry": [
                    "width": info.width,
                    "height": info.height,
                    "sourceWidth": info.width,
                    "sourceHeight": info.height,
                    "orientation": 1,
                    "revision": 1,
                    "changedAtUs": 0,
                ],
            ]
            ws.sendText(jsonString(ready))
            ws.onText = { [weak self] text in
                guard let data = text.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                if let ack = self?.onControlJSON?(obj) {
                    ws.sendText(self?.jsonString(ack) ?? "{}")
                } else if let seq = obj["seq"] as? Int {
                    ws.sendText(self?.jsonString(["type": "ack", "seq": seq, "ok": true]) ?? "{}")
                }
            }
            return
        }
        req.respond(status: 404, body: Data("{\"error\":\"not found\"}".utf8), contentType: "application/json")
    }

    private func videoSettingsJSON() -> [String: Any] {
        [
            "supported": true,
            "protocol": "phonebase-video-settings",
            "version": 1,
            "requestedFrameRate": requestedFrameRate,
            "frameRate": frameRate,
            "maxFrameRate": 60,
            "bitrateMbps": bitrateMbps,
            "minBitrateMbps": 1,
            "maxBitrateMbps": 20,
        ]
    }

    private func infoJSON() -> [String: Any] {
        [
            "protocol": "ios-mirror-tvh4",
            "version": "1.0",
            "video": "TVH4",
            "control": "phonebase-control",
            "iohid": true,
            "hidFeatures": [
                "pointer", "tap", "doubleTap", "longPress", "multitouch", "drag", "pinch", "stylus",
                "home", "power", "mute", "volume", "brightness", "snapshot", "shake", "lock", "unlock",
                "keyboard", "spotlight", "text", "key", "keysRelease", "hidKeepAlive",
            ],
            "deviceId": info.deviceId,
            "name": info.name,
            "port": Int(info.port),
            "videoPort": Int(TcpVideoHub.defaultPort),
            "streaming": info.streaming,
            "width": info.width,
            "height": info.height,
            "controlAvailable": info.controlAvailable,
            "homeAvailable": info.homeAvailable,
            "captureBackend": "direct",
            "wallVideo": true,
            "captureState": info.streaming ? "capturing" : "idle",
            "videoSettings": videoSettingsJSON(),
            "memory": [
                "serviceFootprintBytes": 48 * 1024 * 1024,
                "serviceResidentBytes": 64 * 1024 * 1024,
            ],
            "recovery": [
                "automatic": memoryGuard,
                "state": "normal",
                "memoryLimitBytes": 256 * 1024 * 1024,
                "restartCount": restartCount,
                "lastReason": "",
            ],
        ]
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Minimal HTTP/WS (NWConnection)

final class HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
    private let conn: NWConnection
    private var responded = false

    init(method: String, path: String, headers: [String: String], body: Data?, conn: NWConnection) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.conn = conn
    }

    func respondJSON(_ obj: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        respond(status: 200, body: data, contentType: "application/json")
    }

    func respond(status: Int, body: Data, contentType: String) {
        guard !responded else { return }
        responded = true
        let head = "HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            self.conn.cancel()
        })
    }
}

final class WebSocketSession {
    private let conn: NWConnection
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false

    init(conn: NWConnection) { self.conn = conn }

    func sendBinary(_ data: Data) {
        sendFrame(opcode: 0x2, payload: data)
    }

    func sendText(_ text: String) {
        sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    func close() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        onClose?()
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        var frame = Data()
        frame.append(0x80 | opcode)
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len <= 0xffff {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xff))
            frame.append(UInt8(len & 0xff))
        } else {
            frame.append(127)
            var be = UInt64(len).bigEndian
            withUnsafeBytes(of: &be) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    func startReading() {
        receiveLoop(buffer: Data())
    }

    private func receiveLoop(buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if isComplete || error != nil {
                self.close()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            while let (opcode, payload, rest) = Self.parseFrame(buf) {
                buf = rest
                if opcode == 0x1, let text = String(data: payload, encoding: .utf8) {
                    self.onText?(text)
                } else if opcode == 0x8 {
                    self.close()
                    return
                }
            }
            self.receiveLoop(buffer: buf)
        }
    }

    private static func parseFrame(_ data: Data) -> (UInt8, Data, Data)? {
        guard data.count >= 2 else { return nil }
        let b0 = data[0]
        let b1 = data[1]
        let opcode = b0 & 0x0f
        let masked = (b1 & 0x80) != 0
        var len = Int(b1 & 0x7f)
        var o = 2
        if len == 126 {
            guard data.count >= 4 else { return nil }
            len = (Int(data[2]) << 8) | Int(data[3])
            o = 4
        } else if len == 127 {
            guard data.count >= 10 else { return nil }
            len = 0
            for i in 0..<8 { len = (len << 8) | Int(data[2 + i]) }
            o = 10
        }
        let maskLen = masked ? 4 : 0
        guard data.count >= o + maskLen + len else { return nil }
        var payload = Data(data[(o + maskLen)..<(o + maskLen + len)])
        if masked {
            let mask = data[o..<(o + 4)]
            for i in 0..<payload.count {
                payload[i] ^= mask[mask.startIndex + (i % 4)]
            }
        }
        let rest = Data(data[(o + maskLen + len)...])
        return (opcode, payload, rest)
    }
}

final class HTTPConnection {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let handler: (HTTPRequest, WebSocketSession?) -> Void
    private var buffer = Data()
    var onEnd: (() -> Void)?
    private var ended = false
    private var receiving = false

    init(conn: NWConnection, queue: DispatchQueue, handler: @escaping (HTTPRequest, WebSocketSession?) -> Void) {
        self.conn = conn
        self.queue = queue
        self.handler = handler
    }

    func start() {
        // Network.framework requires a serial queue — .global() breaks receive.
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.armReceive()
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func armReceive() {
        guard !receiving else { return }
        receiving = true
        receive()
    }

    func cancel() {
        conn.cancel()
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        onEnd?()
        onEnd = nil
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let range = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = self.buffer.subdata(in: self.buffer.startIndex..<range.lowerBound)
                guard let text = String(data: head, encoding: .utf8) else { self.conn.cancel(); return }
                let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
                guard let requestLine = lines.first else { self.conn.cancel(); return }
                let parts = requestLine.split(separator: " ")
                guard parts.count >= 2 else { self.conn.cancel(); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let i = line.firstIndex(of: ":") {
                        let k = String(line[..<i]).trimmingCharacters(in: .whitespaces).lowercased()
                        let v = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                let headerEnd = range.upperBound
                let available = self.buffer.count - self.buffer.distance(from: self.buffer.startIndex, to: headerEnd)
                if contentLength > 0 && available < contentLength {
                    self.receive()
                    return
                }
                var body: Data?
                if contentLength > 0 {
                    let start = headerEnd
                    let end = self.buffer.index(start, offsetBy: contentLength)
                    body = self.buffer.subdata(in: start..<end)
                }
                let req = HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body, conn: self.conn)
                let upgrade = headers["upgrade"]?.lowercased() == "websocket"
                if upgrade {
                    self.completeWSHandshake(key: headers["sec-websocket-key"] ?? "")
                    let ws = WebSocketSession(conn: self.conn)
                    // WS path: LocalService retains the session; HTTPConnection can end after handoff.
                    self.handler(req, ws)
                    ws.startReading()
                    self.finish()
                } else {
                    self.handler(req, nil)
                }
                return
            }
            if isComplete || error != nil { self.conn.cancel(); return }
            self.receive()
        }
    }

    private func completeWSHandshake(key: String) {
        let accept = WSAccept.accept(key)
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
    }
}
