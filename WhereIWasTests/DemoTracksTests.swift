import Foundation
import Testing
@testable import WhereIWas

/// `DemoTracks` is a hand-encoded fixture (see `App/DemoTracks.swift`), so
/// nothing checks its shape at compile time — a bad edit only shows up as a
/// wrong-looking screenshot, or worse, a crash on `all["en"]!`. These tests
/// catch that before a capture run does.
@Suite("DemoTracks · fixtures")
struct DemoTracksTests {
    /// Kept in step with `project.yml`'s `knownRegions` by hand: XcodeGen has
    /// no way to feed that list into a Swift test. `scripts/screenshots.sh`
    /// has the same problem and solves it the same way — its own hard-coded
    /// locale list — so if one drifts from `project.yml`, so does the other,
    /// and this test is the tripwire.
    static let knownRegions = ["en", "fr", "de", "es", "it", "ja", "nl", "pl", "cs"]

    @Test("Every known region has its own track, so none silently falls back to English",
          arguments: knownRegions)
    func everyRegionHasATrack(_ languageCode: String) {
        #expect(DemoTracks.all[languageCode] != nil, "no DemoTrack fixture for '\(languageCode)'")
    }

    @Test("Each track has a city name and at least three segments", arguments: knownRegions)
    func shape(_ languageCode: String) throws {
        let track = try #require(DemoTracks.all[languageCode])
        #expect(!track.city.isEmpty)
        #expect(track.segments.count >= 3)
    }

    @Test("Each track walks and drives at least once", arguments: knownRegions)
    func modes(_ languageCode: String) throws {
        let track = try #require(DemoTracks.all[languageCode])
        #expect(track.segments.contains { $0.mode == .walking })
        #expect(track.segments.contains { $0.mode == .automotive })
    }

    @Test("Driving distance is a plausible cross-town trip, not a data-entry typo",
          arguments: knownRegions)
    func drivingDistance(_ languageCode: String) throws {
        let track = try #require(DemoTracks.all[languageCode])
        let drivingMeters = track.segments
            .filter { $0.mode == .automotive }
            .reduce(0.0) { $0 + polylineLength($1.coordinates) }
        #expect(drivingMeters >= 3_000 && drivingMeters <= 12_000,
                "\(track.city): driving distance \(drivingMeters) m out of the 3-12 km range")
    }

    @Test("Every coordinate is a valid lat/lon, with no jump a road could not explain",
          arguments: knownRegions)
    func coordinatesAreSane(_ languageCode: String) throws {
        let track = try #require(DemoTracks.all[languageCode])
        for segment in track.segments {
            for coordinate in segment.coordinates {
                #expect((-90...90).contains(coordinate.latitude))
                #expect((-180...180).contains(coordinate.longitude))
            }
            // The generator simplifies each route with Douglas-Peucker at 4 m,
            // so a long gap means the road ran straight to within 4 m over that
            // whole stretch — routine on an urban arterial, impossible on a
            // pedestrian loop through a city centre. Hence two bounds: they are
            // here to catch a mistyped coordinate, which moves a point by
            // kilometres, not to police the routing engine's own geometry.
            let bound = segment.mode == .walking ? 400.0 : 2_000.0
            for pair in zip(segment.coordinates, segment.coordinates.dropFirst()) {
                let gap = haversineMeters(pair.0, pair.1)
                #expect(gap <= bound,
                        "\(track.city) \(segment.mode): \(gap) m jump between consecutive points")
            }
        }
    }

    @Test("An unknown language code falls back to the English track")
    func fallsBackToEnglish() {
        let fallback = DemoTracks.track(for: "xx")
        #expect(fallback.city == DemoTracks.all["en"]?.city)
    }
}

/// Sum of the haversine distance between consecutive points, in meters.
private func polylineLength(_ coordinates: [(latitude: Double, longitude: Double)]) -> Double {
    zip(coordinates, coordinates.dropFirst()).reduce(0.0) { $0 + haversineMeters($1.0, $1.1) }
}

/// Great-circle distance between two coordinates, in meters.
private func haversineMeters(
    _ a: (latitude: Double, longitude: Double),
    _ b: (latitude: Double, longitude: Double)
) -> Double {
    let earthRadius = 6_371_000.0
    let lat1 = a.latitude * .pi / 180
    let lat2 = b.latitude * .pi / 180
    let deltaLat = (b.latitude - a.latitude) * .pi / 180
    let deltaLon = (b.longitude - a.longitude) * .pi / 180
    let sinLat = sin(deltaLat / 2)
    let sinLon = sin(deltaLon / 2)
    let h = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
    return 2 * earthRadius * asin(min(1, sqrt(h)))
}
