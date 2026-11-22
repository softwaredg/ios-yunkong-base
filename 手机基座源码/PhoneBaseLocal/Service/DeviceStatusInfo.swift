import Foundation
import UIKit
import Darwin

/// 本地基座页「设备信息」快照。
enum DeviceStatusInfo {
    struct Row {
        let title: String
        let value: String
    }

    static func rows(runtimeRunning: Bool) -> [Row] {
        let screen = DeviceIdentity.screenSize()
        let scale = UIScreen.main.scale
        return [
            Row(title: "运行状态", value: runtimeRunning ? "运行正常" : "服务已停止"),
            Row(title: "系统版本", value: "iOS \(UIDevice.current.systemVersion)"),
            Row(title: "设备型号", value: marketingModel()),
            Row(title: "序列号", value: serialNumber() ?? "不可用"),
            Row(title: "屏幕分辨率", value: "\(screen.width) × \(screen.height) (\(fmtScale(scale)))"),
            Row(title: "存储状态", value: storageUsage()),
            Row(title: "内存状态", value: memoryUsage()),
            Row(title: "应用版本", value: TipaSelfUpdate.localVersion),
            Row(title: "应用包名", value: Bundle.main.bundleIdentifier ?? "?"),
        ]
    }

    private static func fmtScale(_ s: CGFloat) -> String {
        if s == floor(s) { return "\(Int(s))x" }
        return String(format: "%.1fx", Double(s))
    }

    private static func machineIdentifier() -> String {
        var uts = utsname()
        uname(&uts)
        return withUnsafePointer(to: &uts.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func marketingModel() -> String {
        let machine = machineIdentifier()
        let map: [String: String] = [
            "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
            "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
            "iPhone11,8": "iPhone XR",
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE (3rd)",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        ]
        if let name = map[machine] { return "\(name) (\(machine))" }
        return "\(UIDevice.current.model) (\(machine))"
    }

    private static func serialNumber() -> String? {
        // 巨魔环境优先 MobileGestalt；失败再试 IOKit
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        typealias MGFn = @convention(c) (CFString) -> Unmanaged<CFTypeRef>?
        if let sym = dlsym(RTLD_DEFAULT, "MGCopyAnswer") {
            let mg = unsafeBitCast(sym, to: MGFn.self)
            if let cf = mg("SerialNumber" as CFString)?.takeRetainedValue() {
                let s = String(describing: cf).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty, s != "nil" { return s }
            }
        }

        typealias MatchingFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
        typealias GetServiceFn = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> UInt32
        typealias CreatePropFn = @convention(c) (UInt32, CFString, CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>?
        typealias ReleaseFn = @convention(c) (UInt32) -> UInt32
        guard
            let matching = dlsym(RTLD_DEFAULT, "IOServiceMatching").map({ unsafeBitCast($0, to: MatchingFn.self) }),
            let getService = dlsym(RTLD_DEFAULT, "IOServiceGetMatchingService").map({ unsafeBitCast($0, to: GetServiceFn.self) }),
            let createProp = dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperty").map({ unsafeBitCast($0, to: CreatePropFn.self) }),
            let release = dlsym(RTLD_DEFAULT, "IOObjectRelease").map({ unsafeBitCast($0, to: ReleaseFn.self) }),
            let dict = matching("IOPlatformExpertDevice")
        else { return nil }
        let service = getService(0, dict)
        guard service != 0 else { return nil }
        defer { _ = release(service) }
        guard let cf = createProp(service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        let s = String(describing: cf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func storageUsage() -> String {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            let total = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
            let used = total > free ? total - free : 0
            return "\(fmtBytes(used)) / \(fmtBytes(total))"
        } catch {
            return "不可用"
        }
    }

    private static func memoryUsage() -> String {
        let total = ProcessInfo.processInfo.physicalMemory
        let available = UInt64(os_proc_available_memory())
        let used: UInt64
        if available > 0, available < total {
            used = total - available
        } else {
            used = MemoryGuard.physFootprint()
        }
        return "\(fmtBytes(used)) / \(fmtBytes(total))"
    }

    private static func fmtBytes(_ n: UInt64) -> String {
        let gb = Double(n) / 1_073_741_824.0
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(n) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }
}
