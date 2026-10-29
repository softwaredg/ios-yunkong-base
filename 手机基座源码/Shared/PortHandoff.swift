import Foundation

/// Host ↔ Broadcast Extension coordination for port 11019.
enum PortHandoff {
    static let appGroupId = "group.cn.local.phonebase.lan"
    static let stopHostNotification = "cn.local.phonebase.lan.stopHostService" as CFString
    static let deviceIdKey = "deviceId"
    static let deviceNameKey = "deviceName"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }

    static func saveIdentity(deviceId: String, deviceName: String) {
        let d = sharedDefaults
        d?.set(deviceId, forKey: deviceIdKey)
        d?.set(deviceName, forKey: deviceNameKey)
        d?.synchronize()
    }

    static func loadDeviceId(fallback: String) -> String {
        sharedDefaults?.string(forKey: deviceIdKey) ?? fallback
    }

    static func loadDeviceName(fallback: String) -> String {
        sharedDefaults?.string(forKey: deviceNameKey) ?? fallback
    }

    static func requestHostReleasePort() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(stopHostNotification),
            nil,
            nil,
            true
        )
        // Give the host a moment to close the socket before extension binds.
        Thread.sleep(forTimeInterval: 0.35)
    }

    static func observeHostRelease(_ handler: @escaping () -> Void) -> OpaquePointer? {
        let block: @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName?, UnsafeRawPointer?, CFDictionary?) -> Void = { _, observer, _, _, _ in
            guard let observer else { return }
            let box = Unmanaged<HostReleaseBox>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { box.handler() }
        }
        let box = HostReleaseBox(handler: handler)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            ptr,
            block,
            stopHostNotification,
            nil,
            .deliverImmediately
        )
        return OpaquePointer(ptr)
    }

    static func unobserve(_ token: OpaquePointer?) {
        guard let token else { return }
        let ptr = UnsafeMutableRawPointer(token)
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            ptr,
            CFNotificationName(stopHostNotification),
            nil
        )
        Unmanaged<HostReleaseBox>.fromOpaque(ptr).release()
    }
}

private final class HostReleaseBox {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
}
