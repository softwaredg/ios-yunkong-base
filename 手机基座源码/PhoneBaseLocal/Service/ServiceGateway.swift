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
    /// 启停代数：stop/start 互相作废对方的在途工作，避免并发把新服务拆掉
    private var epoch: UInt64 = 0
    private let lock = NSLock()

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedRunning
    }

    /// 是否由主进程在听（供 UI / 停止路径判断）。
    var isInProcess: Bool {
        lock.lock()
        defer { lock.unlock() }
        return usingInProcess
    }

    private init() {}

    /// 本机 11019 由 Helper 提供（主进程已在听时绝不算 Helper）。
    private static func helperServing() -> Bool {
        if BaseRuntime.shared.isRunning { return false }
        return HelperLauncher.isHelperAlive() && HelperLauncher.tipaHealthy(expectVersion: "")
    }

    func refreshStatus(completion: (() -> Void)? = nil) {
        let apply: () -> Void = { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?() }
                return
            }
            let helperOk = Self.helperServing()
            let localOk = BaseRuntime.shared.isRunning
            self.lock.lock()
            if self.userStopped {
                self.cachedRunning = false
            } else {
                self.cachedRunning = helperOk || localOk
                if helperOk {
                    self.usingInProcess = false
                } else if localOk {
                    self.usingInProcess = true
                } else {
                    self.usingInProcess = false
                }
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
        epoch &+= 1
        let myEpoch = epoch
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("正在启动服务…")
        }
        if Thread.isMainThread {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = self?.startBlocking(epoch: myEpoch)
            }
            return true
        }
        return startBlocking(epoch: myEpoch)
    }

    @discardableResult
    private func startBlocking(epoch myEpoch: UInt64) -> Bool {
        // 过期 start 只退出，禁止 terminate：可能误杀新一代刚拉起的 Helper
        if isStale(myEpoch) { return false }

        if BaseRuntime.shared.isRunning {
            lock.lock()
            if userStopped || epoch != myEpoch {
                lock.unlock()
                return false
            }
            cachedRunning = true
            usingInProcess = true
            lock.unlock()
            let status = "服务已启动（主进程）· 本机:\(port)"
            DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
            return true
        }

        let helperOk = HelperLauncher.ensureRunning()
        if isStale(myEpoch) { return false }

        let deadline = Date().addingTimeInterval(8)
        var healthy = Self.helperServing()
        while !healthy && Date() < deadline {
            if isStale(myEpoch) { return false }
            if !helperOk, !HelperLauncher.isHelperAlive() { break }
            usleep(400_000)
            healthy = Self.helperServing()
        }

        if healthy {
            lock.lock()
            if userStopped || epoch != myEpoch {
                lock.unlock()
                return false
            }
            cachedRunning = true
            usingInProcess = false
            lock.unlock()
            let status = "服务已启动（Helper）· 本机:\(port)"
            AppRunLog.shared.append("用户启动服务 → Helper 就绪")
            DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
            return true
        }

        if isStale(myEpoch) { return false }

        AppRunLog.shared.append(
            "Helper 未就绪（spawn=\(helperOk ? "ok" : "fail") alive=\(HelperLauncher.isHelperAlive() ? 1 : 0)），回退主进程开服"
        )
        HelperLauncher.terminateHelper()
        usleep(200_000)

        if isStale(myEpoch) { return false }

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
        if userStopped || epoch != myEpoch {
            lock.unlock()
            if localOk {
                if Thread.isMainThread {
                    BaseRuntime.shared.stop()
                } else {
                    DispatchQueue.main.sync { BaseRuntime.shared.stop() }
                }
            }
            return false
        }
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

    private func isStale(_ myEpoch: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return userStopped || epoch != myEpoch
    }

    func stop() {
        AppRunLog.shared.append("用户停止服务")
        let stopEpoch: UInt64
        lock.lock()
        userStopped = true
        epoch &+= 1
        stopEpoch = epoch
        cachedRunning = false
        usingInProcess = false
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("正在停止服务…")
        }
        let work = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let mine = self.userStopped && self.epoch == stopEpoch
            self.lock.unlock()
            guard mine else { return }

            HelperLauncher.terminateHelper()
            if BaseRuntime.shared.isRunning {
                if Thread.isMainThread {
                    BaseRuntime.shared.stop()
                } else {
                    DispatchQueue.main.sync { BaseRuntime.shared.stop() }
                }
            }
            DispatchQueue.main.async {
                self.lock.lock()
                let still = self.userStopped && self.epoch == stopEpoch
                self.lock.unlock()
                if still { self.onStatus?("服务已停止") }
            }
        }
        if Thread.isMainThread {
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        } else {
            work()
        }
    }
}
