import Foundation
import SwiftUI

/// Formatting helpers shared by the UI. Everything is locale-aware and
/// derived from `Foundation` format styles so Dynamic Type / localisation
/// come for free.
enum Formatting {
    /// "12 m", "1.2 km".
    static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    /// Horizontal/vertical accuracy: "±8 m".
    static func accuracy(_ meters: Double) -> String {
        guard meters > 0 else { return "—" }
        return "±" + Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// Speed from m/s: "4.3 km/h" (or mph depending on locale).
    static func speed(_ metersPerSecond: Double?) -> String {
        guard let mps = metersPerSecond, mps >= 0 else { return "—" }
        return Measurement(value: mps, unit: UnitSpeed.metersPerSecond)
            .formatted(.measurement(width: .abbreviated, usage: .general, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    /// Altitude: "123 m".
    static func altitude(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
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
        case .disabled: return String(localized: "Off")
        case .stationary: return String(localized: "Stationary")
        case .probing: return String(localized: "Probing")
        case .moving: return String(localized: "Moving")
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
        case .disabled: return String(localized: "Tracking is switched off. Nothing is recorded.")
        case .stationary: return String(localized: "GPS is off or coarse. Waiting for motion, a significant location change or a visit.")
        case .probing: return String(localized: "GPS is on briefly to confirm whether you are moving.")
        case .moving: return String(localized: "GPS is on, tuned to your current speed and activity.")
        }
    }
}

extension ActivityKind {
    var title: String {
        switch self {
        case .unknown: return String(localized: "Unknown")
        case .stationary: return String(localized: "Stationary")
        case .walking: return String(localized: "Walking")
        case .running: return String(localized: "Running")
        case .cycling: return String(localized: "Cycling")
        case .automotive: return String(localized: "Driving")
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
        case .low: return String(localized: "low", comment: "Activity confidence, shown inline: \"Walking (low)\"")
        case .medium: return String(localized: "medium", comment: "Activity confidence, shown inline: \"Walking (medium)\"")
        case .high: return String(localized: "high", comment: "Activity confidence, shown inline: \"Walking (high)\"")
        }
    }
}

extension AccuracyLevel {
    var title: String {
        switch self {
        case .bestForNavigation: return String(localized: "Best for navigation")
        case .best: return String(localized: "Best")
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
        case .other: return String(localized: "Other")
        case .fitness: return String(localized: "Fitness")
        case .automotiveNavigation: return String(localized: "Automotive")
        case .otherNavigation: return String(localized: "Navigation")
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
        case .significantChange: return String(localized: "Significant change")
        case .visit: return String(localized: "Visit")
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
        case "probing": return String(localized: "Probing")
        case "stationary-coarse": return String(localized: "Stationary (coarse)")
        case "walking": return String(localized: "Walking")
        case "running": return String(localized: "Running")
        case "cycling": return String(localized: "Cycling")
        case "automotive": return String(localized: "Driving")
        case "fast-unknown": return String(localized: "Unknown, fast")
        case "slow-unknown": return String(localized: "Unknown, slow")
        case "unknown": return String(localized: "Unknown")
        default: return label
        }
    }
}

extension AuditCategory {
    var displayName: String {
        switch self {
        case .lifecycle: return String(localized: "Lifecycle")
        case .state: return String(localized: "State")
        case .effect: return String(localized: "Effect")
        case .location: return String(localized: "Location")
        case .filter: return String(localized: "Filter")
        case .motion: return String(localized: "Motion")
        case .permission: return String(localized: "Permission")
        case .persistence: return String(localized: "Storage")
        case .maintenance: return String(localized: "Maintenance")
        case .export: return String(localized: "Export")
        }
    }
}

extension AuditSeverity {
    var displayName: String {
        switch self {
        case .debug: return String(localized: "Debug")
        case .info: return String(localized: "Info")
        case .warning: return String(localized: "Warning")
        case .error: return String(localized: "Error")
        }
    }
}

extension AuditExportFormat {
    var displayName: String {
        self == .json ? "JSON" : String(localized: "Plain text")
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
