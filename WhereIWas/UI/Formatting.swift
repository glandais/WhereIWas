import Foundation
import SwiftUI

/// Formatting helpers shared by the UI. Everything is locale-aware and
/// derived from `Foundation` format styles so Dynamic Type / localisation
/// come for free.
enum Formatting {
    // MARK: Unit system

    /// Unit system the measurement helpers below render in, mirroring
    /// `TrackingSettings.unitSystem`.
    ///
    /// `nonisolated(unsafe)` because the formatting helpers are plain static
    /// functions called from every view body; isolating this to the main
    /// actor would make them `@MainActor` and unusable from the previews and
    /// tests that call them directly. It is only ever *written* from the main
    /// actor — `RootView` applies the setting at launch and on change, and
    /// the Settings picker writes it in its binding setter — and reads
    /// happen while building the UI on that same actor.
    nonisolated(unsafe) static var unitSystem: UnitSystem = .deviceDefault {
        didSet {
            guard unitSystem != oldValue else { return }
            measurementLocale = Self.locale(for: unitSystem)
        }
    }

    /// `Locale.current` with its measurement system forced to ``unitSystem``.
    ///
    /// Cached: it only changes when the setting does, while a single list row
    /// formats several measurements and `Locale.Components` resolution is not
    /// free.
    nonisolated(unsafe) private static var measurementLocale = Formatting.locale(for: .deviceDefault)

    private static func locale(for system: UnitSystem) -> Locale {
        var components = Locale.Components(locale: .current)
        components.measurementSystem = system == .imperial ? .us : .metric
        return Locale(components: components)
    }

    // MARK: Measurements

    /// "12 m", "1.2 km" — or "39 ft", "0.8 mi" in imperial.
    static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1)))
                .locale(measurementLocale))
    }

    /// Horizontal/vertical accuracy: "±8 m", "±26 ft".
    ///
    /// Converted explicitly rather than through `usage: .general`, which would
    /// promote a large value to kilometers or miles: an accuracy is read
    /// against the other accuracies on screen, so the unit has to stay the
    /// same one at every magnitude.
    static func accuracy(_ meters: Double) -> String {
        guard meters > 0 else { return "—" }
        return "±" + length(meters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))
                .locale(measurementLocale))
    }

    /// Speed from m/s: "4.3 km/h", or "2.7 mph" in imperial.
    static func speed(_ metersPerSecond: Double?) -> String {
        guard let mps = metersPerSecond, mps >= 0 else { return "—" }
        return Measurement(value: mps, unit: UnitSpeed.metersPerSecond)
            .formatted(.measurement(width: .abbreviated, usage: .general, numberFormatStyle: .number.precision(.fractionLength(0...1)))
                .locale(measurementLocale))
    }

    /// Altitude: "1234 m", or "4049 ft" in imperial.
    ///
    /// Same explicit conversion as ``accuracy(_:)``: `usage: .general` turns
    /// 1234 m into "1.2 km", which is not how an altitude is read.
    static func altitude(_ meters: Double) -> String {
        length(meters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))
                .locale(measurementLocale))
    }

    /// A length in the base unit of the current system: meters, or feet.
    private static func length(_ meters: Double) -> Measurement<UnitLength> {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        return unitSystem == .imperial ? measurement.converted(to: .feet) : measurement
    }

    /// Course in degrees: "270° W".
    static func course(_ degrees: Double) -> String {
        guard degrees >= 0 else { return "—" }
        let dirs = [
            String(localized: "compass.N", defaultValue: "N", comment: "Compass point: north"),
            String(localized: "compass.NE", defaultValue: "NE", comment: "Compass point: north-east"),
            String(localized: "compass.E", defaultValue: "E", comment: "Compass point: east"),
            String(localized: "compass.SE", defaultValue: "SE", comment: "Compass point: south-east"),
            String(localized: "compass.S", defaultValue: "S", comment: "Compass point: south"),
            String(localized: "compass.SW", defaultValue: "SW", comment: "Compass point: south-west"),
            String(localized: "compass.W", defaultValue: "W", comment: "Compass point: west"),
            String(localized: "compass.NW", defaultValue: "NW", comment: "Compass point: north-west")
        ]
        let index = Int((degrees + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return "\(Int(degrees.rounded()))° \(dirs[index])"
    }

    /// "3 min ago", "yesterday".
    static func relative(_ date: Date, to now: Date = .now) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// "14:32:07".
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    /// "Sep 2, 2026, 14:32".
    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "Tue, Sep 2".
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// Duration in seconds: "2 min", "1 h 30 min".
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }

    /// Battery level 0...1 → "82 %".
    static func battery(_ level: Double?) -> String {
        guard let level, level >= 0 else { return "—" }
        return level.formatted(.percent.precision(.fractionLength(0)))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// Latitude/longitude with 5 decimals (~1 m).
    ///
    /// Coordinates are data, not prose: they keep a dot as the decimal
    /// separator in every locale. A locale-aware style would render
    /// "48,85837, 2,29448" in French, where the decimal separator and the
    /// field separator are the same character.
    static func coordinate(_ latitude: Double, _ longitude: Double) -> String {
        let f = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(5))
            .locale(Locale(identifier: "en_US_POSIX"))
        return "\(latitude.formatted(f)), \(longitude.formatted(f))"
    }

    /// Translates the machine-built transition reason for display.
    ///
    /// `StateTransitionRecord.reason` is composed by the coordinator as
    /// `"<input> [<detail>]"` and is *persisted*, so it stays English on disk
    /// and in the exports. The Status screen is ordinary UI, not the opt-in
    /// audit trail, so it shows a translated copy. Anything outside the known
    /// vocabulary falls through unchanged.
    static func transitionReason(_ raw: String) -> String {
        guard raw.hasSuffix("]"), let bracket = raw.range(of: " [") else {
            return reasonAtom(raw)
        }
        let head = String(raw[raw.startIndex..<bracket.lowerBound])
        let detail = String(raw[bracket.upperBound..<raw.index(before: raw.endIndex)])
        return "\(reasonAtom(head)) [\(reasonAtom(detail))]"
    }

    /// One `TrackingCoordinator.describe(_:)` token, or one of the explicit
    /// reasons the coordinator passes alongside it. Internal so
    /// `TransitionReasonTests` can check it still covers the vocabulary the
    /// coordinator actually produces.
    static func reasonAtom(_ token: String) -> String {
        switch token {
        case "enable": return String(localized: "reason.enable", defaultValue: "Tracking on")
        case "disable": return String(localized: "reason.disable", defaultValue: "Tracking off")
        case "stillness timer": return String(localized: "reason.stillnessTimer", defaultValue: "Stillness timer")
        case "probe timer": return String(localized: "reason.probeTimer", defaultValue: "Probe timer")
        case "significant change": return String(localized: "reason.significantChange", defaultValue: "Significant change")
        case "visit": return String(localized: "reason.visit", defaultValue: "Visit")
        case "visit arrival": return String(localized: "reason.visitArrival", defaultValue: "Visit arrival")
        case "visit departure": return String(localized: "reason.visitDeparture", defaultValue: "Visit departure")
        case "motion hint": return String(localized: "reason.motionHint", defaultValue: "Motion hint")
        case "fix (no speed)": return String(localized: "reason.fixNoSpeed", defaultValue: "Fix (no speed)")
        case "user": return String(localized: "reason.user", defaultValue: "User")
        case "launch": return String(localized: "reason.launch", defaultValue: "App launch")
        case "relaunch (location event)":
            return String(localized: "reason.relaunch", defaultValue: "Relaunch (location event)")
        default: break
        }
        if let rest = token.dropPrefixIfPresent("activity "),
           let slash = rest.firstIndex(of: "/"),
           let kind = ActivityKind(rawValue: String(rest[rest.startIndex..<slash])),
           let confidence = confidence(named: String(rest[rest.index(after: slash)...])) {
            return String(localized: "reason.activity",
                          defaultValue: "Activity \(kind.title) (\(confidence.title))")
        }
        if let rest = token.dropPrefixIfPresent("fix "), rest.hasSuffix(" m/s"),
           let mps = Double(rest.dropLast(4)) {
            return String(localized: "reason.fix", defaultValue: "Fix \(speed(mps))")
        }
        if let rest = token.dropPrefixIfPresent("steps("), rest.hasSuffix(")"),
           let steps = Int(rest.dropLast()) {
            return String(localized: "reason.steps", defaultValue: "\(steps) steps")
        }
        if let rest = token.dropPrefixIfPresent("accelerometer("), rest.hasSuffix("g)") {
            return String(localized: "reason.accelerometer",
                          defaultValue: "Accelerometer (\(String(rest.dropLast(2))) g)")
        }
        return token
    }

    private static func confidence(named name: String) -> ActivityConfidence? {
        switch name {
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        default: return nil
        }
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}

// MARK: - Presentation helpers on domain enums

extension TrackingPhase {
    var title: String {
        switch self {
        case .disabled: return String(localized: "phase.off", defaultValue: "Off")
        case .stationary: return String(localized: "common.stationary", defaultValue: "Stationary")
        case .probing: return String(localized: "common.probing", defaultValue: "Probing")
        case .moving: return String(localized: "phase.moving", defaultValue: "Moving")
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: return "pause.circle"
        case .stationary: return "zzz"
        case .probing: return "dot.radiowaves.left.and.right"
        case .moving: return "location.fill"
        }
    }

    var color: Color {
        switch self {
        case .disabled: return .secondary
        case .stationary: return .orange
        case .probing: return .blue
        case .moving: return .green
        }
    }

    var explanation: String {
        switch self {
        case .disabled: return String(localized: "phase.off.explanation", defaultValue: "Tracking is switched off. Nothing is recorded.")
        case .stationary: return String(localized: "phase.stationary.explanation", defaultValue: "GPS is off or coarse. Waiting for motion, a significant location change or a visit.")
        case .probing: return String(localized: "phase.probing.explanation", defaultValue: "GPS is on briefly to confirm whether you are moving.")
        case .moving: return String(localized: "phase.moving.explanation", defaultValue: "GPS is on, tuned to your current speed and activity.")
        }
    }
}

extension ActivityKind {
    var title: String {
        switch self {
        case .unknown: return String(localized: "activity.unknown", defaultValue: "Unknown")
        case .stationary: return String(localized: "common.stationary", defaultValue: "Stationary")
        case .walking: return String(localized: "activity.walking", defaultValue: "Walking")
        case .running: return String(localized: "activity.running", defaultValue: "Running")
        case .cycling: return String(localized: "activity.cycling", defaultValue: "Cycling")
        case .automotive: return String(localized: "activity.driving", defaultValue: "Driving")
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .stationary: return "figure.stand"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "figure.outdoor.cycle"
        case .automotive: return "car.fill"
        }
    }
}

extension ActivityConfidence {
    var title: String {
        switch self {
        case .low: return String(localized: "confidence.low", defaultValue: "low", comment: "Activity confidence, shown inline: \"Walking (low)\"")
        case .medium: return String(localized: "confidence.medium", defaultValue: "medium", comment: "Activity confidence, shown inline: \"Walking (medium)\"")
        case .high: return String(localized: "confidence.high", defaultValue: "high", comment: "Activity confidence, shown inline: \"Walking (high)\"")
        }
    }
}

extension AccuracyLevel {
    var title: String {
        switch self {
        case .bestForNavigation: return String(localized: "accuracy.bestForNavigation", defaultValue: "Best for navigation")
        case .best: return String(localized: "accuracy.best", defaultValue: "Best")
        case .tenMeters: return Formatting.distance(10)
        case .hundredMeters: return Formatting.distance(100)
        case .kilometer: return Formatting.distance(1_000)
        case .threeKilometers: return Formatting.distance(3_000)
        }
    }
}

extension ActivityTypeHint {
    var title: String {
        switch self {
        case .other: return String(localized: "activityType.other", defaultValue: "Other")
        case .fitness: return String(localized: "activityType.fitness", defaultValue: "Fitness")
        case .automotiveNavigation: return String(localized: "activityType.automotive", defaultValue: "Automotive")
        case .otherNavigation: return String(localized: "activityType.navigation", defaultValue: "Navigation")
        }
    }
}

// The location and motion authorization states read the same in English but
// not in every language: French agrees the adjective with the subject
// ("localisation" is feminine, "mouvement" masculine), so the two enums get
// their own keys instead of sharing one.

extension LocationAuthorization {
    var title: String {
        switch self {
        case .notDetermined:
            return String(localized: "auth.location.notRequested", defaultValue: "Not requested",
                          comment: "Value of the “Location” permission row")
        case .restricted:
            return String(localized: "auth.location.restricted", defaultValue: "Restricted",
                          comment: "Value of the “Location” permission row")
        case .denied:
            return String(localized: "auth.location.denied", defaultValue: "Denied",
                          comment: "Value of the “Location” permission row")
        case .whenInUse:
            return String(localized: "auth.location.whenInUse", defaultValue: "While using",
                          comment: "Value of the “Location” permission row")
        case .always:
            return String(localized: "auth.location.always", defaultValue: "Always",
                          comment: "Value of the “Location” permission row")
        }
    }
}

extension MotionAuthorization {
    var title: String {
        switch self {
        case .notDetermined:
            return String(localized: "auth.motion.notRequested", defaultValue: "Not requested",
                          comment: "Value of the “Motion & Fitness” permission row")
        case .restricted:
            return String(localized: "auth.motion.restricted", defaultValue: "Restricted",
                          comment: "Value of the “Motion & Fitness” permission row")
        case .denied:
            return String(localized: "auth.motion.denied", defaultValue: "Denied",
                          comment: "Value of the “Motion & Fitness” permission row")
        case .authorized:
            return String(localized: "auth.motion.authorized", defaultValue: "Authorized",
                          comment: "Value of the “Motion & Fitness” permission row")
        }
    }
}

extension BatteryState {
    var systemImage: String {
        switch self {
        case .charging: return "battery.100percent.bolt"
        case .full: return "battery.100percent"
        case .unplugged, .unknown: return "battery.50percent"
        }
    }
}

extension LocationSource {
    var title: String {
        switch self {
        case .gps: return "GPS"
        case .significantChange: return String(localized: "source.significantChange", defaultValue: "Significant change")
        case .visit: return String(localized: "source.visit", defaultValue: "Visit")
        }
    }
}

extension ExportFormat {
    var title: String {
        switch self {
        case .gpx: return "GPX"
        case .json: return "JSON"
        }
    }

    var systemImage: String {
        switch self {
        case .gpx: return "map"
        case .json: return "curlybraces"
        }
    }
}

// `GPSProfile.label` and `AuditSeverity.label` are technical identifiers: they
// are persisted in samples, written to the audit exports and asserted on in
// tests, so they stay English. The UI shows these translated `displayName`s
// instead. `AuditCategory` has no `label` for that reason — the exporter
// writes its `rawValue`.

extension GPSProfile {
    var displayName: String {
        switch label {
        case "probing": return String(localized: "common.probing", defaultValue: "Probing")
        case "stationary-coarse": return String(localized: "profile.stationaryCoarse", defaultValue: "Stationary (coarse)")
        case "walking": return String(localized: "activity.walking", defaultValue: "Walking")
        case "running": return String(localized: "activity.running", defaultValue: "Running")
        case "cycling": return String(localized: "activity.cycling", defaultValue: "Cycling")
        case "automotive": return String(localized: "activity.driving", defaultValue: "Driving")
        // These three name a *profile*, not an activity, so they get their own
        // keys: French agrees the adjective with the subject and "profil" is
        // masculine where "activité" — the subject of `ActivityKind.title` —
        // is feminine.
        case "fast-unknown":
            return String(localized: "profile.unknownFast", defaultValue: "Unknown, fast",
                          comment: "GPS profile name; the subject is the profile, not the activity")
        case "slow-unknown":
            return String(localized: "profile.unknownSlow", defaultValue: "Unknown, slow",
                          comment: "GPS profile name; the subject is the profile, not the activity")
        case "unknown":
            return String(localized: "profile.unknown", defaultValue: "Unknown",
                          comment: "GPS profile name; the subject is the profile, not the activity")
        default: return label
        }
    }
}

extension AuditCategory {
    var displayName: String {
        switch self {
        case .lifecycle: return String(localized: "audit.category.lifecycle", defaultValue: "Lifecycle")
        case .state: return String(localized: "common.state", defaultValue: "State")
        case .effect: return String(localized: "audit.category.effect", defaultValue: "Effect")
        case .location: return String(localized: "audit.category.location", defaultValue: "Location")
        case .filter: return String(localized: "audit.category.filter", defaultValue: "Filter")
        case .motion: return String(localized: "audit.category.motion", defaultValue: "Motion")
        case .permission: return String(localized: "audit.category.permission", defaultValue: "Permission")
        case .persistence: return String(localized: "audit.category.storage", defaultValue: "Storage")
        case .maintenance: return String(localized: "audit.category.maintenance", defaultValue: "Maintenance")
        case .export: return String(localized: "common.export", defaultValue: "Export")
        }
    }
}

extension AuditSeverity {
    var displayName: String {
        switch self {
        case .debug: return String(localized: "audit.severity.debug", defaultValue: "Debug")
        case .info: return String(localized: "audit.severity.info", defaultValue: "Info")
        case .warning: return String(localized: "audit.severity.warning", defaultValue: "Warning")
        case .error: return String(localized: "audit.severity.error", defaultValue: "Error")
        }
    }
}

extension AuditExportFormat {
    var displayName: String {
        self == .json ? "JSON" : String(localized: "audit.format.plainText", defaultValue: "Plain text")
    }
}

/// Battery symbol name that reflects the level.
func batterySymbol(level: Double?, state: BatteryState) -> String {
    if state == .charging { return "battery.100percent.bolt" }
    guard let level else { return "battery.50percent" }
    switch level {
    case ..<0.10: return "battery.0percent"
    case ..<0.35: return "battery.25percent"
    case ..<0.60: return "battery.50percent"
    case ..<0.85: return "battery.75percent"
    default: return "battery.100percent"
    }
}
