import Foundation
import Observation

// Minimal no-op implementations of the module interfaces. They keep the
// tree compiling before the real modules land and are handy for SwiftUI
// previews and tests. Do NOT put real logic here.

/// In-memory ``LocationStoring`` used by previews and unit tests.
public actor InMemoryLocationStore: LocationStoring {
    /// Audit events, oldest first.
    private var audit: [AuditEvent] = []

    public func appendAudit(_ events: [AuditEvent]) async throws {
        audit.append(contentsOf: events)
    }

    public func auditEvents(matching query: AuditQuery) async throws -> [AuditEvent] {
        var events = audit.filter(query.matches).sorted { $0.timestamp > $1.timestamp }
        if query.limit > 0, events.count > query.limit {
            events = Array(events.prefix(query.limit))
        }
        return events
    }

    public func auditCount() async throws -> Int { audit.count }

    public func purgeAudit(olderThan date: Date) async throws -> Int {
        let before = audit.count
        audit.removeAll { $0.timestamp < date }
        return before - audit.count
    }

    public func clearAudit() async throws -> Int {
        let count = audit.count
        audit.removeAll()
        return count
    }

    private var samples: [StoredLocationSample] = []
    private var sessionsList: [TrackingSessionSummary] = []
    private var transitions: [StateTransitionRecord] = []
    private var nextSequence: Int64 = 1

    public init() {}

    public func insert(_ drafts: [LocationSampleDraft]) async throws -> [Int64] {
        var assigned: [Int64] = []
        for draft in drafts {
            let seq = nextSequence
            nextSequence += 1
            samples.append(StoredLocationSample(sequence: seq,
                                                fix: draft.fix,
                                                annotation: draft.annotation,
                                                source: draft.source,
                                                uploaded: false,
                                                createdAt: Date()))
            assigned.append(seq)
        }
        return assigned
    }

    public func pendingUpload(limit: Int) async throws -> [StoredLocationSample] {
        Array(samples.filter { !$0.uploaded }.prefix(limit))
    }

    public func markUploaded(sequences: [Int64]) async throws {
        let set = Set(sequences)
        for i in samples.indices where set.contains(samples[i].sequence) {
            samples[i].uploaded = true
        }
    }

    public func samples(in interval: DateInterval) async throws -> [StoredLocationSample] {
        samples.filter { interval.contains($0.fix.timestamp) }
    }

    public func samples(sessionID: UUID) async throws -> [StoredLocationSample] {
        samples.filter { $0.annotation.sessionID == sessionID }
    }

    public func latestSample() async throws -> StoredLocationSample? { samples.last }

    public func purge(olderThan date: Date) async throws -> Int {
        let before = samples.count
        samples.removeAll { $0.fix.timestamp < date }
        transitions.removeAll { $0.timestamp < date }
        return before - samples.count
    }

    public func stats() async throws -> StoreStats {
        StoreStats(totalSamples: samples.count,
                   pendingUpload: samples.filter { !$0.uploaded }.count,
                   oldestSample: samples.first?.fix.timestamp,
                   newestSample: samples.last?.fix.timestamp,
                   sessionCount: sessionsList.count)
    }

    public func beginSession(startedAt: Date) async throws -> UUID {
        let id = UUID()
        sessionsList.insert(TrackingSessionSummary(id: id, startedAt: startedAt, endedAt: nil,
                                                   sampleCount: 0, distanceMeters: 0), at: 0)
        return id
    }

    public func endSession(id: UUID, endedAt: Date) async throws {
        if let i = sessionsList.firstIndex(where: { $0.id == id }) {
            sessionsList[i].endedAt = endedAt
        }
    }

    public func openSession() async throws -> TrackingSessionSummary? {
        sessionsList.first { $0.endedAt == nil }
    }

    public func sessions() async throws -> [TrackingSessionSummary] { sessionsList }

    public func logTransition(_ record: StateTransitionRecord) async throws {
        transitions.insert(record, at: 0)
    }

    public func recentTransitions(limit: Int) async throws -> [StateTransitionRecord] {
        Array(transitions.prefix(limit))
    }
}

/// ``LocationEngineProtocol`` that does nothing (previews / tests).
@MainActor
public final class NoopLocationEngine: LocationEngineProtocol {
    /// Opt-in audit sink; a no-op until the coordinator installs one.
    public var audit: any AuditRecording = NoopAuditLog()

    public weak var delegate: (any LocationEngineDelegate)?
    public var annotationProvider: @MainActor () -> SampleAnnotation = { SampleAnnotation() }
    public private(set) var authorization: LocationAuthorization = .notDetermined
    public private(set) var hasFullAccuracy = false
    public private(set) var currentProfile: GPSProfile?
    public private(set) var lastFix: LocationFix?
    public private(set) var acceptedCount = 0
    public private(set) var rejectedCount = 0
    /// Recorded calls, for assertions in tests.
    public private(set) var calls: [String] = []

    public init() {}

    public func requestAuthorization() { calls.append("requestAuthorization") }
    public func startGPS(profile: GPSProfile) { currentProfile = profile; calls.append("startGPS(\(profile.label))") }
    public func stopGPS() { currentProfile = nil; calls.append("stopGPS") }
    public func startSignificantChangeMonitoring() { calls.append("startSignificantChangeMonitoring") }
    public func stopSignificantChangeMonitoring() { calls.append("stopSignificantChangeMonitoring") }
    public func flush() async { calls.append("flush") }
    public func apply(settings: TrackingSettings) { calls.append("apply(settings)") }
}

/// ``MotionMonitoring`` that does nothing (previews / tests).
@MainActor
public final class NoopMotionMonitor: MotionMonitoring {
    /// Opt-in audit sink; a no-op until the coordinator installs one.
    public var audit: any AuditRecording = NoopAuditLog()

    public private(set) var isActivityAvailable = false
    public private(set) var authorization: MotionAuthorization = .notDetermined
    public private(set) var lastActivity: (kind: ActivityKind, confidence: ActivityConfidence, timestamp: Date)?
    private var handler: (@MainActor (MotionEvent) -> Void)?
    public private(set) var isRunning = false

    public init() {}

    public func start(handler: @escaping @MainActor (MotionEvent) -> Void) {
        self.handler = handler
        isRunning = true
    }

    public func stop() {
        handler = nil
        isRunning = false
    }

    public func requestAccelerometerBurst(duration: TimeInterval) {}

    /// Test helper: inject an event as if CoreMotion produced it.
    public func simulate(_ event: MotionEvent) {
        if case .activity(let kind, let confidence, let timestamp) = event {
            lastActivity = (kind, confidence, timestamp)
        }
        handler?(event)
    }
}

/// ``TrackingControlling`` used as the environment default and in previews.
@MainActor
@Observable
public final class NoopTrackingController: TrackingControlling {
    public var status = TrackingStatus()
    public var settings = TrackingSettings()

    public init(status: TrackingStatus = TrackingStatus()) {
        self.status = status
    }

    public func setTrackingEnabled(_ enabled: Bool) {
        status.isEnabled = enabled
        status.phase = enabled ? .probing : .disabled
    }

    public func requestPermissions() {}

    public func samples(in interval: DateInterval) async throws -> [StoredLocationSample] { [] }
    public func samples(sessionID: UUID) async throws -> [StoredLocationSample] { [] }
    public func sessions() async throws -> [TrackingSessionSummary] { [] }
    public func recentTransitions(limit: Int) async throws -> [StateTransitionRecord] { [] }

    public func export(format: ExportFormat, sessionID: UUID?, interval: DateInterval?) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whereiwas-empty.\(format.fileExtension)")
        try Data().write(to: url)
        return url
    }

    public func purgeNow() async throws -> Int { 0 }

    public func auditEvents(matching query: AuditQuery) async throws -> [AuditEvent] { [] }
    public func auditCount() async throws -> Int { 0 }
    @discardableResult
    public func clearAudit() async -> Int { 0 }

    public func exportAudit(format: AuditExportFormat, query: AuditQuery) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whereiwas-audit-empty.\(format.fileExtension)")
        try Data().write(to: url)
        return url
    }
}
