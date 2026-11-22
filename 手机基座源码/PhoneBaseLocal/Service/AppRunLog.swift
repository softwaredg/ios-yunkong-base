import Foundation

/// 进程内运行日志（环形缓冲 + 落盘），供「运行日志」页展示。
final class AppRunLog {
    static let shared = AppRunLog()

    private let queue = DispatchQueue(label: "cn.iosmirror.base.runlog")
    private var lines: [String] = []
    private let maxLines = 800
    private let fileURL: URL?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        fileURL = dir?.appendingPathComponent("phonebase_run.log")
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.count > maxLines {
                lines = Array(lines.suffix(maxLines))
            }
        }
        append("========== 本地基座运行日志 ==========")
        append("应用启动 · 版本 \(TipaSelfUpdate.localVersion) · \(Bundle.main.bundleIdentifier ?? "?")")
    }

    func append(_ message: String) {
        let stamp = formatter.string(from: Date())
        let raw = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let chunks = raw.split(separator: "\n", omittingEmptySubsequences: false)
        queue.async {
            for (i, chunk) in chunks.enumerated() {
                let line = i == 0 ? "[\(stamp)] \(chunk)" : "           \(chunk)"
                self.lines.append(line)
            }
            if self.lines.count > self.maxLines {
                self.lines = Array(self.lines.suffix(self.maxLines))
            }
            self.persistLocked()
        }
    }

    func snapshot() -> String {
        queue.sync { lines.joined(separator: "\n") }
    }

    func clear() {
        queue.sync {
            lines.removeAll(keepingCapacity: true)
            if let url = fileURL {
                try? "".write(to: url, atomically: true, encoding: .utf8)
            }
        }
        append("日志已清空")
    }

    private func persistLocked() {
        guard let url = fileURL else { return }
        let text = lines.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
