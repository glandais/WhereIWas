import Foundation

/// File formats the audit trail can be shared as.
public enum AuditExportFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Structured envelope, for machine analysis.
    case json
    /// One line per event, for pasting into an incident report.
    case text

    public var id: String { rawValue }
    public var fileExtension: String { self == .json ? "json" : "txt" }
    public var label: String { self == .json ? "JSON" : "Plain text" }

    /// The name an export lands under. A compressed one keeps the format's
    /// own extension in front of `.gz`, so the file still says what it holds.
    public func fileName(_ base: String, compressed: Bool) -> String {
        "\(base).\(fileExtension)\(compressed ? ".gz" : "")"
    }
}

/// Renders the audit trail to a shareable file.
///
/// The export is deliberately self-describing: an incident review happens
/// days later, on someone else's machine, without the app. The settings in
/// force at export time travel with the events, so a reader can tell which
/// event kinds were being recorded at all.
enum AuditExporter {
    struct Envelope: Codable, Sendable {
        var format: String = "whereiwas.audit"
        var version: Int = 1
        var exportedAt: Date
        var app: AppBuild = .current
        var eventCount: Int
        var settings: TrackingSettings
        var events: [AuditEvent]
    }

    /// Which build wrote the file.
    ///
    /// An export used to say only `format` and `version`, so reading one back
    /// meant assuming which build produced it — and the assumption is exactly
    /// what a fix under test needs proven.
    struct AppBuild: Codable, Sendable, Equatable {
        var version: String
        var build: String
        var system: String

        static let current = AppBuild(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            system: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    static func json(_ events: [AuditEvent],
                     settings: TrackingSettings,
                     exportedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(Envelope(exportedAt: exportedAt,
                                           eventCount: events.count,
                                           settings: settings,
                                           events: events))
    }

    static func text(_ events: [AuditEvent],
                     settings: TrackingSettings,
                     exportedAt: Date = Date()) -> String {
        var out = "WhereIWas audit trail\n"
        out += "exported: \(GPXExporter.iso(exportedAt))\n"
        let app = AppBuild.current
        out += "app: \(app.version) (\(app.build)) on \(app.system)\n"
        out += "events: \(events.count)\n"
        out += "recording: accepted=\(settings.auditLogsAcceptedFixes) rejected=\(settings.auditLogsRejectedFixes)"
        out += " checks=\(settings.auditLogsFilterChecks) motion=\(settings.auditLogsMotionEvents)"
        out += " minSeverity=\(settings.auditMinimumSeverity.label) retentionDays=\(settings.auditRetentionDays)\n"
        out += String(repeating: "-", count: 72) + "\n"
        for event in events { out += textLine(event) }
        return out
    }

    /// One event as it appears in a text export, trailing newline included.
    /// Shared with the streaming writer so the two cannot drift.
    static func textLine(_ event: AuditEvent) -> String {
        var out = "\(GPXExporter.iso(event.timestamp)) "
        out += "[\(event.severity.label.uppercased())] "
        out += "\(event.category.rawValue)/\(event.summary)"
        if let phase = event.phase { out += " phase=\(phase.rawValue)" }
        if let battery = event.batteryLevel {
            out += " battery=\(String(format: "%.2f", locale: nil, battery))"
        }
        out += "\n"
        for detail in event.details {
            out += "      \(detail.key): \(detail.value)\n"
        }
        return out
    }

    /// Writes the trail and returns the file URL, ready for `ShareLink`.
    static func write(_ events: [AuditEvent],
                      settings: TrackingSettings,
                      format: AuditExportFormat,
                      compressed: Bool = false,
                      name: String = "WhereIWas-audit",
                      exportedAt: Date = Date(),
                      to directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent(
            format.fileName("\(name)-\(stamp(exportedAt))", compressed: compressed))
        let body: Data
        switch format {
        case .json:
            body = try json(events, settings: settings, exportedAt: exportedAt)
        case .text:
            body = Data(text(events, settings: settings, exportedAt: exportedAt).utf8)
        }
        let writer = try AuditFileWriter(url: url, compressed: compressed)
        try writer.write(body)
        try writer.finish()
        return url
    }

    /// The timestamp in a file name: an ISO instant with the characters a file
    /// system would rather not see taken out.
    private static func stamp(_ date: Date) -> String {
        GPXExporter.iso(date)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    // MARK: Streaming

    /// Writes the trail page by page and returns the file and how many events
    /// went into it.
    ///
    /// `nextPage` is called until it returns `nil`; nothing larger than one
    /// page is ever held. Both formats announce the event count in their
    /// header and the count is only known once the last page has been read,
    /// so the events go to a scratch file first, the header is written with
    /// the final count, and the scratch file is appended in 256 KB chunks.
    ///
    /// This is what an export uses. The whole-array `write(_:settings:…)`
    /// above stays for the small, known-size cases (the tests, the demo
    /// controller) where a scratch file would be ceremony.
    static func write(settings: TrackingSettings,
                      format: AuditExportFormat,
                      compressed: Bool = false,
                      name: String = "WhereIWas-audit",
                      exportedAt: Date = Date(),
                      to directory: URL = FileManager.default.temporaryDirectory,
                      isolation: isolated (any Actor)? = #isolation,
                      nextPage: () async throws -> [AuditEvent]?) async throws -> (url: URL, count: Int) {
        let base = "\(name)-\(stamp(exportedAt))"
        let url = directory.appendingPathComponent(format.fileName(base, compressed: compressed))
        let scratch = directory.appendingPathComponent("\(base).part")
        defer { try? FileManager.default.removeItem(at: scratch) }

        // The scratch file holds the events uncompressed: the count they carry
        // is only known once the last page has been read, and it belongs in
        // the header. Compression happens on the way out, so the file the user
        // gets is written once and the large one never exists.
        let count = try await writeBody(to: scratch, format: format, nextPage: nextPage)

        let out = try AuditFileWriter(url: url, compressed: compressed)
        try out.write(Data(header(settings: settings,
                                  format: format,
                                  exportedAt: exportedAt,
                                  count: count).utf8))
        let body = try FileHandle(forReadingFrom: scratch)
        defer { try? body.close() }
        while let chunk = try body.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try out.write(chunk)
        }
        try out.write(Data(footer(settings: settings,
                                  format: format,
                                  exportedAt: exportedAt,
                                  count: count).utf8))
        try out.finish()
        return (url, count)
    }

    /// Streams every event into `scratch` and returns how many there were.
    private static func writeBody(to scratch: URL,
                                  format: AuditExportFormat,
                                  isolation: isolated (any Actor)? = #isolation,
                                  nextPage: () async throws -> [AuditEvent]?) async throws -> Int {
        try? FileManager.default.removeItem(at: scratch)
        guard FileManager.default.createFile(atPath: scratch.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: scratch)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var count = 0
        while let page = try await nextPage() {
            var chunk = Data()
            for event in page {
                switch format {
                case .json:
                    chunk.append(Data((count == 0 ? "\n    " : ",\n    ").utf8))
                    chunk.append(try encoder.encode(event))
                case .text:
                    chunk.append(Data(textLine(event).utf8))
                }
                count += 1
            }
            if !chunk.isEmpty { try handle.write(contentsOf: chunk) }
        }
        return count
    }

    /// The envelope up to the point where the events start.
    ///
    /// Written by hand rather than encoded, because the events are streamed in
    /// after it. `.sortedKeys` puts `eventCount` and `events` before the rest,
    /// which is what makes a streamed body possible — so this text and
    /// ``footer(settings:format:exportedAt:count:)`` have to keep that order.
    private static func header(settings: TrackingSettings,
                               format: AuditExportFormat,
                               exportedAt: Date,
                               count: Int) -> String {
        let app = AppBuild.current
        switch format {
        case .json:
            return "{\n  \"app\" : \(inline(app)),\n  \"eventCount\" : \(count),\n  \"events\" : ["
        case .text:
            var out = "WhereIWas audit trail\n"
            out += "exported: \(GPXExporter.iso(exportedAt))\n"
            out += "app: \(app.version) (\(app.build)) on \(app.system)\n"
            out += "events: \(count)\n"
            out += "recording: accepted=\(settings.auditLogsAcceptedFixes) rejected=\(settings.auditLogsRejectedFixes)"
            out += " checks=\(settings.auditLogsFilterChecks) motion=\(settings.auditLogsMotionEvents)"
            out += " minSeverity=\(settings.auditMinimumSeverity.label) retentionDays=\(settings.auditRetentionDays)\n"
            out += String(repeating: "-", count: 72) + "\n"
            return out
        }
    }

    /// Everything after the events: the keys that sort after `events`.
    private static func footer(settings: TrackingSettings,
                               format: AuditExportFormat,
                               exportedAt: Date,
                               count: Int) -> String {
        guard format == .json else { return "" }
        var out = count == 0 ? "]" : "\n  ]"
        out += ",\n  \"exportedAt\" : \"\(iso8601(exportedAt))\""
        out += ",\n  \"format\" : \"whereiwas.audit\""
        out += ",\n  \"settings\" : \(inline(settings))"
        out += ",\n  \"version\" : 1\n}\n"
        return out
    }

    /// A `Codable` value as one line of JSON, for embedding in the envelope.
    private static func inline<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// The same shape `JSONEncoder.dateEncodingStrategy = .iso8601` writes, so
    /// a streamed envelope decodes with the same decoder as a whole-array one.
    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
