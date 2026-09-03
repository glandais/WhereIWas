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
    static func coordinate(_ latitude: Double, _ longitude: Double) -> String {
        let f = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(5))
        return "\(latitude.formatted(f)), \(longitude.formatted(f))"
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
        case .tenMeters: return "10 m"
        case .hundredMeters: return "100 m"
        case .kilometer: return "1 km"
        case .threeKilometers: return "3 km"
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

extension LocationAuthorization {
    var title: String {
        switch self {
        case .notDetermined: return String(localized: "Not requested")
        case .restricted: return String(localized: "Restricted")
        case .denied: return String(localized: "Denied")
        case .whenInUse: return String(localized: "While using")
        case .always: return String(localized: "Always")
        }
    }
}

extension MotionAuthorization {
    var title: String {
        switch self {
        case .notDetermined: return String(localized: "Not requested")
        case .restricted: return String(localized: "Restricted")
        case .denied: return String(localized: "Denied")
        case .authorized: return String(localized: "Authorized")
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

// `GPSProfile.label`, `AuditCategory.label` and `AuditSeverity.label` are
// technical identifiers: they are persisted in samples, written to the audit
// exports and asserted on in tests, so they stay English. The UI shows these
// translated `displayName`s instead.

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
