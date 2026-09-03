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
    var message: String
    /// JSON-encoded `[AuditDetail]`. Empty data means no details.
    var detailsData: Data
    var phaseRaw: String?
    var batteryLevel: Double?

    init(event: AuditEvent) {
        id = event.id
        timestamp = event.timestamp
        categoryRaw = event.category.rawValue
        severityRaw = event.severity.rawValue
        name = event.name
        message = event.message
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
                   message: message,
                   details: (try? JSONDecoder().decode([AuditDetail].self, from: detailsData)) ?? [],
                   phase: phaseRaw.flatMap(TrackingPhase.init(rawValue:)),
                   batteryLevel: batteryLevel)
    }
}
