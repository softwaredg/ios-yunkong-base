import Foundation

/// 主 App / Helper 共享的装后标记（同一 App 沙盒）。
enum UpdateMarker {
    private static var url: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("phonebase-post-update.flag")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func write(expectVersion: String) {
        let body = "\(expectVersion)\n\(Date().timeIntervalSince1970)\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    static func readVersion() -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let v = text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v : nil
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
