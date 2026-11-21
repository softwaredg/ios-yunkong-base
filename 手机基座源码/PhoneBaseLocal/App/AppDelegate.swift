import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var runtime: BaseRuntime?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // watchdog 子进程不进 UI / 不启服务；主进程崩了由它拉起
        if ProcessWatchdog.bootstrapIfNeeded() {
            return false
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
