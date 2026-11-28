import Foundation
import UIKit
import Darwin

/// 入口分流：
/// - uid=0（persona root，装 tipa 武装）：不进 UIKit，只跑 Supervisor 装后拉起（样板同款）
/// - 日常 Helper：先同步开服，再进 UIApplication（embedded 二进制上 didFinishLaunching 常不来）
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
    let shouldListen = ProcessRole.forceServe || ServeIntent.shouldServe || UpdateMarker.exists
    if shouldListen {
        HelperSupervisor.shared.start()
        // 必须在 UIApplicationMain 之前同步听口：日志里从未出现「Helper 进程启动」= delegate 没跑到
        let ok = BaseRuntime.shared.start(notifyStatus: true)
        AppRunLog.shared.append(ok ? "Helper 预开服成功（UIKit前）" : "Helper 预开服失败（UIKit前）")
        AppRunLog.shared.flush()
    } else {
        AppRunLog.shared.append("Helper mobile 入口 · 应开服=0，跳过预开服")
        AppRunLog.shared.flush()
    }
    UIApplicationMain(
        CommandLine.argc,
        CommandLine.unsafeArgv,
        nil,
        NSStringFromClass(HelperAppDelegate.self)
    )
}
