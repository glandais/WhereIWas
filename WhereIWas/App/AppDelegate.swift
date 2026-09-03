import UIKit

/// UIKit delegate used only for launch handling.
///
/// `application(_:didFinishLaunchingWithOptions:)` runs before the first
/// SwiftUI view is created. It synchronously builds `AppEnvironment.shared`
/// (which constructs `TrackingCoordinator`) and calls `bootstrap`, so that
/// when iOS relaunches the app for a significant-change / visit event
/// (`UIApplication.LaunchOptionsKey.location`) — after termination or a
/// reboot — the `CLLocationManager` is re-created and monitoring re-armed
/// in this very run-loop turn, from the persisted "tracking enabled" flag.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let launchedForLocation = launchOptions?[.location] != nil
        AppEnvironment.shared.bootstrap(launchedForLocation: launchedForLocation)
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        AppEnvironment.shared.didEnterBackground()
    }
}
