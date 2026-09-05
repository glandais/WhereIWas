import Foundation
import Testing
@testable import WhereIWas

@Suite("GPSProfile · activity table")
struct GPSProfileActivityTests {
    @Test("walking → best / 10 m / fitness")
    func walking() {
        let p = GPSProfile.profile(for: .walking, speed: nil)
        #expect(p == GPSProfile(desiredAccuracy: .best, distanceFilter: 10, activityType: .fitness, label: "walking"))
    }

    @Test("running and cycling → best / 20 m / fitness", arguments: [ActivityKind.running, .cycling])
    func runningCycling(kind: ActivityKind) {
        let p = GPSProfile.profile(for: kind, speed: 1)
        #expect(p.desiredAccuracy == .best)
        #expect(p.distanceFilter == 20)
        #expect(p.activityType == .fitness)
        #expect(p.label == kind.rawValue)
    }

    @Test("automotive → bestForNavigation / 50 m / automotiveNavigation regardless of speed",
          arguments: [nil, -1.0, 0.0, 3.0, 30.0] as [Double?])
    func automotive(speed: Double?) {
        let p = GPSProfile.profile(for: .automotive, speed: speed)
        #expect(p == GPSProfile(desiredAccuracy: .bestForNavigation, distanceFilter: 50,
                                activityType: .automotiveNavigation, label: "automotive"))
    }

    @Test("unknown / stationary without speed → best / 10 m / other",
          arguments: [ActivityKind.unknown, .stationary], [nil, -1.0, -0.01] as [Double?])
    func unknownNoSpeed(kind: ActivityKind, speed: Double?) {
        let p = GPSProfile.profile(for: kind, speed: speed)
        #expect(p == GPSProfile(desiredAccuracy: .best, distanceFilter: 10, activityType: .other, label: "unknown"))
    }

    @Test("Activity labels are distinct and non-empty")
    func labels() {
        let labels = ActivityKind.allCases.map { GPSProfile.profile(for: $0, speed: nil).label }
        #expect(labels.allSatisfy { !$0.isEmpty })
        // unknown and stationary intentionally share the "unknown" label.
        #expect(Set(labels).count == ActivityKind.allCases.count - 1)
    }
}

@Suite("GPSProfile · speed tiers")
struct GPSProfileSpeedTests {
    @Test("Speed tiers for unknown activity",
          arguments: [
            (0.0, 10.0, AccuracyLevel.best, "slow-unknown"),
            (2.49, 10.0, .best, "slow-unknown"),
            (2.5, 20.0, .best, "fast-unknown"),
            (6.99, 20.0, .best, "fast-unknown"),
            (7.0, 50.0, .bestForNavigation, "automotive"),
            (40.0, 50.0, .bestForNavigation, "automotive"),
          ] as [(Double, Double, AccuracyLevel, String)])
    func unknownTiers(speed: Double, filter: Double, accuracy: AccuracyLevel, label: String) {
        let p = GPSProfile.profile(for: .unknown, speed: speed)
        #expect(p.distanceFilter == filter)
        #expect(p.desiredAccuracy == accuracy)
        #expect(p.label == label)
    }

    @Test("Threshold constants match the documented tiers")
    func thresholds() {
        #expect(GPSProfile.runningSpeedThreshold == 2.5)
        #expect(GPSProfile.vehicleSpeedThreshold == 7.0)
        #expect(GPSProfile.cyclingVehicleSpeedThreshold == 12.5)
        #expect(GPSProfile.runningSpeedThreshold < GPSProfile.vehicleSpeedThreshold)
        #expect(GPSProfile.vehicleSpeedThreshold < GPSProfile.cyclingVehicleSpeedThreshold)
    }

    @Test("Vehicle speed overrides a slow activity label",
          arguments: [ActivityKind.walking, .unknown, .stationary])
    func speedOverridesLabel(kind: ActivityKind) {
        let p = GPSProfile.profile(for: kind, speed: 9)
        #expect(p.desiredAccuracy == .bestForNavigation)
        #expect(p.distanceFilter == 50)
        #expect(p.activityType == .automotiveNavigation)
    }

    /// 25 km/h is an ordinary cycling speed, so it must not turn a ride into
    /// a drive; 45 km/h is not one a bicycle holds, so it must.
    @Test("A wheeled label holds its profile until the higher threshold",
          arguments: [ActivityKind.cycling, .running])
    func wheeledLabelSurvivesVehicleSpeed(kind: ActivityKind) {
        let fast = GPSProfile.profile(for: kind, speed: 9)
        #expect(fast.label == kind.rawValue)
        #expect(fast.desiredAccuracy == .best)
        #expect(fast.distanceFilter == 20)
        #expect(fast.activityType == .fitness)

        let vehicle = GPSProfile.profile(for: kind, speed: 13)
        #expect(vehicle.label == "automotive")
        #expect(vehicle.desiredAccuracy == .bestForNavigation)
        #expect(vehicle.distanceFilter == 50)
    }

    @Test("Sub-vehicle speed does not override an explicit activity label")
    func slowSpeedKeepsLabel() {
        #expect(GPSProfile.profile(for: .walking, speed: 6.9).label == "walking")
        #expect(GPSProfile.profile(for: .running, speed: 0.1).label == "running")
        #expect(GPSProfile.profile(for: .cycling, speed: 5).distanceFilter == 20)
    }

    @Test("distanceFilter is monotonically non-decreasing with speed for every activity",
          arguments: ActivityKind.allCases)
    func monotonicDistanceFilter(kind: ActivityKind) {
        var previous = -Double.infinity
        var speed = 0.0
        while speed <= 60 {
            let filter = GPSProfile.profile(for: kind, speed: speed).distanceFilter
            #expect(filter >= previous, "distanceFilter decreased at \(speed) m/s for \(kind)")
            previous = filter
            speed += 0.1
        }
    }

    @Test("Accuracy never gets coarser than best while moving, and only bestForNavigation at vehicle speed",
          arguments: ActivityKind.allCases)
    func accuracyBounds(kind: ActivityKind) {
        for speed in stride(from: 0.0, through: 60.0, by: 0.5) {
            let p = GPSProfile.profile(for: kind, speed: speed)
            #expect(p.desiredAccuracy <= .best)
            let override = kind == .cycling || kind == .running
                ? GPSProfile.cyclingVehicleSpeedThreshold
                : GPSProfile.vehicleSpeedThreshold
            if speed >= override || kind == .automotive {
                #expect(p.desiredAccuracy == .bestForNavigation)
            } else {
                #expect(p.desiredAccuracy == .best)
            }
        }
    }

    @Test("distanceFilter is always within the configured bounds", arguments: ActivityKind.allCases)
    func filterBounds(kind: ActivityKind) {
        let s = TrackingSettings()
        let lower = min(s.walkingDistanceFilter, s.unknownDistanceFilter, s.runningCyclingDistanceFilter, s.automotiveDistanceFilter)
        let upper = max(s.walkingDistanceFilter, s.unknownDistanceFilter, s.runningCyclingDistanceFilter, s.automotiveDistanceFilter)
        for speed in [nil, -5.0, 0.0, 1.0, 2.5, 5.0, 7.0, 20.0, 100.0] as [Double?] {
            let f = GPSProfile.profile(for: kind, speed: speed).distanceFilter
            #expect(f >= lower && f <= upper)
        }
    }

    @Test("Settings distance filters flow through the table")
    func customSettings() {
        var s = TrackingSettings()
        s.walkingDistanceFilter = 5
        s.runningCyclingDistanceFilter = 15
        s.automotiveDistanceFilter = 100
        s.unknownDistanceFilter = 8
        #expect(GPSProfile.profile(for: .walking, speed: nil, settings: s).distanceFilter == 5)
        #expect(GPSProfile.profile(for: .running, speed: nil, settings: s).distanceFilter == 15)
        #expect(GPSProfile.profile(for: .cycling, speed: nil, settings: s).distanceFilter == 15)
        #expect(GPSProfile.profile(for: .automotive, speed: nil, settings: s).distanceFilter == 100)
        #expect(GPSProfile.profile(for: .unknown, speed: nil, settings: s).distanceFilter == 8)
        #expect(GPSProfile.profile(for: .unknown, speed: 3, settings: s).distanceFilter == 15)
        #expect(GPSProfile.profile(for: .walking, speed: 10, settings: s).distanceFilter == 100)
    }

    @Test("The table is a pure function: same inputs, same output")
    func purity() {
        let a = GPSProfile.profile(for: .cycling, speed: 4.2)
        let b = GPSProfile.profile(for: .cycling, speed: 4.2)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }
}

@Suite("GPSProfile · presets and types")
struct GPSProfilePresetTests {
    @Test("Probing preset: best, no distance filter")
    func probing() {
        #expect(GPSProfile.probing.desiredAccuracy == .best)
        #expect(GPSProfile.probing.distanceFilter == 0)
        #expect(GPSProfile.probing.label == "probing")
    }

    @Test("Stationary coarse preset is the cheapest possible")
    func stationaryCoarse() {
        #expect(GPSProfile.stationaryCoarse.desiredAccuracy == .threeKilometers)
        #expect(GPSProfile.stationaryCoarse.distanceFilter == 3_000)
        #expect(GPSProfile.stationaryCoarse.label == "stationary-coarse")
        for kind in ActivityKind.allCases {
            #expect(GPSProfile.profile(for: kind, speed: nil) != GPSProfile.stationaryCoarse)
        }
    }

    @Test("AccuracyLevel ordering: more precise sorts first")
    func accuracyOrdering() {
        let ordered: [AccuracyLevel] = [.bestForNavigation, .best, .tenMeters, .hundredMeters, .kilometer, .threeKilometers]
        #expect(ordered == ordered.sorted())
        #expect(AccuracyLevel.bestForNavigation < .best)
        #expect(AccuracyLevel.best < .threeKilometers)
        #expect(!(AccuracyLevel.best < .best))
    }

    @Test("GPSProfile round-trips through JSON")
    func codable() throws {
        let p = GPSProfile.profile(for: .running, speed: 3)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(GPSProfile.self, from: data)
        #expect(decoded == p)
    }
}

/// The status screen reads `appliedProfile`, not `currentProfile`: with coarse
/// updates on, CoreLocation keeps running while STATIONARY (and the system
/// location indicator with it), which "GPS off" would deny.
@MainActor
@Suite("Applied profile · coarse mode")
struct AppliedProfileTests {
    @Test("stopGPS keeps the coarse profile applied when the option is on")
    func coarseStaysApplied() {
        let engine = NoopLocationEngine()
        engine.startGPS(profile: .probing)
        #expect(engine.appliedProfile == .probing)

        engine.stopGPS()
        #expect(engine.currentProfile == nil)
        #expect(engine.appliedProfile == .stationaryCoarse)
    }

    @Test("stopGPS applies nothing when coarse updates are off")
    func coarseDisabled() {
        let engine = NoopLocationEngine()
        var settings = TrackingSettings()
        settings.keepCoarseUpdatesWhileStationary = false
        engine.apply(settings: settings)

        engine.startGPS(profile: .probing)
        engine.stopGPS()
        #expect(engine.appliedProfile == nil)
    }

    @Test("speedTier maps a reading onto the four tiers the table uses",
          arguments: [(nil as Double?, 0), (-1, 0), (0, 0), (2.49, 0),
                      (2.5, 1), (6.99, 1), (7.0, 2), (12.49, 2), (12.5, 3), (30, 3)])
    func speedTier(speed: Double?, tier: Int) {
        #expect(GPSProfile.speedTier(speed) == tier)
    }

    /// The invariant `TrackingStateMachine.updateProfileSpeed` relies on:
    /// comparing tiers is a faithful stand-in for comparing profiles, whatever
    /// the classifier says.
    @Test("Two speeds in the same tier yield the same profile, for every activity",
          arguments: [(0.5, 2.0), (3.0, 6.5), (8.0, 12.0), (13.0, 30.0)], ActivityKind.allCases)
    func sameTierSameProfile(speeds: (Double, Double), activity: ActivityKind) {
        #expect(GPSProfile.profile(for: activity, speed: speeds.0)
                == GPSProfile.profile(for: activity, speed: speeds.1))
    }

    @Test("Crossing a tier changes the profile for an unlabelled activity",
          arguments: [(2.0, 3.0), (6.5, 8.0)])
    func tierChangeChangesProfile(slow: Double, fast: Double) {
        #expect(GPSProfile.speedTier(slow) != GPSProfile.speedTier(fast))
        #expect(GPSProfile.profile(for: .unknown, speed: slow)
                != GPSProfile.profile(for: .unknown, speed: fast))
    }

    @Test("The coarse profile shows a human label, never its technical one")
    func coarseDisplayName() {
        #expect(GPSProfile.stationaryCoarse.displayName != GPSProfile.stationaryCoarse.label)
        #expect(!GPSProfile.stationaryCoarse.displayName.isEmpty)
    }
}
