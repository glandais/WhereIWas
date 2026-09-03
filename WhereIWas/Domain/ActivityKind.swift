import Foundation

/// The coarse kind of physical activity the user is doing.
///
/// This is a framework-free mirror of the information exposed by
/// `CMMotionActivity`. The Motion module maps CoreMotion values onto it;
/// the state machine and the GPS profile table only ever see this enum.
public enum ActivityKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// CoreMotion could not classify the activity (or nothing was reported yet).
    case unknown
    /// Device is not moving.
    case stationary
    case walking
    case running
    case cycling
    /// In a car, bus, train, etc.
    case automotive

    /// `true` for every kind that implies the user is displacing.
    public var impliesMotion: Bool {
        switch self {
        case .stationary, .unknown: return false
        case .walking, .running, .cycling, .automotive: return true
        }
    }
}

/// How confident the motion classifier is in an ``ActivityKind``.
///
/// Mirrors `CMMotionActivityConfidence` without importing CoreMotion.
public enum ActivityConfidence: Int, Codable, Sendable, Comparable, Hashable {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (lhs: ActivityConfidence, rhs: ActivityConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Battery charging state, mirrored from `UIDevice.BatteryState`.
public enum BatteryState: String, Codable, Sendable, Hashable {
    case unknown
    case unplugged
    case charging
    case full
}

/// Location authorization, mirrored from `CLAuthorizationStatus`
/// (plus the accuracy flag) so the UI and coordinator never import CoreLocation.
public enum LocationAuthorization: String, Codable, Sendable, Hashable {
    case notDetermined
    case restricted
    case denied
    case whenInUse
    case always

    /// `true` when background tracking can work at all.
    public var allowsBackgroundTracking: Bool { self == .always }
}

/// Motion authorization, mirrored from `CMAuthorizationStatus`.
public enum MotionAuthorization: String, Codable, Sendable, Hashable {
    case notDetermined
    case restricted
    case denied
    case authorized
}
