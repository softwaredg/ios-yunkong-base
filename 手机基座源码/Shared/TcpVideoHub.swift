import Foundation
import Network

/// Raw TCP :5909 — TVH4 frames for the PC agent (`PRODUCT_VIDEO_PORT`).
final class TcpVideoHub {
    static let defaultPort: UInt16 = 5909

    private let queue = DispatchQueue(label: "cn.iosmirror.base.tvh4.tcp")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var ready: Set<ObjectIdentifier> = []
    private var latestConfig: Data?
    private var latestKeyframe: Data?

    private var listenPort: UInt16 = defaultPort

    func start(port: UInt16 = defaultPort) throws {
        listenPort = port
        stop()
        try bindListener(port: port)
    }

    private func bindListener(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.queue.async { self?.accept(conn) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                NSLog("[TVH4] TCP ready :%u", port)
            case .failed(let err):
                NSLog("[TVH4] TCP failed: %@ — rebind", String(describing: err))
                self?.queue.asyncAfter(deadline: .now() + 0.4) {
                    self?.rebind()
                }
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        NSLog("[TVH4] TCP listen :%u", port)
    }

    private func rebind() {
        listener?.cancel()
        listener = nil
        do {
            try bindListener(port: listenPort)
        } catch {
            NSLog("[TVH4] rebind error: %@", error.localizedDescription)
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.rebind() }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in clients.values { c.cancel() }
        clients.removeAll()
        ready.removeAll()
        // Keep latestConfig / latestKeyframe so a soft-restart can still seed new clients.
    }

    /// Drop cached bitstream (e.g. after encoder reset) so clients wait for a fresh IDR.
    func clearCachedFrames() {
        latestConfig = nil
        latestKeyframe = nil
    }

    func setConfiguration(_ annexB: Data) {
        let pkt = TVH4.build(flags: TVH4.flagConfig, ptsUs: 0, payload: annexB)
        latestConfig = pkt
        broadcast(pkt)
    }

    func sendFrame(annexB: Data, keyframe: Bool, ptsUs: UInt64) {
        var flags: UInt8 = 0
        if keyframe { flags |= TVH4.flagKey }
        let pkt = TVH4.build(flags: flags, ptsUs: ptsUs, payload: annexB)
        if keyframe { latestKeyframe = pkt }
        broadcast(pkt)
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        clients[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    self.ready.insert(id)
                    // Must wait until .ready — early send is silently dropped on Network.framework.
                    if let cfg = self.latestConfig {
                        conn.send(content: cfg, completion: .contentProcessed { _ in })
                    }
                    if let key = self.latestKeyframe {
                        conn.send(content: key, completion: .contentProcessed { _ in })
                    }
                    NSLog("[TVH4] client ready, config=%d key=%d", self.latestConfig == nil ? 0 : 1, self.latestKeyframe == nil ? 0 : 1)
                case .failed, .cancelled:
                    self.drop(id, conn)
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
        receiveLoop(conn, id: id)
    }

    private func receiveLoop(_ conn: NWConnection, id: ObjectIdentifier) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.queue.async { self?.drop(id, conn) }
                return
            }
            self?.receiveLoop(conn, id: id)
        }
    }

    private func drop(_ id: ObjectIdentifier, _ conn: NWConnection) {
        ready.remove(id)
        clients.removeValue(forKey: id)
        conn.cancel()
    }

    private func broadcast(_ data: Data) {
        for id in ready {
            guard let conn = clients[id] else { continue }
            conn.send(content: data, completion: .contentProcessed { [weak self] err in
                if err != nil { self?.queue.async { self?.drop(id, conn) } }
            })
        }
    }
}
