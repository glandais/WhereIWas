import CoreLocation
import Foundation
import os
import UIKit

/// Owner of the single `CLLocationManager` of the app.
///
/// Responsibilities (see ARCHITECTURE.md §5):
/// * configure the manager for background tracking
///   (`allowsBackgroundLocationUpdates`, no automatic pausing, indicator on);
/// * apply a ``GPSProfile`` in place (`startGPS`) or drop to coarse / off
///   (`stopGPS`) while holding a `CLBackgroundActivitySession` whenever
///   high-accuracy GPS runs;
/// * keep significant-change + visit monitoring armed while tracking is
///   enabled, because those two are what relaunch a terminated app;
/// * run every `CLLocation` through the pure ``LocationFilter``, annotate
///   accepted fixes and write them to the ``LocationStoring`` in batches;
/// * forward events (fixes, significant changes, visits, authorization,
///   errors) to its ``LocationEngineDelegate`` on the main actor.
///
/// The engine knows nothing about the state machine: the coordinator decides
/// *when* GPS runs, the engine decides *how* and records what arrives.
///
/// Threading: the manager is created on the main actor (in `init`) so
/// CoreLocation delivers its delegate callbacks on the main thread; the
/// `nonisolated` delegate methods re-enter the actor with
/// `MainActor.assumeIsolated`.
@MainActor
public final class LocationEngine: NSObject, LocationEngineProtocol {
    /// Opt-in audit sink; a no-op until the coordinator installs one.
    public var audit: any AuditRecording = NoopAuditLog()

    // MARK: Public state (LocationEngineProtocol)

    public weak var delegate: (any LocationEngineDelegate)?
    public var annotationProvider: @MainActor () -> SampleAnnotation = { SampleAnnotation() }

    public private(set) var authorization: LocationAuthorization
    public private(set) var hasFullAccuracy: Bool
    /// High-accuracy profile in force; `nil` while GPS is off or coarse.
    public private(set) var currentProfile: GPSProfile?
    public private(set) var lastFix: LocationFix?
    public private(set) var acceptedCount = 0
    public private(set) var rejectedCount = 0

    // MARK: Extra observable state (superset of the protocol)

    /// Profile actually applied to the manager, including
    /// ``GPSProfile/stationaryCoarse``; `nil` when updates are stopped.
    public private(set) var appliedProfile: GPSProfile?
    /// `true` between `startSignificantChangeMonitoring` and its stop.
    public private(set) var isMonitoringSignificantChanges = false
    /// `true` while a `CLBackgroundActivitySession` is held.
    public private(set) var hasBackgroundActivitySession = false
    /// Last rejection, for the status screen.
    public private(set) var lastRejection: LocationRejection?
    /// Battery level 0…1 (`nil` when the device does not report it).
    public private(set) var batteryLevel: Double?
    public private(set) var batteryState: BatteryState = .unknown
    /// Number of samples waiting in memory for the next batch insert.
    public var bufferedCount: Int { buffer.count }

    // MARK: Private

    private let manager: CLLocationManager
    private let store: any LocationStoring
    private var settings: TrackingSettings
    private let logger = Logger(subsystem: "io.github.glandais.whereiwas", category: "engine")

    private var backgroundSession: CLBackgroundActivitySession?
    private var buffer: [LocationSampleDraft] = []
    private var flushTask: Task<Void, Never>?
    private var wantsAlwaysUpgrade = false
    private var observers: [any NSObjectProtocol] = []

    // MARK: Init

    /// Creates and configures the `CLLocationManager` synchronously. Nothing
    /// is started; call ``rearmAfterLaunch()`` / ``startSignificantChangeMonitoring()``
    /// and ``startGPS(profile:)`` from the coordinator.
    public init(store: any LocationStoring, settings: TrackingSettings) {
        self.store = store
        self.settings = settings
        let manager = CLLocationManager()
        self.manager = manager
        self.authorization = LocationAuthorization(manager.authorizationStatus)
        self.hasFullAccuracy = manager.accuracyAuthorization == .fullAccuracy
        super.init()

        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        applyBackgroundFlags()

        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        refreshBattery()
        observeNotifications()

        logger.info("engine init auth=\(self.authorization.rawValue, privacy: .public) full=\(self.hasFullAccuracy)")
    }

    deinit {
        // `observers` are removed by NotificationCenter when the block
        // observer objects are released; nothing else to tear down.
    }

    // MARK: Authorization

    /// Requests "Always" authorization. Apple only shows the Always prompt
    /// once, and only after When-In-Use has been granted, so the flow is:
    /// notDetermined → `requestWhenInUseAuthorization`, then on the
    /// `.whenInUse` callback → `requestAlwaysAuthorization`.
    public func requestAuthorization() {
        switch authorization {
        case .notDetermined:
            wantsAlwaysUpgrade = true
            manager.requestWhenInUseAuthorization()
        case .whenInUse:
            wantsAlwaysUpgrade = false
            manager.requestAlwaysAuthorization()
        case .always, .denied, .restricted:
            // Nothing the app can do; the UI offers "Open Settings".
            break
        }
    }

    // MARK: GPS control

    public func startGPS(profile: GPSProfile) {
        if currentProfile == profile, appliedProfile == profile {
            return
        }
        applyBackgroundFlags()
        apply(profile: profile)
        currentProfile = profile
        if backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
            hasBackgroundActivitySession = true
        }
        logger.info("startGPS \(profile.label, privacy: .public) filter=\(profile.distanceFilter)")
    }

    public func stopGPS() {
        let wasOn = currentProfile != nil
        currentProfile = nil
        if settings.keepCoarseUpdatesWhileStationary {
            apply(profile: .stationaryCoarse)
        } else {
            stopUpdates()
        }
        backgroundSession?.invalidate()
        backgroundSession = nil
        hasBackgroundActivitySession = false
        if wasOn {
            logger.info("stopGPS coarse=\(self.settings.keepCoarseUpdatesWhileStationary)")
        }
        scheduleFlush()
    }

    // MARK: Significant change + visits

    public func startSignificantChangeMonitoring() {
        audit.record(AuditEvent(timestamp: Date(),
                                category: .location,
                                severity: .info,
                                name: "monitoring.started",
                                message: "Significant-change and visit monitoring armed",
                                details: [AuditDetail("significantChangeAvailable",
                                                      CLLocationManager.significantLocationChangeMonitoringAvailable())]))
        isMonitoringSignificantChanges = true
        applyBackgroundFlags()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            logger.warning("significant-change monitoring unavailable on this device")
        }
        manager.startMonitoringVisits()
        logger.info("significant-change + visit monitoring on")
    }

    public func stopSignificantChangeMonitoring() {
        isMonitoringSignificantChanges = false
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        logger.info("significant-change + visit monitoring off")
    }

    /// Launch-path entry point. Must be called synchronously from
    /// `application(_:didFinishLaunchingWithOptions:)` (through the
    /// coordinator) when the persisted "tracking enabled" flag is set: the
    /// location event that relaunched the process is only delivered to a
    /// manager that is monitoring by the time launch returns.
    ///
    /// It re-arms significant-change + visit monitoring and, when the
    /// settings ask for it, coarse updates, so that the process stays alive
    /// long enough for the coordinator to run `.enable` (→ PROBING → GPS).
    public func rearmAfterLaunch() {
        startSignificantChangeMonitoring()
        if currentProfile == nil, settings.keepCoarseUpdatesWhileStationary {
            apply(profile: .stationaryCoarse)
        }
        logger.info("re-armed after launch")
    }

    /// Tear everything down (tracking disabled). Also stops the coarse
    /// updates and flushes the buffer.
    public func stopAll() {
        currentProfile = nil
        stopUpdates()
        backgroundSession?.invalidate()
        backgroundSession = nil
        hasBackgroundActivitySession = false
        stopSignificantChangeMonitoring()
        scheduleFlush()
    }

    // MARK: Store

    public func flush() async {
        if let running = flushTask {
            await running.value
        }
        guard !buffer.isEmpty else { return }
        let task = Task { await self.drain() }
        flushTask = task
        await task.value
        if flushTask == task { flushTask = nil }
    }

    public func apply(settings: TrackingSettings) {
        let old = self.settings
        self.settings = settings
        // Coarse-mode toggle while stationary.
        if currentProfile == nil, isMonitoringSignificantChanges,
           old.keepCoarseUpdatesWhileStationary != settings.keepCoarseUpdatesWhileStationary {
            if settings.keepCoarseUpdatesWhileStationary {
                apply(profile: .stationaryCoarse)
            } else {
                stopUpdates()
            }
        }
        // The indicator flag is read by CoreLocation continuously, so a change
        // takes effect without restarting the updates.
        if old.showsLocationIndicator != settings.showsLocationIndicator {
            manager.showsBackgroundLocationIndicator = settings.showsLocationIndicator
            audit.record(AuditEvent(timestamp: Date(),
                                    category: .location,
                                    severity: .info,
                                    name: "indicator.changed",
                                    message: settings.showsLocationIndicator
                                        ? "System location indicator shown"
                                        : "System location indicator hidden",
                                    details: [AuditDetail("showsLocationIndicator",
                                                          settings.showsLocationIndicator)]))
        }
        if buffer.count >= settings.insertBatchSize {
            scheduleFlush()
        }
    }

    // MARK: - Private helpers

    private func applyBackgroundFlags() {
        // Setting `allowsBackgroundLocationUpdates` without the location
        // background mode throws an ObjC exception; project.yml declares it.
        if !manager.allowsBackgroundLocationUpdates {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.showsBackgroundLocationIndicator = settings.showsLocationIndicator
    }

    private func apply(profile: GPSProfile) {
        if appliedProfile != profile {
            audit.record(AuditEvent(timestamp: Date(),
                                    category: .location,
                                    severity: .info,
                                    name: "gps.profile",
                                    message: appliedProfile == nil
                                        ? "GPS updates started with profile \(profile.label)"
                                        : "GPS profile changed to \(profile.label)",
                                    details: [AuditDetail("from", appliedProfile?.label ?? "off"),
                                              AuditDetail("to", profile.label),
                                              AuditDetail("desiredAccuracy", profile.desiredAccuracy.rawValue),
                                              AuditDetail("distanceFilter", profile.distanceFilter),
                                              AuditDetail("activityType", String(describing: profile.activityType))]))
            manager.desiredAccuracy = profile.desiredAccuracy.clAccuracy
            manager.distanceFilter = profile.distanceFilter <= 0 ? kCLDistanceFilterNone : profile.distanceFilter
            manager.activityType = profile.activityType.clActivityType
        }
        if appliedProfile == nil {
            manager.startUpdatingLocation()
        }
        appliedProfile = profile
    }

    private func stopUpdates() {
        if appliedProfile != nil {
            manager.stopUpdatingLocation()
            audit.record(AuditEvent(timestamp: Date(),
                                    category: .location,
                                    severity: .info,
                                    name: "gps.stopped",
                                    message: "GPS updates stopped",
                                    details: [AuditDetail("from", appliedProfile?.label ?? "off")]))
        }
        appliedProfile = nil
    }

    private func scheduleFlush() {
        guard !buffer.isEmpty, flushTask == nil else { return }
        flushTask = Task { [weak self] in
            guard let self else { return }
            await self.drain()
            self.flushTask = nil
        }
    }

    /// Insert everything buffered. On failure the drafts are put back in
    /// front of the buffer so nothing is lost; the next flush retries.
    private func drain() async {
        while !buffer.isEmpty {
            let batch = buffer
            buffer.removeAll(keepingCapacity: true)
            do {
                let sequences = try await store.insert(batch)
                logger.debug("flushed \(batch.count) samples")
                audit.record(AuditEvent(timestamp: Date(),
                                        category: .persistence,
                                        severity: .debug,
                                        name: "store.insert",
                                        message: "Persisted \(batch.count) samples",
                                        details: [AuditDetail("count", batch.count),
                                                  AuditDetail("firstSequence", Int(sequences.first ?? 0)),
                                                  AuditDetail("lastSequence", Int(sequences.last ?? 0))]))
            } catch {
                buffer.insert(contentsOf: batch, at: 0)
                logger.error("insert failed: \(error.localizedDescription, privacy: .public)")
                audit.record(AuditEvent(timestamp: Date(),
                                        category: .persistence,
                                        severity: .error,
                                        name: "store.insertFailed",
                                        message: "Insert failed, \(batch.count) samples kept in memory",
                                        details: [AuditDetail("count", batch.count),
                                                  AuditDetail("error", error.localizedDescription)]))
                delegate?.locationEngine(self, didFail: error)
                return
            }
        }
    }

    private func annotate() -> SampleAnnotation {
        var annotation = annotationProvider()
        if annotation.batteryLevel == nil { annotation.batteryLevel = batteryLevel }
        if annotation.batteryState == .unknown { annotation.batteryState = batteryState }
        if annotation.profileLabel == nil { annotation.profileLabel = appliedProfile?.label }
        return annotation
    }

    private func enqueue(_ fix: LocationFix, source: LocationSource) {
        buffer.append(LocationSampleDraft(fix: fix, annotation: annotate(), source: source))
        lastFix = fix
        acceptedCount += 1
        if buffer.count >= max(1, settings.insertBatchSize) || source != .gps {
            // Event-style fixes are flushed immediately: after a background
            // relaunch the process may be suspended within seconds.
            scheduleFlush()
        }
    }

    // MARK: Incoming data

    private func handle(locations: [CLLocation]) {
        let now = Date()
        for location in locations {
            let fix = LocationFix(location)
            let previous = lastFix
            let result = LocationFilter.evaluate(fix, previous: previous, now: now, settings: settings)
            recordAudit(fix: fix, previous: previous, now: now, result: result)
            switch result {
            case .accepted:
                enqueue(fix, source: .gps)
                delegate?.locationEngine(self, didAccept: fix)
            case .rejected(let reason):
                if currentProfile == nil, case .poorAccuracy = reason {
                    // Coarse (stationary) mode: a cell-tower grade fix means
                    // we moved by roughly the 3 km filter. Treat it as a
                    // significant change so the coordinator can probe.
                    handleCoarse(fix, source: .significantChange)
                    delegate?.locationEngine(self, didReceiveSignificantChange: fix)
                } else {
                    rejectedCount += 1
                    lastRejection = reason
                    delegate?.locationEngine(self, didReject: fix, reason: reason)
                }
            }
        }
    }

    /// Writes the raw fix and the validation tests it went through to the
    /// audit trail.
    ///
    /// The trace is only computed when the trail is on and the relevant
    /// switch is set, so the hot path stays allocation-free by default.
    private func recordAudit(fix: LocationFix,
                             previous: LocationFix?,
                             now: Date,
                             result: LocationFilterResult) {
        guard audit.isEnabled else { return }
        let accepted = result.isAccepted
        guard accepted ? settings.auditLogsAcceptedFixes : settings.auditLogsRejectedFixes else { return }

        var details = TrackingCoordinator.details(for: fix)
        details.append(AuditDetail("source", LocationSource.gps.rawValue))
        if let profile = appliedProfile {
            details.append(AuditDetail("profile", profile.label))
            details.append(AuditDetail("desiredAccuracy", profile.desiredAccuracy.rawValue))
            details.append(AuditDetail("distanceFilter", profile.distanceFilter))
        }
        if let previous {
            details.append(AuditDetail("distanceFromPrevious", fix.distance(to: previous)))
        }

        var message: String
        var severity: AuditSeverity = .debug
        if case .rejected(let reason) = result {
            message = "Fix rejected: \(Self.describe(reason))"
            severity = .info
            details.append(AuditDetail("rejection", Self.describe(reason)))
        } else {
            message = "Fix accepted"
        }

        if settings.auditLogsFilterChecks {
            let trace = LocationFilter.trace(fix, previous: previous, now: now, settings: settings)
            for check in trace.checks {
                var value = check.verdict.rawValue
                if let measured = check.measured { value += " (\(measured)" }
                if let limit = check.limit { value += " vs \(limit)" }
                if check.measured != nil { value += ")" }
                details.append(AuditDetail("check.\(check.name)", value))
            }
        }

        audit.record(AuditEvent(timestamp: Date(),
                                category: accepted ? .location : .filter,
                                severity: severity,
                                name: accepted ? "fix.accepted" : "fix.rejected",
                                message: message,
                                details: details))
    }

    /// Short, stable description of a rejection reason.
    static func describe(_ reason: LocationRejection) -> String {
        switch reason {
        case .invalidAccuracy: return "invalidAccuracy"
        case .poorAccuracy(let meters): return "poorAccuracy(\(String(format: "%.1f", locale: nil, meters)) m)"
        case .stale(let age): return "stale(\(String(format: "%.1f", locale: nil, age)) s)"
        case .futureTimestamp: return "futureTimestamp"
        case .duplicate: return "duplicate"
        case .outOfOrder: return "outOfOrder"
        }
    }

    /// Relaxed acceptance for event fixes (significant change, visit,
    /// coarse update): accuracy limits do not apply (they are ~500 m by
    /// nature), but obviously invalid, out-of-order or duplicate ones are
    /// dropped. Returns `true` when persisted.
    @discardableResult
    private func handleCoarse(_ fix: LocationFix, source: LocationSource) -> Bool {
        guard fix.horizontalAccuracy > 0 else { return false }
        if let previous = lastFix {
            if fix.timestamp <= previous.timestamp { return false }
            if fix.distance(to: previous) <= settings.duplicateDistance { return false }
        }
        enqueue(fix, source: source)
        return true
    }

    private func handleSignificantChange(_ location: CLLocation) {
        let fix = LocationFix(location)
        logger.info("significant change acc=\(fix.horizontalAccuracy)")
        handleCoarse(fix, source: .significantChange)
        delegate?.locationEngine(self, didReceiveSignificantChange: fix)
    }

    private func handleVisit(_ fix: LocationFix, isArrival: Bool) {
        logger.info("visit arrival=\(isArrival) acc=\(fix.horizontalAccuracy)")
        handleCoarse(fix, source: .visit)
        delegate?.locationEngine(self, didReceiveVisit: fix, isArrival: isArrival)
    }

    private func handleAuthorizationChange() {
        authorization = LocationAuthorization(manager.authorizationStatus)
        hasFullAccuracy = manager.accuracyAuthorization == .fullAccuracy
        logger.info("authorization \(self.authorization.rawValue, privacy: .public) full=\(self.hasFullAccuracy)")
        if authorization == .whenInUse, wantsAlwaysUpgrade {
            wantsAlwaysUpgrade = false
            manager.requestAlwaysAuthorization()
        }
        if authorization == .always || authorization == .whenInUse {
            applyBackgroundFlags()
        }
        delegate?.locationEngine(self, didChangeAuthorization: authorization)
    }

    private func handle(error: any Error) {
        if let clError = error as? CLError {
            switch clError.code {
            case .locationUnknown:
                // Transient; CoreLocation keeps trying.
                logger.debug("locationUnknown (transient)")
                return
            case .denied:
                logger.error("location denied")
                handleAuthorizationChange()
            default:
                logger.error("CLError \(clError.code.rawValue)")
            }
        } else {
            logger.error("error \(error.localizedDescription, privacy: .public)")
        }
        delegate?.locationEngine(self, didFail: error)
    }

    // MARK: Battery + lifecycle notifications

    private func refreshBattery() {
        let device = UIDevice.current
        let level = Double(device.batteryLevel)
        batteryLevel = level >= 0 ? level : nil
        batteryState = BatteryState(device.batteryState)
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        let names: [(Notification.Name, @MainActor (LocationEngine) -> Void)] = [
            (UIDevice.batteryLevelDidChangeNotification, { $0.refreshBattery() }),
            (UIDevice.batteryStateDidChangeNotification, { $0.refreshBattery() }),
            (UIApplication.didEnterBackgroundNotification, { $0.scheduleFlush() }),
            (UIApplication.willTerminateNotification, { $0.scheduleFlush() }),
            (UIApplication.willResignActiveNotification, { $0.scheduleFlush() }),
        ]
        for (name, action) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self)
                }
            }
            observers.append(token)
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationEngine: CLLocationManagerDelegate {
    // The manager was created on the main thread, so every callback arrives
    // on the main thread; `assumeIsolated` re-enters the actor without a hop
    // (and traps loudly if that invariant were ever broken).

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            // While only significant-change monitoring is on (no
            // startUpdatingLocation), fixes arrive through this same
            // callback: route them as events.
            if appliedProfile == nil {
                for location in locations { handleSignificantChange(location) }
            } else {
                handle(locations: locations)
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // `CLVisit` is not `Sendable`; project it into value types in this
        // nonisolated context before re-entering the main actor.
        let fix = LocationFix(visit)
        let isArrival = visit.isArrivalEvent
        MainActor.assumeIsolated { handleVisit(fix, isArrival: isArrival) }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { handleAuthorizationChange() }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated { handle(error: error) }
    }

    nonisolated public func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            // Should never happen (pausesLocationUpdatesAutomatically = false).
            logger.warning("CoreLocation paused updates")
        }
    }

    nonisolated public func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { logger.info("CoreLocation resumed updates") }
    }
}
