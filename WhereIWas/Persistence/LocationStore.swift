import Foundation
import OSLog
import SwiftData

/// SQLite-backed implementation of ``LocationStoring`` (a `@ModelActor`).
///
/// All work happens on the actor's own `ModelContext`; only `Sendable` DTOs
/// cross the boundary. Every mutating call saves explicitly, so a crash right
/// after the call cannot lose the batch.
@ModelActor
actor LocationStore: LocationStoring {
    private static let log = Logger(subsystem: "io.github.glandais.whereiwas", category: "store")

    /// Next `sequence` to hand out; `nil` until seeded from the store.
    private var nextSequence: Int64?

    // MARK: - Container factory

    /// Every model the store knows about (one place to keep in sync).
    static let schema = Schema([LocationSample.self, TrackingSession.self,
                                StateTransitionLog.self, AuditEventLog.self])

    /// On-disk location of the SQLite store (Application Support).
    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("WhereIWas.store")
    }

    /// Creates the app's `ModelContainer`. `inMemory: true` is for tests and
    /// previews (`isStoredInMemoryOnly`).
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration("WhereIWasInMemory", schema: schema, isStoredInMemoryOnly: true)
        } else {
            let url = storeURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            configuration = ModelConfiguration("WhereIWas", schema: schema, url: url)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - Sequence allocation

    private func allocateSequences(_ count: Int) throws -> [Int64] {
        if nextSequence == nil {
            var descriptor = FetchDescriptor<LocationSample>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.sequence]
            nextSequence = (try modelContext.fetch(descriptor).first?.sequence ?? 0) + 1
        }
        guard var next = nextSequence, count > 0 else { return [] }
        let assigned = Array(next..<(next + Int64(count)))
        next += Int64(count)
        nextSequence = next
        return assigned
    }

    // MARK: - Samples

    func insert(_ drafts: [LocationSampleDraft]) throws -> [Int64] {
        guard !drafts.isEmpty else { return [] }
        let sequences = try allocateSequences(drafts.count)
        let now = Date()
        var sessions: [UUID: TrackingSession] = [:]
        for (draft, sequence) in zip(drafts, sequences) {
            modelContext.insert(LocationSample(sequence: sequence, draft: draft, createdAt: now))
            if let sessionID = draft.annotation.sessionID {
                let session: TrackingSession?
                if let cached = sessions[sessionID] {
                    session = cached
                } else {
                    session = try fetchSession(id: sessionID)
                    sessions[sessionID] = session
                }
                session?.append(draft.fix)
            }
        }
        do {
            try modelContext.save()
        } catch {
            // Do not burn sequences we could not persist.
            modelContext.rollback()
            nextSequence = sequences.first
            Self.log.error("insert failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return sequences
    }

    func pendingUpload(limit: Int) throws -> [StoredLocationSample] {
        var descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { $0.uploaded == false },
            sortBy: [SortDescriptor(\.sequence, order: .forward)])
        if limit > 0 { descriptor.fetchLimit = limit }
        return try modelContext.fetch(descriptor).map(\.stored)
    }

    func markUploaded(sequences: [Int64]) throws {
        guard !sequences.isEmpty else { return }
        let set = sequences
        let descriptor = FetchDescriptor<LocationSample>(predicate: #Predicate { set.contains($0.sequence) })
        for sample in try modelContext.fetch(descriptor) {
            sample.uploaded = true
        }
        try modelContext.save()
    }

    func samples(in interval: DateInterval) throws -> [StoredLocationSample] {
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.sequence, order: .forward)])
        return try modelContext.fetch(descriptor).map(\.stored)
    }

    func samples(sessionID: UUID) throws -> [StoredLocationSample] {
        let descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.sequence, order: .forward)])
        return try modelContext.fetch(descriptor).map(\.stored)
    }

    /// Every sample, ordered by sequence (used by "export everything").
    func allSamples() throws -> [StoredLocationSample] {
        let descriptor = FetchDescriptor<LocationSample>(sortBy: [SortDescriptor(\.sequence, order: .forward)])
        return try modelContext.fetch(descriptor).map(\.stored)
    }

    func latestSample() throws -> StoredLocationSample? {
        var descriptor = FetchDescriptor<LocationSample>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.stored
    }

    func purge(olderThan date: Date) throws -> Int {
        let samplePredicate = #Predicate<LocationSample> { $0.timestamp < date }
        let count = try modelContext.fetchCount(FetchDescriptor<LocationSample>(predicate: samplePredicate))
        try modelContext.delete(model: LocationSample.self, where: samplePredicate)
        try modelContext.delete(model: StateTransitionLog.self, where: #Predicate { $0.timestamp < date })
        try modelContext.save()
        Self.log.info("purged \(count) samples older than \(date, privacy: .public)")
        return count
    }

    func stats() throws -> StoreStats {
        let total = try modelContext.fetchCount(FetchDescriptor<LocationSample>())
        let pending = try modelContext.fetchCount(
            FetchDescriptor<LocationSample>(predicate: #Predicate { $0.uploaded == false }))
        var oldest = FetchDescriptor<LocationSample>(sortBy: [SortDescriptor(\.timestamp, order: .forward)])
        oldest.fetchLimit = 1
        var newest = FetchDescriptor<LocationSample>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        newest.fetchLimit = 1
        let sessionCount = try modelContext.fetchCount(FetchDescriptor<TrackingSession>())
        return StoreStats(totalSamples: total,
                          pendingUpload: pending,
                          oldestSample: try modelContext.fetch(oldest).first?.timestamp,
                          newestSample: try modelContext.fetch(newest).first?.timestamp,
                          sessionCount: sessionCount)
    }

    /// Number of samples whose fix timestamp is at or after `date`
    /// (the status screen's "today" counter).
    func sampleCount(since date: Date) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<LocationSample>(predicate: #Predicate { $0.timestamp >= date }))
    }

    // MARK: - Sessions

    private func fetchSession(id: UUID) throws -> TrackingSession? {
        var descriptor = FetchDescriptor<TrackingSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func beginSession(startedAt: Date) throws -> UUID {
        let session = TrackingSession(startedAt: startedAt)
        modelContext.insert(session)
        try modelContext.save()
        return session.id
    }

    func endSession(id: UUID, endedAt: Date) throws {
        guard let session = try fetchSession(id: id) else { return }
        session.endedAt = endedAt
        try modelContext.save()
    }

    func openSession() throws -> TrackingSessionSummary? {
        var descriptor = FetchDescriptor<TrackingSession>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.summary
    }

    func sessions() throws -> [TrackingSessionSummary] {
        let descriptor = FetchDescriptor<TrackingSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map(\.summary)
    }

    // MARK: - Transition log

    func logTransition(_ record: StateTransitionRecord) throws {
        modelContext.insert(StateTransitionLog(record: record))
        try modelContext.save()
    }

    func recentTransitions(limit: Int) throws -> [StateTransitionRecord] {
        var descriptor = FetchDescriptor<StateTransitionLog>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        if limit > 0 { descriptor.fetchLimit = limit }
        return try modelContext.fetch(descriptor).map(\.record)
    }

    // MARK: - Audit trail

    func appendAudit(_ events: [AuditEvent]) throws {
        guard !events.isEmpty else { return }
        for event in events {
            modelContext.insert(AuditEventLog(event: event))
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            Self.log.error("audit append failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func auditEvents(matching query: AuditQuery) throws -> [AuditEvent] {
        // Severity and interval are pushed into SQLite; the category set is
        // applied in memory because `#Predicate` cannot capture a `Set` of a
        // custom enum. The severity/interval bounds already keep the fetch
        // small, and `limit` is applied after filtering so a category filter
        // still returns a full page.
        let minSeverity = query.minimumSeverity.rawValue
        let start = query.interval?.start ?? Date.distantPast
        let end = query.interval?.end ?? Date.distantFuture
        var descriptor = FetchDescriptor<AuditEventLog>(
            predicate: #Predicate { $0.severityRaw >= minSeverity && $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        if query.categories == nil, query.limit > 0 {
            descriptor.fetchLimit = query.limit
        }
        var events = try modelContext.fetch(descriptor).map(\.event)
        if let categories = query.categories {
            events = events.filter { categories.contains($0.category) }
            if query.limit > 0, events.count > query.limit {
                events = Array(events.prefix(query.limit))
            }
        }
        return events
    }

    func auditCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<AuditEventLog>())
    }

    func purgeAudit(olderThan date: Date) throws -> Int {
        let predicate = #Predicate<AuditEventLog> { $0.timestamp < date }
        let count = try modelContext.fetchCount(FetchDescriptor<AuditEventLog>(predicate: predicate))
        guard count > 0 else { return 0 }
        try modelContext.delete(model: AuditEventLog.self, where: predicate)
        try modelContext.save()
        Self.log.info("purged \(count) audit events older than \(date, privacy: .public)")
        return count
    }

    func clearAudit() throws -> Int {
        let count = try modelContext.fetchCount(FetchDescriptor<AuditEventLog>())
        guard count > 0 else { return 0 }
        try modelContext.delete(model: AuditEventLog.self)
        try modelContext.save()
        return count
    }
}
