import Foundation

/// The five phases of the tracking state machine.
///
/// ```
/// disabled ──enable──▶ probing ──(2 fixes ≥ moving | activity moving)──▶ moving
///    ▲                   │  ▲                                              │
///    │                   │  │ significantChange / visit / low-conf hint     │ stillnessTimerFired
///    │       probeTimerFired│  │                                              ▼
///    │                   ▼  │                                    settling ──probeTimerFired──▶ stationary
///    └────────disable────┴──┴───────────────────────────────────────────────┘
/// ```
///
/// A stillness timer that fires without a second still reading behind it goes
/// back to PROBING rather than STATIONARY: see
/// ``TrackingStateMachine/stillnessCorroborated``.
///
/// A stop that ends a trip does not switch GPS off at once: it goes through
/// SETTLING, a bounded window on a cheap profile whose only job is to catch
/// the departure. See ``TrackingStateMachine/recentlyMoved``.
public enum TrackingPhase: String, Codable, Sendable, Hashable, CaseIterable {
    /// User switched tracking off. Nothing runs, nothing is monitored.
    case disabled
    /// GPS off. Waiting for CoreMotion / significant-change / visit.
    case stationary
    /// The trip has just stopped. GPS stays on with a wide distance filter for
    /// `settlingTimeout`, so starting again is seen in seconds rather than in
    /// the minutes CoreMotion takes to classify a restart.
    case settling
    /// GPS briefly on at best accuracy to confirm whether we are really moving.
    case probing
    /// GPS on with a speed/activity dependent ``GPSProfile``.
    case moving

    /// `true` while GPS should be running — at best accuracy in PROBING and
    /// MOVING, on the cheap ``GPSProfile/settling(_:)`` profile in SETTLING.
    public var isGPSActive: Bool { self == .probing || self == .moving || self == .settling }
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
    /// Stop location updates entirely.
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
/// * Going **to MOVING** is immediate on a credible activity (≥ minimum
///   confidence with `impliesMotion`). A GPS speed alone needs
///   `movingFixConfirmations` consecutive fast probing fixes: CoreLocation
///   occasionally reports a large speed on a fix that did not move. The same
///   confirmation gates the GPS profile: `profileSpeed` climbs a speed tier
///   only once that many fixes agree, and drops one at the first slow fix.
/// * Going **to STATIONARY** from MOVING always goes through the stillness
///   timer (hysteresis). From PROBING it happens when the probe timer fires
///   or when the classifier confidently says `stationary`.
/// * Going **to STATIONARY after a trip** goes through SETTLING first: GPS
///   stays on with a wide distance filter for `settlingTimeout` so a restart
///   is caught by a fix instead of waiting for CoreMotion. The window is
///   fixed — no `stationary` report shortens it — because the reports that
///   would shorten it are exactly the ones that were wrong.
/// * Once we have settled — the classifier said `stationary` with high
///   confidence, or a whole probe window found nothing — a confident
///   `unknown` no longer reopens PROBING (the classifier flaps between the
///   two while the phone sits still); the pedometer, significant change,
///   visits and any moving activity still do, and clear the settle.
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
    /// Last known GPS speed (m/s), `nil` when unknown. The raw observation,
    /// which the status screen shows.
    public private(set) var lastSpeed: Double?
    /// Speed the GPS profile is computed from. It follows ``lastSpeed`` down a
    /// tier immediately, but climbs one only after `movingFixConfirmations`
    /// consecutive fixes agree: a lone aberrant reading must not widen the
    /// distance filter to the automotive 50 m.
    public private(set) var profileSpeed: Double?
    /// Consecutive fixes seen in a tier above ``profileSpeed``'s.
    private var profileSpeedStreak = 0
    /// Profile currently requested from the engine, `nil` when GPS is off.
    public private(set) var activeProfile: GPSProfile?
    /// Whether a stillness timer is currently armed (MOVING only).
    public private(set) var stillnessTimerArmed = false
    /// Whether a *second* still reading arrived since the timer was armed.
    ///
    /// One reading arms the countdown; it is the next one that proves the app
    /// was still being fed while it ran. Without that, a timer that fires says
    /// only that nothing arrived — which is what an app suspended mid-ride
    /// looks like, and is no more evidence of stillness than the fix-less
    /// probe window ``settledStationary`` already refuses to trust.
    public private(set) var stillnessCorroborated = false
    /// Whether a probe timer is currently armed. PROBING arms it for
    /// `probeTimeout`, SETTLING for `settlingTimeout`: both are "a window that
    /// ends in STATIONARY unless something moves", so they share the timer.
    public private(set) var probeTimerArmed = false
    /// Number of fixes received during the current PROBING window.
    public private(set) var probeFixCount = 0
    /// Consecutive PROBING fixes at or above ``TrackingSettings/movingSpeedThreshold``.
    /// Reset by any slower fix and on every PROBING entry and exit.
    public private(set) var fastFixStreak = 0
    /// `true` between entering MOVING and reaching STATIONARY: a trip is in
    /// progress or has just ended.
    ///
    /// It is what makes a stop go through SETTLING rather than straight to
    /// GPS off. The phone that has been sitting on a desk all morning —
    /// PROBING windows opening and expiring on classifier noise — never sets
    /// it, and keeps costing nothing.
    public private(set) var recentlyMoved = false
    /// `true` once the classifier said `stationary` with high confidence and
    /// nothing has contradicted it since. While set, a confident `unknown`
    /// report is classifier noise rather than the device being handled.
    public private(set) var settledStationary = false
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
            // Steps and accelerometer bursts are physical evidence: they
            // override a classifier that had settled on "stationary".
            if phase != .disabled { settledStationary = false }
            switch phase {
            case .stationary, .settling:
                // From SETTLING too: the cheap profile is watching for a
                // departure, and best accuracy decides one faster.
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
            guard stillnessCorroborated else {
                // Silence, not stillness: go and measure rather than declare.
                // PROBING costs one `probeTimeout` of GPS and ends in
                // STATIONARY anyway if nothing is moving.
                stillnessCorroborated = false
                return transition(to: .probing, input: input)
            }
            stillnessCorroborated = false
            return transition(to: .stationary, input: input)

        case .probeTimerFired:
            guard phase == .probing || phase == .settling, probeTimerArmed else { return [] }
            probeTimerArmed = false
            if phase == .settling {
                // The window is over and nothing moved through it. Whether the
                // classifier ever said so is beside the point: a whole
                // `settlingTimeout` of fixes that did not move is the same
                // evidence a probe window gives, only longer.
                settledStationary = probeFixCount > 0
                return transition(to: .stationary, input: input)
            }
            // A probe window that saw fixes and none of them moved is at least
            // as good a settle as the classifier's own verdict — without it,
            // every window ending on the timer rather than on a
            // `stationary/high` report restarts the unknown/probe loop. A
            // window that saw *no* fix proves nothing though (indoors, a
            // parking garage, a cold receiver): it must not settle anything.
            settledStationary = probeFixCount > 0
            return transition(to: .stationary, input: input)

        case .significantChange, .visit:
            if phase != .disabled { settledStationary = false }
            switch phase {
            case .stationary, .settling:
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
        // `unknown` is not an observation, it is the absence of one:
        // CoreMotion is saying "I cannot tell", never "this is no longer
        // cycling". Letting it overwrite an explicit label is what put a ride
        // on the driving profile — a 110-minute ride flapped
        // `cycling` → `unknown` every ten to thirty seconds, and each flap
        // dropped the profile back onto the speed table, where 25 km/h reads
        // as a car: 69 % of that ride ran on `bestForNavigation` with a 50 m
        // filter, at 5.5 %/h of battery.
        //
        // Keeping the label is what makes `cyclingVehicleSpeedThreshold`
        // (12.5 m/s, the speed above which even a `cycling` label yields to a
        // vehicle) apply at all: it was never reached, because by the time a
        // fix arrived the label was already gone. A ride that really turns
        // into a drive is still caught — by that threshold, or by the
        // classifier eventually saying `automotive`, which does overwrite.
        //
        // The phase logic below reads `kind`, not `lastActivity`, so a
        // confident `unknown` still opens PROBING exactly as before.
        if kind != .unknown {
            lastActivity = kind
            lastActivityConfidence = confidence
        }
        let credible = confidence >= settings.minimumActivityConfidence
        if kind.impliesMotion {
            settledStationary = false
        } else if kind == .stationary && confidence == .high
                    && phase != .moving && phase != .settling {
            // Not from MOVING: a phone lying on a car seat is genuinely
            // stationary to CoreMotion while the car drives on, and settling
            // there would silence the `unknown` reports that bring us back.
            // Not from SETTLING either, and for the same reason twice over:
            // the classifier saying "stationary" is what opened the window,
            // and letting it settle would make the restart that follows the
            // window slower than if the window had never run.
            settledStationary = true
        }

        switch phase {
        case .stationary:
            if kind.impliesMotion {
                return credible ? transition(to: .moving, input: input)
                                : transition(to: .probing, input: input)
            }
            if kind == .unknown && credible {
                // Confidently "unknown" usually means the device is being
                // handled — but right after a firm "stationary" it is just the
                // classifier flapping between the two, and probing on every
                // flap is what wakes GPS all day for nothing. The pedometer,
                // significant change and visits still open a window.
                guard !settledStationary else { return [] }
                return transition(to: .probing, input: input)
            }
            return []

        case .settling:
            // Moving again ends the window; nothing else does. A `stationary`
            // report is not news here — we know we stopped, that is why we are
            // settling — and acting on it is what cut GPS for three minutes
            // while a ride resumed.
            if kind.impliesMotion {
                return credible ? transition(to: .moving, input: input)
                                : transition(to: .probing, input: input)
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
        guard phase != .disabled else { return [] }
        let valid = (speed ?? -1) >= 0 ? speed : nil
        lastSpeed = valid
        // Coarse fixes reach the machine while STATIONARY too, and the profile
        // must be as fresh as the reading it is built from.
        updateProfileSpeed(valid)
        if let s = valid, s >= settings.movingSpeedThreshold {
            // A settle is a guess about stillness; a measured speed refutes it.
            settledStationary = false
        }

        switch phase {
        case .probing, .settling:
            // SETTLING counts fixes the same way: its fixes come through a
            // wide distance filter, so one arriving at all already means the
            // device travelled — but a speed still has to confirm it, and the
            // fixes are stored either way, so the window records the departure
            // it is there to catch.
            probeFixCount += 1
            if let s = valid, s >= settings.movingSpeedThreshold {
                fastFixStreak += 1
                // One reading is not a departure: CoreLocation sometimes puts
                // a large speed on a fix that has not moved at all.
                guard fastFixStreak >= max(1, settings.movingFixConfirmations) else { return [] }
                return transition(to: .moving, input: input)
            }
            fastFixStreak = 0
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
        guard !stillnessTimerArmed else {
            // Already counting down. A second still reading is the whole
            // corroboration: it says data is still reaching us.
            stillnessCorroborated = true
            return []
        }
        stillnessTimerArmed = true
        stillnessCorroborated = false
        return [.startStillnessTimer(seconds: settings.stillnessTimeout)]
    }

    private mutating func disarmStillnessTimer() -> [TrackingEffect] {
        guard stillnessTimerArmed else { return [] }
        stillnessTimerArmed = false
        stillnessCorroborated = false
        return [.cancelStillnessTimer]
    }

    private mutating func armProbeTimer(seconds: TimeInterval? = nil) -> [TrackingEffect] {
        probeTimerArmed = true
        return [.startProbeTimer(seconds: seconds ?? settings.probeTimeout)]
    }

    private mutating func disarmProbeTimer() -> [TrackingEffect] {
        guard probeTimerArmed else { return [] }
        probeTimerArmed = false
        return [.cancelProbeTimer]
    }

    /// Feed a fix's speed to ``profileSpeed``.
    ///
    /// Dropping to a slower tier is applied at once — a tighter distance
    /// filter only costs precision we already have. Climbing needs
    /// `movingFixConfirmations` fixes in a row, so a single aberrant reading
    /// (CoreLocation reported 8.4 m/s on a fix that had moved 25 cm) can no
    /// longer switch the manager to the automotive profile.
    private mutating func updateProfileSpeed(_ speed: Double?) {
        guard GPSProfile.speedTier(speed) > GPSProfile.speedTier(profileSpeed) else {
            profileSpeed = speed
            profileSpeedStreak = 0
            return
        }
        profileSpeedStreak += 1
        if profileSpeedStreak >= max(1, settings.movingFixConfirmations) {
            profileSpeed = speed
            profileSpeedStreak = 0
        }
    }

    /// Recompute the MOVING profile and emit `startGPS` only when it changed.
    private mutating func updateProfileIfNeeded() -> [TrackingEffect] {
        let wanted = GPSProfile.profile(for: lastActivity, speed: profileSpeed, settings: settings)
        guard wanted != activeProfile else { return [] }
        activeProfile = wanted
        return [.startGPS(wanted)]
    }

    /// Perform a phase change: exit effects of the old phase, entry effects
    /// of the new one, plus a log line. `prefix`/`suffix` wrap them.
    private mutating func transition(to requested: TrackingPhase,
                                     input: TrackingInput,
                                     prefix: [TrackingEffect] = [],
                                     suffix: [TrackingEffect] = []) -> [TrackingEffect] {
        let previous = phase
        // A trip never ends in the dark. Whatever decided the stop — a
        // corroborated stillness timer, an expired probe window, a confident
        // `stationary` — switching GPS off at that instant leaves the restart
        // to CoreMotion, which takes minutes on a bicycle (no steps to count)
        // and to significant change, which takes ~500 m. Two rides lost 0.9 km
        // and 0.8 km that way on 2026-09-12. So a stop that ends a trip lands
        // in SETTLING; only the window's own expiry reaches STATIONARY.
        let next: TrackingPhase = (requested == .stationary && recentlyMoved
                                   && previous != .settling && settings.settlingTimeout > 0)
            ? .settling : requested
        var effects = prefix

        // Exit.
        switch previous {
        case .moving:
            effects += disarmStillnessTimer()
        case .probing, .settling:
            effects += disarmProbeTimer()
            probeFixCount = 0
            fastFixStreak = 0
        case .stationary, .disabled:
            break
        }

        phase = next
        lastTransition = TrackingTransition(from: previous, to: next, input: input)

        // Entry.
        switch next {
        case .probing:
            activeProfile = .probing
            fastFixStreak = 0
            effects.append(.startGPS(.probing))
            effects += armProbeTimer()
        case .moving:
            recentlyMoved = true
            let profile = GPSProfile.profile(for: lastActivity, speed: profileSpeed, settings: settings)
            activeProfile = profile
            effects.append(.startGPS(profile))
        case .settling:
            let profile = GPSProfile.settling(settings)
            activeProfile = profile
            effects.append(.startGPS(profile))
            effects += armProbeTimer(seconds: settings.settlingTimeout)
        case .stationary:
            recentlyMoved = false
            activeProfile = nil
            effects.append(.stopGPS)
        case .disabled:
            recentlyMoved = false
            activeProfile = nil
            lastSpeed = nil
            profileSpeed = nil
            profileSpeedStreak = 0
            settledStationary = false
            effects.append(.stopGPS)
        }

        effects += suffix
        effects.append(.log("\(previous.rawValue) -> \(next.rawValue) on \(input)"))
        return effects
    }
}
