#if SCREENSHOTS
import Foundation

/// Which screen the app opens straight onto in screenshot mode.
///
/// One launch per screenshot, no taps: the capture script never has to find a
/// tab by its label, which would otherwise differ between `en` and `fr`.
enum ScreenshotScreen: String {
    case status, map, export, settings, audit
}

/// Launch-argument flags that drive App Store screenshot capture.
///
/// Compiled only in the `Screenshots` configuration (see `project.yml`), so
/// none of this — nor ``DemoTrackingController`` — exists in the archived
/// Release binary.
///
/// `simctl launch … -screenshotMode YES -screenshotScreen map` lands in
/// `UserDefaults`' `NSArgumentDomain`, so there is nothing to parse.
enum ScreenshotMode {
    static let isActive = UserDefaults.standard.bool(forKey: "screenshotMode")

    static let screen = ScreenshotScreen(
        rawValue: UserDefaults.standard.string(forKey: "screenshotScreen") ?? "") ?? .status

    /// The instant the demo dataset is anchored on: launch time, read once.
    ///
    /// It has to be *now*, not a fixed hour: `MapView` filters on the selected
    /// day, `StatusView` counts today's samples, and every timestamp is
    /// rendered relatively ("3 s ago"), so a fixed hour would either empty the
    /// map or print "in 10 hr". Read once so the whole dataset agrees.
    static let clock = Date()
}
#endif
