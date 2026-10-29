import Foundation
import UIKit

/// Headless entry for `--helper`: owns HTTP/TVH4/capture (survives UI background).
enum HelperBootstrap {
    @MainActor
    private static var runtime: AppRuntime?

    static func run() {
        _ = UIApplication.shared
        HotspotKeepAlive.register()
        BackgroundKeepAlive.shared().start()
        Task { @MainActor in
            let rt = AppRuntime()
            runtime = rt
            rt.autoStart()
        }
        RunLoop.main.run()
    }
}
