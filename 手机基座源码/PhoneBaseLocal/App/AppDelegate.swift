import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        TipaSelfUpdate.resumeInstalledUpdateIfNeeded()

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = RootViewController(gateway: ServiceGateway.shared)
        window.makeKeyAndVisible()
        self.window = window

        LocalNetworkPermission.shared.requestIfNeeded()
        BackgroundKeepAlive.shared.start()

        // 主 UI 不绑 11019；拉起独立 Helper 跑投屏服务
        DispatchQueue.global(qos: .userInitiated).async {
            ServiceGateway.shared.startIfNeededOnLaunch()
            DispatchQueue.main.async {
                ServiceGateway.shared.refreshStatus()
            }
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundKeepAlive.shared.start()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        BackgroundKeepAlive.shared.start()
        // 只刷新状态；若用户已停止服务，不要自动再拉 Helper
        ServiceGateway.shared.refreshStatus()
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard url.scheme?.lowercased() == "phonebase" else { return false }
        BackgroundKeepAlive.shared.start()
        _ = HelperLauncher.ensureRunning()
        ServiceGateway.shared.refreshStatus()
        return true
    }
}
