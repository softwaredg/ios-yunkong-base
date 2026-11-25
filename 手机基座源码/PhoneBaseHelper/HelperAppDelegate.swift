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
        // 必须同步开服：posix_spawn 出来的进程 main.async 常迟迟不跑，会出现 alive 但 11019 无响应
        let ok = BaseRuntime.shared.start(notifyStatus: true)
        NSLog("[Helper] BaseRuntime start ok=%d", ok ? 1 : 0)
        AppRunLog.shared.append(ok ? "Helper 服务已启动" : "Helper 服务启动失败")
        if !ok {
            // 再丢一次到 main，避免首次同步时 UIKit 未就绪
            DispatchQueue.main.async {
                if !BaseRuntime.shared.isRunning {
                    let again = BaseRuntime.shared.start(notifyStatus: true)
                    NSLog("[Helper] BaseRuntime retry ok=%d", again ? 1 : 0)
                }
            }
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
