import SwiftUI

/// Application entry point.
///
/// The `AppDelegate` adaptor is initialised **before** the first view is
/// created, which is where tracking is re-armed after a relaunch (see
/// `AppDelegate` and `AppEnvironment.bootstrap`).
@main
struct WhereIWasApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.trackingController, AppEnvironment.shared.trackingController)
        }
    }
}
