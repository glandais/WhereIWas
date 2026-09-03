import Foundation
import Testing
@testable import WhereIWas

/// Isolated `UserDefaults` suite per test, cleaned up afterwards.
private final class DefaultsSandbox: Sendable {
    let name: String
    /// `UserDefaults` is documented as thread-safe but is not marked
    /// `Sendable`; the sandbox is only read from the owning test.
    nonisolated(unsafe) let defaults: UserDefaults

    init() {
        name = "WhereIWasTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

@Suite("TrackingSettings · defaults")
struct TrackingSettingsDefaultTests {
    @Test("Default values match ARCHITECTURE.md")
    func defaults() {
        let s = TrackingSettings()
        #expect(s.stillnessTimeout == 120)
        #expect(s.probeTimeout == 45)
        #expect(s.movingSpeedThreshold == 0.7)
        #expect(s.stillSpeedThreshold == 0.3)
        #expect(s.minimumActivityConfidence == .medium)
        #expect(s.keepCoarseUpdatesWhileStationary)
        #expect(s.showsLocationIndicator)
        #expect(s.unitSystem == UnitSystem.deviceDefault)
        #expect(s.walkingDistanceFilter == 10)
        #expect(s.runningCyclingDistanceFilter == 20)
        #expect(s.automotiveDistanceFilter == 50)
        #expect(s.unknownDistanceFilter == 10)
        #expect(s.maxHorizontalAccuracy == 50)
        #expect(s.maxSampleAge == 30)
        #expect(s.duplicateDistance == 0)
        #expect(s.retentionDays == 30)
        #expect(s.insertBatchSize == 20)
    }

    @Test("Defaults are internally consistent")
    func consistency() {
        let s = TrackingSettings()
        #expect(s.stillSpeedThreshold < s.movingSpeedThreshold)
        #expect(s.probeTimeout < s.stillnessTimeout)
        #expect(s.walkingDistanceFilter <= s.runningCyclingDistanceFilter)
        #expect(s.runningCyclingDistanceFilter <= s.automotiveDistanceFilter)
        #expect(s.insertBatchSize > 0)
        #expect(s.retentionDays >= 0)
    }

    @Test("userDefaultsKey is the documented one")
    func key() {
        #expect(TrackingSettings.userDefaultsKey == "whereiwas.settings.v1")
    }
}

@Suite("TrackingSettings · Codable")
struct TrackingSettingsCodableTests {
    @Test("JSON round-trip preserves every field")
    func roundTrip() throws {
        var s = TrackingSettings()
        s.stillnessTimeout = 33
        s.probeTimeout = 7
        s.movingSpeedThreshold = 1.1
        s.stillSpeedThreshold = 0.05
        s.minimumActivityConfidence = .high
        s.keepCoarseUpdatesWhileStationary = false
        s.showsLocationIndicator = false
        s.unitSystem = UnitSystem.deviceDefault == .metric ? .imperial : .metric
        s.walkingDistanceFilter = 1
        s.runningCyclingDistanceFilter = 2
        s.automotiveDistanceFilter = 3
        s.unknownDistanceFilter = 4
        s.maxHorizontalAccuracy = 99
        s.maxSampleAge = 12
        s.duplicateDistance = 1.5
        s.retentionDays = 0
        s.insertBatchSize = 1

        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(TrackingSettings.self, from: data)
        #expect(decoded == s)
        #expect(decoded != TrackingSettings())
    }

    @Test("Missing keys fall back to defaults (forward compatibility)")
    func partialJSON() throws {
        let json = #"{"stillnessTimeout": 60, "retentionDays": 7}"#
        let decoded = try JSONDecoder().decode(TrackingSettings.self, from: Data(json.utf8))
        var expected = TrackingSettings()
        expected.stillnessTimeout = 60
        expected.retentionDays = 7
        #expect(decoded == expected)
    }

    @Test("Empty object decodes to defaults")
    func emptyJSON() throws {
        let decoded = try JSONDecoder().decode(TrackingSettings.self, from: Data("{}".utf8))
        #expect(decoded == TrackingSettings())
    }

    @Test("Unknown keys are ignored")
    func unknownKeys() throws {
        let json = #"{"probeTimeout": 10, "somethingFromTheFuture": true}"#
        let decoded = try JSONDecoder().decode(TrackingSettings.self, from: Data(json.utf8))
        #expect(decoded.probeTimeout == 10)
    }

    @Test("unitSystem round-trips through JSON in both directions")
    func unitSystemRoundTrip() throws {
        for system in UnitSystem.allCases {
            var s = TrackingSettings()
            s.unitSystem = system
            let decoded = try JSONDecoder().decode(TrackingSettings.self,
                                                   from: try JSONEncoder().encode(s))
            #expect(decoded.unitSystem == system)
            #expect(decoded == s)
        }
    }

    @Test("Settings saved before the unit setting existed fall back to the device default")
    func unitSystemMissingKey() throws {
        let json = #"{"stillnessTimeout": 60, "retentionDays": 7}"#
        let decoded = try JSONDecoder().decode(TrackingSettings.self, from: Data(json.utf8))
        #expect(decoded.unitSystem == UnitSystem.deviceDefault)
    }

    @Test("Wrong type for a known key throws")
    func wrongType() {
        let json = #"{"stillnessTimeout": "soon"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TrackingSettings.self, from: Data(json.utf8))
        }
    }

    @Test("Encoded JSON uses the documented key names")
    func keyNames() throws {
        let data = try JSONEncoder().encode(TrackingSettings())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expectedKeys: Set<String> = [
            "stillnessTimeout", "probeTimeout", "movingSpeedThreshold", "stillSpeedThreshold",
            "minimumActivityConfidence", "keepCoarseUpdatesWhileStationary", "showsLocationIndicator",
            "unitSystem",
            "walkingDistanceFilter", "runningCyclingDistanceFilter", "automotiveDistanceFilter", "unknownDistanceFilter",
            "maxHorizontalAccuracy", "maxSampleAge", "duplicateDistance",
            "retentionDays", "insertBatchSize",
            "auditEnabled", "auditMinimumSeverity", "auditRetentionDays",
            "auditLogsAcceptedFixes", "auditLogsRejectedFixes",
            "auditLogsFilterChecks", "auditLogsMotionEvents",
        ]
        #expect(Set(object.keys) == expectedKeys)
        #expect(object["minimumActivityConfidence"] as? Int == ActivityConfidence.medium.rawValue)
    }
}

@Suite("TrackingSettings · UserDefaults persistence")
struct TrackingSettingsPersistenceTests {
    @Test("load returns defaults when nothing is stored")
    func loadEmpty() {
        let box = DefaultsSandbox()
        #expect(TrackingSettings.load(from: box.defaults) == TrackingSettings())
    }

    @Test("save then load round-trips")
    func saveLoad() {
        let box = DefaultsSandbox()
        var s = TrackingSettings()
        s.stillnessTimeout = 300
        s.minimumActivityConfidence = .low
        s.keepCoarseUpdatesWhileStationary = false
        s.showsLocationIndicator = false
        s.save(to: box.defaults)
        #expect(box.defaults.data(forKey: TrackingSettings.userDefaultsKey) != nil)
        #expect(TrackingSettings.load(from: box.defaults) == s)
    }

    @Test("Saving again overwrites the previous value")
    func overwrite() {
        let box = DefaultsSandbox()
        var s = TrackingSettings()
        s.retentionDays = 1
        s.save(to: box.defaults)
        s.retentionDays = 90
        s.save(to: box.defaults)
        #expect(TrackingSettings.load(from: box.defaults).retentionDays == 90)
    }

    @Test("Corrupt blob falls back to defaults instead of crashing")
    func corrupt() {
        let box = DefaultsSandbox()
        box.defaults.set(Data("not json".utf8), forKey: TrackingSettings.userDefaultsKey)
        #expect(TrackingSettings.load(from: box.defaults) == TrackingSettings())
        box.defaults.set("a string, not data", forKey: TrackingSettings.userDefaultsKey)
        #expect(TrackingSettings.load(from: box.defaults) == TrackingSettings())
    }
}

@Suite("Domain enums")
struct DomainEnumTests {
    @Test("impliesMotion is true exactly for displacing activities")
    func impliesMotion() {
        #expect(!ActivityKind.unknown.impliesMotion)
        #expect(!ActivityKind.stationary.impliesMotion)
        #expect(ActivityKind.walking.impliesMotion)
        #expect(ActivityKind.running.impliesMotion)
        #expect(ActivityKind.cycling.impliesMotion)
        #expect(ActivityKind.automotive.impliesMotion)
    }

    @Test("ActivityConfidence is ordered low < medium < high")
    func confidenceOrdering() {
        #expect(ActivityConfidence.low < .medium)
        #expect(ActivityConfidence.medium < .high)
        #expect([ActivityConfidence.high, .low, .medium].sorted() == [.low, .medium, .high])
    }

    @Test("Only `always` allows background tracking")
    func authorization() {
        #expect(LocationAuthorization.always.allowsBackgroundTracking)
        for status in [LocationAuthorization.notDetermined, .restricted, .denied, .whenInUse] {
            #expect(!status.allowsBackgroundTracking)
        }
    }
}
