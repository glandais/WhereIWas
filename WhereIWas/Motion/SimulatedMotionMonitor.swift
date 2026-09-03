import Foundation

/// ``MotionMonitoring`` for unit tests and SwiftUI previews.
///
/// Unlike ``NoopMotionMonitor`` it reports activity as available, lets the
/// test control authorization, records every call, and answers
/// ``requestAccelerometerBurst(duration:)`` with a canned verdict so the
/// coordinator's probing path can be exercised without hardware.
@MainActor
public final class SimulatedMotionMonitor: MotionMonitoring {
    /// Opt-in audit sink; a no-op until the coordinator installs one.
    public var audit: any AuditRecording = NoopAuditLog()

    public var isActivityAvailable: Bool
    public private(set) var authorization: MotionAuthorization
    public private(set) var lastActivity: (kind: ActivityKind, confidence: ActivityConfidence, timestamp: Date)?
    public private(set) var isRunning = false
    /// Recorded calls (`"start"`, `"stop"`, `"burst(3.0)"`), for assertions.
    public private(set) var calls: [String] = []
    /// Verdict emitted by ``requestAccelerometerBurst(duration:)``; `nil` → no event.
    public var burstVerdict: (isMoving: Bool, magnitude: Double)? = (false, 0.005)
    /// Emits all events synchronously when `true` (default); otherwise
    /// callers must invoke ``simulate(_:)`` themselves.
    public var respondsToBurstRequests = true

    private var handler: (@MainActor (MotionEvent) -> Void)?

    public init(isActivityAvailable: Bool = true, authorization: MotionAuthorization = .authorized) {
        self.isActivityAvailable = isActivityAvailable
        self.authorization = authorization
    }

    public func start(handler: @escaping @MainActor (MotionEvent) -> Void) {
        self.handler = handler
        isRunning = true
        calls.append("start")
    }

    public func stop() {
        handler = nil
        isRunning = false
        calls.append("stop")
    }

    public func requestAccelerometerBurst(duration: TimeInterval) {
        calls.append("burst(\(duration))")
        guard respondsToBurstRequests, let verdict = burstVerdict else { return }
        simulate(.accelerometerBurst(isMoving: verdict.isMoving, magnitude: verdict.magnitude, timestamp: Date()))
    }

    /// Inject an event as if CoreMotion produced it. Delivered only while running.
    public func simulate(_ event: MotionEvent) {
        switch event {
        case .activity(let kind, let confidence, let timestamp):
            lastActivity = (kind, confidence, timestamp)
        case .authorizationChanged(let status):
            authorization = status
        default:
            break
        }
        handler?(event)
    }

    /// Change authorization and notify the handler.
    public func setAuthorization(_ status: MotionAuthorization) {
        simulate(.authorizationChanged(status))
    }
}
