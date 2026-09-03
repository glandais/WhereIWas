import Foundation
import SwiftData

// SwiftData model classes. They never leave the Persistence module:
// `LocationStore` converts them to/from the `Sendable` DTOs in
// `Domain/Interfaces.swift`. Enums are stored as raw values so predicates
// stay simple and the schema stays lightweight-migratable.

/// One accepted location fix plus its annotation.
///
/// `sequence` is the monotonically increasing primary key used for upload
/// batching. It is unique (SwiftData creates an index for `.unique`) and is
/// assigned by ``LocationStore`` from an in-memory counter seeded with
/// `max(sequence)` at first use.
@Model
final class LocationSample {
    @Attribute(.unique) var sequence: Int64

    // LocationFix
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var horizontalAccuracy: Double
    var verticalAccuracy: Double
    var speed: Double
    var speedAccuracy: Double
    var course: Double
    /// Fix timestamp (GPS time). Used for date-range queries and purge.
    var timestamp: Date

    // SampleAnnotation
    var activityRaw: String
    var activityConfidenceRaw: Int
    var phaseRaw: String
    var batteryLevel: Double?
    var batteryStateRaw: String
    /// Denormalized session id (no relationship: purging thousands of rows
    /// must not touch the session graph, and the DTO only needs the id).
    var sessionID: UUID?
    var profileLabel: String?

    var sourceRaw: String
    /// `false` until an upload layer flips it via `markUploaded`.
    var uploaded: Bool
    /// Wall-clock time the row was written.
    var createdAt: Date

    init(sequence: Int64, draft: LocationSampleDraft, createdAt: Date) {
        self.sequence = sequence
        let fix = draft.fix
        latitude = fix.latitude
        longitude = fix.longitude
        altitude = fix.altitude
        horizontalAccuracy = fix.horizontalAccuracy
        verticalAccuracy = fix.verticalAccuracy
        speed = fix.speed
        speedAccuracy = fix.speedAccuracy
        course = fix.course
        timestamp = fix.timestamp
        let a = draft.annotation
        activityRaw = a.activity.rawValue
        activityConfidenceRaw = a.activityConfidence.rawValue
        phaseRaw = a.phase.rawValue
        batteryLevel = a.batteryLevel
        batteryStateRaw = a.batteryState.rawValue
        sessionID = a.sessionID
        profileLabel = a.profileLabel
        sourceRaw = draft.source.rawValue
        uploaded = false
        self.createdAt = createdAt
    }

    var fix: LocationFix {
        LocationFix(latitude: latitude,
                    longitude: longitude,
                    altitude: altitude,
                    horizontalAccuracy: horizontalAccuracy,
                    verticalAccuracy: verticalAccuracy,
                    speed: speed,
                    speedAccuracy: speedAccuracy,
                    course: course,
                    timestamp: timestamp)
    }

    var annotation: SampleAnnotation {
        SampleAnnotation(activity: ActivityKind(rawValue: activityRaw) ?? .unknown,
                         activityConfidence: ActivityConfidence(rawValue: activityConfidenceRaw) ?? .low,
                         phase: TrackingPhase(rawValue: phaseRaw) ?? .disabled,
                         batteryLevel: batteryLevel,
                         batteryState: BatteryState(rawValue: batteryStateRaw) ?? .unknown,
                         sessionID: sessionID,
                         profileLabel: profileLabel)
    }

    var stored: StoredLocationSample {
        StoredLocationSample(sequence: sequence,
                             fix: fix,
                             annotation: annotation,
                             source: LocationSource(rawValue: sourceRaw) ?? .gps,
                             uploaded: uploaded,
                             createdAt: createdAt)
    }
}

/// One enable → disable interval. `sampleCount` / `distanceMeters` are
/// maintained incrementally on insert (the last coordinate is cached so no
/// fetch is needed to extend the path length).
@Model
final class TrackingSession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var sampleCount: Int
    var distanceMeters: Double
    var lastLatitude: Double?
    var lastLongitude: Double?

    init(id: UUID = UUID(), startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
        endedAt = nil
        sampleCount = 0
        distanceMeters = 0
        lastLatitude = nil
        lastLongitude = nil
    }

    var summary: TrackingSessionSummary {
        TrackingSessionSummary(id: id,
                               startedAt: startedAt,
                               endedAt: endedAt,
                               sampleCount: sampleCount,
                               distanceMeters: distanceMeters)
    }

    /// Extends the cached path length with `fix` and bumps the counter.
    func append(_ fix: LocationFix) {
        if let lat = lastLatitude, let lon = lastLongitude {
            let previous = LocationFix(latitude: lat, longitude: lon,
                                       horizontalAccuracy: 1, timestamp: fix.timestamp)
            distanceMeters += previous.distance(to: fix)
        }
        lastLatitude = fix.latitude
        lastLongitude = fix.longitude
        sampleCount += 1
    }
}

/// A persisted state-machine transition (diagnostics for the status screen).
@Model
final class StateTransitionLog {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var fromRaw: String
    var toRaw: String
    var reason: String
    var batteryLevel: Double?

    init(record: StateTransitionRecord) {
        id = record.id
        timestamp = record.timestamp
        fromRaw = record.from.rawValue
        toRaw = record.to.rawValue
        reason = record.reason
        batteryLevel = record.batteryLevel
    }

    var record: StateTransitionRecord {
        StateTransitionRecord(id: id,
                              timestamp: timestamp,
                              from: TrackingPhase(rawValue: fromRaw) ?? .disabled,
                              to: TrackingPhase(rawValue: toRaw) ?? .disabled,
                              reason: reason,
                              batteryLevel: batteryLevel)
    }
}
