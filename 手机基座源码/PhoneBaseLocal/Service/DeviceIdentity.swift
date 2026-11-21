import Foundation
import UIKit
import Darwin

enum DeviceIdentity {
    private static let key = "phonebase.local.deviceId"

    /// 与桌面校验兼容：字母数字开头，长度 ≤64
    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: key), isValid(existing) {
            return existing
        }
        let generated = "local" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)
        let value = String(generated)
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    static var displayName: String {
        UIDevice.current.name
    }

    static func isValid(_ id: String) -> Bool {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    static func screenSize() -> (width: Int, height: Int) {
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        return (Int(bounds.width * scale), Int(bounds.height * scale))
    }
}

enum LanAddress {
    static func ipv4List() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) != IFF_LOOPBACK else { continue }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let ip = String(cString: hostname)
                if !ip.hasPrefix("169.254.") {
                    addresses.append(ip)
                }
            }
        }
        return addresses
    }
}
