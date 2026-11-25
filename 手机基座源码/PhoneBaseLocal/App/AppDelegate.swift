import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var runtime: BaseRuntime?
    /// 看门狗/relauncher 进程持有，避免被系统过早回收
    private var watchdogBgTask: UIBackgroundTaskIdentifier = .invalid

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // watchdog / relauncher：不启投屏服务，但必须保活 runloop + 音频，否则秒挂起
        if ProcessWatchdog.bootstrapIfNeeded() {
            BackgroundKeepAlive.shared.start()
            watchdogBgTask = application.beginBackgroundTask(withName: "phonebase-watchdog") { [weak self] in
                guard let self else { return }
                if self.watchdogBgTask != .invalid {
                    application.endBackgroundTask(self.watchdogBgTask)
                    self.watchdogBgTask = .invalid
                }
            }
            // 零尺寸窗，避免再占一层 UI；runloop 仍要转
            let window = UIWindow(frame: .zero)
            window.isHidden = true
            self.window = window
            return true
        }

        let runtime = BaseRuntime.shared
        self.runtime = runtime
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = RootViewController(runtime: runtime)
        window.makeKeyAndVisible()
        self.window = window
        LocalNetworkPermission.shared.requestIfNeeded()
        BackgroundKeepAlive.shared.start()
        runtime.start()
        runtime.setStreamingActive(true)
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundKeepAlive.shared.start()
        if let runtime, runtime.isRunning {
            runtime.setStreamingActive(true)
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        BackgroundKeepAlive.shared.start()
        if let runtime, runtime.isRunning {
            runtime.setStreamingActive(true)
        }
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard url.scheme?.lowercased() == "phonebase" else { return false }
        BackgroundKeepAlive.shared.start()
        if let runtime {
            if !runtime.isRunning {
                _ = runtime.start()
            }
            runtime.setStreamingActive(true)
        }
        return true
    }
}
