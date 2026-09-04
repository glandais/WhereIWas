import Foundation
import SwiftData

/// A persisted ``AuditEvent``.
///
/// Details are stored as a single JSON blob: they are never queried on, only
/// rendered and exported, and one column keeps the table narrow enough that
/// the audit trail stays cheap even at debug verbosity.
@Model
final class AuditEventLog {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var categoryRaw: String
    var severityRaw: Int
    var name: String
    /// The code's parameters, joined by a unit separator: they are never
    /// queried on, only rendered. Defaulted so a store written before the
    /// codes replaced the English `message` migrates lightly.
    var argumentsRaw: String = ""
    /// JSON-encoded `[AuditDetail]`. Empty data means no details.
    var detailsData: Data
    var phaseRaw: String?
    var batteryLevel: Double?

    /// ASCII unit separator: it cannot occur in a formatted argument.
    static let argumentSeparator = "\u{1F}"

    init(event: AuditEvent) {
        id = event.id
        timestamp = event.timestamp
        categoryRaw = event.category.rawValue
        severityRaw = event.severity.rawValue
        name = event.name
        argumentsRaw = event.arguments.joined(separator: AuditEventLog.argumentSeparator)
        detailsData = (try? JSONEncoder().encode(event.details)) ?? Data()
        phaseRaw = event.phase?.rawValue
        batteryLevel = event.batteryLevel
    }

    var event: AuditEvent {
        AuditEvent(id: id,
                   timestamp: timestamp,
                   category: AuditCategory(rawValue: categoryRaw) ?? .lifecycle,
                   severity: AuditSeverity(rawValue: severityRaw) ?? .info,
                   name: name,
                   arguments: argumentsRaw.isEmpty ? [] : argumentsRaw.components(separatedBy: AuditEventLog.argumentSeparator),
                   details: (try? JSONDecoder().decode([AuditDetail].self, from: detailsData)) ?? [],
                   phase: phaseRaw.flatMap(TrackingPhase.init(rawValue:)),
                   batteryLevel: batteryLevel)
    }
}
