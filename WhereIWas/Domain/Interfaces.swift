import Foundation
import Observation

// MARK: - Sendable data transfer types shared across modules
//
// These are the ONLY types crossing module boundaries. SwiftData @Model
// classes (LocationSample, TrackingSession, StateTransitionLog) never leave
// the Persistence module; LocationStore converts to/from these values.

/// Context attached to every stored sample, captured by the coordinator at
/// the moment the fix is accepted.
public struct SampleAnnotation: Codable, Sendable, Hashable {
    public var activity: ActivityKind
    public var activityConfidence: ActivityConfidence
    public var phase: TrackingPhase
    /// 0…1, `nil` when unknown (simulator, monitoring disabled).
    public var batteryLevel: Double?
    public var batteryState: BatteryState
    /// The session the sample belongs to (`nil` if none is open).
    public var sessionID: UUID?
    /// Label of the ``GPSProfile`` in force, e.g. "walking", "probing".
    public var profileLabel: String?

    public init(activity: ActivityKind = .unknown,
                activityConfidence: ActivityConfidence = .low,
                phase: TrackingPhase = .disabled,
                batteryLevel: Double? = nil,
                batteryState: BatteryState = .unknown,
                sessionID: UUID? = nil,
                profileLabel: String? = nil) {
        self.activity = activity
        self.activityConfidence = activityConfidence
        self.phase = phase
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.sessionID = sessionID
        self.profileLabel = profileLabel
    }
}

/// A sample not yet persisted: an accepted fix plus its annotation.
public struct LocationSampleDraft: Codable, Sendable, Hashable {
    public var fix: LocationFix
    public var annotation: SampleAnnotation
    /// Where the fix came from.
    public var source: LocationSource

    public init(fix: LocationFix, annotation: SampleAnnotation, source: LocationSource = .gps) {
        self.fix = fix
        self.annotation = annotation
        self.source = source
    }
}

/// Origin of a location fix.
public enum LocationSource: String, Codable, Sendable, Hashable {
    /// `startUpdatingLocation` (continuous GPS).
    case gps
    /// `startMonitoringSignificantLocationChanges`.
    case significantChange
    /// `CLVisit` coordinate (arrival/departure).
    case visit
}

/// A persisted sample as returned by the store. `sequence` is the
/// monotonically increasing primary key used for upload batching.
public struct StoredLocationSample: Codable, Sendable, Hashable, Identifiable {
    /// Monotonically increasing id assigned by the store (never reused).
    public var sequence: Int64
    public var fix: LocationFix
    public var annotation: SampleAnnotation
    public var source: LocationSource
    public var uploaded: Bool
    /// Wall-clock time the sample was written.
    public var createdAt: Date

    public var id: Int64 { sequence }

    public init(sequence: Int64,
                fix: LocationFix,
                annotation: SampleAnnotation,
                source: LocationSource,
                uploaded: Bool,
                createdAt: Date) {
        self.sequence = sequence
        self.fix = fix
        self.annotation = annotation
        self.source = source
        self.uploaded = uploaded
        self.createdAt = createdAt
    }
}

/// Summary of a tracking session (one enable → disable interval).
public struct TrackingSessionSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var sampleCount: Int
    /// Approximate path length in meters (sum of consecutive distances).
    public var distanceMeters: Double

    public init(id: UUID, startedAt: Date, endedAt: Date?, sampleCount: Int, distanceMeters: Double) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sampleCount = sampleCount
        self.distanceMeters = distanceMeters
    }
}

/// A persisted state machine transition.
public struct StateTransitionRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var from: TrackingPhase
    public var to: TrackingPhase
    /// Textual description of the input that caused it.
    public var reason: String
    public var batteryLevel: Double?

    public init(id: UUID = UUID(),
                timestamp: Date,
                from: TrackingPhase,
                to: TrackingPhase,
                reason: String,
                batteryLevel: Double? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.from = from
        self.to = to
        self.reason = reason
        self.batteryLevel = batteryLevel
    }
}

/// Aggregate numbers for the status screen.
public struct StoreStats: Codable, Sendable, Hashable {
    public var totalSamples: Int
    public var pendingUpload: Int
    public var oldestSample: Date?
    public var newestSample: Date?
    public var sessionCount: Int

    public init(totalSamples: Int = 0,
                pendingUpload: Int = 0,
                oldestSample: Date? = nil,
                newestSample: Date? = nil,
                sessionCount: Int = 0) {
        self.totalSamples = totalSamples
        self.pendingUpload = pendingUpload
        self.oldestSample = oldestSample
        self.newestSample = newestSample
        self.sessionCount = sessionCount
    }
}

/// Export formats offered by the UI.
public enum ExportFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case gpx
    case json
    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
}

// MARK: - Persistence (owner: Persistence agent, implemented by `LocationStore` ModelActor)

/// Async, thread-safe access to the SQLite store. Implemented by
/// `LocationStore` (a SwiftData `@ModelActor`). All inputs/outputs are
/// `Sendable` values.
public protocol LocationStoring: Sendable {
    /// Insert samples in one transaction, assigning increasing `sequence`
    /// values. Returns the sequences assigned, in input order.
    func insert(_ drafts: [LocationSampleDraft]) async throws -> [Int64]

    /// Samples with `uploaded == false`, ordered by `sequence` ascending,
    /// at most `limit`.
    func pendingUpload(limit: Int) async throws -> [StoredLocationSample]

    /// Flag the given sequences as uploaded.
    func markUploaded(sequences: [Int64]) async throws

    /// Samples whose `fix.timestamp` is in `interval`, ordered by sequence.
    func samples(in interval: DateInterval) async throws -> [StoredLocationSample]

    /// Samples of a session, ordered by sequence.
    func samples(sessionID: UUID) async throws -> [StoredLocationSample]

    /// The most recent stored sample, if any.
    func latestSample() async throws -> StoredLocationSample?

    /// Delete samples (and transition records) older than `date`.
    /// Returns the number of samples deleted. Sessions are kept.
    func purge(olderThan date: Date) async throws -> Int

    func stats() async throws -> StoreStats

    // Sessions
    func beginSession(startedAt: Date) async throws -> UUID
    func endSession(id: UUID, endedAt: Date) async throws
    /// The most recent session without `endedAt`, if any (used at relaunch).
    func openSession() async throws -> TrackingSessionSummary?
    /// All sessions, most recent first.
    func sessions() async throws -> [TrackingSessionSummary]

    // Transition log
    func logTransition(_ record: StateTransitionRecord) async throws
    /// Most recent transitions, newest first.
    func recentTransitions(limit: Int) async throws -> [StateTransitionRecord]

    // MARK: Audit trail (opt-in)

    /// Append a batch of audit events. Called only while the user has opted
    /// in; implementations that do not keep an audit trail can ignore it.
    func appendAudit(_ events: [AuditEvent]) async throws
    /// Read the audit trail back, newest first.
    func auditEvents(matching query: AuditQuery) async throws -> [AuditEvent]
    /// Total number of stored audit events.
    func auditCount() async throws -> Int
    /// Delete audit events older than `date`; returns how many went.
    func purgeAudit(olderThan date: Date) async throws -> Int
    /// Delete the whole audit trail; returns how many went.
    func clearAudit() async throws -> Int
}

// MARK: - Location engine (owner: Location agent, implemented by `LocationEngine`)

/// Callbacks from the location engine to the coordinator. Everything is
/// delivered on the main actor.
@MainActor
public protocol LocationEngineDelegate: AnyObject {
    /// A fix accepted by ``LocationFilter`` from continuous updates.
    /// The engine has already persisted (or buffered) it.
    func locationEngine(_ engine: any LocationEngineProtocol, didAccept fix: LocationFix)
    /// A fix was rejected (for diagnostics / status screen).
    func locationEngine(_ engine: any LocationEngineProtocol, didReject fix: LocationFix, reason: LocationRejection)
    /// A significant-change location arrived (possibly the launch event).
    func locationEngine(_ engine: any LocationEngineProtocol, didReceiveSignificantChange fix: LocationFix)
    /// A visit arrival/departure arrived. `fix` carries the visit coordinate.
    func locationEngine(_ engine: any LocationEngineProtocol, didReceiveVisit fix: LocationFix, isArrival: Bool)
    func locationEngine(_ engine: any LocationEngineProtocol, didChangeAuthorization status: LocationAuthorization)
    /// CoreLocation reported an error (logged; may trigger a re-probe).
    func locationEngine(_ engine: any LocationEngineProtocol, didFail error: any Error)
}

/// Owns `CLLocationManager`. Executes ``TrackingEffect`` values related to
/// location and persists accepted fixes into a ``LocationStoring``.
@MainActor
public protocol LocationEngineProtocol: AnyObject {
    var delegate: (any LocationEngineDelegate)? { get set }
    /// Opt-in audit sink. Defaults to a no-op log; the coordinator installs
    /// the real one when the user has turned the audit trail on.
    var audit: any AuditRecording { get set }

    /// Called synchronously for every accepted fix to build its annotation
    /// (activity, phase, battery, session). Set by the coordinator.
    var annotationProvider: @MainActor () -> SampleAnnotation { get set }

    var authorization: LocationAuthorization { get }
    /// `true` when precise location is granted (`CLAccuracyAuthorization.fullAccuracy`).
    var hasFullAccuracy: Bool { get }
    /// Profile currently applied, `nil` when high-accuracy GPS is off.
    var currentProfile: GPSProfile? { get }
    /// Profile actually pushed to CoreLocation, ``GPSProfile/stationaryCoarse``
    /// included. `nil` only when no location updates run at all — so it is
    /// what the status screen shows, `currentProfile` being blind to the
    /// coarse mode that keeps the blue indicator on.
    var appliedProfile: GPSProfile? { get }
    /// Last accepted fix (from any source), in memory.
    var lastFix: LocationFix? { get }
    /// Number of fixes accepted since launch (for the status screen).
    var acceptedCount: Int { get }
    var rejectedCount: Int { get }

    /// Requests "Always" authorization (when-in-use first if needed).
    func requestAuthorization()

    /// `startUpdatingLocation` with the profile (reconfigures in place if
    /// already running). Also opens a `CLBackgroundActivitySession`.
    func startGPS(profile: GPSProfile)
    /// Stops high-accuracy updates (or downgrades to coarse depending on
    /// settings) and ends the background activity session.
    func stopGPS()

    /// `startMonitoringSignificantLocationChanges` + `startMonitoringVisits`.
    func startSignificantChangeMonitoring()
    func stopSignificantChangeMonitoring()

    /// Flush buffered samples to the store (call on background transition,
    /// disable, and before export).
    func flush() async

    /// Push new settings (filter thresholds, batch size, coarse mode).
    func apply(settings: TrackingSettings)
}

// MARK: - Motion monitor (owner: Motion agent, implemented by `MotionMonitor`)

/// Owns `CMMotionActivityManager`, `CMPedometer` and optional
/// `CMMotionManager` bursts. Emits ``MotionEvent`` on the main actor.
@MainActor
public protocol MotionMonitoring: AnyObject {
    /// Opt-in audit sink, see ``LocationEngineProtocol/audit``.
    var audit: any AuditRecording { get set }
    /// `CMMotionActivityManager.isActivityAvailable()`.
    var isActivityAvailable: Bool { get }
    var authorization: MotionAuthorization { get }
    /// Last activity reported, for the status screen.
    var lastActivity: (kind: ActivityKind, confidence: ActivityConfidence, timestamp: Date)? { get }

    /// Start activity + pedometer updates. `handler` is called on the main
    /// actor for every event. Calling `start` while running replaces the handler.
    func start(handler: @escaping @MainActor (MotionEvent) -> Void)
    func stop()

    /// Optionally sample the accelerometer for `duration` seconds and emit a
    /// `.accelerometerBurst` event. No-op when unavailable.
    func requestAccelerometerBurst(duration: TimeInterval)
}

// MARK: - Tracking controller (owner: Coordinator agent, implemented by `TrackingCoordinator`)

/// Snapshot of everything the UI shows. Rebuilt by the coordinator whenever
/// anything changes; being a value keeps SwiftUI updates cheap.
public struct TrackingStatus: Sendable, Hashable {
    public var isEnabled: Bool
    public var phase: TrackingPhase
    public var activeProfile: GPSProfile?
    /// Profile CoreLocation is really running, coarse mode included. The
    /// status screen shows this one; ``activeProfile`` stays the
    /// high-accuracy profile that annotates the samples.
    public var appliedProfile: GPSProfile?
    public var lastActivity: ActivityKind
    public var lastActivityConfidence: ActivityConfidence
    public var lastFix: LocationFix?
    public var lastFixSource: LocationSource?
    public var acceptedCount: Int
    public var rejectedCount: Int
    public var stats: StoreStats
    public var batteryLevel: Double?
    public var batteryState: BatteryState
    public var locationAuthorization: LocationAuthorization
    public var hasFullAccuracy: Bool
    public var motionAuthorization: MotionAuthorization
    public var currentSessionID: UUID?
    public var lastTransition: StateTransitionRecord?
    /// Last error message worth surfacing, if any.
    public var lastError: String?

    public init(isEnabled: Bool = false,
                phase: TrackingPhase = .disabled,
                activeProfile: GPSProfile? = nil,
                appliedProfile: GPSProfile? = nil,
                lastActivity: ActivityKind = .unknown,
                lastActivityConfidence: ActivityConfidence = .low,
                lastFix: LocationFix? = nil,
                lastFixSource: LocationSource? = nil,
                acceptedCount: Int = 0,
                rejectedCount: Int = 0,
                stats: StoreStats = StoreStats(),
                batteryLevel: Double? = nil,
                batteryState: BatteryState = .unknown,
                locationAuthorization: LocationAuthorization = .notDetermined,
                hasFullAccuracy: Bool = false,
                motionAuthorization: MotionAuthorization = .notDetermined,
                currentSessionID: UUID? = nil,
                lastTransition: StateTransitionRecord? = nil,
                lastError: String? = nil) {
        self.isEnabled = isEnabled
        self.phase = phase
        self.activeProfile = activeProfile
        self.appliedProfile = appliedProfile
        self.lastActivity = lastActivity
        self.lastActivityConfidence = lastActivityConfidence
        self.lastFix = lastFix
        self.lastFixSource = lastFixSource
        self.acceptedCount = acceptedCount
        self.rejectedCount = rejectedCount
        self.stats = stats
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.locationAuthorization = locationAuthorization
        self.hasFullAccuracy = hasFullAccuracy
        self.motionAuthorization = motionAuthorization
        self.currentSessionID = currentSessionID
        self.lastTransition = lastTransition
        self.lastError = lastError
    }
}

/// The single object the UI talks to. Implemented by `TrackingCoordinator`
/// (`@MainActor @Observable`). The UI receives it through
/// `@Environment(\.trackingController)`, so views compile against this
/// protocol without depending on the coordinator type.
@MainActor
public protocol TrackingControlling: AnyObject, Observable, Sendable {
    /// Observable snapshot for the status screen.
    var status: TrackingStatus { get }
    /// Current settings; assignment persists them and re-applies to engines.
    var settings: TrackingSettings { get set }

    /// Turn tracking on/off. Persists the flag so launch can re-arm it.
    func setTrackingEnabled(_ enabled: Bool)
    /// Ask for location "Always" + motion permissions.
    func requestPermissions()

    // Data access for Map / Export views.
    func samples(in interval: DateInterval) async throws -> [StoredLocationSample]
    func samples(sessionID: UUID) async throws -> [StoredLocationSample]
    func sessions() async throws -> [TrackingSessionSummary]
    func recentTransitions(limit: Int) async throws -> [StateTransitionRecord]

    /// Write an export file to a temporary URL (GPX or JSON) and return it,
    /// suitable for `ShareLink`. `sessionID == nil` exports `interval`;
    /// `interval == nil && sessionID == nil` exports everything.
    func export(format: ExportFormat, sessionID: UUID?, interval: DateInterval?) async throws -> URL

    /// Delete samples older than `settings.retentionDays` now.
    func purgeNow() async throws -> Int

    // MARK: Audit trail (opt-in)

    /// Read the audit trail, newest first. Empty when the user never opted in.
    func auditEvents(matching query: AuditQuery) async throws -> [AuditEvent]
    /// Number of audit events currently stored.
    func auditCount() async throws -> Int
    /// Write the audit trail to a shareable file.
    func exportAudit(format: AuditExportFormat, query: AuditQuery) async throws -> URL
    /// Delete the whole audit trail; returns how many events went.
    @discardableResult
    func clearAudit() async -> Int
}

// No default implementations on purpose: a protocol-extension default would
// silently win over an actor-isolated member of a conforming type, and the
// audit trail would look empty while the store was writing rows correctly.
