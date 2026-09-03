import Foundation
import Testing
@testable import WhereIWas

// MARK: - Helpers

private extension TrackingStateMachine {
    /// A machine already in `phase`, built by driving real inputs so the
    /// internal bookkeeping (timers, profile) is consistent.
    static func at(_ phase: TrackingPhase, settings: TrackingSettings = TrackingSettings()) -> TrackingStateMachine {
        var m = TrackingStateMachine(settings: settings)
        switch phase {
        case .disabled:
            break
        case .probing:
            _ = m.handle(.enable)
        case .moving:
            _ = m.handle(.enable)
            _ = m.handle(.gpsFix(speed: 1.5))
        case .stationary:
            _ = m.handle(.enable)
            _ = m.handle(.probeTimerFired)
        }
        precondition(m.phase == phase)
        return m
    }
}

private extension Array where Element == TrackingEffect {
    var withoutLogs: [TrackingEffect] {
        filter { if case .log = $0 { return false } else { return true } }
    }

    var hasLog: Bool {
        contains { if case .log = $0 { return true } else { return false } }
    }

    var startGPSProfiles: [GPSProfile] {
        compactMap { if case .startGPS(let p) = $0 { return p } else { return nil } }
    }
}

// MARK: - Initial state

@Suite("TrackingStateMachine · initial state")
struct TrackingStateInitialTests {
    @Test("Fresh machine is disabled with nothing armed")
    func initial() {
        let m = TrackingStateMachine()
        #expect(m.phase == .disabled)
        #expect(m.activeProfile == nil)
        #expect(m.lastSpeed == nil)
        #expect(m.lastActivity == .unknown)
        #expect(m.lastActivityConfidence == .low)
        #expect(!m.stillnessTimerArmed)
        #expect(!m.probeTimerArmed)
        #expect(m.probeFixCount == 0)
        #expect(m.lastTransition == nil)
    }

    @Test("isGPSActive is true only for probing and moving")
    func gpsActive() {
        #expect(!TrackingPhase.disabled.isGPSActive)
        #expect(!TrackingPhase.stationary.isGPSActive)
        #expect(TrackingPhase.probing.isGPSActive)
        #expect(TrackingPhase.moving.isGPSActive)
    }

    @Test("Disabled machine ignores every non-enable input",
          arguments: [
            TrackingInput.disable,
            .motionActivity(kind: .walking, confidence: .high),
            .stillnessTimerFired,
            .probeTimerFired,
            .significantChange,
            .visit,
            .gpsFix(speed: 5),
            .motionHint,
          ])
    func disabledIgnores(input: TrackingInput) {
        var m = TrackingStateMachine()
        #expect(m.handle(input).isEmpty)
        #expect(m.phase == .disabled)
        #expect(m.lastTransition == nil)
    }
}

// MARK: - Enable

@Suite("TrackingStateMachine · enable")
struct TrackingStateEnableTests {
    @Test("enable goes to PROBING with exact effect order")
    func enableEffects() {
        var m = TrackingStateMachine()
        let effects = m.handle(.enable)
        #expect(m.phase == .probing)
        #expect(effects.withoutLogs == [
            .startSignificantChange,
            .startMotionUpdates,
            .startGPS(.probing),
            .startProbeTimer(seconds: 45),
        ])
        #expect(effects.hasLog)
        #expect(effects.last.map { if case .log = $0 { return true } else { return false } } == true)
        #expect(m.activeProfile == .probing)
        #expect(m.probeTimerArmed)
        #expect(m.lastTransition == TrackingTransition(from: .disabled, to: .probing, input: .enable))
    }

    @Test("enable uses the configured probe timeout")
    func enableUsesSettings() {
        var s = TrackingSettings()
        s.probeTimeout = 12
        var m = TrackingStateMachine(settings: s)
        #expect(m.handle(.enable).contains(.startProbeTimer(seconds: 12)))
    }

    @Test("enable is a no-op when already enabled", arguments: [TrackingPhase.probing, .moving, .stationary])
    func enableIdempotent(phase: TrackingPhase) {
        var m = TrackingStateMachine.at(phase)
        let before = m
        #expect(m.handle(.enable).isEmpty)
        #expect(m == before)
    }
}

// MARK: - Disable

@Suite("TrackingStateMachine · disable")
struct TrackingStateDisableTests {
    @Test("disable from PROBING cancels the probe timer and stops everything")
    func fromProbing() {
        var m = TrackingStateMachine.at(.probing)
        let effects = m.handle(.disable)
        #expect(m.phase == .disabled)
        #expect(effects.withoutLogs == [
            .cancelProbeTimer,
            .stopGPS,
            .stopMotionUpdates,
            .stopSignificantChange,
        ])
        #expect(!m.probeTimerArmed)
        #expect(m.activeProfile == nil)
        #expect(m.lastTransition == TrackingTransition(from: .probing, to: .disabled, input: .disable))
    }

    @Test("disable from MOVING with stillness timer armed cancels it")
    func fromMovingWithTimer() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        #expect(m.stillnessTimerArmed)
        let effects = m.handle(.disable)
        #expect(m.phase == .disabled)
        #expect(effects.withoutLogs == [
            .cancelStillnessTimer,
            .stopGPS,
            .stopMotionUpdates,
            .stopSignificantChange,
        ])
        #expect(!m.stillnessTimerArmed)
        #expect(m.lastSpeed == nil)
        #expect(m.activeProfile == nil)
    }

    @Test("disable from MOVING without timer")
    func fromMovingNoTimer() {
        var m = TrackingStateMachine.at(.moving)
        let effects = m.handle(.disable)
        #expect(effects.withoutLogs == [.stopGPS, .stopMotionUpdates, .stopSignificantChange])
    }

    @Test("disable from STATIONARY")
    func fromStationary() {
        var m = TrackingStateMachine.at(.stationary)
        let effects = m.handle(.disable)
        #expect(m.phase == .disabled)
        #expect(effects.withoutLogs == [.stopGPS, .stopMotionUpdates, .stopSignificantChange])
    }

    @Test("After disable the machine can be re-enabled")
    func reEnable() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.disable)
        let effects = m.handle(.enable)
        #expect(m.phase == .probing)
        #expect(effects.contains(.startGPS(.probing)))
    }
}

// MARK: - Probing

@Suite("TrackingStateMachine · probing")
struct TrackingStateProbingTests {
    @Test("Fast fix promotes to MOVING, cancelling the probe timer")
    func fastFix() {
        var m = TrackingStateMachine.at(.probing)
        let effects = m.handle(.gpsFix(speed: 0.7))
        #expect(m.phase == .moving)
        let expected = GPSProfile.profile(for: .unknown, speed: 0.7)
        #expect(effects.withoutLogs == [.cancelProbeTimer, .startGPS(expected)])
        #expect(m.activeProfile == expected)
        #expect(m.lastSpeed == 0.7)
        #expect(!m.probeTimerArmed)
        #expect(m.probeFixCount == 0)
        #expect(m.lastTransition == TrackingTransition(from: .probing, to: .moving, input: .gpsFix(speed: 0.7)))
    }

    @Test("Slow, nil and negative-speed fixes keep PROBING and count fixes")
    func slowFixes() {
        var m = TrackingStateMachine.at(.probing)
        #expect(m.handle(.gpsFix(speed: 0.69)).isEmpty)
        #expect(m.phase == .probing)
        #expect(m.probeFixCount == 1)
        #expect(m.lastSpeed == 0.69)

        #expect(m.handle(.gpsFix(speed: nil)).isEmpty)
        #expect(m.probeFixCount == 2)
        #expect(m.lastSpeed == nil)

        #expect(m.handle(.gpsFix(speed: -1)).isEmpty)
        #expect(m.probeFixCount == 3)
        #expect(m.lastSpeed == nil)
        #expect(m.phase == .probing)
    }

    @Test("Probe timer expiry falls back to STATIONARY")
    func probeTimeout() {
        var m = TrackingStateMachine.at(.probing)
        _ = m.handle(.gpsFix(speed: 0.1))
        let effects = m.handle(.probeTimerFired)
        #expect(m.phase == .stationary)
        #expect(effects.withoutLogs == [.stopGPS])
        #expect(m.activeProfile == nil)
        #expect(!m.probeTimerArmed)
        #expect(m.probeFixCount == 0)
    }

    @Test("Credible moving activity promotes to MOVING with its profile",
          arguments: [ActivityKind.walking, .running, .cycling, .automotive],
          [ActivityConfidence.medium, .high])
    func credibleActivity(kind: ActivityKind, confidence: ActivityConfidence) {
        var m = TrackingStateMachine.at(.probing)
        let effects = m.handle(.motionActivity(kind: kind, confidence: confidence))
        #expect(m.phase == .moving)
        let expected = GPSProfile.profile(for: kind, speed: nil)
        #expect(effects.withoutLogs == [.cancelProbeTimer, .startGPS(expected)])
        #expect(m.lastActivity == kind)
        #expect(m.lastActivityConfidence == confidence)
    }

    @Test("Low-confidence moving activity does not leave PROBING")
    func lowConfidenceActivity() {
        var m = TrackingStateMachine.at(.probing)
        #expect(m.handle(.motionActivity(kind: .walking, confidence: .low)).isEmpty)
        #expect(m.phase == .probing)
        #expect(m.lastActivity == .walking)
    }

    @Test("High-confidence stationary after a fix goes STATIONARY")
    func stationaryAfterFix() {
        var m = TrackingStateMachine.at(.probing)
        _ = m.handle(.gpsFix(speed: 0))
        let effects = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        #expect(m.phase == .stationary)
        #expect(effects.withoutLogs == [.cancelProbeTimer, .stopGPS])
    }

    @Test("Stationary before any fix, or below high confidence, does not leave PROBING")
    func stationaryWithoutFix() {
        var m = TrackingStateMachine.at(.probing)
        #expect(m.handle(.motionActivity(kind: .stationary, confidence: .high)).isEmpty)
        #expect(m.phase == .probing)
        _ = m.handle(.gpsFix(speed: 0))
        #expect(m.handle(.motionActivity(kind: .stationary, confidence: .medium)).isEmpty)
        #expect(m.phase == .probing)
    }

    @Test("Unknown activity while probing is ignored")
    func unknownActivity() {
        var m = TrackingStateMachine.at(.probing)
        #expect(m.handle(.motionActivity(kind: .unknown, confidence: .high)).isEmpty)
        #expect(m.phase == .probing)
    }

    @Test("significantChange / visit while probing restart the probe timer",
          arguments: [TrackingInput.significantChange, .visit])
    func extendProbe(input: TrackingInput) {
        var m = TrackingStateMachine.at(.probing)
        let effects = m.handle(input)
        #expect(m.phase == .probing)
        #expect(effects == [.startProbeTimer(seconds: 45)])
        #expect(m.probeTimerArmed)
    }

    @Test("motionHint while probing with timer armed is a no-op")
    func hint() {
        var m = TrackingStateMachine.at(.probing)
        #expect(m.handle(.motionHint).isEmpty)
        #expect(m.phase == .probing)
    }

    @Test("Stale stillness timer is ignored while probing")
    func staleStillness() {
        var m = TrackingStateMachine.at(.probing)
        #expect(m.handle(.stillnessTimerFired).isEmpty)
        #expect(m.phase == .probing)
    }
}

// MARK: - Stationary

@Suite("TrackingStateMachine · stationary")
struct TrackingStateStationaryTests {
    @Test("Credible moving activity jumps straight to MOVING",
          arguments: [ActivityKind.walking, .running, .cycling, .automotive])
    func credibleActivity(kind: ActivityKind) {
        var m = TrackingStateMachine.at(.stationary)
        let effects = m.handle(.motionActivity(kind: kind, confidence: .medium))
        #expect(m.phase == .moving)
        #expect(effects.withoutLogs == [.startGPS(GPSProfile.profile(for: kind, speed: nil))])
        #expect(m.lastTransition?.from == .stationary)
        #expect(m.lastTransition?.to == .moving)
    }

    @Test("Low-confidence moving activity only opens a PROBING window")
    func lowConfidence() {
        var m = TrackingStateMachine.at(.stationary)
        let effects = m.handle(.motionActivity(kind: .cycling, confidence: .low))
        #expect(m.phase == .probing)
        #expect(effects.withoutLogs == [.startGPS(.probing), .startProbeTimer(seconds: 45)])
    }

    @Test("Credible unknown activity opens PROBING; low-confidence unknown is ignored")
    func unknown() {
        var m = TrackingStateMachine.at(.stationary)
        #expect(m.handle(.motionActivity(kind: .unknown, confidence: .low)).isEmpty)
        #expect(m.phase == .stationary)
        _ = m.handle(.motionActivity(kind: .unknown, confidence: .medium))
        #expect(m.phase == .probing)
    }

    @Test("Stationary activity keeps STATIONARY")
    func stationaryActivity() {
        var m = TrackingStateMachine.at(.stationary)
        #expect(m.handle(.motionActivity(kind: .stationary, confidence: .high)).isEmpty)
        #expect(m.phase == .stationary)
    }

    @Test("significantChange / visit / motionHint open PROBING, never MOVING",
          arguments: [TrackingInput.significantChange, .visit, .motionHint])
    func probeTriggers(input: TrackingInput) {
        var m = TrackingStateMachine.at(.stationary)
        let effects = m.handle(input)
        #expect(m.phase == .probing)
        #expect(effects.withoutLogs == [.startGPS(.probing), .startProbeTimer(seconds: 45)])
        #expect(m.probeTimerArmed)
        #expect(m.lastTransition == TrackingTransition(from: .stationary, to: .probing, input: input))
    }

    @Test("Coarse fixes and stale timers while stationary carry no decision power")
    func ignoredInputs() {
        var m = TrackingStateMachine.at(.stationary)
        #expect(m.handle(.gpsFix(speed: 10)).isEmpty)
        #expect(m.phase == .stationary)
        #expect(m.lastSpeed == 10)
        #expect(m.handle(.stillnessTimerFired).isEmpty)
        #expect(m.handle(.probeTimerFired).isEmpty)
        #expect(m.phase == .stationary)
    }
}

// MARK: - Moving & hysteresis

@Suite("TrackingStateMachine · moving and hysteresis")
struct TrackingStateMovingTests {
    @Test("Credible stationary activity arms the stillness timer once")
    func armByActivity() {
        var m = TrackingStateMachine.at(.moving)
        let e1 = m.handle(.motionActivity(kind: .stationary, confidence: .medium))
        #expect(e1 == [.startStillnessTimer(seconds: 120)])
        #expect(m.stillnessTimerArmed)
        #expect(m.phase == .moving)
        // Re-arming is idempotent.
        #expect(m.handle(.motionActivity(kind: .stationary, confidence: .high)).isEmpty)
        #expect(m.handle(.gpsFix(speed: 0.1)).isEmpty)
    }

    @Test("Low-confidence stationary activity does not arm the timer")
    func lowConfidenceStationary() {
        var m = TrackingStateMachine.at(.moving)
        #expect(m.handle(.motionActivity(kind: .stationary, confidence: .low)).isEmpty)
        #expect(!m.stillnessTimerArmed)
    }

    @Test("Slow fix arms the stillness timer using the configured timeout")
    func armBySlowFix() {
        var s = TrackingSettings()
        s.stillnessTimeout = 30
        var m = TrackingStateMachine.at(.moving, settings: s)
        let effects = m.handle(.gpsFix(speed: 0.29))
        #expect(effects.withoutLogs == [.startStillnessTimer(seconds: 30)])
        #expect(m.stillnessTimerArmed)
    }

    @Test("Fix at exactly stillSpeedThreshold does not arm the timer")
    func boundaryStillSpeed() {
        var m = TrackingStateMachine.at(.moving)
        let effects = m.handle(.gpsFix(speed: 0.3))
        #expect(!effects.contains(.startStillnessTimer(seconds: 120)))
        #expect(!m.stillnessTimerArmed)
    }

    @Test("Stillness timer expiry goes STATIONARY and stops GPS")
    func timerFires() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        let effects = m.handle(.stillnessTimerFired)
        #expect(m.phase == .stationary)
        #expect(effects.withoutLogs == [.stopGPS])
        #expect(!m.stillnessTimerArmed)
        #expect(m.activeProfile == nil)
        #expect(m.lastTransition == TrackingTransition(from: .moving, to: .stationary, input: .stillnessTimerFired))
    }

    @Test("Stillness timer expiry without an armed timer is ignored (stale timer)")
    func staleTimer() {
        var m = TrackingStateMachine.at(.moving)
        #expect(m.handle(.stillnessTimerFired).isEmpty)
        #expect(m.phase == .moving)
    }

    @Test("Any moving activity cancels the stillness timer",
          arguments: [ActivityKind.walking, .running, .cycling, .automotive],
          [ActivityConfidence.low, .medium, .high])
    func cancelByActivity(kind: ActivityKind, confidence: ActivityConfidence) {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        let effects = m.handle(.motionActivity(kind: kind, confidence: confidence))
        #expect(effects.first == .cancelStillnessTimer)
        #expect(!m.stillnessTimerArmed)
        #expect(m.phase == .moving)
        // The activity also changes the profile.
        #expect(effects.contains(.startGPS(GPSProfile.profile(for: kind, speed: 1.5))))
    }

    @Test("Fast fix cancels the timer unless the classifier says stationary")
    func cancelByFastFix() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.gpsFix(speed: 0.1))
        #expect(m.stillnessTimerArmed)
        let e1 = m.handle(.gpsFix(speed: 2))
        #expect(e1.contains(.cancelStillnessTimer))
        #expect(!m.stillnessTimerArmed)

        // Classifier says stationary: speed jitter must not defeat it.
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        #expect(m.stillnessTimerArmed)
        let e2 = m.handle(.gpsFix(speed: 2))
        #expect(!e2.contains(.cancelStillnessTimer))
        #expect(m.stillnessTimerArmed)
        _ = m.handle(.stillnessTimerFired)
        #expect(m.phase == .stationary)
    }

    @Test("Fix between still and moving thresholds leaves the timer untouched")
    func inBetweenSpeed() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.gpsFix(speed: 0.1))
        #expect(m.handle(.gpsFix(speed: 0.5)).withoutLogs.isEmpty)
        #expect(m.stillnessTimerArmed)
    }

    @Test("motionHint cancels the stillness timer")
    func hintCancels() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        #expect(m.handle(.motionHint) == [.cancelStillnessTimer])
        #expect(!m.stillnessTimerArmed)
        #expect(m.handle(.motionHint).isEmpty)
    }

    @Test("significantChange / visit while moving only log",
          arguments: [TrackingInput.significantChange, .visit])
    func ignoredWhileMoving(input: TrackingInput) {
        var m = TrackingStateMachine.at(.moving)
        let effects = m.handle(input)
        #expect(m.phase == .moving)
        #expect(effects.withoutLogs.isEmpty)
        #expect(effects.hasLog)
    }

    @Test("Probe timer expiry while moving is ignored")
    func staleProbeTimer() {
        var m = TrackingStateMachine.at(.moving)
        #expect(m.handle(.probeTimerFired).isEmpty)
        #expect(m.phase == .moving)
    }
}

// MARK: - Profile updates while moving

@Suite("TrackingStateMachine · profile updates")
struct TrackingStateProfileTests {
    @Test("Profile is re-emitted only when it changes")
    func reemitOnChange() {
        var m = TrackingStateMachine.at(.moving) // unknown @ 1.5 m/s → slow-unknown
        #expect(m.activeProfile?.label == "slow-unknown")

        // Same tier: no new startGPS.
        #expect(m.handle(.gpsFix(speed: 2.0)).startGPSProfiles.isEmpty)

        // Crossing the running threshold changes the profile.
        let e1 = m.handle(.gpsFix(speed: 3.0))
        #expect(e1.startGPSProfiles == [GPSProfile.profile(for: .unknown, speed: 3.0)])
        #expect(m.activeProfile?.label == "fast-unknown")

        // Vehicle speed.
        let e2 = m.handle(.gpsFix(speed: 12))
        #expect(e2.startGPSProfiles == [GPSProfile.profile(for: .unknown, speed: 12)])
        #expect(m.activeProfile?.desiredAccuracy == .bestForNavigation)

        // Same tier again: nothing.
        #expect(m.handle(.gpsFix(speed: 15)).startGPSProfiles.isEmpty)
    }

    @Test("Activity change reconfigures the profile, unchanged activity does not")
    func activityChange() {
        var m = TrackingStateMachine.at(.moving)
        let e1 = m.handle(.motionActivity(kind: .walking, confidence: .high))
        #expect(e1 == [.startGPS(GPSProfile.profile(for: .walking, speed: 1.5))])
        #expect(m.handle(.motionActivity(kind: .walking, confidence: .high)).isEmpty)
        let e2 = m.handle(.motionActivity(kind: .cycling, confidence: .medium))
        #expect(e2 == [.startGPS(GPSProfile.profile(for: .cycling, speed: 1.5))])
        #expect(m.activeProfile?.label == "cycling")
    }

    @Test("Profile honours custom distance filters from settings")
    func settingsDistanceFilters() {
        var s = TrackingSettings()
        s.walkingDistanceFilter = 3
        var m = TrackingStateMachine.at(.moving, settings: s)
        let e = m.handle(.motionActivity(kind: .walking, confidence: .high))
        #expect(e.startGPSProfiles.first?.distanceFilter == 3)
    }

    @Test("Last activity survives into the MOVING profile after a stationary interlude")
    func activityRemembered() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.motionActivity(kind: .automotive, confidence: .high))
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        _ = m.handle(.stillnessTimerFired)
        #expect(m.phase == .stationary)
        _ = m.handle(.significantChange)
        let e = m.handle(.gpsFix(speed: 1))
        // lastActivity is .stationary → speed decides.
        #expect(m.phase == .moving)
        #expect(e.startGPSProfiles == [GPSProfile.profile(for: .stationary, speed: 1)])
    }
}

// MARK: - Scenarios

@Suite("TrackingStateMachine · scenarios")
struct TrackingStateScenarioTests {
    @Test("A day in the life: enable, walk, drive, park, relaunch probe, disable")
    func dayInTheLife() {
        var m = TrackingStateMachine()
        var log: [TrackingTransition] = []
        func step(_ input: TrackingInput) -> [TrackingEffect] {
            let e = m.handle(input)
            if let t = m.lastTransition, log.last != t { log.append(t) }
            return e
        }

        _ = step(.enable)
        _ = step(.gpsFix(speed: 0.2))
        _ = step(.motionActivity(kind: .walking, confidence: .high))
        #expect(m.phase == .moving)
        #expect(m.activeProfile?.label == "walking")

        _ = step(.motionActivity(kind: .automotive, confidence: .high))
        #expect(m.activeProfile?.label == "automotive")
        _ = step(.gpsFix(speed: 25))

        _ = step(.motionActivity(kind: .stationary, confidence: .high))
        #expect(m.stillnessTimerArmed)
        // A brief walking blip cancels the countdown.
        _ = step(.motionActivity(kind: .walking, confidence: .medium))
        #expect(!m.stillnessTimerArmed)
        _ = step(.motionActivity(kind: .stationary, confidence: .high))
        _ = step(.stillnessTimerFired)
        #expect(m.phase == .stationary)

        // Relaunch-style significant change with no real motion.
        _ = step(.significantChange)
        #expect(m.phase == .probing)
        _ = step(.gpsFix(speed: 0))
        _ = step(.probeTimerFired)
        #expect(m.phase == .stationary)

        _ = step(.disable)
        #expect(m.phase == .disabled)

        #expect(log.map(\.to) == [.probing, .moving, .stationary, .probing, .stationary, .disabled])
    }

    @Test("Every reachable phase can be disabled and returns to a clean state",
          arguments: [TrackingPhase.probing, .moving, .stationary])
    func disableFromAnywhere(phase: TrackingPhase) {
        var m = TrackingStateMachine.at(phase)
        let effects = m.handle(.disable)
        #expect(m.phase == .disabled)
        #expect(effects.contains(.stopGPS))
        #expect(effects.contains(.stopMotionUpdates))
        #expect(effects.contains(.stopSignificantChange))
        #expect(effects.withoutLogs.last == .stopSignificantChange)
        #expect(m.activeProfile == nil)
        #expect(!m.stillnessTimerArmed)
        #expect(!m.probeTimerArmed)
        #expect(m.probeFixCount == 0)
    }

    @Test("Machine is a value: copies diverge independently")
    func valueSemantics() {
        let base = TrackingStateMachine.at(.probing)
        var a = base
        var b = base
        _ = a.handle(.gpsFix(speed: 5))
        _ = b.handle(.probeTimerFired)
        #expect(a.phase == .moving)
        #expect(b.phase == .stationary)
        #expect(base.phase == .probing)
    }
}
