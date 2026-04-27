import SwiftUI

@main
struct MhostApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onDisappear {
                    PrivilegedSession.shared.shutdown()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
