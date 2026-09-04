import CoreMotion
import Foundation
import os

/// Production ``MotionMonitoring`` built on CoreMotion.
///
/// Sources, cheapest first (all run on the motion coprocessor and keep
/// working while the app is in the background, as long as the process is
/// alive):
///
/// * `CMMotionActivityManager.startActivityUpdates` → ``MotionEvent/activity``
///   (deduplicated by ``ActivityDebouncer``).
/// * `CMPedometer.startUpdates` → ``MotionEvent/steps`` (delta since the
///   previous callback). Steps are a secondary "the user is walking" signal
///   that often precedes the activity classifier by 10–20 s.
/// * On demand, a short low-rate accelerometer burst (`CMMotionManager`,
///   5 Hz, ≤ 3 s) → ``MotionEvent/accelerometerBurst``. Used by the
///   coordinator to confirm stillness cheaply before switching GPS off.
///
/// Every callback is hopped onto the main actor before touching state or
/// invoking the handler; CoreMotion objects never escape this file.
///
/// Authorization: `CMMotionActivityManager.authorizationStatus()` is
/// polled after `start()` until it leaves `.notDetermined` (the system
/// prompt has no completion callback) and re-checked on every callback;
/// changes are reported as ``MotionEvent/authorizationChanged``.
@MainActor
public final class MotionMonitor: MotionMonitoring {
    /// Opt-in audit sink; a no-op until the coordinator installs one.
    public var audit: any AuditRecording = NoopAuditLog()

    // MARK: Configuration

    /// Accelerometer sample rate during a burst (Hz). 5 Hz is plenty to see
    /// walking (1–2 Hz) and costs almost nothing.
    public var burstSampleRate: Double = 5
    /// Upper bound on a burst, whatever the caller asks for.
    public var maximumBurstDuration: TimeInterval = 3
    /// Identical activity reports are re-emitted at most this often.
    public var activityRepeatInterval: TimeInterval = 30 {
        didSet { debouncer.repeatInterval = activityRepeatInterval }
    }
    public var burstAnalyzer = AccelerometerBurstAnalyzer()

    // MARK: MotionMonitoring

    public var isActivityAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }
    public private(set) var authorization: MotionAuthorization
    public private(set) var lastActivity: (kind: ActivityKind, confidence: ActivityConfidence, timestamp: Date)?
    public private(set) var isRunning = false
    /// `true` while an accelerometer burst is being sampled.
    public private(set) var isBursting = false

    // MARK: Private state

    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    /// Single instance per app (several instances degrade sensor rates).
    private let motionManager = CMMotionManager()
    private let logger = Logger(subsystem: "io.github.glandais.whereiwas", category: "motion")

    private var handler: (@MainActor (MotionEvent) -> Void)?
    private var streamContinuations: [UUID: AsyncStream<MotionEvent>.Continuation] = [:]
    private var debouncer = ActivityDebouncer(repeatInterval: 30)
    private var lastStepCount: Int?
    private var authorizationPollTask: Task<Void, Never>?
    private var burstTask: Task<Void, Never>?
    private var burstMagnitudes: [Double] = []

    public init() {
        authorization = Self.mapAuthorization(CMMotionActivityManager.authorizationStatus())
    }

    // MARK: Lifecycle

    public func start(handler: @escaping @MainActor (MotionEvent) -> Void) {
        self.handler = handler
        guard !isRunning else { return }
        isRunning = true
        debouncer.reset()
        lastStepCount = nil
        logger.info("start (activityAvailable=\(self.isActivityAvailable), auth=\(self.authorization.rawValue))")

        if isActivityAvailable {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                // Extract plain values: CMMotionActivity is not Sendable.
                guard let activity else { return }
                let kind = ActivityMapping.dominantKind(stationary: activity.stationary,
                                                        walking: activity.walking,
                                                        running: activity.running,
                                                        cycling: activity.cycling,
                                                        automotive: activity.automotive)
                let confidence = ActivityMapping.confidence(rawValue: activity.confidence.rawValue)
                let timestamp = activity.startDate
                // The `.main` operation queue runs on the main thread.
                MainActor.assumeIsolated {
                    self?.handleActivity(kind: kind, confidence: confidence, timestamp: timestamp)
                }
            }
        } else {
            logger.notice("motion activity not available on this device")
        }

        if CMPedometer.isStepCountingAvailable() {
            // `@Sendable` is load-bearing: without it the closure inherits this
            // class's `@MainActor` isolation, and the runtime check the compiler
            // inserts for an Objective-C caller traps (`EXC_BREAKPOINT` in
            // `dispatch_assert_queue`) — CMPedometer calls back on a private
            // serial queue, never on main.
            pedometer.startUpdates(from: Date()) { @Sendable [weak self] data, error in
                let steps = data?.numberOfSteps.intValue
                let timestamp = data?.endDate ?? Date()
                let errorCode = (error as NSError?).map { ($0.domain, $0.code) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let errorCode {
                        self.logger.error("pedometer error \(errorCode.0):\(errorCode.1)")
                        self.refreshAuthorization()
                    }
                    if let steps {
                        self.handleSteps(cumulative: steps, timestamp: timestamp)
                    }
                }
            }
        }

        refreshAuthorization()
        startAuthorizationPollingIfNeeded()
    }

    public func stop() {
        guard isRunning else {
            handler = nil
            return
        }
        logger.info("stop")
        isRunning = false
        activityManager.stopActivityUpdates()
        pedometer.stopUpdates()
        authorizationPollTask?.cancel()
        authorizationPollTask = nil
        cancelBurst()
        handler = nil
    }

    // MARK: Accelerometer burst

    public func requestAccelerometerBurst(duration: TimeInterval) {
        guard motionManager.isAccelerometerAvailable else {
            logger.notice("accelerometer unavailable; burst ignored")
            return
        }
        guard !isBursting else { return }
        let seconds = max(0.2, min(duration, maximumBurstDuration))
        isBursting = true
        burstMagnitudes.removeAll(keepingCapacity: true)
        motionManager.accelerometerUpdateInterval = 1.0 / burstSampleRate
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let m = AccelerometerBurstAnalyzer.magnitude(x: data.acceleration.x,
                                                         y: data.acceleration.y,
                                                         z: data.acceleration.z)
            MainActor.assumeIsolated {
                guard let self, self.isBursting else { return }
                self.burstMagnitudes.append(m)
            }
        }
        burstTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.finishBurst()
        }
    }

    private func finishBurst() {
        motionManager.stopAccelerometerUpdates()
        burstTask = nil
        isBursting = false
        let verdict = burstAnalyzer.analyze(magnitudes: burstMagnitudes)
        burstMagnitudes.removeAll(keepingCapacity: true)
        logger.debug("burst: n=\(verdict.sampleCount) rms=\(verdict.rmsDeviation, format: .fixed(precision: 4)) peak=\(verdict.peakDeviation, format: .fixed(precision: 3)) moving=\(verdict.isMoving)")
        emit(.accelerometerBurst(isMoving: verdict.isMoving, magnitude: verdict.peakDeviation, timestamp: Date()))
    }

    private func cancelBurst() {
        burstTask?.cancel()
        burstTask = nil
        if isBursting {
            motionManager.stopAccelerometerUpdates()
            isBursting = false
            burstMagnitudes.removeAll()
        }
    }

    // MARK: Event stream (optional alternative to the handler)

    /// An `AsyncStream` that receives every event the handler receives.
    /// Finishes when the monitor is deallocated or the consumer cancels.
    public func makeEventStream() -> AsyncStream<MotionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MotionEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        streamContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.streamContinuations[id] = nil }
        }
        return stream
    }

    // MARK: Handling

    private func handleActivity(kind: ActivityKind, confidence: ActivityConfidence, timestamp: Date) {
        guard isRunning else { return }
        refreshAuthorization()
        lastActivity = (kind, confidence, timestamp)
        guard debouncer.shouldEmit(kind: kind, confidence: confidence, at: Date()) else { return }
        logger.debug("activity \(kind.rawValue) conf=\(confidence.rawValue)")
        emit(.activity(kind: kind, confidence: confidence, timestamp: timestamp))
    }

    private func handleSteps(cumulative: Int, timestamp: Date) {
        guard isRunning else { return }
        refreshAuthorization()
        defer { lastStepCount = cumulative }
        guard let previous = lastStepCount else {
            // First callback after `startUpdates(from:)`: the count is already a
            // delta since `from`, so report it as such.
            if cumulative > 0 { emit(.steps(count: cumulative, timestamp: timestamp)) }
            return
        }
        let delta = cumulative - previous
        guard delta > 0 else { return }
        emit(.steps(count: delta, timestamp: timestamp))
    }

    private func emit(_ event: MotionEvent) {
        handler?(event)
        for continuation in streamContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: Authorization

    private func refreshAuthorization() {
        let current = Self.mapAuthorization(CMMotionActivityManager.authorizationStatus())
        guard current != authorization else { return }
        logger.info("motion authorization \(self.authorization.rawValue) -> \(current.rawValue)")
        authorization = current
        emit(.authorizationChanged(current))
    }

    /// The permission prompt has no completion callback; poll until the
    /// user answers (or give up after two minutes).
    private func startAuthorizationPollingIfNeeded() {
        authorizationPollTask?.cancel()
        guard authorization == .notDetermined else { return }
        authorizationPollTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.refreshAuthorization()
                if self.authorization != .notDetermined { return }
            }
        }
    }

    static func mapAuthorization(_ status: CMAuthorizationStatus) -> MotionAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .notDetermined
        }
    }
}
