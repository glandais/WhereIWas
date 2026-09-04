import Foundation
import Observation
import SwiftUI

// The UI talks to the coordinator exclusively through the Domain protocol
// `TrackingControlling`, received via `@Environment(\.trackingController)`.
// `TrackingStatusProviding` is a UI-side alias for that façade so views and
// previews name a single type; the integrator only has to inject the real
// `TrackingCoordinator` in `WhereIWasApp` (already done by the scaffold).
typealias TrackingStatusProviding = TrackingControlling

// MARK: - Derived presentation state

extension TrackingStatus {
    /// Something is wrong enough that the user must act (permissions).
    var needsAttention: Bool { !warnings.isEmpty }

    /// Human readable warnings, most severe first.
    var warnings: [StatusWarning] {
        var list: [StatusWarning] = []
        switch locationAuthorization {
        case .denied, .restricted:
            list.append(.init(id: "loc-denied", severity: .critical,
                              title: String(localized: "warning.locationDenied.title", defaultValue: "Location access denied"),
                              message: String(localized: "warning.locationDenied.message", defaultValue: "WhereIWas cannot record anything. Allow location access “Always” in Settings."),
                              action: .openSettings))
        case .whenInUse:
            list.append(.init(id: "loc-wheninuse", severity: .critical,
                              title: String(localized: "warning.whenInUse.title", defaultValue: "Location only while using the app"),
                              message: String(localized: "warning.whenInUse.message", defaultValue: "Background tracking stops as soon as the app is suspended. Change location access to “Always” in Settings."),
                              action: .openSettings))
        case .notDetermined:
            list.append(.init(id: "loc-none", severity: .warning,
                              title: String(localized: "warning.locationNotDetermined.title", defaultValue: "Location permission not granted yet"),
                              message: String(localized: "warning.locationNotDetermined.message", defaultValue: "Grant “Always” location access so tracking survives in the background."),
                              action: .requestPermissions))
        case .always:
            break
        }
        if locationAuthorization == .always, !hasFullAccuracy {
            list.append(.init(id: "loc-reduced", severity: .warning,
                              title: String(localized: "warning.preciseOff.title", defaultValue: "Precise Location is off"),
                              message: String(localized: "warning.preciseOff.message", defaultValue: "Samples are only accurate to a few kilometers. Enable Precise Location in Settings."),
                              action: .openSettings))
        }
        switch motionAuthorization {
        case .denied, .restricted:
            list.append(.init(id: "motion-denied", severity: .warning,
                              title: String(localized: "warning.motionDenied.title", defaultValue: "Motion access denied"),
                              message: String(localized: "warning.motionDenied.message", defaultValue: "Without motion activity the app must rely on GPS to detect movement, which uses more battery."),
                              action: .openSettings))
        case .notDetermined:
            list.append(.init(id: "motion-none", severity: .info,
                              title: String(localized: "warning.motionNotDetermined.title", defaultValue: "Motion permission not granted yet"),
                              message: String(localized: "warning.motionNotDetermined.message", defaultValue: "Motion activity lets the app switch GPS off while you are still."),
                              action: .requestPermissions))
        case .authorized:
            break
        }
        if let lastError {
            list.append(.init(id: "error", severity: .info, title: String(localized: "warning.lastError.title", defaultValue: "Last error"), message: lastError, action: nil))
        }
        return list
    }

    /// `true` when tracking is on but no sample arrived for a suspicious time.
    func isStale(now: Date = .now, threshold: TimeInterval = 30 * 60) -> Bool {
        guard isEnabled, phase != .disabled else { return false }
        guard let last = lastFix?.timestamp else { return stats.totalSamples > 0 }
        return now.timeIntervalSince(last) > threshold && phase != .stationary
    }
}

struct StatusWarning: Identifiable, Hashable {
    enum Severity: Hashable { case critical, warning, info }
    enum Action: Hashable { case openSettings, requestPermissions }

    var id: String
    var severity: Severity
    var title: String
    var message: String
    var action: Action?

    var color: Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    var systemImage: String {
        switch severity {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

// MARK: - Preview mock

/// A `TrackingControlling` with realistic fake data for SwiftUI previews.
/// Never used in production; `NoopTrackingController` remains the
/// environment default.
@MainActor
@Observable
final class PreviewTrackingController: TrackingControlling {
    var status: TrackingStatus
    var settings = TrackingSettings()

    private let sessionID = UUID()
    private var storedSamples: [StoredLocationSample] = []
    private var storedSessions: [TrackingSessionSummary] = []
    private var transitions: [StateTransitionRecord] = []

    init(phase: TrackingPhase = .moving, warnings: Bool = false) {
        let now = Date.now
        let samples = Self.makeTrack(sessionID: sessionID, endingAt: now)
        storedSamples = samples
        storedSessions = [
            TrackingSessionSummary(id: sessionID, startedAt: now.addingTimeInterval(-3600), endedAt: nil,
                                   sampleCount: samples.count, distanceMeters: 4_250),
            TrackingSessionSummary(id: UUID(), startedAt: now.addingTimeInterval(-90_000),
                                   endedAt: now.addingTimeInterval(-80_000), sampleCount: 812, distanceMeters: 12_300)
        ]
        let seededTransitions = [
            StateTransitionRecord(timestamp: now.addingTimeInterval(-60), from: .probing, to: .moving, reason: "motionActivity(walking, high)", batteryLevel: 0.82),
            StateTransitionRecord(timestamp: now.addingTimeInterval(-400), from: .stationary, to: .probing, reason: "significantChange", batteryLevel: 0.83),
            StateTransitionRecord(timestamp: now.addingTimeInterval(-1_900), from: .moving, to: .stationary, reason: "stillnessTimerFired", batteryLevel: 0.85),
            StateTransitionRecord(timestamp: now.addingTimeInterval(-3_600), from: .disabled, to: .probing, reason: "enable", batteryLevel: 0.90)
        ]
        transitions = seededTransitions
        status = TrackingStatus(
            isEnabled: phase != .disabled,
            phase: phase,
            activeProfile: phase == .moving ? GPSProfile.profile(for: .walking, speed: 1.4) : (phase == .probing ? .probing : nil),
            lastActivity: .walking,
            lastActivityConfidence: .high,
            lastFix: samples.last?.fix,
            lastFixSource: .gps,
            acceptedCount: samples.count,
            rejectedCount: 7,
            stats: StoreStats(totalSamples: 18_452, pendingUpload: 1_203,
                              oldestSample: now.addingTimeInterval(-86_400 * 9), newestSample: now, sessionCount: 2),
            batteryLevel: 0.82,
            batteryState: .unplugged,
            locationAuthorization: warnings ? .whenInUse : .always,
            hasFullAccuracy: !warnings,
            motionAuthorization: warnings ? .denied : .authorized,
            currentSessionID: sessionID,
            lastTransition: seededTransitions.first,
            lastError: nil
        )
    }

    private static func makeTrack(sessionID: UUID, endingAt end: Date) -> [StoredLocationSample] {
        // A wobbly loop around Paris' Place de la République.
        let origin = (lat: 48.8675, lon: 2.3633)
        var out: [StoredLocationSample] = []
        let count = 180
        for i in 0..<count {
            let t = Double(i) / Double(count) * 2 * .pi
            let lat = origin.lat + 0.006 * sin(t) + 0.0004 * sin(t * 9)
            let lon = origin.lon + 0.009 * cos(t) + 0.0005 * cos(t * 7)
            let ts = end.addingTimeInterval(-Double(count - i) * 20)
            let fix = LocationFix(latitude: lat, longitude: lon, altitude: 40 + 5 * sin(t * 3),
                                  horizontalAccuracy: 6 + 4 * abs(sin(t * 5)), verticalAccuracy: 8,
                                  speed: 1.2 + 0.4 * sin(t * 4), speedAccuracy: 0.3,
                                  course: (t * 180 / .pi).truncatingRemainder(dividingBy: 360), timestamp: ts)
            let annotation = SampleAnnotation(activity: .walking, activityConfidence: .high, phase: .moving,
                                              batteryLevel: 0.9 - Double(i) / Double(count) * 0.08,
                                              batteryState: .unplugged, sessionID: sessionID, profileLabel: "walking")
            out.append(StoredLocationSample(sequence: Int64(i + 1), fix: fix, annotation: annotation,
                                            source: .gps, uploaded: i < count / 2, createdAt: ts))
        }
        return out
    }

    func setTrackingEnabled(_ enabled: Bool) {
        status.isEnabled = enabled
        status.phase = enabled ? .probing : .disabled
        status.activeProfile = enabled ? .probing : nil
    }

    func requestPermissions() {
        status.locationAuthorization = .always
        status.hasFullAccuracy = true
        status.motionAuthorization = .authorized
    }

    func samples(in interval: DateInterval) async throws -> [StoredLocationSample] {
        storedSamples.filter { interval.contains($0.fix.timestamp) }
    }

    func samples(sessionID: UUID) async throws -> [StoredLocationSample] {
        storedSamples.filter { $0.annotation.sessionID == sessionID }
    }

    func sessions() async throws -> [TrackingSessionSummary] { storedSessions }

    func recentTransitions(limit: Int) async throws -> [StateTransitionRecord] {
        Array(transitions.prefix(limit))
    }

    func export(format: ExportFormat, sessionID: UUID?, interval: DateInterval?) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whereiwas-preview.\(format.fileExtension)")
        try Data("preview".utf8).write(to: url)
        return url
    }

    func purgeNow() async throws -> Int { 42 }

    // MARK: Audit trail

    /// A short, representative trail so the audit screen has something to
    /// render in previews: raw data, the checks run on it, and the state
    /// change that followed.
    private static func previewAuditEvents(now: Date) -> [AuditEvent] {
        [
            AuditEvent(timestamp: now.addingTimeInterval(-4),
                       category: .state, severity: .info,
                       name: "state.transition",
                       arguments: ["probing", "moving"],
                       details: [AuditDetail("from", "probing"), AuditDetail("to", "moving"),
                                 AuditDetail("input", "activity walking/high"),
                                 AuditDetail("reason", "motionActivity")],
                       phase: .moving, batteryLevel: 0.82),
            AuditEvent(timestamp: now.addingTimeInterval(-6),
                       category: .location, severity: .debug,
                       name: "fix.accepted",
                       details: [AuditDetail("latitude", 48.867512, decimals: 6),
                                 AuditDetail("longitude", 2.363301, decimals: 6),
                                 AuditDetail("horizontalAccuracy", 6.4),
                                 AuditDetail("speed", 1.42),
                                 AuditDetail("profile", "walking"),
                                 AuditDetail("check.horizontalAccuracy.withinLimit", "passed (6.40 vs <= 50.00 m)"),
                                 AuditDetail("check.timestamp.notStale", "passed (0.30 s vs <= 30.00 s)")],
                       phase: .moving, batteryLevel: 0.82),
            AuditEvent(timestamp: now.addingTimeInterval(-9),
                       category: .filter, severity: .info,
                       name: "fix.rejected",
                       arguments: ["poorAccuracy", "88.0"],
                       details: [AuditDetail("latitude", 48.867001, decimals: 6),
                                 AuditDetail("longitude", 2.362800, decimals: 6),
                                 AuditDetail("horizontalAccuracy", 88.0),
                                 AuditDetail("rejection", "poorAccuracy(88.0 m)"),
                                 AuditDetail("check.horizontalAccuracy.valid", "passed (88.00 vs > 0 m)"),
                                 AuditDetail("check.horizontalAccuracy.withinLimit", "failed (88.00 vs <= 50.00 m)"),
                                 AuditDetail("check.timestamp.notStale", "skipped")],
                       phase: .moving, batteryLevel: 0.82),
            AuditEvent(timestamp: now.addingTimeInterval(-30),
                       category: .motion, severity: .debug,
                       name: "motion.activity",
                       arguments: ["walking", "high"],
                       details: [AuditDetail("kind", "walking"), AuditDetail("confidence", "high")],
                       phase: .probing, batteryLevel: 0.83),
            AuditEvent(timestamp: now.addingTimeInterval(-3_600),
                       category: .lifecycle, severity: .info,
                       name: "app.relaunched",
                       details: [AuditDetail("launchedForLocation", true),
                                 AuditDetail("trackingEnabled", true)],
                       phase: .disabled, batteryLevel: 0.90),
        ]
    }

    func auditEvents(matching query: AuditQuery) async throws -> [AuditEvent] {
        guard settings.auditEnabled else { return [] }
        return Self.previewAuditEvents(now: Date()).filter(query.matches)
    }

    func auditCount() async throws -> Int {
        settings.auditEnabled ? Self.previewAuditEvents(now: Date()).count : 0
    }

    func exportAudit(format: AuditExportFormat, query: AuditQuery) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whereiwas-audit-preview.\(format.fileExtension)")
        try Data("preview".utf8).write(to: url)
        return url
    }

    func clearAudit() async -> Int { 0 }
}
