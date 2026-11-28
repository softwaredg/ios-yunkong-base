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

        // 先落盘：证明 Helper 已起来；装后拉起不依赖开服成败
        AppRunLog.shared.append(
            "Helper 进程启动 uid=\(getuid()) marker=\(UpdateMarker.exists ? 1 : 0) postUpdate=\(ProcessRole.postUpdateArmed ? 1 : 0)"
        )
        HelperSupervisor.shared.start()
        // 用户已停止则只挂 Supervisor，不开服
        if !ServeIntent.shouldServe, !UpdateMarker.exists {
            AppRunLog.shared.append("Helper 进程启动 · 应开服=0，跳过听口")
            return true
        }
        // 必须同步开服：posix_spawn 出来的进程 main.async 常迟迟不跑，会出现 alive 但 11019 无响应
        let ok = BaseRuntime.shared.start(notifyStatus: true)
        NSLog("[Helper] BaseRuntime start ok=%d", ok ? 1 : 0)
        AppRunLog.shared.append(ok ? "Helper 服务已启动（常驻）" : "Helper 服务启动失败")
        if !ok {
            DispatchQueue.main.async {
                if !BaseRuntime.shared.isRunning, ServeIntent.shouldServe || UpdateMarker.exists {
                    let again = BaseRuntime.shared.start(notifyStatus: true)
                    NSLog("[Helper] BaseRuntime retry ok=%d", again ? 1 : 0)
                }
            }
        }
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
