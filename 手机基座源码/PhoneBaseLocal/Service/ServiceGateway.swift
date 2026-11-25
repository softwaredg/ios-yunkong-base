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

    func refreshStatus(completion: (() -> Void)? = nil) {
        let apply: () -> Void = { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?() }
                return
            }
            let ok = HelperLauncher.tipaHealthy(expectVersion: "")
            self.lock.lock()
            // 用户点过停止：即使 Helper 尚未杀掉，也不要把停止意图清掉、也不显示运行中
            if self.userStopped {
                self.cachedRunning = false
            } else {
                self.cachedRunning = ok
            }
            self.lock.unlock()
            DispatchQueue.main.async { completion?() }
        }
        if Thread.isMainThread {
            DispatchQueue.global(qos: .utility).async(execute: apply)
        } else {
            apply()
        }
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
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("正在拉起 Helper 服务…")
        }
        // 禁止在主线程 posix_spawn / 信号量干等，避免卡死 UI
        if Thread.isMainThread {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = self?.startBlocking()
            }
            return true
        }
        return startBlocking()
    }

    @discardableResult
    private func startBlocking() -> Bool {
        let ok = HelperLauncher.ensureRunning()
        let expect = TipaSelfUpdate.localVersion
        let deadline = Date().addingTimeInterval(10)
        var healthy = HelperLauncher.tipaHealthy(expectVersion: expect)
        while !healthy && Date() < deadline {
            usleep(400_000)
            healthy = HelperLauncher.tipaHealthy(expectVersion: expect)
        }
        lock.lock()
        cachedRunning = healthy
        lock.unlock()
        let status: String
        if healthy {
            status = "服务已启动（Helper）· 本机:\(port)"
            AppRunLog.shared.append("用户启动服务 → Helper 就绪")
        } else if ok {
            status = "Helper 已拉起，服务就绪中…"
            AppRunLog.shared.append("Helper 已 spawn，健康检查仍等待")
        } else {
            status = "启动失败：无法拉起 PhoneBaseHelper"
        }
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(status)
        }
        return healthy || ok
    }

    func stop() {
        AppRunLog.shared.append("用户停止服务")
        lock.lock()
        userStopped = true
        cachedRunning = false
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("正在停止 Helper…")
        }
        if Thread.isMainThread {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                HelperLauncher.terminateHelper()
                DispatchQueue.main.async {
                    self?.onStatus?("服务已停止")
                }
            }
        } else {
            HelperLauncher.terminateHelper()
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?("服务已停止")
            }
        }
    }
}
