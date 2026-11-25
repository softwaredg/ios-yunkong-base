import Foundation
import UIKit

final class ControlHub {
    private let deviceId: String
    private var width: Int
    private var height: Int
    private var revision: Int
    /// UIInterfaceOrientation rawValue：1/2 竖，3/4 横
    private var orientation: Int
    private let injector: TouchInjector
    private let textAvailable: Bool
    private let keyboardAvailable: Bool
    private let lock = NSLock()
    private var sessions: [WebSocketSession] = []
    var latestFrameTimestampUs: UInt64 = 0

    init(
        deviceId: String,
        width: Int,
        height: Int,
        revision: Int,
        orientation: Int = 1,
        injector: TouchInjector = LogTouchInjector(),
        textAvailable: Bool = false,
        keyboardAvailable: Bool = false
    ) {
        self.deviceId = deviceId
        self.width = width
        self.height = height
        self.revision = revision
        self.orientation = orientation
        self.injector = injector
        self.textAvailable = textAvailable
        self.keyboardAvailable = keyboardAvailable
    }

    /// 手机 → PC：广播剪贴板文本（运行日志「复制」等）
    func broadcastClipboard(_ raw: String) {
        let text = String(raw.prefix(256_000))
        guard !text.isEmpty else { return }
        lock.lock()
        let copy = sessions
        lock.unlock()
        let body: [String: Any] = ["type": "clipboard", "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let payload = String(data: data, encoding: .utf8)
        else { return }
        copy.forEach { $0.sendText(payload) }
    }

    /// 手机横竖变化 → revision++ 并广播 geometry，桌面窗据此自动旋转
    func publishOrientation(_ next: Int) {
        guard (1 ... 8).contains(next) else { return }
        lock.lock()
        guard next != orientation else {
            lock.unlock()
            return
        }
        orientation = next
        revision += 1
        let geo = geometryDictLocked()
        let copy = sessions
        lock.unlock()
        let body: [String: Any] = ["type": "geometry", "geometry": geo]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8)
        else { return }
        copy.forEach { $0.sendText(text) }
    }

    func attach(_ session: WebSocketSession) {
        lock.lock()
        sessions.append(session)
        lock.unlock()

        let ready: [String: Any] = [
            "type": "ready",
            "protocol": "phonebase-control",
            "version": 1,
            "deviceId": deviceId,
            "controlAvailable": true,
            "homeAvailable": true,
            "textAvailable": textAvailable,
            "keyboardAvailable": keyboardAvailable,
            "geometry": geometryDict(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: ready),
           let text = String(data: data, encoding: .utf8) {
            session.sendText(text)
        }

        session.onText = { [weak self, weak session] text in
            guard let self, let session else { return }
            self.handle(text: text, session: session)
        }
        session.onClose = { [weak self, weak session] in
            guard let self, let session else { return }
            self.lock.lock()
            self.sessions.removeAll { $0 === session }
            self.lock.unlock()
        }
    }

    func detachAll() {
        lock.lock()
        let copy = sessions
        sessions.removeAll()
        lock.unlock()
        copy.forEach { $0.close() }
    }

    private func geometryDict() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return geometryDictLocked()
    }

    private func geometryDictLocked() -> [String: Any] {
        [
            "width": width,
            "height": height,
            "sourceWidth": width,
            "sourceHeight": height,
            "orientation": orientation,
            "revision": revision,
            "changedAtUs": Int(Date().timeIntervalSince1970 * 1_000_000),
        ]
    }

    private func handle(text: String, session: WebSocketSession) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return }

        switch type {
        case "keepalive":
            return
        case "pointer":
            let action = obj["action"] as? String ?? ""
            let seq = intVal(obj["seq"]) ?? 0
            if action == "cancel" {
                // 必须抬指：样板 cancelGesture；旧逻辑只 ack 会幽灵按住 / 悬浮球拖丢
                injector.pointer(action: "cancel", x: 0, y: 0)
                ack(session, seq: seq, ok: true)
                return
            }
            // JSONSerialization 数字是 NSNumber，不能 as? Double
            guard let x = doubleVal(obj["x"]), let y = doubleVal(obj["y"]),
                  x >= 0, x <= 1, y >= 0, y <= 1
            else {
                ack(session, seq: seq, ok: false, error: "bad coords")
                return
            }
            injector.pointer(action: action, x: x, y: y)
            // move 高频：不 ack，少一半往返，滑动更跟手
            if action != "move" {
                ack(session, seq: seq, ok: true)
            }
        case "button":
            let seq = intVal(obj["seq"]) ?? 0
            let btn = obj["button"] as? String ?? ""
            if btn == "home" {
                injector.pressHome()
                ack(session, seq: seq, ok: true)
            } else if btn == "app-switcher" || btn == "task-switcher" {
                injector.pressAppSwitcher()
                ack(session, seq: seq, ok: true)
            } else {
                ack(session, seq: seq, ok: false, error: "unsupported button")
            }
        case "home":
            let seq = intVal(obj["seq"]) ?? 0
            injector.pressHome()
            ack(session, seq: seq, ok: true)
        case "app-switcher":
            let seq = intVal(obj["seq"]) ?? 0
            injector.pressAppSwitcher()
            ack(session, seq: seq, ok: true)
        case "text":
            let seq = intVal(obj["seq"]) ?? 0
            let text = obj["text"] as? String ?? ""
            guard !text.isEmpty, text.utf8.count <= 4096 else {
                ack(session, seq: seq, ok: false, error: "bad text")
                return
            }
            injector.injectText(text)
            ack(session, seq: seq, ok: true)
        case "key":
            let seq = intVal(obj["seq"]) ?? 0
            let key = obj["key"] as? String ?? ""
            let allowed: Set<String> = ["backspace", "enter", "tab", "escape", "left", "right", "up", "down"]
            guard allowed.contains(key) else {
                ack(session, seq: seq, ok: false, error: "unsupported key")
                return
            }
            injector.injectKey(key)
            ack(session, seq: seq, ok: true)
        case "open-url":
            // PC「更新基座」：直接跳巨魔，不经 Safari；ack 以系统 open 结果为准
            let seq = intVal(obj["seq"]) ?? 0
            let raw = (obj["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.utf8.count <= 8192, let url = URL(string: raw), Self.allowedOpenURL(url) else {
                ack(session, seq: seq, ok: false, error: "bad url")
                return
            }
            let needArm = (url.scheme ?? "").lowercased() == "apple-magnifier"
            let parsedVer = TipaSelfUpdate.versionFromInstallURL(url) ?? ""
            // 先 open 巨魔（样板：workspace + UIApplication），再武装：
            // arm 在主进程回退时会 stop BaseRuntime 并掐断 WS，若先 arm 会导致 open 被跳过。
            TipaSelfUpdate.openTrollStore(url: url) { [weak self, weak session] ok in
                guard let self else { return }
                if ok {
                    AppRunLog.shared.append("控制通道打开巨魔 scheme=\(url.scheme ?? "?")")
                    if let session { self.ack(session, seq: seq, ok: true) }
                    if needArm {
                        DispatchQueue.global(qos: .userInitiated).async {
                            HelperLauncher.armPostUpdate(expectVersion: parsedVer)
                        }
                    }
                } else {
                    AppRunLog.shared.append("控制通道打开失败 scheme=\(url.scheme ?? "?")")
                    if let session { self.ack(session, seq: seq, ok: false, error: "open failed") }
                }
            }
        default:
            break
        }
    }

    /// 仅允许巨魔 install / 本应用唤起，避免被当成任意 URL 跳板
    private static func allowedOpenURL(_ url: URL) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "apple-magnifier" {
            // apple-magnifier://install?url=…
            let host = (url.host ?? "").lowercased()
            let path = url.path.lowercased()
            return host == "install" || path == "/install" || path.hasSuffix("/install")
        }
        if scheme == "phonebase" { return true }
        return false
    }

    private func doubleVal(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private func intVal(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private func ack(_ session: WebSocketSession, seq: Int, ok: Bool, error: String? = nil) {
        var body: [String: Any] = ["type": "ack", "seq": seq, "ok": ok]
        if let error { body["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: body),
           let text = String(data: data, encoding: .utf8) {
            session.sendText(text)
        }
    }
}
