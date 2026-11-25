import Foundation

enum ProcessRole {
    static let roleKey = "PHONEBASE_ROLE"
    static let parentKey = "PHONEBASE_PARENT_PID"
    static let postUpdateKey = "PHONEBASE_POST_UPDATE"
    static let expectVerKey = "PHONEBASE_EXPECT_VER"

    static var isHelper: Bool {
        (ProcessInfo.processInfo.environment[roleKey] ?? "") == "helper"
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
