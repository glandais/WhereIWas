import Foundation
import Testing
@testable import WhereIWas

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func fix(lat: Double = 48.8566,
                 lon: Double = 2.3522,
                 accuracy: Double = 5,
                 age: TimeInterval = 1,
                 speed: Double = -1) -> LocationFix {
    LocationFix(latitude: lat, longitude: lon, horizontalAccuracy: accuracy,
                speed: speed, timestamp: now.addingTimeInterval(-age))
}

@Suite("LocationFilter · single fix")
struct LocationFilterEvaluateTests {
    @Test("A fresh, precise fix with no predecessor is accepted")
    func accepted() {
        let r = LocationFilter.evaluate(fix(), previous: nil, now: now)
        #expect(r == .accepted)
        #expect(r.isAccepted)
    }

    @Test("Invalid horizontal accuracy is rejected", arguments: [0.0, -1.0, -100.0])
    func invalidAccuracy(accuracy: Double) {
        let r = LocationFilter.evaluate(fix(accuracy: accuracy), previous: nil, now: now)
        #expect(r == .rejected(.invalidAccuracy))
        #expect(!r.isAccepted)
    }

    @Test("Accuracy above maxHorizontalAccuracy is rejected, at the limit is accepted")
    func poorAccuracy() {
        #expect(LocationFilter.evaluate(fix(accuracy: 50), previous: nil, now: now) == .accepted)
        #expect(LocationFilter.evaluate(fix(accuracy: 50.1), previous: nil, now: now) == .rejected(.poorAccuracy(meters: 50.1)))
        #expect(LocationFilter.evaluate(fix(accuracy: 1_000), previous: nil, now: now) == .rejected(.poorAccuracy(meters: 1_000)))
    }

    @Test("maxHorizontalAccuracy comes from settings")
    func customAccuracy() {
        var s = TrackingSettings()
        s.maxHorizontalAccuracy = 10
        #expect(LocationFilter.evaluate(fix(accuracy: 10), previous: nil, now: now, settings: s) == .accepted)
        #expect(LocationFilter.evaluate(fix(accuracy: 11), previous: nil, now: now, settings: s) == .rejected(.poorAccuracy(meters: 11)))
    }

    @Test("Invalid accuracy wins over poor accuracy ordering is irrelevant, but stale beats duplicate")
    func checkOrder() {
        // A stale duplicate is reported as stale (check 4 before 6).
        let prev = fix(age: 60)
        let stale = fix(age: 40)
        #expect(LocationFilter.evaluate(stale, previous: prev, now: now) == .rejected(.stale(ageSeconds: 40)))
        // A poor-accuracy stale fix is reported as poor (check 2 before 4).
        #expect(LocationFilter.evaluate(fix(accuracy: 80, age: 40), previous: nil, now: now) == .rejected(.poorAccuracy(meters: 80)))
        // Invalid accuracy beats everything.
        #expect(LocationFilter.evaluate(fix(accuracy: 0, age: 40), previous: nil, now: now) == .rejected(.invalidAccuracy))
    }

    @Test("Stale fixes are rejected, at the limit accepted")
    func stale() {
        #expect(LocationFilter.evaluate(fix(age: 30), previous: nil, now: now) == .accepted)
        #expect(LocationFilter.evaluate(fix(age: 30.5), previous: nil, now: now) == .rejected(.stale(ageSeconds: 30.5)))
        #expect(LocationFilter.evaluate(fix(age: 3_600), previous: nil, now: now) == .rejected(.stale(ageSeconds: 3_600)))
    }

    @Test("maxSampleAge comes from settings")
    func customAge() {
        var s = TrackingSettings()
        s.maxSampleAge = 5
        #expect(LocationFilter.evaluate(fix(age: 4), previous: nil, now: now, settings: s) == .accepted)
        #expect(LocationFilter.evaluate(fix(age: 6), previous: nil, now: now, settings: s) == .rejected(.stale(ageSeconds: 6)))
    }

    @Test("Slightly-future timestamps are tolerated, far-future rejected")
    func future() {
        #expect(LocationFilter.evaluate(fix(age: -2), previous: nil, now: now) == .accepted)
        #expect(LocationFilter.evaluate(fix(age: -LocationFilter.futureTolerance), previous: nil, now: now) == .accepted)
        #expect(LocationFilter.evaluate(fix(age: -6), previous: nil, now: now) == .rejected(.futureTimestamp))
        #expect(LocationFilter.evaluate(fix(age: -3_600), previous: nil, now: now) == .rejected(.futureTimestamp))
    }

    @Test("Identical coordinates as the previous accepted fix are a duplicate")
    func duplicate() {
        let prev = fix(age: 5)
        let same = fix(age: 1)
        #expect(LocationFilter.evaluate(same, previous: prev, now: now) == .rejected(.duplicate))
    }

    @Test("A tiny move is not a duplicate with the default 0 m tolerance")
    func tinyMoveAccepted() {
        let prev = fix(age: 5)
        let moved = fix(lat: 48.8566 + 0.000001, age: 1) // ~11 cm
        #expect(LocationFilter.evaluate(moved, previous: prev, now: now) == .accepted)
    }

    @Test("duplicateDistance widens the duplicate radius")
    func duplicateDistance() {
        var s = TrackingSettings()
        s.duplicateDistance = 2
        let prev = fix(age: 5)
        let near = fix(lat: 48.8566 + 0.00001, age: 1) // ~1.1 m
        let far = fix(lat: 48.8566 + 0.0001, age: 1)   // ~11 m
        #expect(LocationFilter.evaluate(near, previous: prev, now: now, settings: s) == .rejected(.duplicate))
        #expect(LocationFilter.evaluate(far, previous: prev, now: now, settings: s) == .accepted)
    }

    @Test("Same timestamp or earlier than previous is out of order")
    func outOfOrder() {
        let prev = fix(lat: 48.0, age: 5)
        #expect(LocationFilter.evaluate(fix(lat: 48.1, age: 5), previous: prev, now: now) == .rejected(.outOfOrder))
        #expect(LocationFilter.evaluate(fix(lat: 48.1, age: 10), previous: prev, now: now) == .rejected(.outOfOrder))
        #expect(LocationFilter.evaluate(fix(lat: 48.1, age: 4.9), previous: prev, now: now) == .accepted)
    }

    @Test("Out of order is reported before duplicate")
    func outOfOrderBeatsDuplicate() {
        let prev = fix(age: 1)
        let older = fix(age: 5)
        #expect(LocationFilter.evaluate(older, previous: prev, now: now) == .rejected(.outOfOrder))
    }

    @Test("Previous fix does not affect accuracy/staleness checks")
    func previousIndependent() {
        let prev = fix(lat: 47, age: 20)
        #expect(LocationFilter.evaluate(fix(accuracy: 0, age: 1), previous: prev, now: now) == .rejected(.invalidAccuracy))
        #expect(LocationFilter.evaluate(fix(age: 40), previous: prev, now: now) == .rejected(.stale(ageSeconds: 40)))
    }
}

@Suite("LocationFilter · batch")
struct LocationFilterBatchTests {
    @Test("filter threads the last accepted fix through the batch")
    func batch() {
        let fixes = [
            fix(lat: 48.0, age: 10),                 // accepted
            fix(lat: 48.0, age: 9),                  // duplicate of #1
            fix(lat: 48.1, accuracy: 0, age: 8),     // invalid accuracy
            fix(lat: 48.1, age: 7),                  // accepted
            fix(lat: 48.2, age: 7.5),                // out of order vs #4
            fix(lat: 48.2, accuracy: 200, age: 6),   // poor accuracy
            fix(lat: 48.2, age: 5),                  // accepted
        ]
        let out = LocationFilter.filter(fixes, previous: nil, now: now)
        #expect(out.map(\.latitude) == [48.0, 48.1, 48.2])
        #expect(out == [fixes[0], fixes[3], fixes[6]])
    }

    @Test("filter respects an externally supplied previous fix")
    func batchWithPrevious() {
        let prev = fix(lat: 48.0, age: 10)
        let fixes = [fix(lat: 48.0, age: 9), fix(lat: 48.5, age: 8)]
        let out = LocationFilter.filter(fixes, previous: prev, now: now)
        #expect(out == [fixes[1]])
    }

    @Test("Empty batch yields empty output")
    func empty() {
        #expect(LocationFilter.filter([], previous: nil, now: now).isEmpty)
        #expect(LocationFilter.filter([], previous: fix(), now: now).isEmpty)
    }

    @Test("A batch of all-rejected fixes yields nothing and keeps order in accepted output")
    func allRejected() {
        let fixes = [fix(accuracy: 0), fix(age: 100), fix(age: -100)]
        #expect(LocationFilter.filter(fixes, previous: nil, now: now).isEmpty)
    }
}

@Suite("LocationFix · helpers")
struct LocationFixTests {
    @Test("validSpeed is nil for negative speed")
    func validSpeed() {
        #expect(fix(speed: -1).validSpeed == nil)
        #expect(fix(speed: 0).validSpeed == 0)
        #expect(fix(speed: 3.5).validSpeed == 3.5)
    }

    @Test("distance(to:) is zero for identical points and symmetric")
    func distanceBasics() {
        let a = fix(lat: 48.8566, lon: 2.3522)
        let b = fix(lat: 48.8606, lon: 2.3376)
        #expect(a.distance(to: a) == 0)
        #expect(abs(a.distance(to: b) - b.distance(to: a)) < 1e-6)
    }

    @Test("distance(to:) matches a known geodesic: Paris → London ≈ 343.5 km")
    func distanceKnown() {
        let paris = fix(lat: 48.8566, lon: 2.3522)
        let london = fix(lat: 51.5074, lon: -0.1278)
        let d = paris.distance(to: london)
        #expect(abs(d - 343_500) < 1_500)
    }

    @Test("One degree of latitude is about 111 km")
    func oneDegreeLatitude() {
        let d = fix(lat: 0, lon: 0).distance(to: fix(lat: 1, lon: 0))
        #expect(abs(d - 111_195) < 100)
    }
}
