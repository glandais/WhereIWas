import Foundation

/// An event produced by the Motion module (CoreMotion) and consumed by the
/// coordinator, which turns it into a ``TrackingInput``.
///
/// All associated values are plain Swift types so the event is `Sendable`
/// and can be synthesized in unit tests.
public enum MotionEvent: Sendable, Equatable {
    /// `CMMotionActivityManager` reported a (possibly unchanged) activity.
    ///
    /// - Parameters:
    ///   - kind: the dominant activity kind. When CoreMotion flags several
    ///     activities at once the Motion module picks the most "moving" one
    ///     (automotive > cycling > running > walking > stationary > unknown).
    ///   - confidence: classifier confidence.
    ///   - timestamp: when the activity started, per CoreMotion.
    case activity(kind: ActivityKind, confidence: ActivityConfidence, timestamp: Date)

    /// `CMPedometer` reported new steps since the last event. `steps` is the
    /// delta, never the cumulative count.
    case steps(count: Int, timestamp: Date)

    /// Result of an optional short accelerometer burst (`CMMotionManager`).
    /// `isMoving` is the Motion module's verdict after analysing the burst;
    /// `magnitude` is the peak user-acceleration magnitude in g.
    case accelerometerBurst(isMoving: Bool, magnitude: Double, timestamp: Date)

    /// Motion authorization changed (e.g. the user answered the prompt).
    case authorizationChanged(MotionAuthorization)
}
