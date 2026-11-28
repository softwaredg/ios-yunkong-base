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
    // RunLoop.main.run() 无源会立刻返回 → 装后 Helper 秒退；dispatchMain 常驻
    dispatchMain()
} else {
    AppRunLog.shared.append(
        "Helper mobile 入口 → UIKit forceServe=\(ProcessRole.forceServe ? 1 : 0) home=\(ProcessRole.dataHomePath ?? "?")"
    )
    AppRunLog.shared.flush()
    UIApplicationMain(
        CommandLine.argc,
        CommandLine.unsafeArgv,
        nil,
        NSStringFromClass(HelperAppDelegate.self)
    )
}
