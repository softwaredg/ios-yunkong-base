import Foundation
import UIKit

/// 主 UI 侧服务门面：日常优先主进程开服（可靠）；Helper 主要用于装后拉起。
final class ServiceGateway {
    static let shared = ServiceGateway()

    let port: UInt16 = 11019
    var onStatus: ((String) -> Void)?

    private var cachedRunning = false
    private var usingInProcess = false
    private var userStopped = false
    private var epoch: UInt64 = 0
    private let lock = NSLock()

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedRunning
    }

    var isInProcess: Bool {
        lock.lock()
        defer { lock.unlock() }
        return usingInProcess
    }

    private init() {}

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
        if isStale(myEpoch) { return false }

        // 日常投屏：主进程优先（Helper 在部分机型 posix_spawn 后进程活着但不听口）
        if commitInProcessIfPossible(epoch: myEpoch) {
            return true
        }
        if isStale(myEpoch) { return false }

        // 主进程失败时再试 Helper（短等）
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("主进程未就绪，尝试 Helper…")
        }
        let helperOk = HelperLauncher.ensureRunning()
        if isStale(myEpoch) { return false }

        let deadline = Date().addingTimeInterval(4)
        var healthy = Self.helperServing()
        while !healthy && Date() < deadline {
            if isStale(myEpoch) { return false }
            if !helperOk, !HelperLauncher.isHelperAlive() { break }
            usleep(300_000)
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
            "Helper 仍未就绪（spawn=\(helperOk ? "ok" : "fail") alive=\(HelperLauncher.isHelperAlive() ? 1 : 0)），再次主进程开服"
        )
        HelperLauncher.terminateHelper()
        usleep(150_000)
        if isStale(myEpoch) { return false }

        if commitInProcessIfPossible(epoch: myEpoch, forceStart: true) {
            return true
        }

        let status = "启动失败：无法监听 \(port)"
        AppRunLog.shared.append("启动失败：主进程与 Helper 均未就绪")
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
        return false
    }

    /// 主进程开服并提交状态。
    @discardableResult
    private func commitInProcessIfPossible(epoch myEpoch: UInt64, forceStart: Bool = false) -> Bool {
        if !forceStart, BaseRuntime.shared.isRunning {
            lock.lock()
            if userStopped || epoch != myEpoch {
                lock.unlock()
                return false
            }
            cachedRunning = true
            usingInProcess = true
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?("服务已启动（主进程）· 本机:\(self?.port ?? 11019)")
            }
            return true
        }

        // 清掉僵死 Helper，避免占口
        if HelperLauncher.isHelperAlive() {
            HelperLauncher.terminateHelper()
            usleep(150_000)
        }
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

        if localOk {
            AppRunLog.shared.append("主进程 BaseRuntime 已启动")
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?("服务已启动（主进程）· 本机:\(self?.port ?? 11019)")
            }
        }
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
