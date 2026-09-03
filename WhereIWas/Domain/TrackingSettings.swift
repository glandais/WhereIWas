import Foundation

/// User-tunable settings. Plain `Codable` value persisted as JSON in
/// `UserDefaults` under ``TrackingSettings/userDefaultsKey``.
///
/// Every field has a documented default so `TrackingSettings()` is always a
/// sensible configuration. Pure domain code receives the struct explicitly;
/// only the coordinator / settings screen load and save it.
public struct TrackingSettings: Codable, Sendable, Hashable {
    // MARK: State machine

    /// Seconds of continuous stillness (stationary activity or near-zero
    /// speed) required before leaving MOVING for STATIONARY. Default 120 s.
    public var stillnessTimeout: TimeInterval = 120

    /// Maximum time GPS stays on in PROBING without evidence of motion before
    /// falling back to STATIONARY. Default 45 s.
    public var probeTimeout: TimeInterval = 45

    /// GPS speed (m/s) at or above which a fix counts as "moving" while
    /// PROBING. Default 0.7 m/s (~2.5 km/h).
    public var movingSpeedThreshold: Double = 0.7

    /// GPS speed (m/s) below which a fix counts as "still" while MOVING and
    /// arms the stillness timer. Default 0.3 m/s.
    public var stillSpeedThreshold: Double = 0.3

    /// Minimum classifier confidence to act on a motion activity report.
    /// Default `.medium`. Reports below it are treated as "hints" (they can
    /// trigger PROBING but never jump straight to MOVING).
    public var minimumActivityConfidence: ActivityConfidence = .medium

    /// When `true`, the Location engine keeps `startUpdatingLocation` running
    /// with ``GPSProfile/stationaryCoarse`` while STATIONARY instead of
    /// stopping updates. Costs ~nothing and keeps the location background
    /// mode "active" so the process is less likely to be suspended.
    /// Default `true`.
    public var keepCoarseUpdatesWhileStationary: Bool = true

    /// When `true` (default), CoreLocation shows the system location
    /// indicator while the app may use location in the background. Turning it
    /// off only hides it in the coarse/STATIONARY case: the
    /// `CLBackgroundActivitySession` held while GPS is on always shows it.
    public var showsLocationIndicator: Bool = true

    // MARK: GPS profile distance filters (meters)

    public var walkingDistanceFilter: Double = 10
    public var runningCyclingDistanceFilter: Double = 20
    public var automotiveDistanceFilter: Double = 50
    public var unknownDistanceFilter: Double = 10

    // MARK: Sample filter

    /// Fixes with `horizontalAccuracy` above this (meters) are dropped. Default 50 m.
    public var maxHorizontalAccuracy: Double = 50

    /// Fixes older than this (seconds) relative to "now" are dropped. Default 30 s.
    public var maxSampleAge: TimeInterval = 30

    /// Two consecutive fixes closer than this (meters) are considered
    /// duplicates. Default 0 (exact same coordinates only).
    public var duplicateDistance: Double = 0

    // MARK: Retention

    /// Samples older than this many days are purged by the maintenance task.
    /// Default 30 days. `0` disables purging.
    public var retentionDays: Int = 30

    /// Number of samples the engine buffers before flushing to the store.
    /// Default 20 (flushed earlier on state change / background transition).
    public var insertBatchSize: Int = 20

    // MARK: Audit trail (opt-in, off by default)

    /// Master switch for the detailed audit trail: the data received, the
    /// tests run on it and the state changes it caused. Off by default: at
    /// debug verbosity it writes several rows per accepted fix.
    public var auditEnabled: Bool = false

    /// Events below this severity are discarded before they reach storage.
    /// Default `.debug` (keep everything) — the volume knobs below are the
    /// ones worth touching first.
    public var auditMinimumSeverity: AuditSeverity = .debug

    /// Record one event per accepted fix, with its coordinates and metadata.
    /// Default `true`; the single biggest contributor to trail size.
    public var auditLogsAcceptedFixes: Bool = true

    /// Record one event per rejected fix, with the reason. Default `true`.
    public var auditLogsRejectedFixes: Bool = true

    /// Attach the full list of validation checks (name, measured value,
    /// threshold, verdict) to fix events. Default `true`.
    public var auditLogsFilterChecks: Bool = true

    /// Record raw motion-activity reports. Default `true`.
    public var auditLogsMotionEvents: Bool = true

    /// Audit events older than this many days are purged by the maintenance
    /// task. Default 7 days (shorter than sample retention on purpose).
    /// `0` keeps them forever.
    public var auditRetentionDays: Int = 7

    public init() {}

    // MARK: Persistence

    public static let userDefaultsKey = "whereiwas.settings.v1"

    /// Loads settings from `defaults`, returning defaults when absent or
    /// undecodable (a corrupt blob must never brick tracking).
    public static func load(from defaults: UserDefaults = .standard) -> TrackingSettings {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(TrackingSettings.self, from: data) else {
            return TrackingSettings()
        }
        return decoded
    }

    /// Saves settings as JSON.
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.userDefaultsKey)
        }
    }

    // MARK: Decoding with defaults for missing keys

    private enum CodingKeys: String, CodingKey {
        case stillnessTimeout, probeTimeout, movingSpeedThreshold, stillSpeedThreshold
        case minimumActivityConfidence, keepCoarseUpdatesWhileStationary, showsLocationIndicator
        case walkingDistanceFilter, runningCyclingDistanceFilter, automotiveDistanceFilter, unknownDistanceFilter
        case maxHorizontalAccuracy, maxSampleAge, duplicateDistance
        case retentionDays, insertBatchSize
        case auditEnabled, auditMinimumSeverity, auditLogsAcceptedFixes, auditLogsRejectedFixes
        case auditLogsFilterChecks, auditLogsMotionEvents, auditRetentionDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TrackingSettings()
        stillnessTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .stillnessTimeout) ?? d.stillnessTimeout
        probeTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .probeTimeout) ?? d.probeTimeout
        movingSpeedThreshold = try c.decodeIfPresent(Double.self, forKey: .movingSpeedThreshold) ?? d.movingSpeedThreshold
        stillSpeedThreshold = try c.decodeIfPresent(Double.self, forKey: .stillSpeedThreshold) ?? d.stillSpeedThreshold
        minimumActivityConfidence = try c.decodeIfPresent(ActivityConfidence.self, forKey: .minimumActivityConfidence) ?? d.minimumActivityConfidence
        keepCoarseUpdatesWhileStationary = try c.decodeIfPresent(Bool.self, forKey: .keepCoarseUpdatesWhileStationary) ?? d.keepCoarseUpdatesWhileStationary
        showsLocationIndicator = try c.decodeIfPresent(Bool.self, forKey: .showsLocationIndicator) ?? d.showsLocationIndicator
        walkingDistanceFilter = try c.decodeIfPresent(Double.self, forKey: .walkingDistanceFilter) ?? d.walkingDistanceFilter
        runningCyclingDistanceFilter = try c.decodeIfPresent(Double.self, forKey: .runningCyclingDistanceFilter) ?? d.runningCyclingDistanceFilter
        automotiveDistanceFilter = try c.decodeIfPresent(Double.self, forKey: .automotiveDistanceFilter) ?? d.automotiveDistanceFilter
        unknownDistanceFilter = try c.decodeIfPresent(Double.self, forKey: .unknownDistanceFilter) ?? d.unknownDistanceFilter
        maxHorizontalAccuracy = try c.decodeIfPresent(Double.self, forKey: .maxHorizontalAccuracy) ?? d.maxHorizontalAccuracy
        maxSampleAge = try c.decodeIfPresent(TimeInterval.self, forKey: .maxSampleAge) ?? d.maxSampleAge
        duplicateDistance = try c.decodeIfPresent(Double.self, forKey: .duplicateDistance) ?? d.duplicateDistance
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        insertBatchSize = try c.decodeIfPresent(Int.self, forKey: .insertBatchSize) ?? d.insertBatchSize
        auditEnabled = try c.decodeIfPresent(Bool.self, forKey: .auditEnabled) ?? d.auditEnabled
        auditMinimumSeverity = try c.decodeIfPresent(AuditSeverity.self, forKey: .auditMinimumSeverity) ?? d.auditMinimumSeverity
        auditLogsAcceptedFixes = try c.decodeIfPresent(Bool.self, forKey: .auditLogsAcceptedFixes) ?? d.auditLogsAcceptedFixes
        auditLogsRejectedFixes = try c.decodeIfPresent(Bool.self, forKey: .auditLogsRejectedFixes) ?? d.auditLogsRejectedFixes
        auditLogsFilterChecks = try c.decodeIfPresent(Bool.self, forKey: .auditLogsFilterChecks) ?? d.auditLogsFilterChecks
        auditLogsMotionEvents = try c.decodeIfPresent(Bool.self, forKey: .auditLogsMotionEvents) ?? d.auditLogsMotionEvents
        auditRetentionDays = try c.decodeIfPresent(Int.self, forKey: .auditRetentionDays) ?? d.auditRetentionDays
    }
}
