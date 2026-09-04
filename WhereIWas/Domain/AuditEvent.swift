import Foundation

/// What part of the system an ``AuditEvent`` came from.
///
/// Categories are the filter axis of the audit screen and of the audit
/// export, so they are coarse on purpose: one per collaborator.
public enum AuditCategory: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    /// Process launch, re-arm, background / foreground transitions.
    case lifecycle
    /// State-machine inputs and the transitions they produced.
    case state
    /// Effects the coordinator executed on behalf of the machine.
    case effect
    /// Raw location data in and out of CoreLocation.
    case location
    /// The per-fix validation checks (the "tests" run on each sample).
    case filter
    /// CoreMotion activity, pedometer and accelerometer signals.
    case motion
    /// Location / motion authorization changes.
    case permission
    /// Store writes, sessions, purges.
    case persistence
    /// Background maintenance task.
    case maintenance
    /// Export operations.
    case export

    public var id: String { rawValue }

    /// SF Symbol used by the audit screen.
    public var symbolName: String {
        switch self {
        case .lifecycle: return "power"
        case .state: return "arrow.triangle.branch"
        case .effect: return "bolt"
        case .location: return "location"
        case .filter: return "line.3.horizontal.decrease.circle"
        case .motion: return "figure.walk.motion"
        case .permission: return "lock.shield"
        case .persistence: return "internaldrive"
        case .maintenance: return "wrench.and.screwdriver"
        case .export: return "square.and.arrow.up"
        }
    }
}

/// How much attention an ``AuditEvent`` deserves.
public enum AuditSeverity: Int, Codable, Sendable, Hashable, Comparable, CaseIterable {
    /// High-volume detail (every fix, every check).
    case debug = 0
    /// Normal operation worth keeping.
    case info = 1
    /// Something unexpected that tracking recovered from.
    case warning = 2
    /// Something that stopped or degraded tracking.
    case error = 3

    public static func < (lhs: AuditSeverity, rhs: AuditSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }
}

/// One ordered key/value pair attached to an ``AuditEvent``.
///
/// Details are stored as an ordered array rather than a dictionary so the
/// audit screen and the text export always render fields in the order the
/// producer wrote them, and so the encoded form is stable across runs.
public struct AuditDetail: Codable, Sendable, Hashable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    /// Convenience for numbers, rendered locale-independently.
    public init(_ key: String, _ value: Double, decimals: Int = 2) {
        self.key = key
        self.value = String(format: "%.\(decimals)f", locale: nil, value)
    }

    public init(_ key: String, _ value: Int) {
        self.key = key
        self.value = String(value)
    }

    public init(_ key: String, _ value: Bool) {
        self.key = key
        self.value = value ? "true" : "false"
    }
}

/// A single audit-trail entry.
///
/// Audit events are only produced when the user has opted in (see
/// ``TrackingSettings/auditEnabled``). They are written to the same SQLite
/// store as the samples, in their own table, and are purged on their own
/// retention schedule.
public struct AuditEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var category: AuditCategory
    public var severity: AuditSeverity
    /// Short, stable, machine-greppable event code, e.g. `fix.rejected`.
    ///
    /// The code *is* the message: the UI renders a localized sentence from it
    /// (`Formatting.auditSummary`) and the export writes it as-is. Codes that
    /// need a parameter carry it in ``arguments`` rather than in prose, so
    /// nothing English is ever persisted or parsed back.
    public var name: String
    /// Parameters the code needs to read as a sentence, in the order the
    /// sentence uses them. Formatted locale-independently; empty whenever the
    /// code says everything on its own.
    public var arguments: [String]
    /// Ordered structured payload: the data the event is about.
    public var details: [AuditDetail]
    /// State-machine phase at the time of the event, when known.
    public var phase: TrackingPhase?
    /// Battery level (0...1) at the time of the event, when known.
    public var batteryLevel: Double?

    public init(id: UUID = UUID(),
                timestamp: Date,
                category: AuditCategory,
                severity: AuditSeverity = .info,
                name: String,
                arguments: [String] = [],
                details: [AuditDetail] = [],
                phase: TrackingPhase? = nil,
                batteryLevel: Double? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.severity = severity
        self.name = name
        self.arguments = arguments
        self.details = details
        self.phase = phase
        self.batteryLevel = batteryLevel
    }

    /// `name arg arg` — the machine rendering, used by the text export and
    /// the log lines. The UI shows the localized ``Formatting/auditSummary``
    /// of the same thing.
    public var summary: String {
        arguments.isEmpty ? name : "\(name) \(arguments.joined(separator: " "))"
    }

    /// `key=value key=value` rendering of ``details``, used by the text
    /// export and the log line.
    public var detailLine: String {
        details.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}

/// Filter applied when reading the audit trail back.
public struct AuditQuery: Sendable, Hashable {
    /// Only these categories; `nil` means all of them.
    public var categories: Set<AuditCategory>?
    /// Only events at or above this severity.
    public var minimumSeverity: AuditSeverity
    /// Only events inside this interval; `nil` means no bound.
    public var interval: DateInterval?
    /// Newest-first result cap.
    public var limit: Int

    public init(categories: Set<AuditCategory>? = nil,
                minimumSeverity: AuditSeverity = .debug,
                interval: DateInterval? = nil,
                limit: Int = 500) {
        self.categories = categories
        self.minimumSeverity = minimumSeverity
        self.interval = interval
        self.limit = limit
    }

    /// Does `event` match this query? (Used by the in-memory ring buffer;
    /// the store applies the equivalent predicate in SQLite.)
    public func matches(_ event: AuditEvent) -> Bool {
        if let categories, !categories.contains(event.category) { return false }
        if event.severity < minimumSeverity { return false }
        if let interval, !interval.contains(event.timestamp) { return false }
        return true
    }
}

// MARK: - Recording

/// Sink for audit events.
///
/// `record` takes an `@autoclosure` so that building the event — string
/// interpolation, detail arrays — costs nothing at all when the audit trail
/// is off, which is the default. Always call it as
/// `audit.record(AuditEvent(...))` and never hoist the event into a `let`.
@MainActor
public protocol AuditRecording: AnyObject {
    /// `false` when the user has not opted in. Producers may check it to skip
    /// expensive preparation, but `record` is already free when it is `false`.
    var isEnabled: Bool { get }

    /// Append an event. Never throws, never blocks: implementations buffer in
    /// memory and flush to storage asynchronously.
    func record(_ event: @autoclosure () -> AuditEvent)
}

/// Audit sink used when the feature is compiled in but nothing should be
/// recorded (previews, tests that do not assert on the trail).
@MainActor
public final class NoopAuditLog: AuditRecording {
    public init() {}
    public var isEnabled: Bool { false }
    public func record(_ event: @autoclosure () -> AuditEvent) {}
}
