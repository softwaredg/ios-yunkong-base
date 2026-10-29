import Foundation
import Network

/// Raw TCP :5909 — TVH4 frames for the PC agent (`PRODUCT_VIDEO_PORT`).
final class TcpVideoHub {
    static let defaultPort: UInt16 = 5909

    private let queue = DispatchQueue(label: "cn.iosmirror.base.tvh4.tcp")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var latestConfig: Data?

    func start(port: UInt16 = defaultPort) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.queue.async { self?.accept(conn) }
        }
        listener.start(queue: queue)
        self.listener = listener
        NSLog("[TVH4] TCP listen :%u", port)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in clients.values { c.cancel() }
        clients.removeAll()
    }

    func setConfiguration(_ annexB: Data) {
        let pkt = TVH4.build(flags: TVH4.flagConfig, ptsUs: 0, payload: annexB)
        latestConfig = pkt
        broadcast(pkt)
    }

    func sendFrame(annexB: Data, keyframe: Bool, ptsUs: UInt64) {
        var flags: UInt8 = 0
        if keyframe { flags |= TVH4.flagKey }
        broadcast(TVH4.build(flags: flags, ptsUs: ptsUs, payload: annexB))
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        clients[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.drop(id, conn) }
            if case .cancelled = state { self?.drop(id, conn) }
        }
        conn.start(queue: queue)
        if let latestConfig {
            conn.send(content: latestConfig, completion: .contentProcessed { _ in })
        }
        // Keep reading so we notice peer close (ignore TVHC for now — agent may write encode prefs).
        receiveLoop(conn, id: id)
    }

    private func receiveLoop(_ conn: NWConnection, id: ObjectIdentifier) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.drop(id, conn)
                return
            }
            self?.receiveLoop(conn, id: id)
        }
    }

    private func drop(_ id: ObjectIdentifier, _ conn: NWConnection) {
        clients.removeValue(forKey: id)
        conn.cancel()
    }

    private func broadcast(_ data: Data) {
        for (id, conn) in clients {
            conn.send(content: data, completion: .contentProcessed { [weak self] err in
                if err != nil { self?.drop(id, conn) }
            })
        }
    }
}
