import Foundation

/// Desired accuracy expressed without CoreLocation. The Location module maps
/// each case to the corresponding `kCLLocationAccuracy…` constant.
public enum AccuracyLevel: String, Codable, Sendable, Hashable, Comparable {
    case bestForNavigation
    case best
    case tenMeters
    case hundredMeters
    case kilometer
    case threeKilometers

    /// Ordering: a *lower* value means *more precise* (more power hungry).
    private var rank: Int {
        switch self {
        case .bestForNavigation: return 0
        case .best: return 1
        case .tenMeters: return 2
        case .hundredMeters: return 3
        case .kilometer: return 4
        case .threeKilometers: return 5
        }
    }

    public static func < (lhs: AccuracyLevel, rhs: AccuracyLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Hint for `CLLocationManager.activityType`, framework-free.
public enum ActivityTypeHint: String, Codable, Sendable, Hashable {
    case other
    case fitness
    case automotiveNavigation
    case otherNavigation
}

/// A complete description of how `CLLocationManager` should be configured
/// while GPS is on. This is a value: comparing two profiles tells the engine
/// whether it must reconfigure the manager.
public struct GPSProfile: Codable, Sendable, Hashable {
    public var desiredAccuracy: AccuracyLevel
    /// Minimum horizontal displacement (meters) between two delivered fixes.
    public var distanceFilter: Double
    public var activityType: ActivityTypeHint
    /// Human readable label, useful for logs and the status screen.
    public var label: String

    public init(desiredAccuracy: AccuracyLevel,
                distanceFilter: Double,
                activityType: ActivityTypeHint,
                label: String) {
        self.desiredAccuracy = desiredAccuracy
        self.distanceFilter = distanceFilter
        self.activityType = activityType
        self.label = label
    }

    /// Profile used while PROBING: GPS on with best accuracy and no distance
    /// filter, so a handful of fixes is delivered quickly and speed can be read.
    public static let probing = GPSProfile(desiredAccuracy: .best,
                                           distanceFilter: 0,
                                           activityType: .other,
                                           label: "probing")

    /// A near-free profile the engine may use instead of stopping updates
    /// entirely (see ``TrackingSettings/keepCoarseUpdatesWhileStationary``).
    public static let stationaryCoarse = GPSProfile(desiredAccuracy: .threeKilometers,
                                                    distanceFilter: 3_000,
                                                    activityType: .other,
                                                    label: "stationary-coarse")

    // MARK: - Pure table

    /// Speed tiers (m/s) used when the activity classifier is `unknown`.
    /// Roughly: < 2.5 m/s walking, < 7 m/s running/cycling, above: vehicle.
    public static let runningSpeedThreshold: Double = 2.5
    public static let vehicleSpeedThreshold: Double = 7.0

    /// The pure speed/activity → profile table.
    ///
    /// - Parameters:
    ///   - activity: latest activity kind reported by the Motion module.
    ///   - speed: latest GPS speed in m/s, `nil` or negative when unknown.
    ///   - settings: distance filters to apply.
    /// - Returns: the profile GPS should run with while MOVING.
    ///
    /// Rules:
    /// * `walking` → best / `settings.walkingDistanceFilter` (10 m)
    /// * `running`, `cycling` → best / `settings.runningCyclingDistanceFilter` (20 m)
    /// * `automotive` → bestForNavigation / `settings.automotiveDistanceFilter` (50 m)
    /// * `unknown`/`stationary` (we are MOVING anyway, e.g. after a significant
    ///   change) → the speed decides using the thresholds above; with no
    ///   speed → best / `settings.unknownDistanceFilter` (10 m).
    /// * A high speed always wins over a "slow" activity label: walking at
    ///   9 m/s is a vehicle with a wrong label.
    public static func profile(for activity: ActivityKind,
                               speed: Double?,
                               settings: TrackingSettings = TrackingSettings()) -> GPSProfile {
        let validSpeed: Double? = (speed ?? -1) >= 0 ? speed : nil

        // Speed overrides a wrong "slow" classification.
        if let s = validSpeed, s >= vehicleSpeedThreshold {
            return automotive(settings)
        }

        switch activity {
        case .walking:
            return GPSProfile(desiredAccuracy: .best,
                              distanceFilter: settings.walkingDistanceFilter,
                              activityType: .fitness,
                              label: "walking")
        case .running:
            return GPSProfile(desiredAccuracy: .best,
                              distanceFilter: settings.runningCyclingDistanceFilter,
                              activityType: .fitness,
                              label: "running")
        case .cycling:
            return GPSProfile(desiredAccuracy: .best,
                              distanceFilter: settings.runningCyclingDistanceFilter,
                              activityType: .fitness,
                              label: "cycling")
        case .automotive:
            return automotive(settings)
        case .unknown, .stationary:
            guard let s = validSpeed else {
                return GPSProfile(desiredAccuracy: .best,
                                  distanceFilter: settings.unknownDistanceFilter,
                                  activityType: .other,
                                  label: "unknown")
            }
            if s >= runningSpeedThreshold {
                return GPSProfile(desiredAccuracy: .best,
                                  distanceFilter: settings.runningCyclingDistanceFilter,
                                  activityType: .fitness,
                                  label: "fast-unknown")
            }
            return GPSProfile(desiredAccuracy: .best,
                              distanceFilter: settings.unknownDistanceFilter,
                              activityType: .other,
                              label: "slow-unknown")
        }
    }

    private static func automotive(_ settings: TrackingSettings) -> GPSProfile {
        GPSProfile(desiredAccuracy: .bestForNavigation,
                   distanceFilter: settings.automotiveDistanceFilter,
                   activityType: .automotiveNavigation,
                   label: "automotive")
    }
}
