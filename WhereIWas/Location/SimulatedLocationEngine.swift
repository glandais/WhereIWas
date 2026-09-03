import Foundation

/// A ``LocationEngineProtocol`` with no CoreLocation behind it.
///
/// Used by SwiftUI previews, the simulator and coordinator tests: the test
/// injects fixes / events with the `simulate…` methods and the engine
/// behaves exactly like ``LocationEngine`` from the coordinator's point of
/// view (filtering, annotation, batching into the store, delegate calls,
/// call recording).
@MainActor
public final class SimulatedLocationEngine: LocationEngineProtocol {
    /// Opt-in audit sink; a no-op until the coordinator installs one.
    public var audit: any AuditRecording = NoopAuditLog()

    public weak var delegate: (any LocationEngineDelegate)?
    public var annotationProvider: @MainActor () -> SampleAnnotation = { SampleAnnotation() }

    public private(set) var authorization: LocationAuthorization
    public private(set) var hasFullAccuracy: Bool
    public private(set) var currentProfile: GPSProfile?
    public private(set) var lastFix: LocationFix?
    public private(set) var acceptedCount = 0
    public private(set) var rejectedCount = 0

    /// Profile applied including the coarse one; mirrors `LocationEngine.appliedProfile`.
    public private(set) var appliedProfile: GPSProfile?
    public private(set) var isMonitoringSignificantChanges = false
    public private(set) var hasBackgroundActivitySession = false
    /// Every protocol call, in order, for assertions.
    public private(set) var calls: [String] = []
    public var bufferedCount: Int { buffer.count }

    /// Authorization granted when `requestAuthorization()` is called.
    public var authorizationToGrant: LocationAuthorization = .always
    /// Clock used for filtering (defaults to wall clock).
    public var now: @MainActor () -> Date = { Date() }

    private let store: any LocationStoring
    private var settings: TrackingSettings
    private var buffer: [LocationSampleDraft] = []

    public init(store: any LocationStoring = InMemoryLocationStore(),
                settings: TrackingSettings = TrackingSettings(),
                authorization: LocationAuthorization = .notDetermined,
                hasFullAccuracy: Bool = true) {
        self.store = store
        self.settings = settings
        self.authorization = authorization
        self.hasFullAccuracy = hasFullAccuracy
    }

    // MARK: LocationEngineProtocol

    public func requestAuthorization() {
        calls.append("requestAuthorization")
        simulateAuthorization(authorizationToGrant)
    }

    public func startGPS(profile: GPSProfile) {
        calls.append("startGPS(\(profile.label))")
        currentProfile = profile
        appliedProfile = profile
        hasBackgroundActivitySession = true
    }

    public func stopGPS() {
        calls.append("stopGPS")
        currentProfile = nil
        appliedProfile = settings.keepCoarseUpdatesWhileStationary ? .stationaryCoarse : nil
        hasBackgroundActivitySession = false
        Task { await flush() }
    }

    public func startSignificantChangeMonitoring() {
        calls.append("startSignificantChangeMonitoring")
        isMonitoringSignificantChanges = true
    }

    public func stopSignificantChangeMonitoring() {
        calls.append("stopSignificantChangeMonitoring")
        isMonitoringSignificantChanges = false
    }

    public func rearmAfterLaunch() {
        calls.append("rearmAfterLaunch")
        startSignificantChangeMonitoring()
        if currentProfile == nil, settings.keepCoarseUpdatesWhileStationary {
            appliedProfile = .stationaryCoarse
        }
    }

    public func stopAll() {
        calls.append("stopAll")
        currentProfile = nil
        appliedProfile = nil
        hasBackgroundActivitySession = false
        isMonitoringSignificantChanges = false
        Task { await flush() }
    }

    public func flush() async {
        calls.append("flush")
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll()
        do {
            _ = try await store.insert(batch)
        } catch {
            buffer.insert(contentsOf: batch, at: 0)
            delegate?.locationEngine(self, didFail: error)
        }
    }

    public func apply(settings: TrackingSettings) {
        calls.append("apply(settings)")
        self.settings = settings
    }

    // MARK: Simulation entry points

    /// Feed a fix as if `didUpdateLocations` delivered it. Returns the
    /// filter result so tests can assert on it.
    @discardableResult
    public func simulateFix(_ fix: LocationFix) -> LocationFilterResult {
        let result = LocationFilter.evaluate(fix, previous: lastFix, now: now(), settings: settings)
        switch result {
        case .accepted:
            enqueue(fix, source: .gps)
            delegate?.locationEngine(self, didAccept: fix)
        case .rejected(let reason):
            rejectedCount += 1
            delegate?.locationEngine(self, didReject: fix, reason: reason)
        }
        return result
    }

    /// Feed a whole route (e.g. for a preview map), spacing timestamps by `interval`.
    public func simulateRoute(_ coordinates: [(latitude: Double, longitude: Double)],
                              from start: Date,
                              interval: TimeInterval = 5,
                              speed: Double = 1.4,
                              accuracy: Double = 8) {
        for (index, coordinate) in coordinates.enumerated() {
            simulateFix(LocationFix(latitude: coordinate.latitude,
                                    longitude: coordinate.longitude,
                                    altitude: 100,
                                    horizontalAccuracy: accuracy,
                                    verticalAccuracy: 10,
                                    speed: speed,
                                    speedAccuracy: 0.5,
                                    course: 90,
                                    timestamp: start.addingTimeInterval(Double(index) * interval)))
        }
    }

    public func simulateSignificantChange(_ fix: LocationFix) {
        enqueue(fix, source: .significantChange)
        delegate?.locationEngine(self, didReceiveSignificantChange: fix)
    }

    public func simulateVisit(_ fix: LocationFix, isArrival: Bool) {
        enqueue(fix, source: .visit)
        delegate?.locationEngine(self, didReceiveVisit: fix, isArrival: isArrival)
    }

    public func simulateAuthorization(_ status: LocationAuthorization, fullAccuracy: Bool? = nil) {
        authorization = status
        if let fullAccuracy { hasFullAccuracy = fullAccuracy }
        delegate?.locationEngine(self, didChangeAuthorization: status)
    }

    public func simulateError(_ error: any Error) {
        delegate?.locationEngine(self, didFail: error)
    }

    // MARK: Private

    private func enqueue(_ fix: LocationFix, source: LocationSource) {
        var annotation = annotationProvider()
        if annotation.profileLabel == nil { annotation.profileLabel = appliedProfile?.label }
        buffer.append(LocationSampleDraft(fix: fix, annotation: annotation, source: source))
        lastFix = fix
        acceptedCount += 1
        if buffer.count >= max(1, settings.insertBatchSize) || source != .gps {
            Task { await flush() }
        }
    }
}
