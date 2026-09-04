#if SCREENSHOTS
import Foundation

/// Which screen the app opens straight onto in screenshot mode.
///
/// One launch per screenshot, no taps: the capture script never has to find a
/// tab by its label, which would otherwise differ between `en` and `fr`.
enum ScreenshotScreen: String {
    case status, map, export, settings, audit
}

/// Which story the demo dataset tells on the Status screen.
///
/// The two Status cards make opposite arguments — one that the app records
/// while you move, one that it lets GPS go while you do not — and they cannot
/// share a dataset: the second needs no active profile, an older fix and a
/// closed session.
enum ScreenshotScenario: String {
    /// Driving, high-confidence activity, a fix seconds old.
    case moving
    /// Parked: coarse profile, no session open, a fix minutes old.
    case stationary
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

    static let scenario = ScreenshotScenario(
        rawValue: UserDefaults.standard.string(forKey: "screenshotScenario") ?? "") ?? .moving

    /// Launch time, read once so the whole dataset agrees on "now".
    ///
    /// Only the screens that render a *relative* time are anchored on it —
    /// Status ("11 s ago"), the transitions list and the audit trail — because
    /// a fixed hour would print "in 10 hr" there. The map and the export
    /// deliberately do **not** use it: their days are fixed daytime windows on
    /// past days, so a capture at 01:45 shows the same complete day as one at
    /// noon.
    static let clock = Date()

    /// The language the app was launched in, as a ``DemoTracks`` key: it picks
    /// the city whose streets the demo track follows.
    ///
    /// `simctl launch … -AppleLanguages "(ja)"` writes the argument domain, so
    /// that default is the authoritative answer during a capture; `Locale`
    /// answers for a launch by hand. Both may carry a region (`fr-FR`), which
    /// the fixtures — keyed on `knownRegions` — do not.
    static let languageCode: String = {
        let launched = (UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []).first
        guard let identifier = launched ?? Locale.current.language.languageCode?.identifier else {
            return "en"
        }
        return String(identifier.prefix { $0 != "-" && $0 != "_" })
    }()
}
#endif
