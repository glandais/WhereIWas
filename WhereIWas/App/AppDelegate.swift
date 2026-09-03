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
        #if SCREENSHOTS
        // Screenshot mode runs on DemoTrackingController alone: skipping
        // bootstrap keeps CLLocationManager, the permission prompts, the
        // BGTask registration and the on-disk SwiftData store out of the way.
        if ScreenshotMode.isActive { return true }
        #endif
        let launchedForLocation = launchOptions?[.location] != nil
        AppEnvironment.shared.bootstrap(launchedForLocation: launchedForLocation)
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        #if SCREENSHOTS
        if ScreenshotMode.isActive { return }
        #endif
        AppEnvironment.shared.didEnterBackground()
    }
}
