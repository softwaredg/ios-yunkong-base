import SwiftUI

@main
struct IOSYunKongBaseApp: App {
    @StateObject private var runtime = AppRuntime()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(runtime)
                .onAppear { runtime.autoStart() }
        }
    }
}
