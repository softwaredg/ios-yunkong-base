import Foundation

/// 主 UI / Helper 共享：用户是否要求开服（停止后 Helper 不拉 UI、可停听口）。
enum ServeIntent {
    private static func libraryFile(_ name: String) -> URL {
        if let home = ProcessRole.dataHomePath {
            return URL(fileURLWithPath: home)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent(name)
        }
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(name)
    }

    private static var url: URL { libraryFile("phonebase-should-serve.flag") }
    private static var stoppedUrl: URL { libraryFile("phonebase-user-stopped.flag") }

    static var shouldServe: Bool {
        // 主进程 spawn 时带 FORCE_SERVE：Helper 不得因 flag 路径不一致而跳过听口
        if ProcessRole.forceServe { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 用户曾点过停止（冷启动勿自动开服）
    static var userStoppedBefore: Bool {
        FileManager.default.fileExists(atPath: stoppedUrl.path)
    }

    static func set(_ on: Bool) {
        if on {
            try? FileManager.default.removeItem(at: stoppedUrl)
            try? "1\n\(Date().timeIntervalSince1970)\n".write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
            try? "1\n\(Date().timeIntervalSince1970)\n".write(to: stoppedUrl, atomically: true, encoding: .utf8)
        }
    }
}
