import SwiftUI

/// Application entry point.
///
/// The `AppDelegate` adaptor is initialised **before** the first view is
/// created, which is where tracking is re-armed after a relaunch (see
/// `AppDelegate` and `AppEnvironment.bootstrap`).
@main
struct WhereIWasApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Listens to transactions from launch: a tip approved later (Ask to Buy)
    /// or interrupted must be finished, whether the tip screen is open or not.
    @State private var tipJar: TipJar

    init() {
        let tipJar = TipJar()
        tipJar.start()
        _tipJar = State(initialValue: tipJar)
    }

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
                    .environment(tipJar)
            } else {
                RootView()
                    .environment(\.trackingController, AppEnvironment.shared.trackingController)
                    .environment(tipJar)
            }
            #else
            RootView()
                .environment(\.trackingController, AppEnvironment.shared.trackingController)
                .environment(tipJar)
            #endif
        }
    }
}
