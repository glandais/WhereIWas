#if SCREENSHOTS
import Foundation
import Observation

/// The ``TrackingControlling`` the app runs on in screenshot mode.
///
/// Same idea as `PreviewTrackingController`, but the dataset is built for the
/// App Store rather than for a Xcode canvas, and answers the two complaints
/// against the hand-taken shots it replaced:
///
/// * a real track — a walking loop then a drive, ~11 km over the morning —
///   instead of four points and 0 m;
/// * a device that is actually **moving**, so the Status screen shows a phase,
///   a populated GPS profile, a detected activity and a fresh fix.
///
/// Everything is fictional and anchored on ``ScreenshotMode/clock`` so two
/// runs produce identical pixels. Coordinates sit on open ground near Place de
/// la République in Paris — a neutral spot that is nobody's home.
@MainActor
@Observable
final class DemoTrackingController: TrackingControlling {
    var status: TrackingStatus
    var settings: TrackingSettings

    private let walkSessionID = UUID()
    private let driveSessionID = UUID()
    private let storedSamples: [StoredLocationSample]
    private let storedSessions: [TrackingSessionSummary]
    private let transitions: [StateTransitionRecord]
    private let auditEvents: [AuditEvent]

    /// The dataset spans this much wall time when the day is long enough.
    private static let nominalSpan: TimeInterval = 92 * 60

    init() {
        let clock = ScreenshotMode.clock
        // Everything must land *today*: the map shows one day at a time and
        // the Status screen counts today's samples. Run at 00:10 and a 92
        // minute track would mostly be yesterday's, so squeeze it into what is
        // left of the day instead of straddling midnight.
        let sinceMidnight = clock.timeIntervalSince(Calendar.current.startOfDay(for: clock))
        let scale = min(1, max(0, sinceMidnight - 60) / Self.nominalSpan)
        /// `minutes` before ``clock``, compressed by `scale`.
        let ago: (Double) -> Date = { clock.addingTimeInterval(-$0 * 60 * scale) }

        var settings = TrackingSettings()
        // The audit trail is opt-in and off by default; the screenshot that
        // shows it is the one no competitor has, so turn it on.
        settings.auditEnabled = true
        self.settings = settings

        // 09:41 → the drive is still in progress, the walk ended an hour ago.
        let walk = Self.walkingLoop(sessionID: walkSessionID,
                                    from: ago(92), to: ago(66),
                                    firstSequence: 1)
        let drive = Self.drive(sessionID: driveSessionID,
                               from: ago(22), to: clock,
                               firstSequence: Int64(walk.count + 1))
        storedSamples = walk + drive

        storedSessions = [
            TrackingSessionSummary(id: driveSessionID,
                                   startedAt: ago(22),
                                   endedAt: nil,
                                   sampleCount: drive.count,
                                   distanceMeters: 9_640),
            TrackingSessionSummary(id: walkSessionID,
                                   startedAt: ago(92),
                                   endedAt: ago(66),
                                   sampleCount: walk.count,
                                   distanceMeters: 1_580),
            TrackingSessionSummary(id: UUID(),
                                   startedAt: clock.addingTimeInterval(-26 * 3_600),
                                   endedAt: clock.addingTimeInterval(-21 * 3_600),
                                   sampleCount: 1_412,
                                   distanceMeters: 23_800)
        ]

        // The reasons are the machine vocabulary `Formatting.transitionReason`
        // knows how to translate, so this section reads in both locales.
        transitions = [
            StateTransitionRecord(timestamp: ago(21),
                                  from: .probing, to: .moving,
                                  reason: "motionActivity(automotive, high)", batteryLevel: 0.84),
            StateTransitionRecord(timestamp: ago(22),
                                  from: .stationary, to: .probing,
                                  reason: "significantChange", batteryLevel: 0.85),
            StateTransitionRecord(timestamp: ago(62),
                                  from: .moving, to: .stationary,
                                  reason: "stillnessTimerFired", batteryLevel: 0.88),
            StateTransitionRecord(timestamp: ago(89),
                                  from: .probing, to: .moving,
                                  reason: "motionActivity(walking, high)", batteryLevel: 0.93),
            StateTransitionRecord(timestamp: ago(90),
                                  from: .disabled, to: .probing,
                                  reason: "enable", batteryLevel: 0.94)
        ]

        auditEvents = Self.auditTrail(now: clock, ago: ago)

        let lastFix = storedSamples.last?.fix
        status = TrackingStatus(
            isEnabled: true,
            phase: .moving,
            activeProfile: GPSProfile.profile(for: .automotive, speed: 18, settings: settings),
            appliedProfile: GPSProfile.profile(for: .automotive, speed: 18, settings: settings),
            lastActivity: .automotive,
            lastActivityConfidence: .high,
            lastFix: lastFix,
            lastFixSource: .gps,
            acceptedCount: storedSamples.count,
            rejectedCount: 11,
            stats: StoreStats(totalSamples: 21_734,
                              pendingUpload: 0,
                              oldestSample: clock.addingTimeInterval(-29 * 86_400),
                              newestSample: lastFix?.timestamp,
                              sessionCount: storedSessions.count),
            // The simulator reports -1 for the battery, so the whole status is
            // supplied as a value rather than read from a real coordinator.
            batteryLevel: 0.84,
            batteryState: .unplugged,
            locationAuthorization: .always,
            hasFullAccuracy: true,
            motionAuthorization: .authorized,
            currentSessionID: driveSessionID,
            lastTransition: transitions.first,
            lastError: nil
        )
    }

    // MARK: Track

    /// A wandering loop on foot, ~1.6 km in 26 minutes.
    private static func walkingLoop(sessionID: UUID, from start: Date, to end: Date,
                                    firstSequence: Int64) -> [StoredLocationSample] {
        let origin = (lat: 48.8672, lon: 2.3630)
        let count = 156
        let step = end.timeIntervalSince(start) / Double(count)
        return (0..<count).map { i in
            let t = Double(i) / Double(count) * 2 * .pi
            let fix = LocationFix(latitude: origin.lat + 0.0021 * sin(t) + 0.00035 * sin(t * 6),
                                  longitude: origin.lon + 0.0031 * cos(t) + 0.00045 * cos(t * 5),
                                  altitude: 38 + 3 * sin(t * 3),
                                  horizontalAccuracy: 5 + 3 * abs(sin(t * 4)),
                                  verticalAccuracy: 8,
                                  speed: 1.3 + 0.3 * sin(t * 4),
                                  speedAccuracy: 0.4,
                                  course: (t * 180 / .pi).truncatingRemainder(dividingBy: 360),
                                  timestamp: start.addingTimeInterval(Double(i) * step))
            let annotation = SampleAnnotation(activity: .walking, activityConfidence: .high,
                                              phase: .moving,
                                              batteryLevel: 0.94 - Double(i) / Double(count) * 0.06,
                                              batteryState: .unplugged,
                                              sessionID: sessionID, profileLabel: "walking")
            return StoredLocationSample(sequence: firstSequence + Int64(i), fix: fix,
                                        annotation: annotation, source: .gps,
                                        uploaded: false, createdAt: fix.timestamp)
        }
    }

    /// A drive heading north-east out of the loop, ~9.6 km in 22 minutes.
    private static func drive(sessionID: UUID, from start: Date, to end: Date,
                              firstSequence: Int64) -> [StoredLocationSample] {
        let origin = (lat: 48.8672, lon: 2.3661)
        let count = 132
        let step = end.timeIntervalSince(start) / Double(count)
        return (0..<count).map { i in
            let p = Double(i) / Double(count)
            let speed = 14 + 8 * sin(p * .pi)          // slow start, slow finish
            let fix = LocationFix(latitude: origin.lat + 0.052 * p + 0.0016 * sin(p * 11),
                                  longitude: origin.lon + 0.071 * p + 0.0022 * cos(p * 9),
                                  altitude: 45 + 20 * p,
                                  horizontalAccuracy: 6 + 4 * abs(sin(p * 13)),
                                  verticalAccuracy: 10,
                                  speed: speed,
                                  speedAccuracy: 0.8,
                                  course: 42 + 12 * sin(p * 7),
                                  timestamp: start.addingTimeInterval(Double(i) * step))
            let annotation = SampleAnnotation(activity: .automotive, activityConfidence: .high,
                                              phase: .moving,
                                              batteryLevel: 0.88 - p * 0.04,
                                              batteryState: .unplugged,
                                              sessionID: sessionID, profileLabel: "driving")
            return StoredLocationSample(sequence: firstSequence + Int64(i), fix: fix,
                                        annotation: annotation, source: .gps,
                                        uploaded: false, createdAt: fix.timestamp)
        }
    }

    // MARK: Audit trail

    /// Enough events to fill the screen with several categories and
    /// severities, and to show the per-fix validation checks — the part of the
    /// trail worth putting on the store page.
    private static func auditTrail(now: Date, ago: (Double) -> Date) -> [AuditEvent] {
        [
            AuditEvent(timestamp: now.addingTimeInterval(-3),
                       category: .location, severity: .debug,
                       name: "fix.accepted",
                       message: "Fix accepted",
                       details: [AuditDetail("latitude", 48.919312, decimals: 6),
                                 AuditDetail("longitude", 2.437122, decimals: 6),
                                 AuditDetail("horizontalAccuracy", 6.2),
                                 AuditDetail("speed", 18.4),
                                 AuditDetail("profile", "driving"),
                                 AuditDetail("check.horizontalAccuracy.valid", "passed (6.20 vs > 0 m)"),
                                 AuditDetail("check.horizontalAccuracy.withinLimit", "passed (6.20 vs <= 50.00 m)"),
                                 AuditDetail("check.timestamp.notInFuture", "passed"),
                                 AuditDetail("check.timestamp.notStale", "passed (0.24 s vs <= 30.00 s)"),
                                 AuditDetail("check.distance.notDuplicate", "passed (184.10 vs > 0.00 m)")],
                       phase: .moving, batteryLevel: 0.84),
            AuditEvent(timestamp: now.addingTimeInterval(-9),
                       category: .filter, severity: .info,
                       name: "fix.rejected",
                       message: "Fix rejected: poorAccuracy(94.0 m)",
                       details: [AuditDetail("latitude", 48.918770, decimals: 6),
                                 AuditDetail("longitude", 2.436015, decimals: 6),
                                 AuditDetail("horizontalAccuracy", 94.0),
                                 AuditDetail("rejection", "poorAccuracy(94.0 m)"),
                                 AuditDetail("check.horizontalAccuracy.valid", "passed (94.00 vs > 0 m)"),
                                 AuditDetail("check.horizontalAccuracy.withinLimit", "failed (94.00 vs <= 50.00 m)"),
                                 AuditDetail("check.timestamp.notStale", "skipped")],
                       phase: .moving, batteryLevel: 0.84),
            AuditEvent(timestamp: now.addingTimeInterval(-64),
                       category: .persistence, severity: .debug,
                       name: "store.insert",
                       message: "20 samples written",
                       details: [AuditDetail("count", "20"),
                                 AuditDetail("firstSequence", "21715"),
                                 AuditDetail("durationMs", 7.4)],
                       phase: .moving, batteryLevel: 0.84),
            AuditEvent(timestamp: ago(21),
                       category: .effect, severity: .info,
                       name: "gps.profile",
                       message: "GPS reconfigured for driving",
                       details: [AuditDetail("profile", "driving"),
                                 AuditDetail("desiredAccuracy", "bestForNavigation"),
                                 AuditDetail("distanceFilter", 50.0),
                                 AuditDetail("activityType", "automotiveNavigation")],
                       phase: .moving, batteryLevel: 0.84),
            AuditEvent(timestamp: ago(21).addingTimeInterval(-1),
                       category: .state, severity: .info,
                       name: "state.transition",
                       message: "probing → moving",
                       details: [AuditDetail("from", "probing"), AuditDetail("to", "moving"),
                                 AuditDetail("input", "activity automotive/high"),
                                 AuditDetail("reason", "motionActivity")],
                       phase: .moving, batteryLevel: 0.84),
            AuditEvent(timestamp: ago(21).addingTimeInterval(-4),
                       category: .motion, severity: .debug,
                       name: "motion.event",
                       message: "Activity automotive (high confidence)",
                       details: [AuditDetail("kind", "automotive"), AuditDetail("confidence", "high")],
                       phase: .probing, batteryLevel: 0.85),
            AuditEvent(timestamp: ago(22),
                       category: .location, severity: .info,
                       name: "significantChange",
                       message: "Significant location change received",
                       details: [AuditDetail("latitude", 48.867903, decimals: 6),
                                 AuditDetail("longitude", 2.366140, decimals: 6),
                                 AuditDetail("horizontalAccuracy", 65.0)],
                       phase: .stationary, batteryLevel: 0.85),
            AuditEvent(timestamp: ago(62),
                       category: .state, severity: .info,
                       name: "state.transition",
                       message: "moving → stationary",
                       details: [AuditDetail("from", "moving"), AuditDetail("to", "stationary"),
                                 AuditDetail("input", "stillness timer"),
                                 AuditDetail("reason", "stillnessTimerFired")],
                       phase: .stationary, batteryLevel: 0.88),
            AuditEvent(timestamp: ago(89),
                       category: .permission, severity: .info,
                       name: "permission.location",
                       message: "Location authorization: always",
                       details: [AuditDetail("status", "always"),
                                 AuditDetail("fullAccuracy", true)],
                       phase: .probing, batteryLevel: 0.93),
            AuditEvent(timestamp: ago(90),
                       category: .lifecycle, severity: .info,
                       name: "app.bootstrap",
                       message: "Tracking re-armed at launch",
                       details: [AuditDetail("launchedForLocation", true),
                                 AuditDetail("trackingEnabled", true)],
                       phase: .disabled, batteryLevel: 0.94)
        ]
    }

    // MARK: TrackingControlling

    func setTrackingEnabled(_ enabled: Bool) {
        status.isEnabled = enabled
        status.phase = enabled ? .moving : .disabled
        status.activeProfile = enabled ? GPSProfile.profile(for: .automotive, speed: 18, settings: settings) : nil
        status.appliedProfile = status.activeProfile
    }

    func requestPermissions() {}

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

    /// Runs the real exporters, so the Export screen shows a believable file
    /// size instead of a few bytes.
    func export(format: ExportFormat, sessionID: UUID?, interval: DateInterval?) async throws -> URL {
        let samples: [StoredLocationSample]
        let name: String
        if let sessionID {
            samples = try await self.samples(sessionID: sessionID)
            name = "session-\(sessionID.uuidString.prefix(8))"
        } else if let interval {
            samples = try await self.samples(in: interval)
            name = "range"
        } else {
            samples = storedSamples
            name = "all"
        }
        switch format {
        case .gpx:
            return try GPXExporter.write(samples, name: "WhereIWas \(name)")
        case .json:
            return try JSONExporter.write(samples, name: "WhereIWas \(name)")
        }
    }

    func purgeNow() async throws -> Int { 0 }

    func auditEvents(matching query: AuditQuery) async throws -> [AuditEvent] {
        guard settings.auditEnabled else { return [] }
        var events = auditEvents.filter(query.matches)
        if query.limit > 0, events.count > query.limit {
            events = Array(events.prefix(query.limit))
        }
        return events
    }

    func auditCount() async throws -> Int { settings.auditEnabled ? 1_284 : 0 }

    func exportAudit(format: AuditExportFormat, query: AuditQuery) async throws -> URL {
        try AuditExporter.write(auditEvents.filter(query.matches), settings: settings, format: format)
    }

    func clearAudit() async -> Int { 0 }
}
#endif
