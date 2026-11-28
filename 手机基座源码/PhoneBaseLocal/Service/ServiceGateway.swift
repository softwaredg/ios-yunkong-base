import Foundation
import UIKit

/// 主 UI 侧服务门面：对齐样板 — Helper 常驻听 11019；主进程仅兜底。
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
        // 主进程若自己占口，不能把本机探活当成 Helper
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
        // 用户点过停止（flag 已清）则冷启动不自动开服；首次无 flag 仍开服
        if stopped { return }
        if !ServeIntent.shouldServe {
            // 无 flag：可能是首次，或用户停过。用「停过」哨兵文件区分。
            if ServeIntent.userStoppedBefore {
                return
            }
        }
        _ = start()
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        userStopped = false
        epoch &+= 1
        let myEpoch = epoch
        lock.unlock()
        ServeIntent.set(true)
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

        // 主进程让出口，交给 Helper 常驻听 11019
        if BaseRuntime.shared.isRunning {
            AppRunLog.shared.append("开服：主进程让出口给 Helper")
            if Thread.isMainThread {
                BaseRuntime.shared.stop()
            } else {
                DispatchQueue.main.sync { BaseRuntime.shared.stop() }
            }
            usleep(200_000)
        }
        if isStale(myEpoch) { return false }

        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("正在拉起 Helper 服务…")
        }
        let helperOk = HelperLauncher.ensureRunning()
        if isStale(myEpoch) { return false }

        let deadline = Date().addingTimeInterval(6)
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
            AppRunLog.shared.append("用户启动服务 → Helper 就绪（常驻）")
            DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
            return true
        }

        if isStale(myEpoch) { return false }

        AppRunLog.shared.append(
            "Helper 未就绪（spawn=\(helperOk ? "ok" : "fail") alive=\(HelperLauncher.isHelperAlive() ? 1 : 0)），主进程兜底开服"
        )
        HelperLauncher.terminateHelper()
        usleep(150_000)
        if isStale(myEpoch) { return false }

        if commitInProcessFallback(epoch: myEpoch) {
            return true
        }

        let status = "启动失败：无法监听 \(port)"
        AppRunLog.shared.append("启动失败：Helper 与主进程均未就绪")
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
        return false
    }

    /// 仅 Helper 起不来时兜底；会清 Helper 并由主进程占口。
    @discardableResult
    private func commitInProcessFallback(epoch myEpoch: UInt64) -> Bool {
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
            AppRunLog.shared.append("主进程 BaseRuntime 兜底已启动")
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?("服务已启动（主进程兜底）· 本机:\(self?.port ?? 11019)")
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
        ServeIntent.set(false)
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
