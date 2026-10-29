import SwiftUI

@main
enum AppEntry {
    static func main() {
        if HelperLauncher.isHelperProcess() {
            HelperBootstrap.run()
            return
        }
        IOSYunKongBaseApp.main()
    }
}
