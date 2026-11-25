import Foundation
import UIKit

/// 主 UI 侧服务门面：优先 Helper 进程；Helper 起不来时回退到主进程 BaseRuntime。
final class ServiceGateway {
    static let shared = ServiceGateway()

    let port: UInt16 = 11019
    var onStatus: ((String) -> Void)?

    private var cachedRunning = false
    /// 当前由主进程 BaseRuntime 提供服务（Helper 不可用时的回退）
    private var usingInProcess = false
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
            let helperOk = HelperLauncher.tipaHealthy(expectVersion: "")
            let localOk = BaseRuntime.shared.isRunning
            self.lock.lock()
            if self.userStopped {
                self.cachedRunning = false
            } else {
                self.cachedRunning = helperOk || localOk
                if helperOk { self.usingInProcess = false }
                else if localOk { self.usingInProcess = true }
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

    /// 冷启动：若用户未主动停止，则拉起服务。
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
            self?.onStatus?("正在启动服务…")
        }
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
        let helperOk = HelperLauncher.ensureRunning()
        let expect = TipaSelfUpdate.localVersion
        let deadline = Date().addingTimeInterval(8)
        var healthy = HelperLauncher.tipaHealthy(expectVersion: expect)
        while !healthy && Date() < deadline {
            usleep(400_000)
            healthy = HelperLauncher.tipaHealthy(expectVersion: expect)
            if !healthy {
                // 版本戳异常时，至少确认有 lan-phonebase 在听
                healthy = HelperLauncher.tipaHealthy(expectVersion: "")
                    && HelperLauncher.isHelperAlive()
            }
        }

        if healthy {
            lock.lock()
            cachedRunning = true
            usingInProcess = false
            lock.unlock()
            let status = "服务已启动（Helper）· 本机:\(port)"
            AppRunLog.shared.append("用户启动服务 → Helper 就绪")
            DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
            return true
        }

        AppRunLog.shared.append(
            "Helper 未就绪（spawn=\(helperOk ? "ok" : "fail") alive=\(HelperLauncher.isHelperAlive() ? 1 : 0)），回退主进程开服"
        )
        // Helper 起不来：主进程直接开 BaseRuntime，保证 PC 能连
        let localOk: Bool = {
            if Thread.isMainThread {
                return BaseRuntime.shared.start(notifyStatus: true)
            }
            var result = false
            DispatchQueue.main.sync {
                result = BaseRuntime.shared.start(notifyStatus: true)
            }
            return result
        }()

        lock.lock()
        cachedRunning = localOk
        usingInProcess = localOk
        lock.unlock()

        let status: String
        if localOk {
            status = "服务已启动（主进程回退）· 本机:\(port)"
            AppRunLog.shared.append("主进程 BaseRuntime 已启动（Helper 回退）")
        } else {
            status = "启动失败：Helper 与主进程均未能监听 \(port)"
            AppRunLog.shared.append("启动失败：Helper/主进程都未就绪")
        }
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
        return localOk
    }

    func stop() {
        AppRunLog.shared.append("用户停止服务")
        lock.lock()
        userStopped = true
        cachedRunning = false
        let local = usingInProcess
        usingInProcess = false
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("正在停止服务…")
        }
        let work = {
            HelperLauncher.terminateHelper()
            if local || BaseRuntime.shared.isRunning {
                if Thread.isMainThread {
                    BaseRuntime.shared.stop()
                } else {
                    DispatchQueue.main.sync { BaseRuntime.shared.stop() }
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?("服务已停止")
            }
        }
        if Thread.isMainThread {
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        } else {
            work()
        }
    }
}
