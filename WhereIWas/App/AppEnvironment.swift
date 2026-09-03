import Foundation
import os
import SwiftData

/// Composition root: builds and owns the long-lived singletons.
///
/// Created lazily on first access, which happens in
/// `AppDelegate.application(_:didFinishLaunchingWithOptions:)` — i.e. before
/// any SwiftUI view. Construction is synchronous so the location manager is
/// re-armed in the launch run-loop turn (see ARCHITECTURE.md §5).
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let store: any LocationStoring
    let engine: any LocationEngineProtocol
    let motion: any MotionMonitoring
    let coordinator: TrackingCoordinator
    /// Opt-in audit trail, shared by the engine, the monitor and the coordinator.
    let audit: AuditLog
    let maintenance: MaintenanceScheduler

    /// What the UI sees.
    var trackingController: any TrackingControlling { coordinator }

    private let logger = Logger(subsystem: "io.github.glandais.whereiwas", category: "coordinator")
    private var bootstrapped = false

    private init() {
        let defaults = UserDefaults.standard
        let settings = TrackingSettings.load(from: defaults)

        let store: any LocationStoring
        do {
            let container = try LocationStore.makeContainer(inMemory: false)
            store = LocationStore(modelContainer: container)
        } catch {
            // A corrupt store must not brick tracking: fall back to memory
            // and surface the problem in the log.
            logger.fault("on-disk store unavailable, using in-memory store: \(error.localizedDescription, privacy: .public)")
            if let container = try? LocationStore.makeContainer(inMemory: true) {
                store = LocationStore(modelContainer: container)
            } else {
                store = InMemoryLocationStore()
            }
        }
        self.store = store

        let audit = AuditLog(store: store, settings: settings)
        self.audit = audit

        let engine = LocationEngine(store: store, settings: settings)
        let motion = MotionMonitor()
        self.engine = engine
        self.motion = motion

        let coordinator = TrackingCoordinator(store: store,
                                              engine: engine,
                                              motion: motion,
                                              settings: settings,
                                              defaults: defaults,
                                              audit: audit)
        self.coordinator = coordinator
        self.maintenance = MaintenanceScheduler(defaults: defaults) {
            try await coordinator.purgeNow()
        }
    }

    /// Called from `AppDelegate` at launch, before any view exists.
    ///
    /// Order matters: BGTask registration must happen before launch
    /// completes, and the coordinator must re-arm `CLLocationManager` in
    /// this same turn so the launch location event is delivered.
    func bootstrap(launchedForLocation: Bool) {
        guard !bootstrapped else { return }
        bootstrapped = true
        maintenance.register()
        coordinator.bootstrap(launchedForLocation: launchedForLocation)
        maintenance.schedule()
        maintenance.purgeAtLaunchIfNeeded()
    }

    /// Keep one maintenance request pending whenever we go to background,
    /// and write out whatever the audit trail still holds in memory.
    func didEnterBackground() {
        maintenance.schedule()
        Task { [audit] in await audit.flush() }
    }
}
