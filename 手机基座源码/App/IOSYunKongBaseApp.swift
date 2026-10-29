import SwiftUI

@main
struct IOSYunKongBaseApp: App {
    @StateObject private var runtime = AppRuntime()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(runtime)
                .onAppear { runtime.autoStart() }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        runtime.ensureRunning(reason: "foreground")
                    }
                }
        }
    }
}
