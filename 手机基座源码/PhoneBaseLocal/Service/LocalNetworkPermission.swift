import Foundation

/// 触发一次本地网络权限弹窗（iOS 14+），便于 Bonjour / 局域网互通。
final class LocalNetworkPermission: NSObject, NetServiceBrowserDelegate {
    static let shared = LocalNetworkPermission()

    private let browser = NetServiceBrowser()
    private var armed = false

    func requestIfNeeded() {
        guard !armed else { return }
        armed = true
        browser.delegate = self
        browser.searchForServices(ofType: "_phonebase._tcp.", inDomain: "local.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.browser.stop()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        NSLog("[LAN] browser didNotSearch: %@", "\(errorDict)")
    }
}
