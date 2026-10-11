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
    /// iOS replayed a cached network fix: a fresh timestamp, no valid speed,
    /// and coordinates *and* accuracy strictly equal to a fix accepted a
    /// moment ago. `duplicate` only compares against the immediately previous
    /// fix, so such a fix slips through whenever a real one lands in between.
    case cachedRepeat
}

/// Result of ``LocationFilter/evaluate(_:previous:now:settings:recent:)``.
public enum LocationFilterResult: Sendable, Equatable {
    case accepted
    case rejected(LocationRejection)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// Pure sample validation. No state; the caller passes the previously
/// accepted fix, and the last few accepted ones, so duplicate / ordering /
/// cached-repeat checks can be made.
public enum LocationFilter {
    /// Tolerance for fixes timestamped slightly in the future.
    public static let futureTolerance: TimeInterval = 5

    /// A ceiling on the `cachedRepeat` history, never the limit that applies:
    /// one fix a second for ``recentWindow`` plus margin. It used to be ten,
    /// and a count was the bug — indoors on 2026-10-08, ten real fixes
    /// arrived in four minutes, pushed the replayed Wi-Fi fix's twin out, and
    /// the replay got back in every four minutes, each time a 28 m round trip
    /// in the trace.
    public static let recentCapacity = 1000

    /// How far back the `cachedRepeat` check compares, by age of the twin.
    /// ``remember(_:in:)`` refreshes a twin each time its replay is rejected,
    /// so a fix iOS keeps replaying stays silenced for as long as it does, and
    /// the window only lets it back in after ten minutes without one — by
    /// then it is a position again, not an echo. A receiver whose whole input
    /// is that one solution never reaches this check: `duplicate` compares it
    /// with itself first.
    public static let recentWindow: TimeInterval = 600

    /// Records `fix` in the `cachedRepeat` history: drops twins older than
    /// ``recentWindow`` and any earlier copy of the same solution, then
    /// appends it. Call it for every accepted GPS fix *and* every fix rejected
    /// as `cachedRepeat`, so the replay keeps its twin fresh.
    public static func remember(_ fix: LocationFix, in recent: inout [LocationFix]) {
        recent.removeAll {
            fix.timestamp.timeIntervalSince($0.timestamp) >= recentWindow
                || ($0.latitude == fix.latitude
                    && $0.longitude == fix.longitude
                    && $0.horizontalAccuracy == fix.horizontalAccuracy)
        }
        recent.append(fix)
        if recent.count > recentCapacity {
            recent.removeFirst(recent.count - recentCapacity)
        }
    }

    /// Evaluate a fix.
    ///
    /// Check order (first failure wins):
    /// 1. `invalidAccuracy`  2. `poorAccuracy`  3. `futureTimestamp`
    /// 4. `stale`  5. `outOfOrder`  6. `duplicate`  7. `cachedRepeat`
    ///
    /// - Parameter recent: the last accepted fixes, most recent order
    ///   irrelevant. Only used by the `cachedRepeat` check; an empty array
    ///   disables it.
    public static func evaluate(_ fix: LocationFix,
                                previous: LocationFix?,
                                now: Date,
                                settings: TrackingSettings = TrackingSettings(),
                                recent: [LocationFix] = []) -> LocationFilterResult {
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
        if isCachedRepeat(fix, recent: recent) {
            return .rejected(.cachedRepeat)
        }
        return .accepted
    }

    /// `true` when `fix` carries no valid speed and repeats, to the digit, the
    /// coordinates and horizontal accuracy of a fix accepted less than
    /// ``recentWindow`` ago.
    ///
    /// A real GPS fix moves a little and reports a speed; a replayed cached one
    /// is bit-identical and has none. The exact `==` is the point: the pattern
    /// is a re-emission of the very same solution, not a nearby one — proximity
    /// is what `duplicateDistance` is for.
    static func isCachedRepeat(_ fix: LocationFix, recent: [LocationFix]) -> Bool {
        guard fix.validSpeed == nil, !recent.isEmpty else { return false }
        return recent.contains {
            $0.latitude == fix.latitude
                && $0.longitude == fix.longitude
                && $0.horizontalAccuracy == fix.horizontalAccuracy
                && fix.timestamp.timeIntervalSince($0.timestamp) < recentWindow
        }
    }

    /// Convenience: keep only accepted fixes from a batch, threading the
    /// previously accepted fix through. Returns accepted fixes in order.
    public static func filter(_ fixes: [LocationFix],
                              previous: LocationFix?,
                              now: Date,
                              settings: TrackingSettings = TrackingSettings(),
                              recent: [LocationFix] = []) -> [LocationFix] {
        var last = previous
        // The window has to live through the batch, or two replays separated
        // by a real fix both get in.
        var window = recent
        var out: [LocationFix] = []
        for fix in fixes {
            switch evaluate(fix, previous: last, now: now, settings: settings, recent: window) {
            case .accepted:
                out.append(fix)
                last = fix
                remember(fix, in: &window)
            case .rejected(.cachedRepeat):
                remember(fix, in: &window)
            case .rejected:
                break
            }
        }
        return out
    }
}
