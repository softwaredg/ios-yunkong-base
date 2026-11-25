import Foundation
import Darwin

/// 对齐官方 `--memory-guard`：软阈值先降画质，硬阈值再触发重启回调。
final class MemoryGuard {
    static let shared = MemoryGuard()

    /// 软阈值：先回调 onSoftLimit（降码率），默认 320MB
    var softLimitBytes: UInt64 = 320 * 1024 * 1024
    /// 硬阈值：回调 onOverLimit（soft/hard restart），默认 400MB
    var limitBytes: UInt64 = 400 * 1024 * 1024
    private(set) var automatic = true
    private(set) var overLimitSince: TimeInterval?
    private(set) var softLimitSince: TimeInterval?
    private(set) var restartCount = 0
    /// 最近若干次重启间隔（ms），对齐 historyMillis
    private(set) var historyMillis: [Int] = []
    private var lastRestartAt: Date?
    private var lastSoftAt: Date?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "cn.local.phonebase.memory-guard")
    /// 连续超限多久才动作，避免毛刺
    private let overLimitGraceSec: TimeInterval = 3
    private let softGraceSec: TimeInterval = 2
    var onOverLimit: ((UInt64) -> Void)?
    /// 软阈值：优先降画质，勿与硬重启同一节流
    var onSoftLimit: ((UInt64) -> Void)?

    var status: [String: Any] {
        [
            "automatic": automatic,
            "softLimitBytes": softLimitBytes,
            "limitBytes": limitBytes,
            "currentBytes": Self.physFootprint(),
            "overLimitSince": overLimitSince as Any,
            "softLimitSince": softLimitSince as Any,
            "historyMillis": historyMillis,
            "historyCount": historyMillis.count,
            "restartCount": restartCount,
        ]
    }

    func setEnabled(_ on: Bool) {
        automatic = on
        if !on {
            overLimitSince = nil
            softLimitSince = nil
        }
        persist()
    }

    func start() {
        automatic = UserDefaults.standard.object(forKey: "local.memoryGuard.automatic") as? Bool ?? true
        restartCount = UserDefaults.standard.integer(forKey: "local.memoryGuard.restartCount")
        if timer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        overLimitSince = nil
        softLimitSince = nil
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
        softLimitSince = nil
        persist()
        NSLog("[MemoryGuard] restart reason=%@ count=%d", reason, restartCount)
    }

    private func persist() {
        UserDefaults.standard.set(automatic, forKey: "local.memoryGuard.automatic")
        UserDefaults.standard.set(restartCount, forKey: "local.memoryGuard.restartCount")
    }

    private func tick() {
        guard automatic else { return }
        let cur = Self.physFootprint()
        let now = Date().timeIntervalSince1970

        if cur < softLimitBytes {
            softLimitSince = nil
            overLimitSince = nil
            return
        }

        // Soft: degrade encode before hard restart.
        if cur >= softLimitBytes && cur < limitBytes {
            overLimitSince = nil
            if softLimitSince == nil { softLimitSince = now }
            guard let since = softLimitSince, now - since >= softGraceSec else { return }
            if let last = lastSoftAt, Date().timeIntervalSince(last) < 20 { return }
            softLimitSince = nil
            lastSoftAt = Date()
            DispatchQueue.main.async { [weak self] in
                self?.onSoftLimit?(cur)
            }
            return
        }

        // Hard: over limitBytes
        softLimitSince = nil
        if overLimitSince == nil { overLimitSince = now }
        guard let since = overLimitSince, now - since >= overLimitGraceSec else { return }
        // 节流：15s 内不连着重启
        if let last = lastRestartAt, Date().timeIntervalSince(last) < 15 { return }
        overLimitSince = nil
        DispatchQueue.main.async { [weak self] in
            self?.onOverLimit?(cur)
        }
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
}
