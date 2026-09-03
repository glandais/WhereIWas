import Foundation

// Pure, framework-free helpers used by `MotionMonitor`. They take plain
// Swift values (flags, doubles) rather than CoreMotion objects so they can
// be unit-tested without a device.

/// Maps CoreMotion activity flags onto a single ``ActivityKind``.
public enum ActivityMapping {
    /// Picks the dominant kind when several flags are set at once
    /// (automotive > cycling > running > walking > stationary > unknown).
    ///
    /// CoreMotion commonly reports `stationary && automotive` while stopped
    /// at a traffic light; we treat that as automotive so the state machine's
    /// stillness hysteresis (not the classifier) decides when to stop GPS.
    public static func dominantKind(stationary: Bool,
                                    walking: Bool,
                                    running: Bool,
                                    cycling: Bool,
                                    automotive: Bool) -> ActivityKind {
        if automotive { return .automotive }
        if cycling { return .cycling }
        if running { return .running }
        if walking { return .walking }
        if stationary { return .stationary }
        return .unknown
    }

    /// Maps `CMMotionActivityConfidence.rawValue` (0 low, 1 medium, 2 high).
    public static func confidence(rawValue: Int) -> ActivityConfidence {
        ActivityConfidence(rawValue: max(0, min(2, rawValue))) ?? .low
    }
}

/// Suppresses redundant activity reports. CoreMotion can deliver the same
/// classification several times in a row (and the coordinator restarts
/// timers on every input), so an identical (kind, confidence) pair is only
/// re-emitted after `repeatInterval` seconds. Any change in kind, or a
/// confidence increase, passes immediately; a confidence *decrease* for the
/// same kind is also passed because it may downgrade a "moving" verdict.
public struct ActivityDebouncer: Sendable {
    public var repeatInterval: TimeInterval
    private var lastKind: ActivityKind?
    private var lastConfidence: ActivityConfidence?
    private var lastEmitted: Date?

    public init(repeatInterval: TimeInterval = 30) {
        self.repeatInterval = repeatInterval
    }

    /// Returns `true` when the report should be forwarded.
    public mutating func shouldEmit(kind: ActivityKind,
                                    confidence: ActivityConfidence,
                                    at date: Date) -> Bool {
        defer {
            lastKind = kind
            lastConfidence = confidence
        }
        guard let lastKind, let lastConfidence, let lastEmitted else {
            self.lastEmitted = date
            return true
        }
        if kind != lastKind || confidence != lastConfidence {
            self.lastEmitted = date
            return true
        }
        if date.timeIntervalSince(lastEmitted) >= repeatInterval {
            self.lastEmitted = date
            return true
        }
        return false
    }

    public mutating func reset() {
        lastKind = nil
        lastConfidence = nil
        lastEmitted = nil
    }
}

/// Analyses a short burst of raw accelerometer magnitudes (in g, gravity
/// included) and decides whether the device is being moved.
///
/// At rest the magnitude sits at ~1 g with sensor noise of a few mg. Walking
/// produces deviations of 0.1–0.5 g; a phone in a pocket of a seated person
/// is usually below 0.02 g RMS.
public struct AccelerometerBurstAnalyzer: Sendable, Hashable {
    /// RMS deviation from 1 g above which the burst counts as moving. Default 0.03 g.
    public var rmsThreshold: Double
    /// Peak absolute deviation from 1 g above which the burst counts as
    /// moving regardless of RMS (a single pick-up gesture). Default 0.15 g.
    public var peakThreshold: Double
    /// Minimum number of samples for a verdict; fewer samples → not moving
    /// (insufficient evidence must never wake the GPS). Default 5.
    public var minimumSamples: Int

    public init(rmsThreshold: Double = 0.03, peakThreshold: Double = 0.15, minimumSamples: Int = 5) {
        self.rmsThreshold = rmsThreshold
        self.peakThreshold = peakThreshold
        self.minimumSamples = minimumSamples
    }

    public struct Verdict: Sendable, Hashable {
        public var isMoving: Bool
        /// Peak |magnitude − 1 g| over the burst.
        public var peakDeviation: Double
        /// RMS of (magnitude − 1 g) over the burst.
        public var rmsDeviation: Double
        public var sampleCount: Int
    }

    /// `magnitudes` are |a| = sqrt(x² + y² + z²) in g.
    public func analyze(magnitudes: [Double]) -> Verdict {
        guard !magnitudes.isEmpty else {
            return Verdict(isMoving: false, peakDeviation: 0, rmsDeviation: 0, sampleCount: 0)
        }
        var sumSquares = 0.0
        var peak = 0.0
        for m in magnitudes {
            let d = m - 1.0
            sumSquares += d * d
            peak = max(peak, abs(d))
        }
        let rms = (sumSquares / Double(magnitudes.count)).squareRoot()
        let enough = magnitudes.count >= minimumSamples
        let moving = enough && (rms >= rmsThreshold || peak >= peakThreshold)
        return Verdict(isMoving: moving, peakDeviation: peak, rmsDeviation: rms, sampleCount: magnitudes.count)
    }

    /// Convenience: magnitude of an (x, y, z) acceleration vector in g.
    public static func magnitude(x: Double, y: Double, z: Double) -> Double {
        (x * x + y * y + z * z).squareRoot()
    }
}
