import Foundation
import UIKit

/// 巨魔/特权：优先 FBSOrientationObserver（跟前台 App 界面朝向），否则 UIDevice。
enum InterfaceOrientationWatch {
    private static var fbsObserver: NSObject?

    static func bootstrap() {
        guard fbsObserver == nil else { return }
        guard let cls = NSClassFromString("FBSOrientationObserver") as? NSObject.Type else {
            NSLog("[Orient] FBSOrientationObserver missing → UIDevice fallback")
            return
        }
        fbsObserver = cls.init()
        NSLog("[Orient] FBSOrientationObserver ready")
    }

    /// UIInterfaceOrientation raw 1…8（桌面 3/4/7/8 当横屏）
    static func currentRaw(fallbackLast: Int) -> Int {
        if let o = fbsActiveOrientation(), (1 ... 8).contains(o) {
            return o
        }
        switch UIDevice.current.orientation {
        case .portrait: return 1
        case .portraitUpsideDown: return 2
        case .landscapeLeft: return 3
        case .landscapeRight: return 4
        default: break
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let o = scenes.first(where: { $0.activationState == .foregroundActive })?.interfaceOrientation
            ?? scenes.first?.interfaceOrientation
        {
            let v = Int(o.rawValue)
            if (1 ... 4).contains(v) { return v }
        }
        return fallbackLast
    }

    private static func fbsActiveOrientation() -> Int? {
        bootstrap()
        guard let obs = fbsObserver else { return nil }
        let sel = NSSelectorFromString("activeInterfaceOrientation")
        guard obs.responds(to: sel),
              let method = obs.method(for: sel)
        else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Int
        let fn = unsafeBitCast(method, to: Fn.self)
        return fn(obs, sel)
    }
}
