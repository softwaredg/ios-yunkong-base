import Foundation

/// 主 UI 侧服务门面：实际投屏在 Helper 进程，经本机 HTTP 启停/探活。
final class ServiceGateway {
    static let shared = ServiceGateway()

    let port: UInt16 = 11019
    var onStatus: ((String) -> Void)?

    private var cachedRunning = false
    /// 用户点过停止后，启动自动 ensure 不再强行拉起，直到再次点启动
    private var userStopped = false
    private let lock = NSLock()

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedRunning
    }

    private init() {}

    func refreshStatus() {
        let ok = HelperLauncher.tipaHealthy(expectVersion: "")
        lock.lock()
        cachedRunning = ok
        if ok { userStopped = false }
        lock.unlock()
    }

    /// 冷启动：若用户未主动停止，则拉起 Helper。
    func startIfNeededOnLaunch() {
        lock.lock()
        let stopped = userStopped
        lock.unlock()
        if stopped { return }
        _ = start()
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        userStopped = false
        lock.unlock()
        onStatus?("正在拉起 Helper 服务…")
        let ok = HelperLauncher.ensureRunning()
        let deadline = Date().addingTimeInterval(10)
        var healthy = HelperLauncher.tipaHealthy(expectVersion: "")
        while !healthy && Date() < deadline {
            usleep(400_000)
            healthy = HelperLauncher.tipaHealthy(expectVersion: "")
        }
        lock.lock()
        cachedRunning = healthy
        lock.unlock()
        if healthy {
            onStatus?("服务已启动（Helper）· 本机:\(port)")
            AppRunLog.shared.append("用户启动服务 → Helper 就绪")
        } else if ok {
            onStatus?("Helper 已拉起，服务就绪中…")
            AppRunLog.shared.append("Helper 已 spawn，健康检查仍等待")
        } else {
            onStatus?("启动失败：无法拉起 PhoneBaseHelper")
        }
        return healthy || ok
    }

    func stop() {
        AppRunLog.shared.append("用户停止服务")
        lock.lock()
        userStopped = true
        lock.unlock()
        HelperLauncher.terminateHelper()
        lock.lock()
        cachedRunning = false
        lock.unlock()
        onStatus?("服务已停止")
    }
}
