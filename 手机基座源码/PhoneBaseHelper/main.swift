import Foundation
import UIKit
import Darwin

/// 入口分流：
/// - uid=0（persona root，装 tipa 武装）：不进 UIKit，只跑 Supervisor 装后拉起（样板同款）
/// - 日常 Helper：走 UIApplication + 开服
setenv("PHONEBASE_ROLE", "helper", 1)

if getuid() == 0 {
    AppRunLog.shared.append(
        "Helper root 拉起模式 uid=0 marker=\(UpdateMarker.exists ? 1 : 0) expect=\(ProcessRole.expectVersion)"
    )
    HelperSupervisor.shared.start()
    RunLoop.main.run()
} else {
    UIApplicationMain(
        CommandLine.argc,
        CommandLine.unsafeArgv,
        nil,
        NSStringFromClass(HelperAppDelegate.self)
    )
}
