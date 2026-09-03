import Foundation
import Testing
@testable import WhereIWas

@Suite("GPX / JSON exporters")
struct GPXExporterTests {
    private func sample(seq: Int64, lat: Double, lon: Double, at date: Date,
                        session: UUID? = nil, speed: Double = 1.5, vacc: Double = 4) -> StoredLocationSample {
        StoredLocationSample(sequence: seq,
                             fix: LocationFix(latitude: lat, longitude: lon, altitude: 120.5,
                                              horizontalAccuracy: 6, verticalAccuracy: vacc,
                                              speed: speed, speedAccuracy: 0.3, course: 180, timestamp: date),
                             annotation: SampleAnnotation(activity: .walking, activityConfidence: .high,
                                                          phase: .moving, batteryLevel: 0.75,
                                                          batteryState: .unplugged, sessionID: session,
                                                          profileLabel: "walking"),
                             source: .gps, uploaded: false, createdAt: date)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    @Test("GPX document structure and track points")
    func gpxStructure() throws {
        let samples = [
            sample(seq: 1, lat: 48.8566, lon: 2.3522, at: t0),
            sample(seq: 2, lat: 48.8570, lon: 2.3530, at: t0.addingTimeInterval(10)),
        ]
        let gpx = GPXExporter.export(samples, name: "Shift <1> & \"two\"")
        #expect(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        #expect(gpx.contains("<gpx version=\"1.1\" creator=\"WhereIWas\" xmlns=\"http://www.topografix.com/GPX/1/1\""))
        #expect(gpx.contains("<name>Shift &lt;1&gt; &amp; &quot;two&quot;</name>"))
        #expect(gpx.contains("<trkpt lat=\"48.8566\" lon=\"2.3522\">"))
        #expect(gpx.contains("<ele>120.5</ele>"))
        #expect(gpx.contains("<time>2023-11-14T22:13:20.000Z</time>"))
        #expect(gpx.contains("<time>2023-11-14T22:13:30.000Z</time>"))
        #expect(gpx.contains("<wiw:speed>1.5</wiw:speed>"))
        #expect(gpx.contains("<wiw:course>180.0</wiw:course>"))
        #expect(gpx.contains("<wiw:activity>walking</wiw:activity>"))
        #expect(gpx.contains("<wiw:battery>0.75</wiw:battery>"))
        #expect(gpx.contains("<wiw:seq>2</wiw:seq>"))
        #expect(gpx.components(separatedBy: "<trkpt ").count - 1 == 2)
        #expect(gpx.components(separatedBy: "<trkseg>").count - 1 == 1)
        #expect(gpx.hasSuffix("</gpx>\n"))
    }

    @Test("empty export is still a valid document")
    func gpxEmpty() {
        let gpx = GPXExporter.export([], name: "empty")
        #expect(gpx.contains("<trk>"))
        #expect(!gpx.contains("<trkseg>"))
        #expect(gpx.hasSuffix("</gpx>\n"))
    }

    @Test("segments split on session change and on long time gaps; invalid values omitted")
    func gpxSegments() {
        let s1 = UUID(), s2 = UUID()
        let samples = [
            sample(seq: 1, lat: 48.1, lon: 2.1, at: t0, session: s1),
            sample(seq: 2, lat: 48.2, lon: 2.2, at: t0.addingTimeInterval(60), session: s1),
            sample(seq: 3, lat: 48.3, lon: 2.3, at: t0.addingTimeInterval(120), session: s2),
            sample(seq: 4, lat: 48.4, lon: 2.4, at: t0.addingTimeInterval(120 + 2 * 3600), session: s2, speed: -1, vacc: -1),
        ]
        let gpx = GPXExporter.export(samples, name: "segments")
        #expect(gpx.components(separatedBy: "<trkseg>").count - 1 == 3)
        #expect(gpx.components(separatedBy: "</trkseg>").count - 1 == 3)
        // Last point has no valid speed/vertical accuracy: no <ele>, no speed, no vacc.
        let lastPoint = gpx.components(separatedBy: "<trkpt ").last ?? ""
        #expect(!lastPoint.contains("<ele>"))
        #expect(!lastPoint.contains("<wiw:speed>"))
        #expect(!lastPoint.contains("<wiw:vacc>"))
        #expect(lastPoint.contains("<wiw:hacc>6.0</wiw:hacc>"))
    }

    @Test("numbers are locale independent and never use exponent notation for coordinates")
    func numberFormatting() {
        #expect(GPXExporter.num(48.8566) == "48.8566")
        #expect(GPXExporter.num(-0.0001234) == "-0.0001234")
        #expect(GPXExporter.num(120) == "120.0")
        #expect(GPXExporter.num(2.35) == "2.35")
    }

    @Test("GPX write produces a file with a safe name")
    func gpxWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gpx-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try GPXExporter.write([sample(seq: 1, lat: 1, lon: 2, at: t0)], name: "My shift / day 1", to: dir)
        #expect(url.pathExtension == "gpx")
        #expect(url.lastPathComponent.hasPrefix("My-shift-day-1-"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("<trkpt lat=\"1.0\" lon=\"2.0\">"))
    }

    @Test("JSON export round-trips samples with ISO-8601 dates")
    func jsonRoundTrip() throws {
        let session = UUID()
        let samples = [
            sample(seq: 1, lat: 48.8566, lon: 2.3522, at: t0, session: session),
            sample(seq: 2, lat: 48.8570, lon: 2.3530, at: t0.addingTimeInterval(10), session: session),
        ]
        let data = try JSONExporter.export(samples, exportedAt: t0)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"timestamp\":\"2023-11-14T22:13:20Z\""))
        #expect(text.contains("\"format\":\"whereiwas.samples\""))
        let decoded = try JSONExporter.decode(data)
        #expect(decoded.sampleCount == 2)
        #expect(decoded.samples == samples)
    }
}
