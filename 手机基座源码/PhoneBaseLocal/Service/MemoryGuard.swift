import Foundation
import Darwin

/// 对齐官方 `--memory-guard`：超限自动触发重启回调。
final class MemoryGuard {
    static let shared = MemoryGuard()

    /// 默认 400MB；官方 Helper 也靠足迹触发，不追求精确阈值
    var limitBytes: UInt64 = 400 * 1024 * 1024
    private(set) var automatic = true
    private(set) var overLimitSince: TimeInterval?
    private(set) var restartCount = 0
    /// 最近若干次重启间隔（ms），对齐 historyMillis
    private(set) var historyMillis: [Int] = []
    private var lastRestartAt: Date?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "cn.local.phonebase.memory-guard")
    /// 连续超限多久才重启，避免毛刺
    private let overLimitGraceSec: TimeInterval = 3
    var onOverLimit: ((UInt64) -> Void)?

    var status: [String: Any] {
        [
            "automatic": automatic,
            "limitBytes": limitBytes,
            "currentBytes": Self.physFootprint(),
            "overLimitSince": overLimitSince as Any,
            "historyMillis": historyMillis,
            "historyCount": historyMillis.count,
            "restartCount": restartCount,
        ]
    }

    func setEnabled(_ on: Bool) {
        automatic = on
        if !on { overLimitSince = nil }
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
        if cur < limitBytes {
            overLimitSince = nil
            return
        }
        let now = Date().timeIntervalSince1970
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
