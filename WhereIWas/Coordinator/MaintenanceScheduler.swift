import BackgroundTasks
import Foundation
import os

/// Registers and schedules the `BGProcessingTask` that purges samples older
/// than `TrackingSettings.retentionDays`.
///
/// `register()` must run before `application(_:didFinishLaunchingWithOptions:)`
/// returns (BackgroundTasks requirement); `AppEnvironment.bootstrap` calls
/// it. The task is re-submitted from its own handler and whenever the app
/// enters the background, so there is always exactly one pending request.
///
/// Honest limits: the system decides when (and whether) the task runs; with
/// Low Power Mode or Background App Refresh off it may never run. Purging is
/// therefore also performed at launch (`purgeAtLaunchIfNeeded`) and from the
/// Settings screen (`TrackingControlling.purgeNow`).
@MainActor
public final class MaintenanceScheduler {
    public static let taskIdentifier = "io.github.glandais.whereiwas.maintenance"

    /// Minimum delay before the next maintenance run (the system treats it
    /// as a lower bound only).
    public static let interval: TimeInterval = 12 * 3_600

    private static let lastPurgeKey = "whereiwas.lastPurgeAt"

    private let logger = Logger(subsystem: "io.github.glandais.whereiwas", category: "coordinator")
    private let defaults: UserDefaults
    private let purge: @MainActor () async throws -> Int
    private var registered = false

    /// - Parameter purge: the work to perform (normally `coordinator.purgeNow`).
    public init(defaults: UserDefaults = .standard, purge: @escaping @MainActor () async throws -> Int) {
        self.defaults = defaults
        self.purge = purge
    }

    /// Register the launch handler. Must be called during app launch.
    public func register() {
        guard !registered else { return }
        registered = true
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier,
                                                 using: .main) { task in
            // `using: .main` guarantees we are on the main queue.
            MainActor.assumeIsolated {
                guard let processing = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handle(processing)
            }
        }
        if !ok {
            logger.error("BGTaskScheduler.register failed for \(Self.taskIdentifier, privacy: .public)")
        }
    }

    /// Submit (or replace) the pending request.
    public func schedule() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.interval)
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.debug("maintenance task scheduled")
        } catch {
            // Expected on the simulator and when the identifier is missing
            // from BGTaskSchedulerPermittedIdentifiers.
            logger.error("maintenance submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fallback for devices where the processing task never runs: purge at
    /// launch when the last purge is older than ``interval``.
    public func purgeAtLaunchIfNeeded() {
        let last = defaults.object(forKey: Self.lastPurgeKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.interval else { return }
        Task { await self.runPurge() }
    }

    @discardableResult
    private func runPurge() async -> Bool {
        do {
            let deleted = try await purge()
            defaults.set(Date(), forKey: Self.lastPurgeKey)
            logger.notice("maintenance purge deleted \(deleted) samples")
            return true
        } catch {
            logger.error("maintenance purge failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func handle(_ task: BGProcessingTask) {
        schedule() // Always keep one request pending.
        let run = MaintenanceRun(task: task)
        run.start { [weak self] in
            await self?.runPurge() ?? false
        }
    }
}

/// One execution of the processing task. Keeps the non-`Sendable` `BGTask`
/// confined to the main actor and guarantees `setTaskCompleted` is called
/// exactly once (normal end or expiration).
@MainActor
private final class MaintenanceRun {
    private let task: BGProcessingTask
    private var work: Task<Void, Never>?
    private var completed = false

    init(task: BGProcessingTask) {
        self.task = task
    }

    func start(_ body: @escaping @MainActor () async -> Bool) {
        task.expirationHandler = { [self] in
            Task { @MainActor in self.expire() }
        }
        work = Task { [self] in
            let ok = await body()
            complete(success: ok && !Task.isCancelled)
        }
    }

    private func expire() {
        work?.cancel()
        complete(success: false)
    }

    private func complete(success: Bool) {
        guard !completed else { return }
        completed = true
        task.setTaskCompleted(success: success)
    }
}
