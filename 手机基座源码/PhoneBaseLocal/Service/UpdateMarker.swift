import Foundation

/// 主 App / Helper 共享的装后标记（同一 App 沙盒）。
enum UpdateMarker {
    private static var url: URL {
        // persona/root Helper 与主进程共用：优先 PHONEBASE_HOME / HOME
        if let home = ProcessRole.dataHomePath {
            return URL(fileURLWithPath: home)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("phonebase-post-update.flag")
        }
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("phonebase-post-update.flag")
    }

    /// 超过此时长未完成的装后标记视为过期（取消安装 / 中途放弃）。
    private static let maxAgeSec: TimeInterval = 6 * 3600

    static var exists: Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if isExpired {
            clear()
            return false
        }
        return true
    }

    static var isExpired: Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return true }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, let ts = TimeInterval(lines[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return Date().timeIntervalSince1970 - ts > maxAgeSec
    }

    /// line0=expectVersion  line1=timestamp  line2=baselineLocal（装前本机版本）
    static func write(expectVersion: String, baselineLocal: String = TipaSelfUpdate.localVersion) {
        let body = "\(expectVersion)\n\(Date().timeIntervalSince1970)\n\(baselineLocal)\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    static func readVersion() -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let v = text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v : nil
    }

    static func readBaseline() -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3 else { return nil }
        let b = String(lines[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? nil : b
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
