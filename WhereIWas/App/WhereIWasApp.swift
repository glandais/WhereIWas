import SwiftUI

/// Application entry point.
///
/// The `AppDelegate` adaptor is initialised **before** the first view is
/// created, which is where tracking is re-armed after a relaunch (see
/// `AppDelegate` and `AppEnvironment.bootstrap`).
@main
struct WhereIWasApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    #if SCREENSHOTS
    /// Built once, so navigating between tabs does not reshuffle the dataset.
    @State private var screenshotController = DemoTrackingController()
    #endif

    var body: some Scene {
        WindowGroup {
            #if SCREENSHOTS
            if ScreenshotMode.isActive {
                RootView(initialTab: .init(ScreenshotMode.screen))
                    .environment(\.trackingController, screenshotController)
            } else {
                RootView()
                    .environment(\.trackingController, AppEnvironment.shared.trackingController)
            }
            #else
            RootView()
                .environment(\.trackingController, AppEnvironment.shared.trackingController)
            #endif
        }
    }
}
