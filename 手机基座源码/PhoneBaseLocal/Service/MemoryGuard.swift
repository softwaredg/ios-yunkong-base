import Foundation
import Darwin

/// 对齐样板 2.3 `sampleMemoryAndProtect`：trim 一次 + 单硬阈状态机，不刷 soft 日志。
final class MemoryGuard {
    static let shared = MemoryGuard()

    /// 样板主硬阈（默认 400MB）
    var memoryLimitBytes: UInt64 = 400 * 1024 * 1024
    /// 压力 trim 阈值（默认 320MB）；只触发一次 onTrim
    var trimThresholdBytes: UInt64 = 320 * 1024 * 1024
    /// 回滞：低于此才清 trim / onRecovered（默认 280MB）
    var clearTrimBelowBytes: UInt64 = 280 * 1024 * 1024
    /// 兼容旧名
    var softLimitBytes: UInt64 {
        get { trimThresholdBytes }
        set { trimThresholdBytes = newValue }
    }
    var limitBytes: UInt64 {
        get { memoryLimitBytes }
        set { memoryLimitBytes = newValue }
    }

    private(set) var automatic = true
    private(set) var overLimitSince: TimeInterval?
    private(set) var restartCount = 0
    private(set) var historyMillis: [Int] = []
    private(set) var trimmedForPressure = false
    /// normal | observing | waiting-idle | cooldown | rate-limited | restarting | disabled
    private(set) var state = "normal"
    private var lastRestartAt: Date?
    private var trimArmedSince: TimeInterval?
    /// 硬退已安排：避免 exit 前重复 onOverLimit（对齐样板 `_restartScheduled`）
    private var restartScheduled = false
    /// 已向主线程投递 onOverLimit，完成前勿重复投递
    private var overLimitPosted = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "cn.local.phonebase.memory-guard")
    private let overLimitGraceSec: TimeInterval = 3
    private let trimGraceSec: TimeInterval = 2
    private let cooldownSec: TimeInterval = 15
    var onOverLimit: ((UInt64) -> Void)?
    /// 压力 trim：只回调一次直到回滞清除
    var onTrim: ((UInt64) -> Void)?
    var onRecovered: (() -> Void)?
    private let vetoBytes: UInt64 = 800 * 1024 * 1024

    var status: [String: Any] {
        let fp = Self.physFootprint()
        let sustained: Double
        if let since = overLimitSince {
            sustained = max(0, Date().timeIntervalSince1970 - since)
        } else {
            sustained = 0
        }
        let coolLeft: Double
        if let last = lastRestartAt {
            coolLeft = max(0, cooldownSec - Date().timeIntervalSince(last))
        } else {
            coolLeft = 0
        }
        return [
            "automatic": automatic,
            "memoryLimitBytes": memoryLimitBytes,
            "trimThresholdBytes": trimThresholdBytes,
            "clearTrimBelowBytes": clearTrimBelowBytes,
            // 旧 PC / 别名
            "softLimitBytes": trimThresholdBytes,
            "limitBytes": memoryLimitBytes,
            "footprintBytes": fp,
            "currentBytes": fp,
            "overLimitSince": overLimitSince as Any,
            "sustainedSeconds": sustained,
            "cooldownSeconds": cooldownSec,
            "historyMillis": historyMillis,
            "historyCount": historyMillis.count,
            "restartCount": restartCount,
            "trimmedForPressure": trimmedForPressure,
            "state": state,
            "cooldownRemainingSeconds": coolLeft,
        ]
    }

    func setEnabled(_ on: Bool) {
        automatic = on
        if !on {
            overLimitSince = nil
            trimArmedSince = nil
            state = "disabled"
        } else if state == "disabled" {
            state = "normal"
        }
        persist()
    }

    func start() {
        automatic = UserDefaults.standard.object(forKey: "local.memoryGuard.automatic") as? Bool ?? true
        restartCount = UserDefaults.standard.integer(forKey: "local.memoryGuard.restartCount")
        trimmedForPressure =
            UserDefaults.standard.bool(forKey: "local.memoryGuard.trimmedForPressure")
        if !automatic { state = "disabled" }
        if timer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        _ = Self.selfCheckLogic()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        overLimitSince = nil
        trimArmedSince = nil
    }

    func noteRestart(reason: String) {
        let now = Date()
        if let last = lastRestartAt {
            let ms = Int(now.timeIntervalSince(last) * 1000)
            historyMillis.insert(ms, at: 0)
            if historyMillis.count > 3 { historyMillis = Array(historyMillis.prefix(3)) }
        }
        lastRestartAt = now
        restartCount += 1
        overLimitSince = nil
        trimArmedSince = nil
        // hard exit 路径先 markRestarting 再 noteRestart：保持屏蔽，避免 exit 前再入
        if restartScheduled {
            state = "restarting"
        } else {
            restartScheduled = false
            state = "cooldown"
        }
        persist()
        NSLog("[MemoryGuard] restart reason=%@ count=%d", reason, restartCount)
    }

    func markWaitingIdle() {
        restartScheduled = false
        overLimitPosted = false
        state = "waiting-idle"
        // 保留 overLimitSince，下一拍继续决策
    }

    func markRestarting() {
        restartScheduled = true
        overLimitPosted = true
        state = "restarting"
    }

    func setTrimmedForPressure(_ on: Bool, persistNow: Bool = true) {
        trimmedForPressure = on
        if persistNow {
            UserDefaults.standard.set(on, forKey: "local.memoryGuard.trimmedForPressure")
        }
    }

    private func persist() {
        UserDefaults.standard.set(automatic, forKey: "local.memoryGuard.automatic")
        UserDefaults.standard.set(restartCount, forKey: "local.memoryGuard.restartCount")
        UserDefaults.standard.set(trimmedForPressure, forKey: "local.memoryGuard.trimmedForPressure")
    }

    private func tick() {
        guard automatic else {
            state = "disabled"
            return
        }
        let cur = Self.physFootprint()
        let now = Date().timeIntervalSince1970

        // 回滞以下：清 trim
        if cur < clearTrimBelowBytes {
            overLimitSince = nil
            trimArmedSince = nil
            if trimmedForPressure {
                trimmedForPressure = false
                persist()
                state = "normal"
                DispatchQueue.main.async { [weak self] in
                    self?.onRecovered?()
                }
            } else if state != "cooldown" && state != "rate-limited" {
                state = "normal"
            } else if let last = lastRestartAt, Date().timeIntervalSince(last) >= cooldownSec {
                state = "normal"
            }
            return
        }

        // 硬阈
        if cur >= memoryLimitBytes {
            if overLimitSince == nil { overLimitSince = now }
            state = state == "waiting-idle" ? "waiting-idle" : "observing"
            let extreme = cur >= vetoBytes || cur >= memoryLimitBytes &* 2
            let grace = extreme ? 0.5 : overLimitGraceSec
            guard let since = overLimitSince, now - since >= grace else { return }
            if !extreme, let last = lastRestartAt, Date().timeIntervalSince(last) < cooldownSec {
                state = "rate-limited"
                return
            }
            if restartScheduled || overLimitPosted { return }
            // 投递占坑（非 restartScheduled）：soft-ok / waiting-idle 仍可再次进入硬阈
            overLimitPosted = true
            // 不清 overLimitSince：waiting-idle 时可再入；noteRestart / 降回时再清
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onOverLimit?(cur)
                // hardExit 会 markRestarting；未硬退则放开，允许后续 tick 再决策
                if !self.restartScheduled {
                    self.overLimitPosted = false
                }
            }
            return
        }

        overLimitSince = nil

        // trim 带：未 trim 则武装一次
        if cur >= trimThresholdBytes {
            state = "observing"
            if trimmedForPressure { return }
            if trimArmedSince == nil { trimArmedSince = now }
            guard let since = trimArmedSince, now - since >= trimGraceSec else { return }
            trimArmedSince = nil
            trimmedForPressure = true
            persist()
            DispatchQueue.main.async { [weak self] in
                self?.onTrim?(cur)
            }
            return
        }

        // trimThreshold 与 clearTrim 之间：保持现状，不刷回调
        trimArmedSince = nil
        if state == "waiting-idle" { state = "observing" }
    }

    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    /// 纯逻辑自检：trim 只一次、硬阈走 cooldown、回滞才清。失败打日志。
    @discardableResult
    static func selfCheckLogic() -> Bool {
        let trim: UInt64 = 320 * 1024 * 1024
        let hard: UInt64 = 400 * 1024 * 1024
        let clear: UInt64 = 280 * 1024 * 1024
        var trimmed = false
        var trimCalls = 0
        var hardCalls = 0
        func step(_ fp: UInt64) {
            if fp < clear {
                if trimmed { trimmed = false }
                return
            }
            if fp >= hard {
                hardCalls += 1
                return
            }
            if fp >= trim, !trimmed {
                trimmed = true
                trimCalls += 1
            }
        }
        step(350 * 1024 * 1024)
        step(350 * 1024 * 1024)
        step(350 * 1024 * 1024)
        step(420 * 1024 * 1024)
        step(250 * 1024 * 1024)
        let ok = trimCalls == 1 && hardCalls == 1 && trimmed == false
        if !ok {
            NSLog(
                "[MemoryGuard] selfCheck FAIL trimCalls=%d hardCalls=%d trimmed=%d",
                trimCalls, hardCalls, trimmed ? 1 : 0
            )
        } else {
            NSLog("[MemoryGuard] selfCheck OK")
        }
        return ok
    }
}
