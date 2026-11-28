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

        // 主 UI 不绑 11019；按本机版本拉起/替换 Helper（装后会踢掉旧二进制）
        DispatchQueue.global(qos: .userInitiated).async {
            ServiceGateway.shared.startIfNeededOnLaunch()
            DispatchQueue.main.async {
                ServiceGateway.shared.refreshStatus()
            }
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        AppRunLog.shared.append("主 UI 进入后台")
        BackgroundKeepAlive.shared.start()
        // Helper 若已在听则只改标记；未听则保持主进程兜底，勿停口交回（交回失败会空窗）
        if ServiceGateway.shared.isInProcess, HelperLauncher.isHelperAlive(),
           HelperLauncher.tipaHealthy(expectVersion: "") {
            DispatchQueue.global(qos: .utility).async {
                ServiceGateway.shared.refreshStatus()
            }
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppRunLog.shared.append("主 UI 即将退出")
        AppRunLog.shared.flush()
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
        // 走完整启动（含 Helper 失败时主进程回退），不要只 ensure Helper
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ServiceGateway.shared.start()
        }
        return true
    }
}
