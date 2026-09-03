import Foundation

/// A raw GPS fix, framework-free mirror of `CLLocation`.
///
/// The Location module builds one from every `CLLocation`; everything
/// downstream (filter, state machine, store drafts, UI) uses this type.
public struct LocationFix: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    /// Meters above WGS84 ellipsoid (CoreLocation `altitude`).
    public var altitude: Double
    /// Meters. `<= 0` means invalid, per CoreLocation.
    public var horizontalAccuracy: Double
    /// Meters. `<= 0` means invalid.
    public var verticalAccuracy: Double
    /// m/s. Negative means invalid.
    public var speed: Double
    /// m/s. Negative means invalid.
    public var speedAccuracy: Double
    /// Degrees, 0 = north. Negative means invalid.
    public var course: Double
    public var timestamp: Date

    public init(latitude: Double,
                longitude: Double,
                altitude: Double = 0,
                horizontalAccuracy: Double,
                verticalAccuracy: Double = -1,
                speed: Double = -1,
                speedAccuracy: Double = -1,
                course: Double = -1,
                timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.timestamp = timestamp
    }

    /// `speed` if valid, otherwise `nil`.
    public var validSpeed: Double? { speed >= 0 ? speed : nil }

    /// Great-circle distance to another fix, in meters (haversine).
    public func distance(to other: LocationFix) -> Double {
        let r = 6_371_000.0
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(other.latitude * .pi / 180)
            * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// Why a fix was rejected by ``LocationFilter``.
public enum LocationRejection: Sendable, Equatable {
    /// `horizontalAccuracy <= 0`.
    case invalidAccuracy
    /// `horizontalAccuracy > settings.maxHorizontalAccuracy`.
    case poorAccuracy(meters: Double)
    /// The fix is older than `settings.maxSampleAge` relative to `now`
    /// (CoreLocation delivers cached fixes right after `startUpdatingLocation`).
    case stale(ageSeconds: Double)
    /// The fix is in the future by more than a small tolerance (clock skew).
    case futureTimestamp
    /// Same coordinates as the previously accepted fix, within
    /// `settings.duplicateDistance` meters, and not older than the previous.
    case duplicate
    /// Timestamp is not after the previous accepted fix.
    case outOfOrder
}

/// Result of ``LocationFilter/evaluate(_:previous:now:settings:)``.
public enum LocationFilterResult: Sendable, Equatable {
    case accepted
    case rejected(LocationRejection)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// Pure sample validation. No state; the caller passes the previously
/// accepted fix so duplicate / ordering checks can be made.
public enum LocationFilter {
    /// Tolerance for fixes timestamped slightly in the future.
    public static let futureTolerance: TimeInterval = 5

    /// Evaluate a fix.
    ///
    /// Check order (first failure wins):
    /// 1. `invalidAccuracy`  2. `poorAccuracy`  3. `futureTimestamp`
    /// 4. `stale`  5. `outOfOrder`  6. `duplicate`
    public static func evaluate(_ fix: LocationFix,
                                previous: LocationFix?,
                                now: Date,
                                settings: TrackingSettings = TrackingSettings()) -> LocationFilterResult {
        if fix.horizontalAccuracy <= 0 {
            return .rejected(.invalidAccuracy)
        }
        if fix.horizontalAccuracy > settings.maxHorizontalAccuracy {
            return .rejected(.poorAccuracy(meters: fix.horizontalAccuracy))
        }
        let age = now.timeIntervalSince(fix.timestamp)
        if age < -futureTolerance {
            return .rejected(.futureTimestamp)
        }
        if age > settings.maxSampleAge {
            return .rejected(.stale(ageSeconds: age))
        }
        if let previous {
            if fix.timestamp <= previous.timestamp {
                return .rejected(.outOfOrder)
            }
            if fix.distance(to: previous) <= settings.duplicateDistance {
                return .rejected(.duplicate)
            }
        }
        return .accepted
    }

    /// Convenience: keep only accepted fixes from a batch, threading the
    /// previously accepted fix through. Returns accepted fixes in order.
    public static func filter(_ fixes: [LocationFix],
                              previous: LocationFix?,
                              now: Date,
                              settings: TrackingSettings = TrackingSettings()) -> [LocationFix] {
        var last = previous
        var out: [LocationFix] = []
        for fix in fixes {
            if evaluate(fix, previous: last, now: now, settings: settings).isAccepted {
                out.append(fix)
                last = fix
            }
        }
        return out
    }
}
