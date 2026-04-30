import SwiftUI
import CoreLocation

class LocationPermissionRequester: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    override init() {
        super.init()
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }
}

@main
struct MhostApp: App {
    let locationRequester = LocationPermissionRequester() // Trigger permission request
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
