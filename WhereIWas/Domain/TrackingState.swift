import Foundation

/// The four phases of the tracking state machine.
///
/// ```
/// disabled ──enable──▶ probing ──(fix speed ≥ moving | activity moving)──▶ moving
///    ▲                   │  ▲                                              │
///    │                   │  │ significantChange / visit / low-conf hint     │ stillnessTimerFired
///    │       probeTimerFired│  │                                              ▼
///    │                   ▼  │                                           stationary
///    └────────disable────┴──┴───────────────────────────────────────────────┘
/// ```
public enum TrackingPhase: String, Codable, Sendable, Hashable, CaseIterable {
    /// User switched tracking off. Nothing runs, nothing is monitored.
    case disabled
    /// GPS off (or coarse). Waiting for CoreMotion / significant-change / visit.
    case stationary
    /// GPS briefly on at best accuracy to confirm whether we are really moving.
    case probing
    /// GPS on with a speed/activity dependent ``GPSProfile``.
    case moving

    /// `true` while high-accuracy GPS should be running.
    public var isGPSActive: Bool { self == .probing || self == .moving }
}

/// Everything that can happen to the state machine. The coordinator
/// translates real-world callbacks into these inputs.
public enum TrackingInput: Sendable, Equatable {
    /// User (or launch re-arming) turned tracking on.
    case enable
    /// User turned tracking off.
    case disable
    /// A `MotionEvent.activity` arrived.
    case motionActivity(kind: ActivityKind, confidence: ActivityConfidence)
    /// `startStillnessTimer` elapsed without being cancelled.
    case stillnessTimerFired
    /// `startProbeTimer` elapsed without being cancelled.
    case probeTimerFired
    /// CoreLocation delivered a significant-change location (also fired at
    /// app relaunch after termination / reboot).
    case significantChange
    /// CoreLocation delivered a `CLVisit` (arrival or departure).
    case visit
    /// An *accepted* (post-filter) GPS fix. `speed` in m/s, `nil` if invalid.
    case gpsFix(speed: Double?)
    /// Pedometer / accelerometer said "there is movement" (cheap hint that
    /// is not a full activity classification).
    case motionHint
}

/// Side effects the coordinator must perform after ``TrackingStateMachine/handle(_:)``.
/// Effects are values so tests can assert on them.
public enum TrackingEffect: Sendable, Equatable {
    /// Configure and start `CLLocationManager.startUpdatingLocation` with the
    /// profile. Sent again whenever the profile changes; the engine should
    /// diff against its current profile and reconfigure in place.
    case startGPS(GPSProfile)
    /// Stop high-accuracy updates. The engine may downgrade to
    /// ``GPSProfile/stationaryCoarse`` instead of stopping entirely, see
    /// ``TrackingSettings/keepCoarseUpdatesWhileStationary``.
    case stopGPS
    /// Start (or restart) the stillness countdown.
    case startStillnessTimer(seconds: TimeInterval)
    case cancelStillnessTimer
    /// Start (or restart) the probing countdown.
    case startProbeTimer(seconds: TimeInterval)
    case cancelProbeTimer
    /// Turn on `startMonitoringSignificantLocationChanges` **and**
    /// `startMonitoringVisits` (both relaunch the app when terminated).
    case startSignificantChange
    /// Turn both off (only when disabling tracking).
    case stopSignificantChange
    /// Start CoreMotion activity + pedometer updates.
    case startMotionUpdates
    case stopMotionUpdates
    /// Record a transition in the log store / os_log.
    case log(String)
}

/// A recorded phase change, emitted alongside the effects so the coordinator
/// can persist it (`StateTransitionLog`) and show it in the UI.
public struct TrackingTransition: Sendable, Equatable {
    public var from: TrackingPhase
    public var to: TrackingPhase
    public var input: TrackingInput

    public init(from: TrackingPhase, to: TrackingPhase, input: TrackingInput) {
        self.from = from
        self.to = to
        self.input = input
    }
}

/// Pure, framework-free motion-detection state machine.
///
/// Feed it ``TrackingInput`` values with ``handle(_:)`` and execute the
/// returned ``TrackingEffect`` values. The machine never touches the clock:
/// timers are effects, their expiry comes back as inputs, so tests can
/// drive time explicitly.
///
/// Design rules:
/// * Going **to MOVING** is immediate on any credible motion evidence
///   (activity ≥ minimum confidence with `impliesMotion`, or a probing fix
///   with speed ≥ `movingSpeedThreshold`).
/// * Going **to STATIONARY** from MOVING always goes through the stillness
///   timer (hysteresis). From PROBING it happens when the probe timer fires
///   or when the classifier confidently says `stationary`.
/// * **Significant change / visit** never start MOVING directly (their
///   accuracy is poor and they fire when arriving somewhere too); they open a
///   PROBING window so a real fix decides.
/// * `enable` always goes to PROBING: we want a first fix and a speed reading
///   right away, and after a relaunch we do not know what the user is doing.
public struct TrackingStateMachine: Sendable, Equatable {
    public private(set) var phase: TrackingPhase
    public var settings: TrackingSettings

    /// Last activity the classifier reported (any confidence). Used to pick
    /// the GPS profile.
    public private(set) var lastActivity: ActivityKind = .unknown
    public private(set) var lastActivityConfidence: ActivityConfidence = .low
    /// Last known GPS speed (m/s), `nil` when unknown.
    public private(set) var lastSpeed: Double?
    /// Profile currently requested from the engine, `nil` when GPS is off.
    public private(set) var activeProfile: GPSProfile?
    /// Whether a stillness timer is currently armed (MOVING only).
    public private(set) var stillnessTimerArmed = false
    /// Whether a probe timer is currently armed (PROBING only).
    public private(set) var probeTimerArmed = false
    /// Number of fixes received during the current PROBING window.
    public private(set) var probeFixCount = 0
    /// Last phase change, for the UI / logging.
    public private(set) var lastTransition: TrackingTransition?

    public init(phase: TrackingPhase = .disabled, settings: TrackingSettings = TrackingSettings()) {
        self.phase = phase
        self.settings = settings
    }

    // MARK: - Input handling

    /// Apply one input and return the effects to execute, in order.
    public mutating func handle(_ input: TrackingInput) -> [TrackingEffect] {
        switch input {
        case .enable:
            guard phase == .disabled else { return [] }
            return transition(to: .probing, input: input,
                              prefix: [.startSignificantChange, .startMotionUpdates])

        case .disable:
            guard phase != .disabled else { return [] }
            return transition(to: .disabled, input: input,
                              suffix: [.stopMotionUpdates, .stopSignificantChange])

        case .motionActivity(let kind, let confidence):
            return handleActivity(kind: kind, confidence: confidence, input: input)

        case .motionHint:
            switch phase {
            case .stationary:
                return transition(to: .probing, input: input)
            case .moving:
                return disarmStillnessTimer()
            case .probing:
                return probeTimerArmed ? [] : armProbeTimer()
            case .disabled:
                return []
            }

        case .stillnessTimerFired:
            guard phase == .moving, stillnessTimerArmed else { return [] }
            stillnessTimerArmed = false
            return transition(to: .stationary, input: input)

        case .probeTimerFired:
            guard phase == .probing, probeTimerArmed else { return [] }
            probeTimerArmed = false
            return transition(to: .stationary, input: input)

        case .significantChange, .visit:
            switch phase {
            case .stationary:
                return transition(to: .probing, input: input)
            case .probing:
                // Extend the probing window: something is happening.
                return armProbeTimer()
            case .moving:
                return [.log("\(input) while moving: ignored")]
            case .disabled:
                return []
            }

        case .gpsFix(let speed):
            return handleFix(speed: speed, input: input)
        }
    }

    // MARK: - Private helpers

    private mutating func handleActivity(kind: ActivityKind,
                                         confidence: ActivityConfidence,
                                         input: TrackingInput) -> [TrackingEffect] {
        guard phase != .disabled else { return [] }
        lastActivity = kind
        lastActivityConfidence = confidence
        let credible = confidence >= settings.minimumActivityConfidence

        switch phase {
        case .stationary:
            if kind.impliesMotion {
                return credible ? transition(to: .moving, input: input)
                                : transition(to: .probing, input: input)
            }
            if kind == .unknown && credible {
                // Confidently "unknown" usually means the device is being handled.
                return transition(to: .probing, input: input)
            }
            return []

        case .probing:
            if kind.impliesMotion && credible {
                return transition(to: .moving, input: input)
            }
            if kind == .stationary && confidence == .high && probeFixCount > 0 {
                // A fix confirmed nothing is moving and the classifier is sure.
                return transition(to: .stationary, input: input)
            }
            return []

        case .moving:
            if kind.impliesMotion {
                var effects = disarmStillnessTimer()
                effects += updateProfileIfNeeded()
                return effects
            }
            if kind == .stationary && credible {
                return armStillnessTimer()
            }
            return []

        case .disabled:
            return []
        }
    }

    private mutating func handleFix(speed: Double?, input: TrackingInput) -> [TrackingEffect] {
        let valid = (speed ?? -1) >= 0 ? speed : nil
        lastSpeed = valid

        switch phase {
        case .probing:
            probeFixCount += 1
            if let s = valid, s >= settings.movingSpeedThreshold {
                return transition(to: .moving, input: input)
            }
            return []

        case .moving:
            var effects = updateProfileIfNeeded()
            if let s = valid {
                if s < settings.stillSpeedThreshold {
                    effects += armStillnessTimer()
                } else if s >= settings.movingSpeedThreshold && lastActivity != .stationary {
                    // Clearly moving and the classifier does not disagree.
                    effects += disarmStillnessTimer()
                }
            }
            return effects

        case .stationary:
            // Coarse / late fixes while stationary carry no decision power.
            return []

        case .disabled:
            return []
        }
    }

    private mutating func armStillnessTimer() -> [TrackingEffect] {
        guard !stillnessTimerArmed else { return [] }
        stillnessTimerArmed = true
        return [.startStillnessTimer(seconds: settings.stillnessTimeout)]
    }

    private mutating func disarmStillnessTimer() -> [TrackingEffect] {
        guard stillnessTimerArmed else { return [] }
        stillnessTimerArmed = false
        return [.cancelStillnessTimer]
    }

    private mutating func armProbeTimer() -> [TrackingEffect] {
        probeTimerArmed = true
        return [.startProbeTimer(seconds: settings.probeTimeout)]
    }

    private mutating func disarmProbeTimer() -> [TrackingEffect] {
        guard probeTimerArmed else { return [] }
        probeTimerArmed = false
        return [.cancelProbeTimer]
    }

    /// Recompute the MOVING profile and emit `startGPS` only when it changed.
    private mutating func updateProfileIfNeeded() -> [TrackingEffect] {
        let wanted = GPSProfile.profile(for: lastActivity, speed: lastSpeed, settings: settings)
        guard wanted != activeProfile else { return [] }
        activeProfile = wanted
        return [.startGPS(wanted)]
    }

    /// Perform a phase change: exit effects of the old phase, entry effects
    /// of the new one, plus a log line. `prefix`/`suffix` wrap them.
    private mutating func transition(to next: TrackingPhase,
                                     input: TrackingInput,
                                     prefix: [TrackingEffect] = [],
                                     suffix: [TrackingEffect] = []) -> [TrackingEffect] {
        let previous = phase
        var effects = prefix

        // Exit.
        switch previous {
        case .moving:
            effects += disarmStillnessTimer()
        case .probing:
            effects += disarmProbeTimer()
            probeFixCount = 0
        case .stationary, .disabled:
            break
        }

        phase = next
        lastTransition = TrackingTransition(from: previous, to: next, input: input)

        // Entry.
        switch next {
        case .probing:
            activeProfile = .probing
            effects.append(.startGPS(.probing))
            effects += armProbeTimer()
        case .moving:
            let profile = GPSProfile.profile(for: lastActivity, speed: lastSpeed, settings: settings)
            activeProfile = profile
            effects.append(.startGPS(profile))
        case .stationary:
            activeProfile = nil
            effects.append(.stopGPS)
        case .disabled:
            activeProfile = nil
            lastSpeed = nil
            effects.append(.stopGPS)
        }

        effects += suffix
        effects.append(.log("\(previous.rawValue) -> \(next.rawValue) on \(input)"))
        return effects
    }
}
