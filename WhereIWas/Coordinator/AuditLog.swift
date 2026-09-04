import Foundation
import OSLog

/// Opt-in audit trail.
///
/// The audit trail answers three questions after the fact, which the normal
/// status screen cannot: what data arrived, what tests were run on it, and
/// how the state machine reacted. It is off by default
/// (``TrackingSettings/auditEnabled``) because at debug verbosity it writes
/// several rows per accepted fix.
///
/// Design:
/// - `record` is an `@autoclosure`, so a disabled log costs one boolean test
///   and the event is never even constructed.
/// - Events land in an in-memory ring buffer (instant rendering for the audit
///   screen) and in a pending batch that is flushed to SQLite by size or on
///   demand (phase change, backgrounding), so a termination loses at most the
///   current batch.
/// - Missing `phase` / `batteryLevel` are filled in from a context closure the
///   coordinator installs, so producers do not have to thread state around.
@MainActor
public final class AuditLog: AuditRecording {
    /// How many events the in-memory ring keeps for immediate display.
    public static let ringCapacity = 400
    /// Flush to storage once this many events are pending.
    public static let flushBatchSize = 40

    private let store: any LocationStoring
    private let logger = Logger(subsystem: "io.github.glandais.whereiwas", category: "audit")

    private var enabled: Bool
    private var minimumSeverity: AuditSeverity
    private var ring: [AuditEvent] = []
    private var pending: [AuditEvent] = []
    private var flushTask: Task<Void, Never>?
    /// In-flight detached write, awaited by ``flush()``.
    private var writeTask: Task<Void, Never>?
    private var droppedSinceLastFlush = 0

    /// Supplies the current phase and battery level for events that do not
    /// carry their own. Installed by the coordinator.
    public var contextProvider: @MainActor () -> (phase: TrackingPhase?, batteryLevel: Double?) = { (nil, nil) }

    public init(store: any LocationStoring, settings: TrackingSettings) {
        self.store = store
        enabled = settings.auditEnabled
        minimumSeverity = settings.auditMinimumSeverity
        ring.reserveCapacity(Self.ringCapacity)
    }

    // MARK: - AuditRecording

    public var isEnabled: Bool { enabled }

    public func record(_ event: @autoclosure () -> AuditEvent) {
        guard enabled else { return }
        var event = event()
        guard event.severity >= minimumSeverity else { return }
        if event.phase == nil || event.batteryLevel == nil {
            let context = contextProvider()
            if event.phase == nil { event.phase = context.phase }
            if event.batteryLevel == nil { event.batteryLevel = context.batteryLevel }
        }

        ring.append(event)
        if ring.count > Self.ringCapacity {
            ring.removeFirst(ring.count - Self.ringCapacity)
        }
        pending.append(event)
        if pending.count >= Self.flushBatchSize {
            flushSoon()
        }
    }

    // MARK: - Settings

    /// Applies new settings. Turning the trail off drops anything not yet
    /// written; turning it on records the change itself, so every trail
    /// starts with the reason it exists.
    public func apply(settings: TrackingSettings) {
        let wasEnabled = enabled
        enabled = settings.auditEnabled
        minimumSeverity = settings.auditMinimumSeverity

        if wasEnabled, !enabled {
            flushTask?.cancel()
            flushTask = nil
            let toWrite = pending
            pending.removeAll()
            ring.removeAll(keepingCapacity: true)
            write(toWrite)
        } else if !wasEnabled, enabled {
            record(AuditEvent(timestamp: Date(),
                              category: .lifecycle,
                              severity: .info,
                              name: "audit.enabled",
                              details: [AuditDetail("minimumSeverity", settings.auditMinimumSeverity.label),
                                        AuditDetail("retentionDays", settings.auditRetentionDays),
                                        AuditDetail("logAcceptedFixes", settings.auditLogsAcceptedFixes),
                                        AuditDetail("logFilterChecks", settings.auditLogsFilterChecks)]))
        }
    }

    // MARK: - Flushing

    private func flushSoon() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            await self?.flush()
        }
    }

    /// Writes everything buffered, including whatever a detached write
    /// (from turning the trail off) still has in flight. Safe to call when
    /// disabled or empty.
    public func flush() async {
        flushTask?.cancel()
        flushTask = nil
        await writeTask?.value
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        do {
            try await store.appendAudit(batch)
        } catch {
            droppedSinceLastFlush += batch.count
            logger.error("audit flush dropped \(batch.count) events: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fire-and-forget write, used when the trail is turned off and there is
    /// no caller left to await. Writes are chained so they keep their order,
    /// and ``flush()`` awaits the chain.
    private func write(_ batch: [AuditEvent]) {
        guard !batch.isEmpty else { return }
        let previous = writeTask
        writeTask = Task { [store, logger] in
            await previous?.value
            do {
                try await store.appendAudit(batch)
            } catch {
                logger.error("audit write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Reading

    /// Events still in memory, newest first, matching `query`. Instant, but
    /// only covers the last ``ringCapacity`` events.
    public func recent(matching query: AuditQuery = AuditQuery()) -> [AuditEvent] {
        var events = ring.reversed().filter(query.matches)
        if query.limit > 0, events.count > query.limit {
            events = Array(events.prefix(query.limit))
        }
        return events
    }

    /// Events from storage, newest first. Flushes first so the answer
    /// includes everything recorded up to now.
    public func load(matching query: AuditQuery) async throws -> [AuditEvent] {
        await flush()
        return try await store.auditEvents(matching: query)
    }

    /// Number of events on disk.
    public func storedCount() async throws -> Int {
        await flush()
        return try await store.auditCount()
    }

    /// Events dropped because a flush failed since the app started.
    public var droppedCount: Int { droppedSinceLastFlush }

    // MARK: - Maintenance

    /// Applies the audit retention window. `0` days disables audit purging.
    @discardableResult
    public func purge(retentionDays: Int, now: Date = Date()) async -> Int {
        guard retentionDays > 0 else { return 0 }
        await flush()
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        do {
            return try await store.purgeAudit(olderThan: cutoff)
        } catch {
            logger.error("audit purge failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Deletes the whole trail, memory and disk.
    @discardableResult
    public func clear() async -> Int {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll(keepingCapacity: true)
        ring.removeAll(keepingCapacity: true)
        do {
            return try await store.clearAudit()
        } catch {
            logger.error("audit clear failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}
