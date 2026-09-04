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
        var eventCount: Int
        var settings: TrackingSettings
        var events: [AuditEvent]
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
        out += "events: \(events.count)\n"
        out += "recording: accepted=\(settings.auditLogsAcceptedFixes) rejected=\(settings.auditLogsRejectedFixes)"
        out += " checks=\(settings.auditLogsFilterChecks) motion=\(settings.auditLogsMotionEvents)"
        out += " minSeverity=\(settings.auditMinimumSeverity.label) retentionDays=\(settings.auditRetentionDays)\n"
        out += String(repeating: "-", count: 72) + "\n"
        for event in events {
            out += "\(GPXExporter.iso(event.timestamp)) "
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
        }
        return out
    }

    /// Writes the trail and returns the file URL, ready for `ShareLink`.
    static func write(_ events: [AuditEvent],
                      settings: TrackingSettings,
                      format: AuditExportFormat,
                      name: String = "WhereIWas-audit",
                      exportedAt: Date = Date(),
                      to directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let stamp = GPXExporter.iso(exportedAt)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
        let url = directory.appendingPathComponent("\(name)-\(stamp).\(format.fileExtension)")
        switch format {
        case .json:
            try json(events, settings: settings, exportedAt: exportedAt).write(to: url, options: .atomic)
        case .text:
            try Data(text(events, settings: settings, exportedAt: exportedAt).utf8)
                .write(to: url, options: .atomic)
        }
        return url
    }
}
