import Foundation
import NetworkExtension

/// Matches DirectPhoneBase: UIBackgroundModes=network-authentication + HotspotHelper.
enum HotspotKeepAlive {
    private static var registered = false

    static func register() {
        guard !registered else { return }
        let options: [String: NSObject] = [
            kNEHotspotHelperOptionDisplayName: "云控基座" as NSString,
        ]
        let ok = NEHotspotHelper.register(options: options, queue: .main) { cmd in
            let response = cmd.createResponse(.success)
            response.deliver()
        }
        registered = ok
        NSLog("[HotspotKeepAlive] register=%@", ok ? "ok" : "fail")
    }
}
