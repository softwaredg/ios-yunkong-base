import SwiftUI

struct IOSYunKongBaseApp: App {
    @StateObject private var runtime = AppRuntime()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(runtime)
                .onAppear { runtime.autoStart() }
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .active:
                        runtime.ensureRunning(reason: "foreground")
                    case .inactive, .background:
                        runtime.enterBackground()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
