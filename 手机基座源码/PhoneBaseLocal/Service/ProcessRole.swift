import Foundation

enum ProcessRole {
    static let roleKey = "PHONEBASE_ROLE"
    static let parentKey = "PHONEBASE_PARENT_PID"
    static let postUpdateKey = "PHONEBASE_POST_UPDATE"
    static let expectVerKey = "PHONEBASE_EXPECT_VER"
    /// 主进程拉起日常 Helper 时写入：即使 flag 看不见也必须听口
    static let forceServeKey = "PHONEBASE_FORCE_SERVE"
    /// 主容器 HOME，避免 Helper 写到别的 Library 导致「应开服」与日志分裂
    static let homeKey = "PHONEBASE_HOME"

    static var isHelper: Bool {
        (ProcessInfo.processInfo.environment[roleKey] ?? "") == "helper"
    }

    static var forceServe: Bool {
        ProcessInfo.processInfo.environment[forceServeKey] == "1"
    }

    /// 主/Helper 共用数据根（优先 PHONEBASE_HOME）
    static var dataHomePath: String? {
        let env = ProcessInfo.processInfo.environment
        for key in [homeKey, "HOME"] {
            if let h = env[key], !h.isEmpty { return h }
        }
        return nil
    }

    static var parentPid: pid_t {
        Int32(ProcessInfo.processInfo.environment[parentKey] ?? "") ?? 0
    }

    static var postUpdateArmed: Bool {
        ProcessInfo.processInfo.environment[postUpdateKey] == "1" || UpdateMarker.exists
    }

    static var expectVersion: String {
        let env = ProcessInfo.processInfo.environment[expectVerKey] ?? ""
        if !env.isEmpty { return env }
        return UpdateMarker.readVersion() ?? ""
    }

    static let mainBundleId = "cn.iosmirror.base"
    static let helperExecutableName = "PhoneBaseHelper"
}
