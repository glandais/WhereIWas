#!/usr/bin/env swift
//
//  generate-tracks.swift — regenerates WhereIWas/App/DemoTracks.swift.
//
//  A one-off tool, run by hand on a Mac: `swift scripts/generate-tracks.swift`.
//  It is the only thing in this repository that talks to a routing service, and
//  that is the whole point. The App Store captures have to be reproducible and
//  offline, so the street geometry is resolved once here and committed as Swift
//  source; `scripts/screenshots.sh` then never leaves the machine.
//
//  Routing goes through **MKDirections**, which does work from a command-line
//  Swift script as long as the callback is given a run loop to come back on —
//  hence the semaphore-plus-RunLoop wait below rather than a bare
//  `sem.wait()`, which deadlocks. Apple throttles the service, so requests are
//  spaced out and retried; `--osrm` switches the whole run to the public OSRM
//  demo server, which returns comparable street-following geometry, for the day
//  Apple's throttle wins.
//
//  Re-running is safe: the city table below is the only input and the output
//  file is rewritten from scratch. It is not guaranteed byte-identical — the
//  service occasionally returns a different-but-equivalent route for the same
//  pair — so the diff is read like any other, checking the printed summary
//  still lands in range, rather than expected to be empty.
//

import Foundation
import MapKit

// MARK: - Input

/// A leg is a routed pair of waypoints; a segment is the concatenation of its legs.
struct Leg {
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D
}

enum Mode: String {
    case walking, automotive

    var transportType: MKDirectionsTransportType { self == .walking ? .walking : .automobile }
    var osrmProfile: String { self == .walking ? "foot" : "driving" }
    var encodedPrefix: String { self == .walking ? "W" : "D" }
}

struct SegmentSpec {
    let mode: Mode
    /// Routed pairwise; a loop simply repeats its first waypoint at the end.
    let waypoints: [CLLocationCoordinate2D]
}

struct CitySpec {
    let languageCode: String
    let city: String
    let segments: [SegmentSpec]
}

private func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

/// One run per app language: a walking loop around the departure station's
/// square, the drive across town, and a short walk in the arrival park.
///
/// Every waypoint is a public place — a station forecourt, a boulevard corner,
/// a park path — picked so no leg can be read as somebody's address. Distances
/// are checked by the script itself, not by these numbers, so a waypoint can be
/// nudged freely as long as the printed summary stays in range.
let cities: [CitySpec] = [
    CitySpec(languageCode: "en", city: "Boston", segments: [
        SegmentSpec(mode: .walking, waypoints: [        // Dewey Square / Fort Point
            c(42.35222, -71.05528), c(42.35167, -71.05271), c(42.35065, -71.05481),
            c(42.35137, -71.05679), c(42.35222, -71.05528)
        ]),
        SegmentSpec(mode: .automotive, waypoints: [     // South Station → Fenway
            c(42.35222, -71.05528), c(42.34650, -71.09760)
        ]),
        SegmentSpec(mode: .walking, waypoints: [        // Back Bay Fens
            c(42.34650, -71.09760), c(42.34450, -71.09450), c(42.34350, -71.09700)
        ])
    ]),
    CitySpec(languageCode: "fr", city: "Paris", segments: [
        SegmentSpec(mode: .walking, waypoints: [        // Gare de Lyon / rue de Bercy
            c(48.84470, 2.37340), c(48.84520, 2.37430), c(48.84440, 2.37530),
            c(48.84390, 2.37380), c(48.84470, 2.37340)
        ]),
        SegmentSpec(mode: .automotive, waypoints: [     // Gare de Lyon → Buttes-Chaumont
            c(48.84470, 2.37340), c(48.87990, 2.38200)
        ]),
        SegmentSpec(mode: .walking, waypoints: [        // Parc des Buttes-Chaumont
            c(48.87990, 2.38200), c(48.88100, 2.38400), c(48.88000, 2.38700)
        ])
    ]),
    CitySpec(languageCode: "de", city: "Berlin", segments: [
        SegmentSpec(mode: .walking, waypoints: [        // Hauptbahnhof / Spreebogen
            c(52.52500, 13.36940), c(52.52610, 13.37138), c(52.52445, 13.37303),
            c(52.52390, 13.36973), c(52.52500, 13.36940)
        ]),
        SegmentSpec(mode: .automotive, waypoints: [     // Hauptbahnhof → Treptower Park
            c(52.52500, 13.36940), c(52.49300, 13.46900)
        ]),
        SegmentSpec(mode: .walking, waypoints: [        // Treptower Park
            c(52.49300, 13.46900), c(52.49150, 13.46500), c(52.49000, 13.46800)
        ])
    ]),
    CitySpec(languageCode: "es", city: "Madrid", segments: [
        SegmentSpec(mode: .walking, waypoints: [        // Atocha / paseo del Prado
            c(40.40680, -3.69080), c(40.40782, -3.69152), c(40.40842, -3.68912),
            c(40.40692, -3.68852), c(40.40680, -3.69080)
        ]),
        SegmentSpec(mode: .automotive, waypoints: [     // Atocha → Parque del Oeste
            c(40.40680, -3.69080), c(40.42900, -3.72200)
        ]),
        SegmentSpec(mode: .walking, waypoints: [        // Parque del Oeste
            c(40.42900, -3.72200), c(40.43050, -3.72400), c(40.43280, -3.72420)
        ])
    ]),
    CitySpec(languageCode: "it", city: "Roma", segments: [
        SegmentSpec(mode: .walking, waypoints: [        // Termini / piazza dei Cinquecento
            c(41.90100, 12.50100), c(41.90213, 12.49875), c(41.90025, 12.49725),
            c(41.89987, 12.50025), c(41.90100, 12.50100)
        ]),
        SegmentSpec(mode: .automotive, waypoints: [     // Termini → Villa Doria Pamphili
            c(41.90100, 12.50100), c(41.88800, 12.45700)
        ]),
        SegmentSpec(mode: .walking, waypoints: [        // Villa Doria Pamphili
            c(41.88800, 12.45700), c(41.88650, 12.45400), c(41.88500, 12.45600)
        ])
    ]),
    // Tokyo is the dense-tile case (LEDGER D8): a 4 km drive, not a 10 km one,
    // so the map card is not a hairline across a wall of labels.
    CitySpec(languageCode: "ja", city: "Tokyo", segments: [
        SegmentSpec(mode: .walking, waypoints: [        // Tokyo Station / Marunouchi
            c(35.68120, 139.76710), c(35.68300, 139.76500), c(35.68150, 139.76300),
            c(35.67950, 139.76600), c(35.68120, 139.76710)
        ]),
        SegmentSpec(mode: .automotive, waypoints: [     // Tokyo Station → Ueno Park
            c(35.68120, 139.76710), c(35.71480, 139.77400)
        ]),
        SegmentSpec(mode: .walking, waypoints: [        // Ueno Park
            c(35.71480, 139.77400), c(35.71600, 139.77200), c(35.71800, 139.77400)
        ])
    ]),
    CitySpec(languageCode: "nl", city: "Amsterdam", segments: [
        SegmentSpec(mode: .walking, waypoints: [        // Centraal / Damrak
            c(52.37890, 4.90020), c(52.37738, 4.89764), c(52.37618, 4.90004),
            c(52.37738, 4.90284), c(52.37890, 4.90020)
        ]),
        SegmentSpec(mode: .automotive, waypoints: [     // Centraal → Vondelpark (west end)
            c(52.37890, 4.90020), c(52.35500, 4.85300)
        ]),
        SegmentSpec(mode: .walking, waypoints: [        // Vondelpark
            c(52.35500, 4.85300), c(52.35620, 4.85700), c(52.35700, 4.86050)
        ])
    ]),
    CitySpec(languageCode: "pl", city: "Warszawa", segments: [
        SegmentSpec(mode: .walking, waypoints: [        // Centralna / Aleje Jerozolimskie
            c(52.22860, 21.00300), c(52.22993, 21.00510), c(52.22888, 21.00720),
            c(52.22748, 21.00440), c(52.22860, 21.00300)
        ]),
        SegmentSpec(mode: .automotive, waypoints: [     // Centralna → Park Skaryszewski
            c(52.22860, 21.00300), c(52.24300, 21.05500)
        ]),
        SegmentSpec(mode: .walking, waypoints: [        // Park Skaryszewski
            c(52.24300, 21.05500), c(52.24150, 21.05800), c(52.24000, 21.05500)
        ])
    ]),
    CitySpec(languageCode: "cs", city: "Praha", segments: [
        SegmentSpec(mode: .walking, waypoints: [        // hlavní nádraží / Vrchlického sady
            c(50.08300, 14.43550), c(50.08413, 14.43362), c(50.08300, 14.43175),
            c(50.08187, 14.43400), c(50.08300, 14.43550)
        ]),
        SegmentSpec(mode: .automotive, waypoints: [     // hlavní nádraží → Stromovka
            c(50.08300, 14.43550), c(50.10900, 14.40600)
        ]),
        SegmentSpec(mode: .walking, waypoints: [        // Stromovka
            c(50.10900, 14.40600), c(50.10790, 14.40880), c(50.10740, 14.41060)
        ])
    ])
]

/// A city's whole run has to fit in this many points once downsampled: the
/// controller resamples them into timestamped samples, and the map card gains
/// nothing from a denser polyline than the screen can draw.
let pointBudget = 600
/// Two points closer than this are the same point as far as a 1284 px wide card
/// is concerned.
let minSpacingMeters = 8.0

// MARK: - Geometry

/// Metres between two coordinates, close enough for a city (equirectangular).
func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let earth = 6_371_000.0
    let latRad = (a.latitude + b.latitude) / 2 * .pi / 180
    let dx = (b.longitude - a.longitude) * .pi / 180 * cos(latRad) * earth
    let dy = (b.latitude - a.latitude) * .pi / 180 * earth
    return (dx * dx + dy * dy).squareRoot()
}

func pathLength(_ path: [CLLocationCoordinate2D]) -> Double {
    guard path.count > 1 else { return 0 }
    return zip(path, path.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
}

/// Perpendicular distance from `p` to the segment `a`–`b`, in metres.
private func crossTrack(_ p: CLLocationCoordinate2D,
                        _ a: CLLocationCoordinate2D,
                        _ b: CLLocationCoordinate2D) -> Double {
    let earth = 6_371_000.0
    let lat0 = a.latitude * .pi / 180
    func project(_ c: CLLocationCoordinate2D) -> (Double, Double) {
        (c.longitude * .pi / 180 * cos(lat0) * earth, c.latitude * .pi / 180 * earth)
    }
    let (px, py) = project(p), (ax, ay) = project(a), (bx, by) = project(b)
    let dx = bx - ax, dy = by - ay
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return ((px - ax) * (px - ax) + (py - ay) * (py - ay)).squareRoot() }
    let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
    let cx = ax + t * dx, cy = ay + t * dy
    return ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
}

/// Douglas-Peucker, iterative so a 3 000-point drive cannot blow the stack.
func simplify(_ path: [CLLocationCoordinate2D], tolerance: Double) -> [CLLocationCoordinate2D] {
    guard path.count > 2 else { return path }
    var keep = [Bool](repeating: false, count: path.count)
    keep[0] = true
    keep[path.count - 1] = true
    var stack = [(0, path.count - 1)]
    while let (first, last) = stack.popLast() {
        guard last > first + 1 else { continue }
        var worst = 0.0, index = first
        for i in (first + 1)..<last {
            let d = crossTrack(path[i], path[first], path[last])
            if d > worst { worst = d; index = i }
        }
        if worst > tolerance {
            keep[index] = true
            stack.append((first, index))
            stack.append((index, last))
        }
    }
    return path.enumerated().filter { keep[$0.offset] }.map(\.element)
}

/// Drop points closer than `minSpacingMeters` to the one kept before them; the
/// last point always survives so a leg still ends where it was routed to.
func thin(_ path: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    guard let first = path.first else { return [] }
    var out = [first]
    for point in path.dropFirst() where distance(out[out.count - 1], point) >= minSpacingMeters {
        out.append(point)
    }
    if let last = path.last, out.count > 1, distance(out[out.count - 1], last) > 0.5 {
        out.append(last)
    }
    return out
}

// MARK: - Routing

enum RoutingError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let m) = self { return m }; return "" }
}

/// Waits for `body` to signal, pumping the run loop meanwhile.
///
/// MKDirections delivers its completion on the main queue, so a plain
/// `semaphore.wait()` on the main thread of a script never returns.
func waitPumpingRunLoop(timeout: TimeInterval, _ body: (DispatchSemaphore) -> Void) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    body(semaphore)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if semaphore.wait(timeout: .now() + 0.02) == .success { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return false
}

func routeWithMapKit(_ leg: Leg, mode: Mode) throws -> [CLLocationCoordinate2D] {
    let request = MKDirections.Request()
    request.source = MKMapItem(placemark: MKPlacemark(coordinate: leg.from))
    request.destination = MKMapItem(placemark: MKPlacemark(coordinate: leg.to))
    request.transportType = mode.transportType
    request.requestsAlternateRoutes = false

    var result: Result<[CLLocationCoordinate2D], Error>?
    let answered = waitPumpingRunLoop(timeout: 45) { semaphore in
        MKDirections(request: request).calculate { response, error in
            if let route = response?.routes.first {
                var coordinates = [CLLocationCoordinate2D](repeating: .init(),
                                                           count: route.polyline.pointCount)
                route.polyline.getCoordinates(&coordinates,
                                              range: NSRange(location: 0, length: route.polyline.pointCount))
                result = .success(coordinates)
            } else {
                result = .failure(RoutingError.failed(error?.localizedDescription ?? "no route"))
            }
            semaphore.signal()
        }
    }
    guard answered else { throw RoutingError.failed("timed out after 45 s") }
    return try result!.get()
}

func routeWithOSRM(_ leg: Leg, mode: Mode) throws -> [CLLocationCoordinate2D] {
    let path = "\(leg.from.longitude),\(leg.from.latitude);\(leg.to.longitude),\(leg.to.latitude)"
    let url = URL(string: "https://router.project-osrm.org/route/v1/\(mode.osrmProfile)/\(path)"
                  + "?geometries=geojson&overview=full")!
    var result: Result<[CLLocationCoordinate2D], Error>?
    let answered = waitPumpingRunLoop(timeout: 45) { semaphore in
        URLSession.shared.dataTask(with: url) { data, _, error in
            defer { semaphore.signal() }
            guard let data else {
                result = .failure(RoutingError.failed(error?.localizedDescription ?? "no data"))
                return
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let routes = json?["routes"] as? [[String: Any]], let first = routes.first,
                  let geometry = first["geometry"] as? [String: Any],
                  let pairs = geometry["coordinates"] as? [[Double]] else {
                result = .failure(RoutingError.failed("unexpected OSRM payload"))
                return
            }
            result = .success(pairs.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) })
        }.resume()
    }
    guard answered else { throw RoutingError.failed("timed out after 45 s") }
    return try result!.get()
}

let useOSRM = CommandLine.arguments.contains("--osrm")

/// Routes one leg, retrying on the throttle before giving up.
func route(_ leg: Leg, mode: Mode) -> [CLLocationCoordinate2D] {
    for attempt in 1...4 {
        do {
            let coordinates = useOSRM ? try routeWithOSRM(leg, mode: mode)
                                      : try routeWithMapKit(leg, mode: mode)
            // Apple's throttle is per burst rather than per request, so a fixed
            // pause between legs is what keeps a nine-city run from tripping it.
            Thread.sleep(forTimeInterval: 1.2)
            return coordinates
        } catch {
            FileHandle.standardError.write("    retry \(attempt): \(error)\n".data(using: .utf8)!)
            Thread.sleep(forTimeInterval: Double(attempt) * 4)
        }
    }
    FileHandle.standardError.write("    giving up on this leg\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Build

struct BuiltSegment {
    let mode: Mode
    let coordinates: [CLLocationCoordinate2D]
}

func build(_ spec: CitySpec) -> [BuiltSegment] {
    spec.segments.map { segment in
        var joined: [CLLocationCoordinate2D] = []
        for (from, to) in zip(segment.waypoints, segment.waypoints.dropFirst()) {
            let leg = route(Leg(from: from, to: to), mode: segment.mode)
            joined.append(contentsOf: joined.isEmpty ? leg : Array(leg.dropFirst()))
        }
        return BuiltSegment(mode: segment.mode, coordinates: joined)
    }
}

/// Simplifies every segment of a city under one shared tolerance, raised until
/// the whole run fits ``pointBudget``.
func downsample(_ segments: [BuiltSegment]) -> [BuiltSegment] {
    var tolerance = 4.0
    while true {
        let reduced = segments.map {
            BuiltSegment(mode: $0.mode, coordinates: thin(simplify($0.coordinates, tolerance: tolerance)))
        }
        let total = reduced.reduce(0) { $0 + $1.coordinates.count }
        if total <= pointBudget || tolerance > 200 { return reduced }
        tolerance *= 1.5
    }
}

// MARK: - Emit

func encode(_ segments: [BuiltSegment], city: String) -> String {
    ([city] + segments.map { segment in
        segment.mode.encodedPrefix + ":" + segment.coordinates.map {
            String(format: "%.5f,%.5f", $0.latitude, $0.longitude)
        }.joined(separator: ";")
    }).joined(separator: "|")
}

var built: [(spec: CitySpec, segments: [BuiltSegment])] = []
print(useOSRM ? "Routing with OSRM…" : "Routing with MKDirections…")
for spec in cities {
    print("\(spec.city) (\(spec.languageCode))")
    let segments = downsample(build(spec))
    for segment in segments {
        print(String(format: "  %-10@ %6.2f km  %4d pts",
                     segment.mode.rawValue as NSString,
                     pathLength(segment.coordinates) / 1000,
                     segment.coordinates.count))
    }
    print(String(format: "  total      %6.2f km  %4d pts",
                 segments.reduce(0) { $0 + pathLength($1.coordinates) } / 1000,
                 segments.reduce(0) { $0 + $1.coordinates.count }))
    built.append((spec, segments))
}

let literals = built
    .sorted { $0.spec.languageCode < $1.spec.languageCode }
    .map { "        \"\($0.spec.languageCode)\": \"\(encode($0.segments, city: $0.spec.city))\"" }
    .joined(separator: ",\n")

let output = """
// Generated by scripts/generate-tracks.swift — do not edit by hand.
//
// Street geometry for the App Store demo tracks, one run per app language:
// a walking loop around a station square, a drive across town, a short walk in
// the arrival park. Resolved once against Apple's directions service so the
// captures themselves stay offline and reproducible.

#if SCREENSHOTS
import Foundation

/// One leg of a demo track: a street-following polyline walked or driven.
struct DemoTrackSegment {
    enum Mode: String { case walking, automotive }
    let mode: Mode
    let coordinates: [(latitude: Double, longitude: Double)]
}

/// A city's demo run: a walking loop, a drive, and a short walk at the far end.
struct DemoTrack {
    let city: String
    let segments: [DemoTrackSegment]
}

enum DemoTracks {
    /// App language code (the `knownRegions` of project.yml) -> track.
    static let all: [String: DemoTrack] = encoded.mapValues(decode)

    static func track(for languageCode: String) -> DemoTrack { all[languageCode] ?? all["en"]! }

    /// "City|W:lat,lon;lat,lon|D:lat,lon;...|W:..." — one string literal per city
    /// so the type checker never sees thousands of array elements. `W` is walking,
    /// `D` automotive, and the segments are in the order they are travelled.
    private static let encoded: [String: String] = [
\(literals)
    ]

    private static func decode(_ line: String) -> DemoTrack {
        var fields = line.split(separator: "|")
        let city = String(fields.removeFirst())
        let segments = fields.map { field -> DemoTrackSegment in
            let mode: DemoTrackSegment.Mode = field.hasPrefix("W:") ? .walking : .automotive
            let coordinates = field.dropFirst(2).split(separator: ";").map { pair -> (latitude: Double, longitude: Double) in
                let values = pair.split(separator: ",")
                return (Double(values[0])!, Double(values[1])!)
            }
            return DemoTrackSegment(mode: mode, coordinates: coordinates)
        }
        return DemoTrack(city: city, segments: segments)
    }
}
#endif

"""

// The script lives in scripts/, so its own path names the repository root —
// which keeps the run independent of the working directory it is started from.
let repositoryRoot = URL(fileURLWithPath: CommandLine.arguments[0],
                         relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    .standardizedFileURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let destination = repositoryRoot.appendingPathComponent("WhereIWas/App/DemoTracks.swift")
try output.write(to: destination, atomically: true, encoding: .utf8)
print("\nWrote \(destination.path)")
