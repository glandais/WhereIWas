import Foundation

/// One validation test run against a fix, with the numbers behind the verdict.
///
/// This is the "tests performed" half of the audit trail: it says which check
/// ran, what value it measured, what it compared against, and whether the fix
/// passed. Checks after the first failure are reported as `skipped`.
public struct FilterCheck: Sendable, Hashable, Codable {
    public enum Verdict: String, Sendable, Hashable, Codable {
        case passed
        case failed
        /// Not evaluated: an earlier check already rejected the fix.
        case skipped
        /// Not applicable (e.g. ordering checks with no previous fix).
        case notApplicable
    }

    /// Stable check identifier, e.g. `horizontalAccuracy.valid`.
    public var name: String
    public var verdict: Verdict
    /// Measured value, formatted locale-independently. `nil` when the check
    /// has no single scalar (or was skipped).
    public var measured: String?
    /// Threshold or expectation the value was compared against.
    public var limit: String?

    public init(name: String, verdict: Verdict, measured: String? = nil, limit: String? = nil) {
        self.name = name
        self.verdict = verdict
        self.measured = measured
        self.limit = limit
    }

    /// `name: measured vs limit → verdict`, for the audit detail line.
    public var summary: String {
        var s = name
        if let measured { s += " \(measured)" }
        if let limit { s += "/\(limit)" }
        return "\(s) \(verdict.rawValue)"
    }
}

/// The full record of one fix's validation: every check in evaluation order
/// plus the outcome.
public struct FilterTrace: Sendable, Equatable {
    public var checks: [FilterCheck]
    public var result: LocationFilterResult

    public init(checks: [FilterCheck], result: LocationFilterResult) {
        self.checks = checks
        self.result = result
    }

    public var isAccepted: Bool { result.isAccepted }

    /// Name of the first failed check, if any.
    public var failedCheck: String? {
        checks.first { $0.verdict == .failed }?.name
    }

    /// `check1 passed check2 failed …` for an audit detail value.
    public var summary: String {
        checks.map(\.summary).joined(separator: "; ")
    }
}

extension LocationFilter {
    /// Names of the checks, in evaluation order.
    public static let checkNames = [
        "horizontalAccuracy.valid",
        "horizontalAccuracy.withinLimit",
        "timestamp.notInFuture",
        "timestamp.notStale",
        "timestamp.afterPrevious",
        "coordinate.notDuplicate",
    ]

    /// Same decision as ``evaluate(_:previous:now:settings:)``, but recording
    /// every test performed.
    ///
    /// This is only called when the audit trail is enabled: `evaluate` stays
    /// allocation-free on the hot path. `LocationFilterTraceTests` asserts the
    /// two agree on a wide range of inputs, so the trace can never describe a
    /// decision the filter did not make.
    public static func trace(_ fix: LocationFix,
                             previous: LocationFix?,
                             now: Date,
                             settings: TrackingSettings = TrackingSettings()) -> FilterTrace {
        func fmt(_ value: Double, _ decimals: Int = 2) -> String {
            String(format: "%.\(decimals)f", locale: nil, value)
        }

        var checks: [FilterCheck] = []
        var result: LocationFilterResult?

        func append(_ name: String, _ passed: Bool, measured: String?, limit: String?,
                    rejection: LocationRejection? = nil) {
            if result != nil {
                checks.append(FilterCheck(name: name, verdict: .skipped))
                return
            }
            checks.append(FilterCheck(name: name,
                                      verdict: passed ? .passed : .failed,
                                      measured: measured,
                                      limit: limit))
            if !passed, let rejection {
                result = .rejected(rejection)
            }
        }

        append("horizontalAccuracy.valid",
               fix.horizontalAccuracy > 0,
               measured: fmt(fix.horizontalAccuracy),
               limit: "> 0 m",
               rejection: .invalidAccuracy)

        append("horizontalAccuracy.withinLimit",
               fix.horizontalAccuracy <= settings.maxHorizontalAccuracy,
               measured: fmt(fix.horizontalAccuracy),
               limit: "<= \(fmt(settings.maxHorizontalAccuracy)) m",
               rejection: .poorAccuracy(meters: fix.horizontalAccuracy))

        let age = now.timeIntervalSince(fix.timestamp)

        append("timestamp.notInFuture",
               age >= -futureTolerance,
               measured: "\(fmt(age)) s",
               limit: ">= \(fmt(-futureTolerance)) s",
               rejection: .futureTimestamp)

        append("timestamp.notStale",
               age <= settings.maxSampleAge,
               measured: "\(fmt(age)) s",
               limit: "<= \(fmt(settings.maxSampleAge)) s",
               rejection: .stale(ageSeconds: age))

        if let previous {
            append("timestamp.afterPrevious",
                   fix.timestamp > previous.timestamp,
                   measured: "\(fmt(fix.timestamp.timeIntervalSince(previous.timestamp))) s",
                   limit: "> 0 s",
                   rejection: .outOfOrder)

            let distance = fix.distance(to: previous)
            append("coordinate.notDuplicate",
                   distance > settings.duplicateDistance,
                   measured: "\(fmt(distance)) m",
                   limit: "> \(fmt(settings.duplicateDistance)) m",
                   rejection: .duplicate)
        } else {
            let verdict: FilterCheck.Verdict = result == nil ? .notApplicable : .skipped
            checks.append(FilterCheck(name: "timestamp.afterPrevious", verdict: verdict))
            checks.append(FilterCheck(name: "coordinate.notDuplicate", verdict: verdict))
        }

        return FilterTrace(checks: checks, result: result ?? .accepted)
    }
}
