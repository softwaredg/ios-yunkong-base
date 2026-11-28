import Foundation
import Darwin

/// 主 UI / Helper 共享运行日志：Library 落盘 + 追加写，避免两进程整文件互盖。
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
    /// 尚未落盘的行（只追加写，不整文件覆盖）
    private var pending: [String] = []

    private init() {
        fileURL = Self.sharedLogURL()
        queue.sync {
            reloadFromDiskLocked()
            appendLocked("========== 本地基座运行日志 ==========")
            let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let bid = Bundle.main.bundleIdentifier ?? "?"
            let role = ProcessRole.isHelper ? "helper" : "main"
            appendLocked("应用启动 · 版本 \(ver) · \(bid) · \(role)")
            persistLockedNow()
        }
    }

    private static func sharedLogURL() -> URL? {
        // 与 ServeIntent 同级 Library；优先 PHONEBASE_HOME，避免 Helper 日志写丢
        if let home = ProcessRole.dataHomePath {
            return URL(fileURLWithPath: home)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("phonebase_run.log")
        }
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("phonebase_run.log")
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
        queue.sync {
            // 读盘合并，带上对端进程刚写的行
            self.reloadFromDiskLocked()
            return self.lines.joined(separator: "\n")
        }
    }

    func clear() {
        queue.sync {
            lines.removeAll(keepingCapacity: true)
            pending.removeAll(keepingCapacity: true)
            if let url = fileURL {
                try? "".write(to: url, atomically: true, encoding: .utf8)
            }
            appendLocked("日志已清空")
            persistLockedNow()
        }
    }

    /// 硬退出前立刻落盘，避免异步 debounce 被 exit 砍掉。
    func flush() {
        queue.sync { persistLockedNow() }
    }

    private func appendLocked(_ message: String) {
        let stamp = formatter.string(from: Date())
        let chunks = message.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, chunk) in chunks.enumerated() {
            let line = i == 0 ? "[\(stamp)] \(chunk)" : "           \(chunk)"
            lines.append(line)
            pending.append(line)
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
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func persistLockedNow() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        guard let url = fileURL, !pending.isEmpty else { return }
        let chunk = pending.joined(separator: "\n") + "\n"
        pending.removeAll(keepingCapacity: true)
        let path = url.path
        // O_CREAT|O_APPEND：勿用 createFile（会截断已有日志）
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        flock(fd, LOCK_EX)
        chunk.withCString { ptr in
            let len = strlen(ptr)
            _ = write(fd, ptr, len)
        }
        flock(fd, LOCK_UN)
        close(fd)
        trimFileIfNeededLocked(url: url)
    }

    private func reloadFromDiskLocked() {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return }
        var disk = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while disk.last == "" { disk.removeLast() }
        if disk.count > maxLines {
            disk = Array(disk.suffix(maxLines))
        }
        // 保留尚未落盘的 pending，叠在磁盘内容后
        if pending.isEmpty {
            lines = disk
        } else {
            lines = disk + pending
            if lines.count > maxLines {
                lines = Array(lines.suffix(maxLines))
            }
        }
    }

    private func trimFileIfNeededLocked(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return }
        var all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while all.last == "" { all.removeLast() }
        guard all.count > maxLines + 50 else { return }
        let kept = Array(all.suffix(maxLines)).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
}
