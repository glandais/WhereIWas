import Foundation

/// GPX 1.1 writer. One `<trk>`; a new `<trkseg>` starts whenever the session
/// changes or two consecutive samples are more than ``segmentGap`` apart.
/// Per-point metadata goes into `<extensions>` under the `wiw:` prefix.
enum GPXExporter {
    /// Time gap (seconds) that starts a new track segment.
    static let segmentGap: TimeInterval = 30 * 60

    static func export(_ samples: [StoredLocationSample], name: String) -> String {
        var out = ""
        out += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<gpx version=\"1.1\" creator=\"WhereIWas\" xmlns=\"http://www.topografix.com/GPX/1/1\""
        out += " xmlns:wiw=\"https://github.com/glandais/whereiwas/gpx/1\""
        out += " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
        out += " xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">\n"
        out += "  <metadata>\n    <name>\(escape(name))</name>\n"
        if let first = samples.first {
            out += "    <time>\(iso(first.fix.timestamp))</time>\n"
        }
        out += "  </metadata>\n"
        out += "  <trk>\n    <name>\(escape(name))</name>\n"

        var previous: StoredLocationSample?
        var segmentOpen = false
        for sample in samples {
            if let p = previous, needsNewSegment(previous: p, current: sample), segmentOpen {
                out += "    </trkseg>\n"
                segmentOpen = false
            }
            if !segmentOpen {
                out += "    <trkseg>\n"
                segmentOpen = true
            }
            out += trackPoint(sample)
            previous = sample
        }
        if segmentOpen { out += "    </trkseg>\n" }
        out += "  </trk>\n</gpx>\n"
        return out
    }

    /// Writes the GPX document to `directory` (default: temporary directory)
    /// and returns the file URL, ready for `ShareLink`.
    static func write(_ samples: [StoredLocationSample],
                      name: String,
                      to directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent(ExportFileName.make(name: name, format: .gpx))
        try export(samples, name: name).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Helpers

    private static func needsNewSegment(previous: StoredLocationSample, current: StoredLocationSample) -> Bool {
        if previous.annotation.sessionID != current.annotation.sessionID { return true }
        return current.fix.timestamp.timeIntervalSince(previous.fix.timestamp) > segmentGap
    }

    private static func trackPoint(_ sample: StoredLocationSample) -> String {
        let f = sample.fix
        var s = "      <trkpt lat=\"\(num(f.latitude))\" lon=\"\(num(f.longitude))\">\n"
        if f.verticalAccuracy >= 0 {
            s += "        <ele>\(num(f.altitude))</ele>\n"
        }
        s += "        <time>\(iso(f.timestamp))</time>\n"
        s += "        <extensions>\n"
        if f.speed >= 0 { s += "          <wiw:speed>\(num(f.speed))</wiw:speed>\n" }
        if f.course >= 0 { s += "          <wiw:course>\(num(f.course))</wiw:course>\n" }
        s += "          <wiw:hacc>\(num(f.horizontalAccuracy))</wiw:hacc>\n"
        if f.verticalAccuracy >= 0 { s += "          <wiw:vacc>\(num(f.verticalAccuracy))</wiw:vacc>\n" }
        let a = sample.annotation
        s += "          <wiw:activity>\(a.activity.rawValue)</wiw:activity>\n"
        s += "          <wiw:phase>\(a.phase.rawValue)</wiw:phase>\n"
        s += "          <wiw:source>\(sample.source.rawValue)</wiw:source>\n"
        if let label = a.profileLabel { s += "          <wiw:profile>\(escape(label))</wiw:profile>\n" }
        if let battery = a.batteryLevel { s += "          <wiw:battery>\(num(battery))</wiw:battery>\n" }
        s += "          <wiw:seq>\(sample.sequence)</wiw:seq>\n"
        s += "        </extensions>\n"
        s += "      </trkpt>\n"
        return s
    }

    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: true).timeSeparator(.colon)
            // Without an explicit zone the output has no `Z`, which makes the
            // GPX timestamps ambiguous for any consumer.
            .timeZone(separator: .omitted))
    }

    /// Locale-independent decimal formatting (dot separator, no exponent).
    static func num(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.1f", locale: nil, value)
        }
        return String(format: "%.7g", locale: nil, value)
            .replacingOccurrences(of: "e", with: "E")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Builds a filesystem-safe export file name such as
/// `WhereIWas-2026-09-02T10-15-00.gpx`.
enum ExportFileName {
    static func make(name: String, format: ExportFormat, date: Date = Date()) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        var base = String(safe)
        while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
        if base.isEmpty { base = "WhereIWas" }
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        return "\(base)-\(stamp).\(format.fileExtension)"
    }
}
