import Foundation
import Testing
@testable import WhereIWas

@Suite("LocationStore (in-memory SwiftData)")
struct LocationStoreTests {
    private func makeStore() throws -> LocationStore {
        LocationStore(modelContainer: try LocationStore.makeContainer(inMemory: true))
    }

    private func fix(lat: Double = 48.85, lon: Double = 2.35, at date: Date, speed: Double = 1.2) -> LocationFix {
        LocationFix(latitude: lat, longitude: lon, altitude: 35,
                    horizontalAccuracy: 5, verticalAccuracy: 8,
                    speed: speed, speedAccuracy: 0.5, course: 90, timestamp: date)
    }

    private func draft(lat: Double = 48.85, lon: Double = 2.35, at date: Date,
                       session: UUID? = nil, activity: ActivityKind = .walking,
                       source: LocationSource = .gps) -> LocationSampleDraft {
        LocationSampleDraft(fix: fix(lat: lat, lon: lon, at: date),
                            annotation: SampleAnnotation(activity: activity,
                                                         activityConfidence: .high,
                                                         phase: .moving,
                                                         batteryLevel: 0.8,
                                                         batteryState: .unplugged,
                                                         sessionID: session,
                                                         profileLabel: "walking"),
                            source: source)
    }

    @Test("insert assigns monotonically increasing sequences and round-trips every field")
    func insertRoundTrip() async throws {
        let store = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let drafts = (0..<5).map { draft(lat: 48.85 + Double($0) * 0.001, at: t0.addingTimeInterval(Double($0))) }
        let seqs = try await store.insert(drafts)
        #expect(seqs == [1, 2, 3, 4, 5])

        let more = try await store.insert([draft(at: t0.addingTimeInterval(10))])
        #expect(more == [6])

        let all = try await store.pendingUpload(limit: 100)
        #expect(all.count == 6)
        #expect(all.map(\.sequence) == [1, 2, 3, 4, 5, 6])
        let first = try #require(all.first)
        #expect(first.fix == drafts[0].fix)
        #expect(first.annotation == drafts[0].annotation)
        #expect(first.source == .gps)
        #expect(first.uploaded == false)
    }

    @Test("sequence continues after the max stored value (new store instance on same container)")
    func sequenceSeededFromStore() async throws {
        let container = try LocationStore.makeContainer(inMemory: true)
        let t0 = Date()
        let a = LocationStore(modelContainer: container)
        _ = try await a.insert([draft(at: t0), draft(at: t0.addingTimeInterval(1))])
        let b = LocationStore(modelContainer: container)
        let seqs = try await b.insert([draft(at: t0.addingTimeInterval(2))])
        #expect(seqs == [3])
    }

    @Test("empty insert is a no-op")
    func emptyInsert() async throws {
        let store = try makeStore()
        #expect(try await store.insert([]).isEmpty)
        #expect(try await store.stats().totalSamples == 0)
    }

    @Test("pendingUpload honours limit and ordering; markUploaded flips the flag")
    func pendingAndMarkUploaded() async throws {
        let store = try makeStore()
        let t0 = Date()
        _ = try await store.insert((0..<10).map { draft(at: t0.addingTimeInterval(Double($0))) })

        let batch = try await store.pendingUpload(limit: 4)
        #expect(batch.map(\.sequence) == [1, 2, 3, 4])

        try await store.markUploaded(sequences: batch.map(\.sequence))
        let next = try await store.pendingUpload(limit: 4)
        #expect(next.map(\.sequence) == [5, 6, 7, 8])

        let stats = try await store.stats()
        #expect(stats.totalSamples == 10)
        #expect(stats.pendingUpload == 6)

        try await store.markUploaded(sequences: [])
        #expect(try await store.stats().pendingUpload == 6)
    }

    @Test("samples(in:) filters on fix timestamp inclusively and orders by sequence")
    func samplesInInterval() async throws {
        let store = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.insert((0..<10).map { draft(at: t0.addingTimeInterval(Double($0) * 60)) })
        let interval = DateInterval(start: t0.addingTimeInterval(120), end: t0.addingTimeInterval(300))
        let result = try await store.samples(in: interval)
        #expect(result.map(\.sequence) == [3, 4, 5, 6])
    }

    @Test("sessions: begin/end/open, per-session samples, cached count and distance")
    func sessions() async throws {
        let store = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let s1 = try await store.beginSession(startedAt: t0)
        let open = try #require(try await store.openSession())
        #expect(open.id == s1)
        #expect(open.endedAt == nil)

        // ~111 m north per 0.001 deg latitude.
        _ = try await store.insert([
            draft(lat: 48.850, at: t0.addingTimeInterval(1), session: s1),
            draft(lat: 48.851, at: t0.addingTimeInterval(2), session: s1),
            draft(lat: 48.852, at: t0.addingTimeInterval(3), session: s1),
            draft(lat: 48.900, at: t0.addingTimeInterval(4), session: nil),
        ])
        let inSession = try await store.samples(sessionID: s1)
        #expect(inSession.map(\.sequence) == [1, 2, 3])

        try await store.endSession(id: s1, endedAt: t0.addingTimeInterval(10))
        #expect(try await store.openSession() == nil)

        let s2 = try await store.beginSession(startedAt: t0.addingTimeInterval(20))
        let list = try await store.sessions()
        #expect(list.map(\.id) == [s2, s1])
        let summary = try #require(list.last)
        #expect(summary.sampleCount == 3)
        #expect(summary.endedAt == t0.addingTimeInterval(10))
        #expect(summary.distanceMeters > 200 && summary.distanceMeters < 250)
        #expect(try await store.stats().sessionCount == 2)
    }

    @Test("latestSample returns the highest sequence")
    func latest() async throws {
        let store = try makeStore()
        #expect(try await store.latestSample() == nil)
        let t0 = Date()
        _ = try await store.insert([draft(lat: 1, at: t0), draft(lat: 2, at: t0.addingTimeInterval(1))])
        let latest = try #require(try await store.latestSample())
        #expect(latest.sequence == 2)
        #expect(latest.fix.latitude == 2)
    }

    @Test("purge deletes old samples and transitions, keeps sessions, returns count")
    func purge() async throws {
        let store = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let session = try await store.beginSession(startedAt: t0)
        _ = try await store.insert((0..<6).map { draft(at: t0.addingTimeInterval(Double($0) * 3600), session: session) })
        try await store.logTransition(StateTransitionRecord(timestamp: t0, from: .disabled, to: .probing, reason: "enable"))
        try await store.logTransition(StateTransitionRecord(timestamp: t0.addingTimeInterval(5 * 3600),
                                                            from: .probing, to: .moving, reason: "gpsFix"))

        let cutoff = t0.addingTimeInterval(3 * 3600)
        let deleted = try await store.purge(olderThan: cutoff)
        #expect(deleted == 3)

        let stats = try await store.stats()
        #expect(stats.totalSamples == 3)
        #expect(stats.pendingUpload == 3)
        #expect(stats.oldestSample == cutoff)
        #expect(stats.newestSample == t0.addingTimeInterval(5 * 3600))
        #expect(stats.sessionCount == 1)

        let transitions = try await store.recentTransitions(limit: 10)
        #expect(transitions.count == 1)
        #expect(transitions.first?.reason == "gpsFix")

        // Sequences keep increasing after a purge.
        let seqs = try await store.insert([draft(at: t0.addingTimeInterval(10 * 3600))])
        #expect(seqs == [7])
    }

    @Test("transition log is newest first and honours limit")
    func transitions() async throws {
        let store = try makeStore()
        let t0 = Date()
        for i in 0..<5 {
            try await store.logTransition(StateTransitionRecord(timestamp: t0.addingTimeInterval(Double(i)),
                                                                from: .stationary, to: .moving,
                                                                reason: "r\(i)", batteryLevel: 0.5))
        }
        let recent = try await store.recentTransitions(limit: 3)
        #expect(recent.map(\.reason) == ["r4", "r3", "r2"])
        #expect(recent.first?.batteryLevel == 0.5)
    }

    @Test("stats on an empty store and sampleCount(since:)")
    func statsEmptyAndSince() async throws {
        let store = try makeStore()
        let empty = try await store.stats()
        #expect(empty == StoreStats())
        let t0 = Date()
        _ = try await store.insert([draft(at: t0.addingTimeInterval(-7200)), draft(at: t0.addingTimeInterval(-60)), draft(at: t0)])
        #expect(try await store.sampleCount(since: t0.addingTimeInterval(-3600)) == 2)
    }
}
