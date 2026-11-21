import Foundation
import Darwin

final class WebSocketSession {
    private var fd: Int32
    /// 每条 WS 独立队列，绝不能占用 HTTP 处理队列（否则会堵死 /api/info）
    private let queue: DispatchQueue
    private var buffer = Data()
    private var ownsFd = true
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private(set) var isOpen = true

    init(socketFd: Int32, queue _: DispatchQueue? = nil) {
        self.fd = socketFd
        self.queue = DispatchQueue(label: "cn.local.phonebase.ws.\(socketFd)-\(UUID().uuidString)")
        var yes: Int32 = 1
        setsockopt(socketFd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        // 接收保持阻塞；发送用 MSG_DONTWAIT，避免编码线程被 TCP 堵住
    }

    /// 标记 fd 已移交，调用方不要再 close
    @discardableResult
    func takeOwnership() -> Int32 {
        ownsFd = true
        return fd
    }

    func start() {
        queue.async { [weak self] in self?.receiveLoop() }
    }

    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard isOpen, let payload = text.data(using: .utf8) else { return false }
        return send(frame: encodeFrame(opcode: 0x1, payload: payload))
    }

    @discardableResult
    func sendBinary(_ data: Data) -> Bool {
        guard isOpen else { return false }
        return send(frame: encodeFrame(opcode: 0x2, payload: data))
    }

    func close() {
        guard isOpen else { return }
        let frame = encodeFrame(opcode: 0x8, payload: Data())
        isOpen = false
        _ = writeAll(frame)
        if ownsFd, fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        onClose?()
    }

    @discardableResult
    private func send(frame: Data) -> Bool {
        guard fd >= 0, isOpen, !frame.isEmpty else { return false }
        if writeAll(frame) { return true }
        // 发送超时/阻塞：不立刻掐断（对齐 discardUnsent），交给上层丢帧
        return false
    }

    /// Write full frame; false on would-block/error. Does not change isOpen.
    /// discardUnsent：仅在「尚未写出任何字节」时可整帧丢弃；半包必须写完，否则 WS 流损坏 → 墙流永久卡死。
    private func writeAll(_ frame: Data) -> Bool {
        guard fd >= 0, !frame.isEmpty else { return false }
        var offset = 0
        var spins = 0
        while offset < frame.count {
            let n = frame.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.send(fd, base + offset, frame.count - offset, Int32(MSG_DONTWAIT))
            }
            if n > 0 {
                offset += n
                spins = 0
                continue
            }
            let err = errno
            if err == EINTR { continue }
            if err == EAGAIN || err == EWOULDBLOCK {
                if offset == 0 {
                    // 整帧尚未发出：上层丢帧
                    return false
                }
                // 已写出半包：短自旋把尾巴写完，避免协议错位
                spins += 1
                if spins > 2000 { return false }
                sched_yield()
                continue
            }
            return false
        }
        return true
    }

    private func dropPeer() {
        guard isOpen else { return }
        isOpen = false
        if ownsFd, fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        onClose?()
    }

    private func receiveLoop() {
        var tmp = [UInt8](repeating: 0, count: 16 * 1024)
        while isOpen, fd >= 0 {
            let n = Darwin.recv(fd, &tmp, tmp.count, 0)
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                break
            }
            if n == 0 { break }
            buffer.append(contentsOf: tmp.prefix(n))
            consumeFrames()
            if !isOpen { return }
        }
        if isOpen {
            isOpen = false
            if ownsFd, fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
            onClose?()
        }
    }

    private func consumeFrames() {
        while true {
            guard buffer.count >= 2 else { return }
            let b0 = buffer[0]
            let b1 = buffer[1]
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var len = Int(b1 & 0x7F)
            var offset = 2
            if len == 126 {
                guard buffer.count >= 4 else { return }
                len = Int(buffer[2]) << 8 | Int(buffer[3])
                offset = 4
            } else if len == 127 {
                guard buffer.count >= 10 else { return }
                len = 0
                for i in 0..<8 { len = (len << 8) | Int(buffer[2 + i]) }
                offset = 10
            }
            let maskLen = masked ? 4 : 0
            guard buffer.count >= offset + maskLen + len else { return }
            var payload = Data(buffer[(offset + maskLen)..<(offset + maskLen + len)])
            if masked {
                let mask = Array(buffer[offset..<(offset + 4)])
                for i in 0..<payload.count {
                    payload[i] ^= mask[i % 4]
                }
            }
            buffer.removeSubrange(0..<(offset + maskLen + len))

            switch opcode {
            case 0x1:
                if let text = String(data: payload, encoding: .utf8) { onText?(text) }
            case 0x2:
                onBinary?(payload)
            case 0x8:
                isOpen = false
                if ownsFd, fd >= 0 {
                    Darwin.close(fd)
                    fd = -1
                }
                onClose?()
                return
            case 0x9:
                send(frame: encodeFrame(opcode: 0xA, payload: payload))
            default:
                break
            }
        }
    }

    private func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode)
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((count >> 8) & 0xFF))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(127)
            var n = UInt64(count).bigEndian
            withUnsafeBytes(of: &n) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        return frame
    }
}
