import UIKit

/// 独立 Helper：常驻投屏服务 + 装后/崩溃拉起主 App。
@main
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

        HelperSupervisor.shared.start()
        DispatchQueue.main.async {
            let ok = BaseRuntime.shared.start(notifyStatus: true)
            NSLog("[Helper] BaseRuntime start ok=%d", ok ? 1 : 0)
            AppRunLog.shared.append(ok ? "Helper 服务已启动" : "Helper 服务启动失败")
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundKeepAlive.shared.start()
        if BaseRuntime.shared.isRunning {
            BaseRuntime.shared.setStreamingActive(true)
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        BackgroundKeepAlive.shared.start()
        if BaseRuntime.shared.isRunning {
            BaseRuntime.shared.setStreamingActive(true)
        }
    }
}
