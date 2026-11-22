import Foundation

/// 进程内运行日志（环形缓冲 + 落盘），供「运行日志」页展示。
final class AppRunLog {
    static let shared = AppRunLog()

    private let queue = DispatchQueue(label: "cn.iosmirror.base.runlog")
    private var lines: [String] = []
    private let maxLines = 800
    private let fileURL: URL?
    /// 仅在 queue 上使用（DateFormatter 非线程安全）
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private var persistWorkItem: DispatchWorkItem?

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        fileURL = dir?.appendingPathComponent("phonebase_run.log")
        queue.sync {
            if let url = fileURL, let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if lines.count > maxLines {
                    lines = Array(lines.suffix(maxLines))
                }
            }
            appendLocked("========== 本地基座运行日志 ==========")
            let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let bid = Bundle.main.bundleIdentifier ?? "?"
            appendLocked("应用启动 · 版本 \(ver) · \(bid)")
            persistLockedNow()
        }
    }

    func append(_ message: String) {
        let raw = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        queue.async {
            self.appendLocked(raw)
            self.schedulePersistLocked()
        }
    }

    func snapshot() -> String {
        queue.sync { lines.joined(separator: "\n") }
    }

    func clear() {
        queue.sync {
            lines.removeAll(keepingCapacity: true)
            appendLocked("日志已清空")
            persistLockedNow()
        }
    }

    private func appendLocked(_ message: String) {
        let stamp = formatter.string(from: Date())
        let chunks = message.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, chunk) in chunks.enumerated() {
            let line = i == 0 ? "[\(stamp)] \(chunk)" : "           \(chunk)"
            lines.append(line)
        }
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }
    }

    private func schedulePersistLocked() {
        persistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistLockedNow()
        }
        persistWorkItem = work
        // 合并短时高频写入，避免连接通知刷盘
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func persistLockedNow() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        guard let url = fileURL else { return }
        let text = lines.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
