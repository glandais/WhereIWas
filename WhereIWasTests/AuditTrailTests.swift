import Foundation
import SwiftData
import Testing
@testable import WhereIWas

// MARK: - Filter trace

@Suite("Audit · filter trace")
struct LocationFilterTraceTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func fix(lat: Double = 48.0,
                     lon: Double = 2.0,
                     accuracy: Double = 10,
                     age: TimeInterval = 1) -> LocationFix {
        LocationFix(latitude: lat, longitude: lon, horizontalAccuracy: accuracy,
                    speed: 1.2, timestamp: now.addingTimeInterval(-age))
    }

    @Test("The trace always agrees with the filter's own decision")
    func traceMatchesEvaluate() {
        var settings = TrackingSettings()
        settings.duplicateDistance = 5
        let previous = fix(lat: 48.0, lon: 2.0, accuracy: 8, age: 10)

        let accuracies: [Double] = [-1, 0, 5, 50, 51, 500]
        let ages: [TimeInterval] = [-30, -1, 0, 5, 30, 31, 120]
        let offsets: [Double] = [0, 0.00001, 0.001]
        let previousOptions: [LocationFix?] = [nil, previous]

        for accuracy in accuracies {
            for age in ages {
                for offset in offsets {
                    for prev in previousOptions {
                        let candidate = fix(lat: 48.0 + offset, lon: 2.0 + offset,
                                            accuracy: accuracy, age: age)
                        let decision = LocationFilter.evaluate(candidate, previous: prev,
                                                               now: now, settings: settings)
                        let trace = LocationFilter.trace(candidate, previous: prev,
                                                         now: now, settings: settings)
                        #expect(trace.result == decision,
                                "accuracy=\(accuracy) age=\(age) offset=\(offset) previous=\(prev != nil)")
                    }
                }
            }
        }
    }

    @Test("Every check is reported, in order, exactly once")
    func everyCheckReported() {
        let trace = LocationFilter.trace(fix(), previous: nil, now: now)
        #expect(trace.checks.map(\.name) == LocationFilter.checkNames)
    }

    @Test("Checks after the first failure are skipped, not evaluated")
    func checksStopAtFirstFailure() {
        let trace = LocationFilter.trace(fix(accuracy: -1), previous: nil, now: now)
        #expect(trace.checks[0].verdict == .failed)
        #expect(trace.checks.dropFirst().allSatisfy { $0.verdict == .skipped })
        #expect(trace.failedCheck == "horizontalAccuracy.valid")
    }

    @Test("Ordering and duplicate checks are not applicable without a predecessor")
    func notApplicableWithoutPrevious() {
        let trace = LocationFilter.trace(fix(), previous: nil, now: now)
        #expect(trace.isAccepted)
        #expect(trace.checks.suffix(2).allSatisfy { $0.verdict == .notApplicable })
    }

    @Test("A passing check carries the measured value and the threshold")
    func checksCarryNumbers() {
        var settings = TrackingSettings()
        settings.maxHorizontalAccuracy = 50
        let trace = LocationFilter.trace(fix(accuracy: 12.5), previous: nil, now: now, settings: settings)
        let check = try! #require(trace.checks.first { $0.name == "horizontalAccuracy.withinLimit" })
        #expect(check.measured == "12.50")
        #expect(check.limit == "<= 50.00 m")
    }
}

// MARK: - Opt-in behaviour

@MainActor
@Suite("Audit · opt-in log")
struct AuditLogTests {
    private func makeStore() throws -> LocationStore {
        LocationStore(modelContainer: try LocationStore.makeContainer(inMemory: true))
    }

    private func event(_ name: String, severity: AuditSeverity = .info) -> AuditEvent {
        AuditEvent(timestamp: Date(), category: .state, severity: severity,
                   name: name, message: name)
    }

    @Test("Disabled by default: nothing is recorded and the event is never built")
    func disabledByDefault() async throws {
        let store = try makeStore()
        let log = AuditLog(store: store, settings: TrackingSettings())
        #expect(!log.isEnabled)

        var built = 0
        log.record({ built += 1; return event("ignored") }())
        #expect(built == 0)
        #expect(log.recent().isEmpty)
        await log.flush()
        #expect(try await store.auditCount() == 0)
    }

    @Test("Enabling records the opt-in itself, so a trail says why it exists")
    func enablingIsItselfRecorded() throws {
        let store = try makeStore()
        let log = AuditLog(store: store, settings: TrackingSettings())
        var settings = TrackingSettings()
        settings.auditEnabled = true
        log.apply(settings: settings)

        #expect(log.isEnabled)
        let events = log.recent()
        #expect(events.count == 1)
        #expect(events.first?.name == "audit.enabled")
    }

    @Test("Events below the minimum severity are dropped")
    func severityFilter() throws {
        let store = try makeStore()
        var settings = TrackingSettings()
        settings.auditEnabled = true
        settings.auditMinimumSeverity = .warning
        let log = AuditLog(store: store, settings: settings)

        log.record(event("debug", severity: .debug))
        log.record(event("info", severity: .info))
        log.record(event("warning", severity: .warning))
        log.record(event("error", severity: .error))

        #expect(log.recent().map(\.name) == ["error", "warning"])
    }

    @Test("Events reach storage and come back newest first")
    func roundTripThroughStore() async throws {
        let store = try makeStore()
        var settings = TrackingSettings()
        settings.auditEnabled = true
        let log = AuditLog(store: store, settings: settings)

        for i in 0..<5 {
            log.record(AuditEvent(timestamp: Date(timeIntervalSince1970: 1_000 + Double(i)),
                                  category: .location, severity: .info,
                                  name: "fix.\(i)", message: "fix \(i)"))
        }
        let loaded = try await log.load(matching: AuditQuery())
        #expect(loaded.map(\.name) == ["fix.4", "fix.3", "fix.2", "fix.1", "fix.0"])
        #expect(try await log.storedCount() == 5)
    }

    @Test("Category and severity filters are applied by the store")
    func storeQueryFilters() async throws {
        let store = try makeStore()
        var settings = TrackingSettings()
        settings.auditEnabled = true
        let log = AuditLog(store: store, settings: settings)

        log.record(AuditEvent(timestamp: Date(timeIntervalSince1970: 1),
                              category: .location, severity: .debug, name: "a", message: "a"))
        log.record(AuditEvent(timestamp: Date(timeIntervalSince1970: 2),
                              category: .motion, severity: .warning, name: "b", message: "b"))
        log.record(AuditEvent(timestamp: Date(timeIntervalSince1970: 3),
                              category: .location, severity: .error, name: "c", message: "c"))

        let byCategory = try await log.load(matching: AuditQuery(categories: [.location]))
        #expect(byCategory.map(\.name) == ["c", "a"])

        let bySeverity = try await log.load(matching: AuditQuery(minimumSeverity: .warning))
        #expect(bySeverity.map(\.name) == ["c", "b"])
    }

    @Test("The trail has its own retention, independent of the samples")
    func purgeUsesAuditRetention() async throws {
        let store = try makeStore()
        var settings = TrackingSettings()
        settings.auditEnabled = true
        let log = AuditLog(store: store, settings: settings)
        let now = Date(timeIntervalSince1970: 10_000_000)

        log.record(AuditEvent(timestamp: now.addingTimeInterval(-86_400 * 10),
                              category: .state, severity: .info, name: "old", message: "old"))
        log.record(AuditEvent(timestamp: now.addingTimeInterval(-86_400),
                              category: .state, severity: .info, name: "recent", message: "recent"))

        let deleted = await log.purge(retentionDays: 7, now: now)
        #expect(deleted == 1)
        let left = try await log.load(matching: AuditQuery())
        #expect(left.map(\.name) == ["recent"])
    }

    @Test("Clearing removes both the buffer and the stored trail")
    func clearRemovesEverything() async throws {
        let store = try makeStore()
        var settings = TrackingSettings()
        settings.auditEnabled = true
        let log = AuditLog(store: store, settings: settings)
        log.record(event("one"))
        await log.flush()

        let deleted = await log.clear()
        #expect(deleted == 1)
        #expect(log.recent().isEmpty)
        #expect(try await store.auditCount() == 0)
    }

    @Test("Turning the trail off flushes what was buffered and stops recording")
    func disablingFlushesAndStops() async throws {
        let store = try makeStore()
        var on = TrackingSettings()
        on.auditEnabled = true
        let log = AuditLog(store: store, settings: on)
        log.record(event("before"))

        log.apply(settings: TrackingSettings())
        #expect(!log.isEnabled)
        log.record(event("after"))
        await log.flush()

        let stored = try await store.auditEvents(matching: AuditQuery())
        #expect(stored.map(\.name) == ["before"])
    }
}

// MARK: - Export

@Suite("Audit · export")
struct AuditExporterTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var sample: [AuditEvent] {
        [AuditEvent(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
                    timestamp: now,
                    category: .filter,
                    severity: .info,
                    name: "fix.rejected",
                    message: "Fix rejected: poorAccuracy(88.0 m)",
                    details: [AuditDetail("horizontalAccuracy", 88.0),
                              AuditDetail("check.horizontalAccuracy.withinLimit", "failed (88.00 vs <= 50.00 m)")],
                    phase: .moving,
                    batteryLevel: 0.42)]
    }

    @Test("JSON export round-trips and carries the settings in force")
    func jsonRoundTrip() throws {
        var settings = TrackingSettings()
        settings.auditEnabled = true
        settings.auditRetentionDays = 3
        let data = try AuditExporter.json(sample, settings: settings, exportedAt: now)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(AuditExporter.Envelope.self, from: data)
        #expect(envelope.format == "whereiwas.audit")
        #expect(envelope.eventCount == 1)
        #expect(envelope.settings.auditRetentionDays == 3)
        #expect(envelope.events == sample)
    }

    @Test("Text export shows the event, its data and its tests")
    func textExport() {
        let text = AuditExporter.text(sample, settings: TrackingSettings(), exportedAt: now)
        #expect(text.contains("WhereIWas audit trail"))
        #expect(text.contains("filter/fix.rejected"))
        #expect(text.contains("phase=moving"))
        #expect(text.contains("battery=0.42"))
        #expect(text.contains("horizontalAccuracy: 88.00"))
        #expect(text.contains("check.horizontalAccuracy.withinLimit: failed (88.00 vs <= 50.00 m)"))
    }

    @Test("Writing produces a file with the right extension")
    func writeFile() throws {
        let url = try AuditExporter.write(sample, settings: TrackingSettings(), format: .text, exportedAt: now)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.pathExtension == "txt")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Settings

@Suite("Audit · settings")
struct AuditSettingsTests {
    @Test("The audit trail is off by default")
    func offByDefault() {
        let settings = TrackingSettings()
        #expect(!settings.auditEnabled)
        #expect(settings.auditRetentionDays == 7)
        #expect(settings.auditLogsAcceptedFixes)
        #expect(settings.auditLogsRejectedFixes)
        #expect(settings.auditLogsFilterChecks)
        #expect(settings.auditLogsMotionEvents)
    }

    @Test("Audit settings survive a JSON round-trip")
    func roundTrip() throws {
        var settings = TrackingSettings()
        settings.auditEnabled = true
        settings.auditMinimumSeverity = .warning
        settings.auditRetentionDays = 14
        settings.auditLogsAcceptedFixes = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TrackingSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test("A settings blob written before the audit trail existed still decodes")
    func decodesLegacyBlob() throws {
        let legacy = #"{"stillnessTimeout":90,"retentionDays":5}"#
        let decoded = try JSONDecoder().decode(TrackingSettings.self, from: Data(legacy.utf8))
        #expect(decoded.stillnessTimeout == 90)
        #expect(decoded.retentionDays == 5)
        #expect(!decoded.auditEnabled)
        #expect(decoded.auditRetentionDays == 7)
    }
}
