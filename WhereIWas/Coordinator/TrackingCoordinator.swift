import Foundation
import Observation
import os
import UIKit

/// Runs the pure ``TrackingStateMachine`` against the real world.
///
/// Responsibilities:
/// * translate `LocationEngineProtocol` / `MotionMonitoring` callbacks into
///   ``TrackingInput`` values and execute the returned ``TrackingEffect``s;
/// * own the stillness / probe timers (`Task.sleep` based, cancellable);
/// * persist the "tracking enabled" flag (`UserDefaults`
///   `whereiwas.trackingEnabled`) and the ``TrackingSettings``;
/// * open / close a `TrackingSession` per enable → disable interval and
///   log every phase transition to the store;
/// * expose an observable ``TrackingStatus`` snapshot to the UI;
/// * flush the engine on background transitions and before exports.
///
/// Everything runs on the main actor. Persistence calls are `async` and are
/// dispatched in `Task`s; the state machine itself is always mutated
/// synchronously so relaunch re-arming happens in the same run-loop turn as
/// `application(_:didFinishLaunchingWithOptions:)`.
@MainActor
@Observable
public final class TrackingCoordinator: TrackingControlling, LocationEngineDelegate {

    // MARK: - Constants

    /// `UserDefaults` key of the persisted "tracking enabled" flag.
    public static let trackingEnabledKey = "whereiwas.trackingEnabled"

    /// Step delta (per pedometer event) below which steps are ignored as a
    /// motion hint. Shifting on a chair produces a handful of "steps".
    static let motionHintStepThreshold = 10

    /// Accepted fixes between two store statistics refreshes.
    static let statsRefreshEveryFixes = 10

    // MARK: - Observable state

    public private(set) var status = TrackingStatus()

    public var settings: TrackingSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: defaults)
            applyEffectiveSettings()
        }
    }

    // MARK: - Dependencies

    @ObservationIgnored private let store: any LocationStoring
    @ObservationIgnored private let engine: any LocationEngineProtocol
    @ObservationIgnored private let motion: any MotionMonitoring
    @ObservationIgnored private let defaults: UserDefaults
    /// Opt-in audit trail. A ``NoopAuditLog`` when the caller does not want one.
    @ObservationIgnored public let audit: any AuditRecording
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.glandais.whereiwas", category: "coordinator")

    // MARK: - Internal state

    @ObservationIgnored private var machine: TrackingStateMachine
    @ObservationIgnored private var stillnessTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var currentSessionID: UUID?
    @ObservationIgnored private var fixesSinceStatsRefresh = 0
    @ObservationIgnored private var lastFixSource: LocationSource?
    @ObservationIgnored private var lastError: String?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var bootstrapped = false

    /// Exposed for tests / diagnostics: the current phase of the machine.
    public var phase: TrackingPhase { machine.phase }

    /// `true` when the persisted flag says tracking should run.
    public var isTrackingEnabled: Bool { defaults.bool(forKey: Self.trackingEnabledKey) }

    // MARK: - Init

    /// - Parameters:
    ///   - store: persistence.
    ///   - engine: the `CLLocationManager` owner.
    ///   - motion: the CoreMotion owner.
    ///   - settings: initial settings (normally `TrackingSettings.load(from: defaults)`).
    ///   - defaults: where the enabled flag and settings are persisted.
    public init(store: any LocationStoring,
                engine: any LocationEngineProtocol,
                motion: any MotionMonitoring,
                settings: TrackingSettings,
                defaults: UserDefaults = .standard,
                audit: (any AuditRecording)? = nil) {
        self.store = store
        self.engine = engine
        self.motion = motion
        self.defaults = defaults
        self.audit = audit ?? NoopAuditLog()
        self.settings = settings
        self.machine = TrackingStateMachine(phase: .disabled, settings: settings)

        engine.delegate = self
        engine.annotationProvider = { [weak self] in
            self?.makeAnnotation() ?? SampleAnnotation()
        }
        engine.audit = self.audit
        motion.audit = self.audit
        if let log = self.audit as? AuditLog {
            log.contextProvider = { [weak self] in
                (self?.machine.phase, Self.batteryLevel())
            }
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        applyEffectiveSettings()
        installLifecycleObservers()
        refreshStatus()
    }

    // MARK: - Launch re-arming

    /// Re-arms tracking synchronously at launch, **before any UI exists**.
    ///
    /// Called from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`
    /// via `AppEnvironment.bootstrap`. If the persisted flag is set, the
    /// state machine receives `.enable` in this very run-loop turn, which
    /// creates / configures the `CLLocationManager`, restarts significant
    /// change + visit monitoring, CoreMotion updates and GPS probing. If we
    /// were launched for a location event but the flag is off (stale
    /// registration), monitoring is explicitly stopped so iOS stops
    /// relaunching us.
    ///
    /// - Parameter launchedForLocation: `true` when
    ///   `UIApplication.LaunchOptionsKey.location` was present.
    public func bootstrap(launchedForLocation: Bool) {
        guard !bootstrapped else { return }
        bootstrapped = true

        let enabled = isTrackingEnabled
        logger.notice("bootstrap launchedForLocation=\(launchedForLocation) enabled=\(enabled)")
        audit.record(AuditEvent(timestamp: Date(),
                                category: .lifecycle,
                                severity: .info,
                                name: "app.bootstrap",
                                message: launchedForLocation
                                    ? "Relaunched by a location event"
                                    : "Launched normally",
                                details: [AuditDetail("launchedForLocation", launchedForLocation),
                                          AuditDetail("trackingEnabled", enabled),
                                          AuditDetail("locationAuthorization", engine.authorization.rawValue),
                                          AuditDetail("motionAuthorization", motion.authorization.rawValue)]))

        if enabled {
            enable(reason: launchedForLocation ? "relaunch (location event)" : "launch")
        } else if launchedForLocation {
            // Stale registration: make sure the system forgets about us.
            engine.stopSignificantChangeMonitoring()
            engine.stopGPS()
        }
        refreshStatus()
        scheduleStatsRefresh()
    }

    /// Alias of ``bootstrap(launchedForLocation:)`` for callers that only
    /// know whether the launch was location-triggered.
    public func rearmAfterLaunch(launchedForLocation: Bool = false) {
        bootstrap(launchedForLocation: launchedForLocation)
    }

    // MARK: - TrackingControlling

    public func setTrackingEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.trackingEnabledKey)
        guard enabled != (machine.phase != .disabled) else { return }
        if enabled {
            enable(reason: "user")
        } else {
            disable(reason: "user")
        }
        refreshStatus()
        scheduleStatsRefresh()
    }

    public func requestPermissions() {
        engine.requestAuthorization()
        // CoreMotion has no explicit request API: the prompt appears when
        // updates start. If tracking is off the events are ignored by the
        // state machine and updates stop on the next `.disable`.
        if machine.phase == .disabled {
            motion.start { [weak self] event in self?.handleMotionEvent(event) }
        }
        refreshStatus()
    }

    public func samples(in interval: DateInterval) async throws -> [StoredLocationSample] {
        await engine.flush()
        return try await store.samples(in: interval)
    }

    public func samples(sessionID: UUID) async throws -> [StoredLocationSample] {
        await engine.flush()
        return try await store.samples(sessionID: sessionID)
    }

    public func sessions() async throws -> [TrackingSessionSummary] {
        try await store.sessions()
    }

    public func recentTransitions(limit: Int) async throws -> [StateTransitionRecord] {
        try await store.recentTransitions(limit: limit)
    }

    public func export(format: ExportFormat, sessionID: UUID?, interval: DateInterval?) async throws -> URL {
        await engine.flush()
        let samples: [StoredLocationSample]
        let name: String
        if let sessionID {
            samples = try await store.samples(sessionID: sessionID)
            name = "session-\(sessionID.uuidString.prefix(8))"
        } else if let interval {
            samples = try await store.samples(in: interval)
            name = "range"
        } else {
            samples = try await store.samples(in: DateInterval(start: .distantPast, end: .distantFuture))
            name = "all"
        }

        let stamp = Self.fileStampFormatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whereiwas-\(name)-\(stamp)")
            .appendingPathExtension(format.fileExtension)

        let data: Data
        switch format {
        case .gpx:
            data = Data(GPXExporter.export(samples, name: "WhereIWas \(name)").utf8)
        case .json:
            data = try JSONExporter.export(samples)
        }
        try data.write(to: url, options: .atomic)
        logger.info("exported \(samples.count) samples to \(url.lastPathComponent)")
        return url
    }

    // MARK: - Audit trail

    /// Reads the audit trail back, newest first. Returns an empty array when
    /// the user has never opted in.
    public func auditEvents(matching query: AuditQuery) async throws -> [AuditEvent] {
        if let log = audit as? AuditLog {
            return try await log.load(matching: query)
        }
        return try await store.auditEvents(matching: query)
    }

    /// Number of audit events on disk.
    public func auditCount() async throws -> Int {
        if let log = audit as? AuditLog { return try await log.storedCount() }
        return try await store.auditCount()
    }

    /// Writes the audit trail to a shareable file.
    public func exportAudit(format: AuditExportFormat, query: AuditQuery) async throws -> URL {
        let events = try await auditEvents(matching: query)
        let url = try AuditExporter.write(events, settings: settings, format: format)
        audit.record(AuditEvent(timestamp: Date(),
                                category: .export,
                                severity: .info,
                                name: "audit.exported",
                                message: "Exported \(events.count) audit events as \(format.label)",
                                details: [AuditDetail("count", events.count),
                                          AuditDetail("format", format.rawValue)]))
        return url
    }

    /// Deletes the whole audit trail.
    @discardableResult
    public func clearAudit() async -> Int {
        if let log = audit as? AuditLog { return await log.clear() }
        return (try? await store.clearAudit()) ?? 0
    }

    public func purgeNow() async throws -> Int {
        guard settings.retentionDays > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(settings.retentionDays) * 86_400)
        let deleted = try await store.purge(olderThan: cutoff)
        logger.notice("purged \(deleted) samples older than \(cutoff)")
        var purgedAudit = 0
        if let log = audit as? AuditLog {
            purgedAudit = await log.purge(retentionDays: settings.auditRetentionDays)
        }
        audit.record(AuditEvent(timestamp: Date(),
                                category: .maintenance,
                                severity: .info,
                                name: "maintenance.purge",
                                message: "Purged \(deleted) samples and \(purgedAudit) audit events",
                                details: [AuditDetail("samplesDeleted", deleted),
                                          AuditDetail("auditDeleted", purgedAudit),
                                          AuditDetail("retentionDays", settings.retentionDays),
                                          AuditDetail("auditRetentionDays", settings.auditRetentionDays)]))
        await refreshStats()
        return deleted
    }

    // MARK: - Enable / disable

    private func enable(reason: String) {
        applyEffectiveSettings()
        let effects = machine.handle(.enable)
        perform(effects, reason: reason)
        openOrResumeSession()
    }

    private func disable(reason: String) {
        let effects = machine.handle(.disable)
        perform(effects, reason: reason)
        closeSession()
    }

    // MARK: - State machine driving

    /// Feed one input to the machine and execute its effects.
    private func handle(_ input: TrackingInput, reason: String? = nil) {
        let before = machine.lastTransition
        let effects = machine.handle(input)
        let transitioned = machine.lastTransition != before
        perform(effects, reason: reason ?? Self.describe(input), transitioned: transitioned)
    }

    private func perform(_ effects: [TrackingEffect], reason: String, transitioned: Bool = true) {
        for effect in effects {
            audit.record(AuditEvent(timestamp: Date(),
                                    category: .effect,
                                    severity: .debug,
                                    name: "effect.\(Self.effectName(effect))",
                                    message: "Executed \(Self.describe(effect))",
                                    details: [AuditDetail("effect", Self.describe(effect)),
                                              AuditDetail("reason", reason)]))
            switch effect {
            case .startGPS(let profile):
                engine.startGPS(profile: profile)
            case .stopGPS:
                engine.stopGPS()
            case .startStillnessTimer(let seconds):
                startStillnessTimer(seconds: seconds)
            case .cancelStillnessTimer:
                stillnessTask?.cancel()
                stillnessTask = nil
            case .startProbeTimer(let seconds):
                startProbeTimer(seconds: seconds)
            case .cancelProbeTimer:
                probeTask?.cancel()
                probeTask = nil
            case .startSignificantChange:
                engine.startSignificantChangeMonitoring()
            case .stopSignificantChange:
                engine.stopSignificantChangeMonitoring()
            case .startMotionUpdates:
                motion.start { [weak self] event in self?.handleMotionEvent(event) }
            case .stopMotionUpdates:
                motion.stop()
            case .log(let line):
                logger.info("\(line, privacy: .public)")
            }
        }

        if transitioned, let transition = machine.lastTransition {
            recordTransition(transition, reason: reason)
        }
        if !effects.isEmpty {
            refreshStatus()
        }
    }

    private func recordTransition(_ transition: TrackingTransition, reason: String) {
        let record = StateTransitionRecord(timestamp: Date(),
                                           from: transition.from,
                                           to: transition.to,
                                           reason: "\(Self.describe(transition.input)) [\(reason)]",
                                           batteryLevel: Self.batteryLevel())
        status.lastTransition = record
        audit.record(AuditEvent(timestamp: record.timestamp,
                                category: .state,
                                severity: .info,
                                name: "state.transition",
                                message: "\(transition.from.rawValue) → \(transition.to.rawValue)",
                                details: [AuditDetail("from", transition.from.rawValue),
                                          AuditDetail("to", transition.to.rawValue),
                                          AuditDetail("input", Self.describe(transition.input)),
                                          AuditDetail("reason", reason)],
                                phase: transition.to,
                                batteryLevel: record.batteryLevel))
        logger.notice("transition \(transition.from.rawValue, privacy: .public) -> \(transition.to.rawValue, privacy: .public) (\(record.reason, privacy: .public))")
        Task { [store, engine, logger] in
            // Flush buffered samples on every phase change so a termination
            // right after going stationary loses nothing.
            await engine.flush()
            do {
                try await store.logTransition(record)
            } catch {
                logger.error("logTransition failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Timers

    private func startStillnessTimer(seconds: TimeInterval) {
        stillnessTask?.cancel()
        stillnessTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.stillnessTask = nil
            self.handle(.stillnessTimerFired)
        }
    }

    private func startProbeTimer(seconds: TimeInterval) {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.probeTask = nil
            self.handle(.probeTimerFired)
        }
    }

    // MARK: - Motion events

    private func handleMotionEvent(_ event: MotionEvent) {
        if settings.auditLogsMotionEvents {
            audit.record(AuditEvent(timestamp: Date(),
                                    category: .motion,
                                    severity: .debug,
                                    name: "motion.event",
                                    message: Self.describe(event),
                                    details: Self.details(for: event)))
        }
        switch event {
        case .activity(let kind, let confidence, _):
            handle(.motionActivity(kind: kind, confidence: confidence))
        case .steps(let count, _):
            if count >= Self.motionHintStepThreshold {
                handle(.motionHint, reason: "steps(\(count))")
            }
        case .accelerometerBurst(let isMoving, let magnitude, _):
            if isMoving {
                handle(.motionHint, reason: "accelerometer(\(String(format: "%.2f", magnitude))g)")
            }
        case .authorizationChanged(let auth):
            logger.notice("motion authorization: \(auth.rawValue, privacy: .public)")
            audit.record(AuditEvent(timestamp: Date(),
                                    category: .permission,
                                    severity: auth == .authorized ? .info : .warning,
                                    name: "permission.motion",
                                    message: "Motion authorization is \(auth.rawValue)",
                                    details: [AuditDetail("status", auth.rawValue),
                                              AuditDetail("activityAvailable", motion.isActivityAvailable)]))
            applyEffectiveSettings()
        }
        refreshStatus()
    }

    // MARK: - LocationEngineDelegate

    public func locationEngine(_ engine: any LocationEngineProtocol, didAccept fix: LocationFix) {
        lastFixSource = .gps
        handle(.gpsFix(speed: fix.validSpeed))
        fixesSinceStatsRefresh += 1
        if fixesSinceStatsRefresh >= Self.statsRefreshEveryFixes {
            fixesSinceStatsRefresh = 0
            scheduleStatsRefresh()
        }
        refreshStatus()
    }

    public func locationEngine(_ engine: any LocationEngineProtocol, didReject fix: LocationFix, reason: LocationRejection) {
        refreshStatus()
    }

    public func locationEngine(_ engine: any LocationEngineProtocol, didReceiveSignificantChange fix: LocationFix) {
        audit.record(AuditEvent(timestamp: Date(),
                                category: .location,
                                severity: .info,
                                name: "location.significantChange",
                                message: "Significant location change",
                                details: Self.details(for: fix)))
        lastFixSource = .significantChange
        handle(.significantChange)
        refreshStatus()
    }

    public func locationEngine(_ engine: any LocationEngineProtocol, didReceiveVisit fix: LocationFix, isArrival: Bool) {
        audit.record(AuditEvent(timestamp: Date(),
                                category: .location,
                                severity: .info,
                                name: "location.visit",
                                message: isArrival ? "Visit arrival" : "Visit departure",
                                details: [AuditDetail("isArrival", isArrival)] + Self.details(for: fix)))
        lastFixSource = .visit
        handle(.visit, reason: isArrival ? "visit arrival" : "visit departure")
        refreshStatus()
    }

    public func locationEngine(_ engine: any LocationEngineProtocol, didChangeAuthorization status: LocationAuthorization) {
        logger.notice("location authorization: \(status.rawValue, privacy: .public)")
        audit.record(AuditEvent(timestamp: Date(),
                                category: .permission,
                                severity: status.allowsBackgroundTracking ? .info : .warning,
                                name: "permission.location",
                                message: "Location authorization is \(status.rawValue)",
                                details: [AuditDetail("status", status.rawValue),
                                          AuditDetail("fullAccuracy", engine.hasFullAccuracy),
                                          AuditDetail("allowsBackgroundTracking", status.allowsBackgroundTracking)]))
        if isTrackingEnabled && !status.allowsBackgroundTracking {
            lastError = "Location permission is not \"Always\": background tracking will stop when the app is suspended."
        } else if lastError?.hasPrefix("Location permission") == true {
            lastError = nil
        }
        refreshStatus()
    }

    public func locationEngine(_ engine: any LocationEngineProtocol, didFail error: any Error) {
        logger.error("engine error: \(error.localizedDescription, privacy: .public)")
        audit.record(AuditEvent(timestamp: Date(),
                                category: .location,
                                severity: .error,
                                name: "location.error",
                                message: error.localizedDescription,
                                details: [AuditDetail("error", String(describing: error))]))
        lastError = error.localizedDescription
        refreshStatus()
    }

    // MARK: - Sessions

    private func openOrResumeSession() {
        sessionTask?.cancel()
        sessionTask = Task { [weak self, store, logger] in
            do {
                if let open = try await store.openSession() {
                    self?.currentSessionID = open.id
                    logger.info("resumed session \(open.id.uuidString, privacy: .public)")
                } else {
                    let id = try await store.beginSession(startedAt: Date())
                    self?.currentSessionID = id
                    logger.info("began session \(id.uuidString, privacy: .public)")
                }
            } catch {
                logger.error("session open failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.refreshStatus()
        }
    }

    private func closeSession() {
        sessionTask?.cancel()
        let id = currentSessionID
        currentSessionID = nil
        sessionTask = Task { [weak self, store, engine, logger] in
            await engine.flush()
            do {
                // Close the session we know about, or any session left open
                // by a previous process that was terminated.
                var target = id
                if target == nil { target = try await store.openSession()?.id }
                if let target {
                    try await store.endSession(id: target, endedAt: Date())
                    logger.info("ended session \(target.uuidString, privacy: .public)")
                }
            } catch {
                logger.error("session close failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.refreshStatus()
            await self?.refreshStats()
        }
    }

    // MARK: - Settings

    /// Settings actually fed to the machine and the engine: the user's
    /// settings, hardened when motion activity is unavailable / denied
    /// (GPS is then the only motion evidence).
    private var effectiveSettings: TrackingSettings {
        var s = settings
        let motionUsable = motion.isActivityAvailable
            && motion.authorization != .denied
            && motion.authorization != .restricted
        if !motionUsable {
            s.keepCoarseUpdatesWhileStationary = true
            s.probeTimeout = settings.probeTimeout * 2
        }
        return s
    }

    private func applyEffectiveSettings() {
        let effective = effectiveSettings
        machine.settings = effective
        engine.apply(settings: effective)
        (audit as? AuditLog)?.apply(settings: effective)
    }

    // MARK: - Annotation

    private func makeAnnotation() -> SampleAnnotation {
        SampleAnnotation(activity: machine.lastActivity,
                         activityConfidence: machine.lastActivityConfidence,
                         phase: machine.phase,
                         batteryLevel: Self.batteryLevel(),
                         batteryState: Self.batteryState(),
                         sessionID: currentSessionID,
                         profileLabel: engine.currentProfile?.label ?? machine.activeProfile?.label)
    }

    // MARK: - Status

    private func refreshStatus() {
        var s = status
        s.isEnabled = machine.phase != .disabled
        s.phase = machine.phase
        s.activeProfile = engine.currentProfile ?? machine.activeProfile
        // Falls back to the high-accuracy profile for any engine that does not
        // distinguish the two.
        s.appliedProfile = engine.appliedProfile ?? s.activeProfile
        s.lastActivity = machine.lastActivity
        s.lastActivityConfidence = machine.lastActivityConfidence
        s.lastFix = engine.lastFix
        s.lastFixSource = lastFixSource
        s.acceptedCount = engine.acceptedCount
        s.rejectedCount = engine.rejectedCount
        s.batteryLevel = Self.batteryLevel()
        s.batteryState = Self.batteryState()
        s.locationAuthorization = engine.authorization
        s.hasFullAccuracy = engine.hasFullAccuracy
        s.motionAuthorization = motion.authorization
        s.currentSessionID = currentSessionID
        s.lastError = lastError
        if s != status {
            status = s
        }
    }

    private func scheduleStatsRefresh() {
        Task { [weak self] in await self?.refreshStats() }
    }

    /// Re-read store statistics (sample / pending counts).
    public func refreshStats() async {
        do {
            let stats = try await store.stats()
            if stats != status.stats {
                status.stats = stats
            }
        } catch {
            logger.error("stats failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - App lifecycle

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.applicationDidEnterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applicationWillEnterForeground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.engine.flush() }
        })
        observers.append(center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        })
        observers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        })
    }

    /// Flush buffered samples: the process may be suspended or killed soon.
    public func applicationDidEnterBackground() async {
        await engine.flush()
    }

    public func applicationWillEnterForeground() {
        refreshStatus()
        scheduleStatsRefresh()
    }

    // MARK: - Helpers

    static func batteryLevel() -> Double? {
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Double(level) : nil
    }

    static func batteryState() -> BatteryState {
        switch UIDevice.current.batteryState {
        case .unknown: return .unknown
        case .unplugged: return .unplugged
        case .charging: return .charging
        case .full: return .full
        @unknown default: return .unknown
        }
    }

    // MARK: Audit descriptions

    /// Stable, greppable suffix for an effect's audit event name.
    static func effectName(_ effect: TrackingEffect) -> String {
        switch effect {
        case .startGPS: return "startGPS"
        case .stopGPS: return "stopGPS"
        case .startStillnessTimer: return "startStillnessTimer"
        case .cancelStillnessTimer: return "cancelStillnessTimer"
        case .startProbeTimer: return "startProbeTimer"
        case .cancelProbeTimer: return "cancelProbeTimer"
        case .startSignificantChange: return "startSignificantChange"
        case .stopSignificantChange: return "stopSignificantChange"
        case .startMotionUpdates: return "startMotionUpdates"
        case .stopMotionUpdates: return "stopMotionUpdates"
        case .log: return "log"
        }
    }

    static func describe(_ effect: TrackingEffect) -> String {
        switch effect {
        case .startGPS(let profile):
            return "start GPS \(profile.label) (\(profile.desiredAccuracy.rawValue), filter \(Int(profile.distanceFilter)) m)"
        case .stopGPS: return "stop GPS"
        case .startStillnessTimer(let seconds): return "start stillness timer \(Int(seconds)) s"
        case .cancelStillnessTimer: return "cancel stillness timer"
        case .startProbeTimer(let seconds): return "start probe timer \(Int(seconds)) s"
        case .cancelProbeTimer: return "cancel probe timer"
        case .startSignificantChange: return "start significant-change + visit monitoring"
        case .stopSignificantChange: return "stop significant-change + visit monitoring"
        case .startMotionUpdates: return "start motion updates"
        case .stopMotionUpdates: return "stop motion updates"
        case .log(let line): return "log: \(line)"
        }
    }

    static func describe(_ event: MotionEvent) -> String {
        switch event {
        case .activity(let kind, let confidence, _):
            return "Activity \(kind.rawValue) (\(confidence) confidence)"
        case .steps(let count, _):
            return "Pedometer reported \(count) steps"
        case .accelerometerBurst(let isMoving, let magnitude, _):
            return "Accelerometer burst: \(isMoving ? "moving" : "still") at \(String(format: "%.3f", locale: nil, magnitude)) g"
        case .authorizationChanged(let auth):
            return "Motion authorization \(auth.rawValue)"
        }
    }

    static func details(for event: MotionEvent) -> [AuditDetail] {
        switch event {
        case .activity(let kind, let confidence, let timestamp):
            return [AuditDetail("kind", kind.rawValue),
                    AuditDetail("confidence", String(describing: confidence)),
                    AuditDetail("reportedAt", GPXExporter.iso(timestamp))]
        case .steps(let count, let timestamp):
            return [AuditDetail("steps", count),
                    AuditDetail("reportedAt", GPXExporter.iso(timestamp))]
        case .accelerometerBurst(let isMoving, let magnitude, let timestamp):
            return [AuditDetail("isMoving", isMoving),
                    AuditDetail("peakMagnitudeG", magnitude, decimals: 3),
                    AuditDetail("reportedAt", GPXExporter.iso(timestamp))]
        case .authorizationChanged(let auth):
            return [AuditDetail("status", auth.rawValue)]
        }
    }

    /// The raw data of a fix, as recorded in the audit trail.
    static func details(for fix: LocationFix) -> [AuditDetail] {
        var out = [AuditDetail("latitude", fix.latitude, decimals: 6),
                   AuditDetail("longitude", fix.longitude, decimals: 6),
                   AuditDetail("horizontalAccuracy", fix.horizontalAccuracy),
                   AuditDetail("timestamp", GPXExporter.iso(fix.timestamp))]
        if fix.verticalAccuracy >= 0 {
            out.append(AuditDetail("altitude", fix.altitude))
            out.append(AuditDetail("verticalAccuracy", fix.verticalAccuracy))
        }
        if let speed = fix.validSpeed { out.append(AuditDetail("speed", speed)) }
        if fix.course >= 0 { out.append(AuditDetail("course", fix.course, decimals: 1)) }
        return out
    }

    static func describe(_ input: TrackingInput) -> String {
        switch input {
        case .enable: return "enable"
        case .disable: return "disable"
        case .motionActivity(let kind, let confidence):
            return "activity \(kind.rawValue)/\(confidence)"
        case .stillnessTimerFired: return "stillness timer"
        case .probeTimerFired: return "probe timer"
        case .significantChange: return "significant change"
        case .visit: return "visit"
        case .gpsFix(let speed):
            if let speed { return "fix \(String(format: "%.1f", speed)) m/s" }
            return "fix (no speed)"
        case .motionHint: return "motion hint"
        }
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
