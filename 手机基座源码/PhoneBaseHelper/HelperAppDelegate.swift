import UIKit
import Darwin

/// 独立 Helper：常驻投屏服务（mobile uid）。装后 root 拉起见 `main.swift`。
final class HelperAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        setenv("PHONEBASE_ROLE", "helper", 1)
        BackgroundKeepAlive.shared.start()
        bgTask = application.beginBackgroundTask(withName: "phonebase-helper") { [weak self] in
            guard let self else { return }
            if self.bgTask != .invalid {
                application.endBackgroundTask(self.bgTask)
                self.bgTask = .invalid
            }
        }

        let window = UIWindow(frame: .zero)
        window.isHidden = true
        self.window = window

        AppRunLog.shared.append(
            "Helper UIKit 起来 uid=\(getuid()) running=\(BaseRuntime.shared.isRunning ? 1 : 0) marker=\(UpdateMarker.exists ? 1 : 0)"
        )
        HelperSupervisor.shared.start()
        // main.swift 已预开服成功则只挂 KeepAlive
        if BaseRuntime.shared.isRunning {
            AppRunLog.shared.append("Helper 服务已在听（预开服）")
            return true
        }
        if !ServeIntent.shouldServe, !UpdateMarker.exists, !ProcessRole.forceServe {
            AppRunLog.shared.append("Helper UIKit · 应开服=0，跳过听口")
            AppRunLog.shared.flush()
            return true
        }
        let ok = BaseRuntime.shared.start(notifyStatus: true)
        NSLog("[Helper] BaseRuntime start ok=%d", ok ? 1 : 0)
        AppRunLog.shared.append(ok ? "Helper 服务已启动（常驻）" : "Helper 服务启动失败")
        AppRunLog.shared.flush()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        AppRunLog.shared.append("Helper 进入后台")
        BackgroundKeepAlive.shared.start()
        if BaseRuntime.shared.isRunning {
            BaseRuntime.shared.setStreamingActive(true)
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppRunLog.shared.append("Helper 即将退出")
        AppRunLog.shared.flush()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        BackgroundKeepAlive.shared.start()
        if BaseRuntime.shared.isRunning {
            BaseRuntime.shared.setStreamingActive(true)
        }
    }
}
