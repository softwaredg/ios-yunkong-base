import Foundation
import NetworkExtension

/// Matches DirectPhoneBase: UIBackgroundModes=network-authentication + HotspotHelper.
enum HotspotKeepAlive {
    private static var registered = false

    static func register() {
        guard !registered else { return }
        let options = [kNEHotspotHelperOptionDisplayName: "云控基座"]
        let ok = NEHotspotHelper.register(options: options, queue: .main) { cmd in
            let response = cmd.createResponse(.success)
            if cmd.commandType == .filterScanList || cmd.commandType == .evaluate {
                response.networkList = []
            }
            response.deliver()
        }
        registered = ok
        NSLog("[HotspotKeepAlive] register=%@", ok ? "ok" : "fail")
    }
}
