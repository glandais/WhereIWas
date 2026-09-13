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
            // Two fixes: leaving PROBING on speed alone needs a streak.
            _ = m.handle(.gpsFix(speed: 1.5))
            _ = m.handle(.gpsFix(speed: 1.5))
        case .settling:
            _ = m.handle(.enable)
            _ = m.handle(.gpsFix(speed: 1.5))
            _ = m.handle(.gpsFix(speed: 1.5))
            // Two still readings, so the countdown is corroborated and the
            // stop is real; a trip that stops lands in SETTLING.
            _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
            _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
            _ = m.handle(.stillnessTimerFired)
        case .stationary:
            _ = m.handle(.enable)
            // The probe window saw no fix, so this machine is *not* settled:
            // use `settledStationary()` for the other side of that rule.
            // Nothing ever moved either, so there is no trip to settle out of
            // and the machine goes straight to GPS off.
            _ = m.handle(.probeTimerFired)
        }
        precondition(m.phase == phase)
        return m
    }

    /// STATIONARY with the settle confirmed: a probe window that saw fixes and
    /// found nothing moving. `unknown` reports no longer open PROBING here.
    static func settledStationary(settings: TrackingSettings = TrackingSettings()) -> TrackingStateMachine {
        var m = TrackingStateMachine(settings: settings)
        _ = m.handle(.enable)
        _ = m.handle(.gpsFix(speed: 0))
        _ = m.handle(.probeTimerFired)
        precondition(m.phase == .stationary)
        precondition(m.settledStationary)
        return m
    }

    /// STATIONARY reached from MOVING through the stillness timer: nothing
    /// ever confirmed the settle, so `unknown` reports still open PROBING.
    static func unsettledStationary(settings: TrackingSettings = TrackingSettings()) -> TrackingStateMachine {
        var m = TrackingStateMachine.at(.moving, settings: settings)
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .low))
        _ = m.handle(.gpsFix(speed: 0))
        _ = m.handle(.gpsFix(speed: 0))    // corroborates: data still arriving
        _ = m.handle(.stillnessTimerFired)
        precondition(m.phase == .settling)
        _ = m.handle(.probeTimerFired)     // the settling window expires unused
        precondition(m.phase == .stationary)
        precondition(!m.settledStationary)
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
        #expect(m.fastFixStreak == 0)
        #expect(m.profileSpeed == nil)
        #expect(!m.settledStationary)
        #expect(m.lastTransition == nil)
    }

    @Test("isGPSActive is false only for disabled and stationary")
    func gpsActive() {
        #expect(!TrackingPhase.disabled.isGPSActive)
        #expect(!TrackingPhase.stationary.isGPSActive)
        #expect(TrackingPhase.probing.isGPSActive)
        #expect(TrackingPhase.moving.isGPSActive)
        #expect(TrackingPhase.settling.isGPSActive, "GPS runs, rationed")
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
        // The phase bookkeeping stays untouched too: a disabled machine must
        // not come back settled, or holding a streak, from inputs it ignored.
        #expect(!m.settledStationary)
        #expect(m.fastFixStreak == 0)
        #expect(m.profileSpeed == nil)
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
    @Test("Two consecutive fast fixes promote to MOVING, cancelling the probe timer")
    func fastFix() {
        var m = TrackingStateMachine.at(.probing)
        #expect(m.handle(.gpsFix(speed: 0.7)).isEmpty)
        #expect(m.phase == .probing)
        #expect(m.fastFixStreak == 1)
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

    @Test("A single aberrant fast fix does not leave PROBING")
    func isolatedFastFix() {
        var m = TrackingStateMachine.at(.probing)
        // The 8.4 m/s reading of 11:10 — 25 cm of actual movement.
        #expect(m.handle(.gpsFix(speed: 8.4)).isEmpty)
        #expect(m.phase == .probing)
        #expect(m.fastFixStreak == 1)
        #expect(m.handle(.gpsFix(speed: 0.05)).isEmpty)
        #expect(m.fastFixStreak == 0)
        #expect(m.phase == .probing)
    }

    @Test("A speed-less fix breaks the streak")
    func speedlessFixBreaksStreak() {
        var m = TrackingStateMachine.at(.probing)
        #expect(m.handle(.gpsFix(speed: 1.5)).isEmpty)
        #expect(m.handle(.gpsFix(speed: nil)).isEmpty)
        #expect(m.fastFixStreak == 0)
        #expect(m.handle(.gpsFix(speed: 1.5)).isEmpty)
        #expect(m.phase == .probing)
        _ = m.handle(.gpsFix(speed: 1.5))
        #expect(m.phase == .moving)
    }

    @Test("movingFixConfirmations = 1 restores promotion on a single fix")
    func singleConfirmationSetting() {
        var s = TrackingSettings()
        s.movingFixConfirmations = 1
        var m = TrackingStateMachine.at(.probing, settings: s)
        _ = m.handle(.gpsFix(speed: 0.7))
        #expect(m.phase == .moving)
    }

    @Test("Leaving and re-entering PROBING resets the streak")
    func streakResetAcrossWindows() {
        var m = TrackingStateMachine.at(.probing)
        _ = m.handle(.gpsFix(speed: 1.5))
        _ = m.handle(.probeTimerFired)
        #expect(m.phase == .stationary)
        _ = m.handle(.motionHint)
        #expect(m.phase == .probing)
        #expect(m.fastFixStreak == 0)
        #expect(m.handle(.gpsFix(speed: 1.5)).isEmpty)
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

    @Test("Credible unknown activity opens PROBING while unsettled; low confidence never does")
    func unknown() {
        var m = TrackingStateMachine.unsettledStationary()
        #expect(!m.settledStationary)
        #expect(m.handle(.motionActivity(kind: .unknown, confidence: .low)).isEmpty)
        #expect(m.phase == .stationary)
        _ = m.handle(.motionActivity(kind: .unknown, confidence: .medium))
        #expect(m.phase == .probing)
    }

    @Test("Once settled, repeated confident unknown reports are ignored")
    func unknownWhileSettled() {
        var m = TrackingStateMachine.settledStationary()
        #expect(m.settledStationary)
        for _ in 0..<10 {
            #expect(m.handle(.motionActivity(kind: .unknown, confidence: .high)).isEmpty)
        }
        #expect(m.phase == .stationary)
    }

    @Test("A confident stationary report settles the machine")
    func stationaryReportSettles() {
        var m = TrackingStateMachine.unsettledStationary()
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .medium))
        #expect(!m.settledStationary, "medium confidence is not enough")
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        #expect(m.settledStationary)
        #expect(m.handle(.motionActivity(kind: .unknown, confidence: .high)).isEmpty)
        #expect(m.phase == .stationary)
    }

    @Test("Real evidence of motion unsettles the machine",
          arguments: [TrackingInput.motionHint, .significantChange, .visit,
                      .motionActivity(kind: .walking, confidence: .low)])
    func evidenceUnsettles(input: TrackingInput) {
        var m = TrackingStateMachine.settledStationary()
        #expect(m.settledStationary)
        _ = m.handle(input)                    // → probing, and unsettled
        #expect(!m.settledStationary)
        #expect(m.phase == .probing)
    }

    @Test("The observed ping-pong opens PROBING once, not on every unknown report")
    func pingPongOpensProbingOnce() {
        var m = TrackingStateMachine.unsettledStationary()
        var probeEntries = 0
        // unknown/high → probing, a fix, stationary/high → stationary, repeat.
        for _ in 0..<5 {
            if !m.handle(.motionActivity(kind: .unknown, confidence: .high)).isEmpty {
                probeEntries += 1
            }
            if m.phase == .probing {
                _ = m.handle(.gpsFix(speed: 0))
                _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
            }
        }
        #expect(probeEntries == 1)
        #expect(m.phase == .stationary)
    }

    @Test("A probe window that saw no fix at all settles nothing")
    func emptyProbeWindowDoesNotSettle() {
        var m = TrackingStateMachine.at(.probing)
        // Indoors, a garage, a cold receiver: 45 s and not one fix.
        #expect(m.probeFixCount == 0)
        _ = m.handle(.probeTimerFired)
        #expect(m.phase == .stationary)
        #expect(!m.settledStationary, "no evidence in either direction is not evidence of stillness")
        _ = m.handle(.motionActivity(kind: .unknown, confidence: .high))
        #expect(m.phase == .probing)
    }

    @Test("A phone still on a car seat does not settle while MOVING")
    func stationaryReportWhileMovingDoesNotSettle() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        #expect(m.stillnessTimerArmed)
        #expect(!m.settledStationary, "the classifier describes the phone, not the car")
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        _ = m.handle(.stillnessTimerFired)
        _ = m.handle(.probeTimerFired)     // through the settling window
        #expect(m.phase == .stationary)
        // The unknown reports that follow can still bring tracking back.
        _ = m.handle(.motionActivity(kind: .unknown, confidence: .high))
        #expect(m.phase == .probing)
    }

    @Test("A measured speed refutes a settle")
    func fastFixUnsettles() {
        var m = TrackingStateMachine.settledStationary()
        _ = m.handle(.gpsFix(speed: 20))   // a coarse fix while stationary
        #expect(!m.settledStationary)
        #expect(m.phase == .stationary, "a fix alone still does not leave STATIONARY")
        _ = m.handle(.motionActivity(kind: .unknown, confidence: .high))
        #expect(m.phase == .probing)
    }

    @Test("disable clears the settle, so a new session starts unbiased")
    func disableClearsTheSettle() {
        var m = TrackingStateMachine.settledStationary()
        _ = m.handle(.disable)
        #expect(!m.settledStationary)
        _ = m.handle(.enable)
        _ = m.handle(.probeTimerFired)
        _ = m.handle(.motionActivity(kind: .unknown, confidence: .high))
        #expect(m.phase == .probing)
    }

    @Test("The profile speed keeps up with coarse fixes while STATIONARY")
    func profileSpeedFollowsCoarseFixes() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.gpsFix(speed: 15))
        _ = m.handle(.gpsFix(speed: 15))
        #expect(m.activeProfile?.label == "automotive")
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        _ = m.handle(.stillnessTimerFired)
        _ = m.handle(.probeTimerFired)
        #expect(m.phase == .stationary)
        _ = m.handle(.gpsFix(speed: 0))    // coarse updates keep arriving
        #expect(m.profileSpeed == 0)
        // A pedestrian must not inherit the drive's 50 m filter.
        _ = m.handle(.motionActivity(kind: .walking, confidence: .high))
        #expect(m.phase == .moving)
        #expect(m.activeProfile?.label == "walking")
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

    /// A trip that stops does not switch GPS off: it settles first, and only
    /// the settling window's own expiry reaches STATIONARY.
    @Test("Stillness timer expiry goes SETTLING, and the window then goes STATIONARY")
    func timerFires() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        let effects = m.handle(.stillnessTimerFired)
        #expect(m.phase == .settling)
        #expect(effects.withoutLogs == [.startGPS(.settling()), .startProbeTimer(seconds: 300)])
        #expect(!m.stillnessTimerArmed)
        #expect(m.activeProfile == .settling())
        #expect(m.lastTransition == TrackingTransition(from: .moving, to: .settling, input: .stillnessTimerFired))

        let end = m.handle(.probeTimerFired)
        #expect(m.phase == .stationary)
        #expect(end.withoutLogs == [.stopGPS])
        #expect(m.activeProfile == nil)
    }

    /// The bug this guards: on a ride, one fix at a red light armed the
    /// countdown, iOS then suspended the app, and 120 s later the timer fired
    /// on evidence nobody had renewed — STATIONARY in the middle of a 11 km
    /// ride, GPS off.
    @Test("A timer that fires on nothing goes PROBING, not STATIONARY")
    func uncorroboratedTimerProbes() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.gpsFix(speed: 0.1))
        #expect(m.stillnessTimerArmed)
        #expect(!m.stillnessCorroborated)

        let effects = m.handle(.stillnessTimerFired)
        #expect(m.phase == .probing, "silence is not stillness")
        #expect(effects.withoutLogs == [.startGPS(.probing), .startProbeTimer(seconds: 45)])
        #expect(!m.stillnessTimerArmed)
        #expect(!m.stillnessCorroborated)
    }

    /// And the probe settles it either way: still nothing moving, STATIONARY.
    @Test("The probe that follows an uncorroborated timer still settles")
    func uncorroboratedTimerThenProbeSettles() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.gpsFix(speed: 0.1))
        _ = m.handle(.stillnessTimerFired)
        _ = m.handle(.gpsFix(speed: 0))
        _ = m.handle(.probeTimerFired)
        // Still a trip that stopped, so the settle goes through the window.
        #expect(m.phase == .settling)
        _ = m.handle(.gpsFix(speed: 0))
        _ = m.handle(.probeTimerFired)
        #expect(m.phase == .stationary)
        #expect(m.settledStationary)
    }

    /// A second still reading is what tells the machine data is still coming.
    @Test("Two still readings corroborate the countdown",
          arguments: [TrackingInput.gpsFix(speed: 0), .motionActivity(kind: .stationary, confidence: .high)])
    func secondStillReadingCorroborates(_ second: TrackingInput) {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.gpsFix(speed: 0.1))
        #expect(m.handle(second).isEmpty, "the timer is already running")
        #expect(m.stillnessCorroborated)
        _ = m.handle(.stillnessTimerFired)
        #expect(m.phase == .settling, "corroborated: the stop is real, so it settles")
    }

    /// Corroboration belongs to one countdown: cancelling drops it.
    @Test("Cancelling the timer forgets the corroboration")
    func disarmForgetsCorroboration() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.gpsFix(speed: 0))
        _ = m.handle(.gpsFix(speed: 0))
        #expect(m.stillnessCorroborated)
        _ = m.handle(.gpsFix(speed: 2))
        #expect(!m.stillnessTimerArmed)
        #expect(!m.stillnessCorroborated)

        _ = m.handle(.gpsFix(speed: 0))
        #expect(m.stillnessTimerArmed)
        #expect(!m.stillnessCorroborated, "the new countdown starts unproven")
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
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        _ = m.handle(.stillnessTimerFired)
        #expect(m.phase == .settling)
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

// MARK: - Settling

/// The window between a stop and GPS going off.
///
/// Its reason to exist, measured on 2026-09-12: two rides lost 941 m and 779 m
/// because the machine switched GPS off the instant it decided the ride had
/// stopped. The stops were real — the bicycle had not moved for four minutes —
/// but the restarts were invisible for 211 s and 182 s, because a bicycle
/// produces no steps for the pedometer and CoreMotion needs minutes to say
/// `cycling`, while significant change needs ~500 m.
@Suite("TrackingStateMachine · settling")
struct TrackingStateSettlingTests {
    @Test("A stop that ends a trip settles instead of switching GPS off")
    func stopSettles() {
        var m = TrackingStateMachine.at(.settling)
        #expect(m.phase == .settling)
        #expect(m.activeProfile == .settling())
        #expect(m.probeTimerArmed)
        #expect(m.recentlyMoved)
    }

    @Test("The settling profile is rationed by its distance filter, not by accuracy")
    func profileShape() {
        var s = TrackingSettings()
        s.settlingDistanceFilter = 80
        let p = GPSProfile.settling(s)
        #expect(p.distanceFilter == 80)
        #expect(p.label == "settling")
        #expect(p.activityType == .other)

        var m = TrackingStateMachine.at(.moving, settings: s)
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        let e = m.handle(.stillnessTimerFired)
        #expect(e.startGPSProfiles == [p])
    }

    /// The 14:23 loss: `stationary/high` cut GPS while the rider was already
    /// pedalling again, and nothing noticed for three minutes.
    @Test("No stillness report shortens the window",
          arguments: [ActivityConfidence.low, .medium, .high])
    func stationaryDoesNotShorten(_ confidence: ActivityConfidence) {
        var m = TrackingStateMachine.at(.settling)
        let e = m.handle(.motionActivity(kind: .stationary, confidence: confidence))
        #expect(m.phase == .settling)
        #expect(e.isEmpty)
        #expect(!m.settledStationary, "settling here would slow the restart down further")
    }

    @Test("A confident unknown is not news either")
    func unknownIgnored() {
        var m = TrackingStateMachine.at(.settling)
        #expect(m.handle(.motionActivity(kind: .unknown, confidence: .high)).isEmpty)
        #expect(m.phase == .settling)
    }

    /// What the window is for: the departure arrives as fixes through a wide
    /// filter, and two of them are a confirmed restart.
    @Test("Confirmed movement during the window returns to MOVING")
    func departureResumes() {
        var m = TrackingStateMachine.at(.settling)
        #expect(m.handle(.gpsFix(speed: 4)).isEmpty, "one fix is not a departure")
        #expect(m.phase == .settling)
        let e = m.handle(.gpsFix(speed: 4))
        #expect(m.phase == .moving)
        #expect(e.contains(.cancelProbeTimer))
        #expect(m.lastTransition == TrackingTransition(from: .settling, to: .moving,
                                                       input: .gpsFix(speed: 4)))
    }

    @Test("A credible moving activity ends the window at once")
    func activityResumes() {
        var m = TrackingStateMachine.at(.settling)
        _ = m.handle(.motionActivity(kind: .cycling, confidence: .high))
        #expect(m.phase == .moving)
        #expect(m.activeProfile?.label == "cycling")
    }

    @Test("Physical hints and coarse wake-ups open a PROBING window",
          arguments: [TrackingInput.motionHint, .significantChange, .visit,
                      .motionActivity(kind: .cycling, confidence: .low)])
    func hintsProbe(_ input: TrackingInput) {
        var m = TrackingStateMachine.at(.settling)
        let e = m.handle(input)
        #expect(m.phase == .probing)
        #expect(e.startGPSProfiles == [.probing])
        #expect(e.contains(.startProbeTimer(seconds: 45)))
    }

    @Test("An unused window expires into STATIONARY and switches GPS off")
    func windowExpires() {
        var m = TrackingStateMachine.at(.settling)
        let e = m.handle(.probeTimerFired)
        #expect(m.phase == .stationary)
        #expect(e.withoutLogs == [.stopGPS])
        #expect(!m.recentlyMoved)
        #expect(!m.probeTimerArmed)
    }

    @Test("A window that saw fixes and no movement settles; one that saw none does not")
    func expirySettles() {
        var m = TrackingStateMachine.at(.settling)
        _ = m.handle(.gpsFix(speed: 0))
        _ = m.handle(.probeTimerFired)
        #expect(m.settledStationary)

        var blind = TrackingStateMachine.at(.settling)
        _ = blind.handle(.probeTimerFired)
        #expect(!blind.settledStationary, "no fix is no evidence, indoors or suspended")
    }

    @Test("The window runs once per trip, not once per stop decision")
    func onlyOneWindowPerTrip() {
        var m = TrackingStateMachine.at(.settling)
        _ = m.handle(.probeTimerFired)
        #expect(m.phase == .stationary)
        // A probe window that finds nothing now goes straight back to GPS off.
        _ = m.handle(.motionHint)
        #expect(m.phase == .probing)
        _ = m.handle(.probeTimerFired)
        #expect(m.phase == .stationary, "nothing moved, so there is no trip to settle out of")
    }

    @Test("A new trip earns a new window")
    func newTripNewWindow() {
        var m = TrackingStateMachine.at(.settling)
        _ = m.handle(.probeTimerFired)
        _ = m.handle(.motionActivity(kind: .cycling, confidence: .high))
        #expect(m.phase == .moving)
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        _ = m.handle(.stillnessTimerFired)
        #expect(m.phase == .settling)
    }

    /// The other shape the loss took: an uncorroborated timer probes, the
    /// probe then decides STATIONARY — and that decision ends a trip too.
    @Test("The PROBING route to STATIONARY settles as well",
          arguments: [TrackingInput.probeTimerFired,
                      .motionActivity(kind: .stationary, confidence: .high)])
    func probingRouteSettles(_ input: TrackingInput) {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.gpsFix(speed: 0.1))
        _ = m.handle(.stillnessTimerFired)
        #expect(m.phase == .probing)
        _ = m.handle(.gpsFix(speed: 0))       // the probe saw something
        _ = m.handle(input)
        #expect(m.phase == .settling)
    }

    @Test("settlingTimeout = 0 restores the old behaviour: a stop switches GPS off")
    func disabledByZero() {
        var s = TrackingSettings()
        s.settlingTimeout = 0
        var m = TrackingStateMachine.at(.moving, settings: s)
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        let e = m.handle(.stillnessTimerFired)
        #expect(m.phase == .stationary)
        #expect(e.withoutLogs == [.stopGPS])
    }

    @Test("The window uses the configured timeout")
    func customTimeout() {
        var s = TrackingSettings()
        s.settlingTimeout = 90
        var m = TrackingStateMachine.at(.moving, settings: s)
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        let e = m.handle(.stillnessTimerFired)
        #expect(e.contains(.startProbeTimer(seconds: 90)))
    }

    @Test("Disabling during the window stops everything")
    func disableDuringWindow() {
        var m = TrackingStateMachine.at(.settling)
        let e = m.handle(.disable)
        #expect(m.phase == .disabled)
        #expect(e.contains(.cancelProbeTimer))
        #expect(e.contains(.stopGPS))
        #expect(!m.recentlyMoved)
    }
}

// MARK: - Profile updates while moving

@Suite("TrackingStateMachine · profile updates")
struct TrackingStateProfileTests {
    @Test("Profile is re-emitted only when it changes, and climbs a tier on confirmation")
    func reemitOnChange() {
        var m = TrackingStateMachine.at(.moving) // unknown @ 1.5 m/s → slow-unknown
        #expect(m.activeProfile?.label == "slow-unknown")

        // Same tier: no new startGPS.
        #expect(m.handle(.gpsFix(speed: 2.0)).startGPSProfiles.isEmpty)

        // Crossing the running threshold takes two fixes.
        #expect(m.handle(.gpsFix(speed: 3.0)).startGPSProfiles.isEmpty)
        #expect(m.activeProfile?.label == "slow-unknown")
        let e1 = m.handle(.gpsFix(speed: 3.0))
        #expect(e1.startGPSProfiles == [GPSProfile.profile(for: .unknown, speed: 3.0)])
        #expect(m.activeProfile?.label == "fast-unknown")

        // Vehicle speed, likewise.
        #expect(m.handle(.gpsFix(speed: 12)).startGPSProfiles.isEmpty)
        let e2 = m.handle(.gpsFix(speed: 12))
        #expect(e2.startGPSProfiles == [GPSProfile.profile(for: .unknown, speed: 12)])
        #expect(m.activeProfile?.desiredAccuracy == .bestForNavigation)

        // Same tier again: nothing.
        #expect(m.handle(.gpsFix(speed: 15)).startGPSProfiles.isEmpty)
    }

    @Test("A lone aberrant speed does not widen the profile")
    func isolatedFastFixKeepsProfile() {
        var m = TrackingStateMachine.at(.moving)
        #expect(m.activeProfile?.label == "slow-unknown")
        // The 8.4 m/s reading of 11:10, in MOVING this time.
        #expect(m.handle(.gpsFix(speed: 8.4)).startGPSProfiles.isEmpty)
        #expect(m.activeProfile?.label == "slow-unknown")
        #expect(m.lastSpeed == 8.4, "the raw reading is still reported")
        #expect(m.profileSpeed == 1.5, "but the profile has not followed it")
        _ = m.handle(.gpsFix(speed: 1.2))
        #expect(m.activeProfile?.label == "slow-unknown")
        #expect(m.profileSpeed == 1.2)
    }

    @Test("Dropping a tier applies at the first slow fix")
    func tierDropsImmediately() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.gpsFix(speed: 12))
        let e = m.handle(.gpsFix(speed: 12))
        #expect(e.startGPSProfiles.first?.label == "automotive")
        let back = m.handle(.gpsFix(speed: 0.8))
        #expect(back.startGPSProfiles == [GPSProfile.profile(for: .unknown, speed: 0.8)])
        #expect(m.activeProfile?.label == "slow-unknown")
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
        _ = m.handle(.motionActivity(kind: .stationary, confidence: .high))
        _ = m.handle(.stillnessTimerFired)
        _ = m.handle(.probeTimerFired)
        #expect(m.phase == .stationary)
        _ = m.handle(.significantChange)
        _ = m.handle(.gpsFix(speed: 1))          // first of the streak
        let e = m.handle(.gpsFix(speed: 1))
        // lastActivity is .stationary → speed decides.
        #expect(m.phase == .moving)
        #expect(e.startGPSProfiles == [GPSProfile.profile(for: .stationary, speed: 1)])
    }

    @Test("A confident unknown does not erase the cycling label the ride is on")
    func unknownDoesNotEraseAnExplicitLabel() {
        var m = TrackingStateMachine.at(.moving)
        _ = m.handle(.motionActivity(kind: .cycling, confidence: .high))
        #expect(m.lastActivity == .cycling)
        _ = m.handle(.motionActivity(kind: .unknown, confidence: .high))
        #expect(m.lastActivity == .cycling)

        // 8 m/s is 29 km/h: over `vehicleSpeedThreshold`, so the speed table
        // alone would call it a car. The remembered label keeps the ride
        // profile — and since that is the profile already applied, the right
        // assertion is that nothing is re-applied at all. Before the fix each
        // of these flaps emitted a startGPS onto `automotive`, 202 times over
        // one ride.
        let effects = m.handle(.gpsFix(speed: 8)) + m.handle(.gpsFix(speed: 8))
        #expect(!effects.startGPSProfiles.contains { $0.label == "automotive" })
        #expect(effects.startGPSProfiles.isEmpty)
        #expect(GPSProfile.profile(for: m.lastActivity, speed: 8).label == "cycling")
    }

    @Test("A ride that really becomes a drive still switches, on speed or on the label")
    func aRealDriveStillWins() {
        var onSpeed = TrackingStateMachine.at(.moving)
        _ = onSpeed.handle(.motionActivity(kind: .cycling, confidence: .high))
        _ = onSpeed.handle(.motionActivity(kind: .unknown, confidence: .high))
        // 20 m/s is 72 km/h, past `cyclingVehicleSpeedThreshold`.
        _ = onSpeed.handle(.gpsFix(speed: 20))
        let bySpeed = onSpeed.handle(.gpsFix(speed: 20))
        #expect(bySpeed.startGPSProfiles.last?.label == "automotive")

        var onLabel = TrackingStateMachine.at(.moving)
        _ = onLabel.handle(.motionActivity(kind: .cycling, confidence: .high))
        let byLabel = onLabel.handle(.motionActivity(kind: .automotive, confidence: .high))
        #expect(onLabel.lastActivity == .automotive)
        #expect(byLabel.startGPSProfiles.last?.label == "automotive")
    }

    @Test("Ignoring unknown for the profile leaves the phase logic alone")
    func unknownStillDrivesThePhase() {
        // From STATIONARY, a confident unknown still opens PROBING: the phase
        // switch reads the incoming kind, not the remembered one.
        var m = TrackingStateMachine.at(.stationary)
        _ = m.handle(.motionActivity(kind: .cycling, confidence: .high))
        m = TrackingStateMachine.at(.stationary, settings: m.settings)
        let e = m.handle(.motionActivity(kind: .unknown, confidence: .high))
        #expect(m.phase == .probing)
        #expect(!e.isEmpty)
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
        _ = step(.motionActivity(kind: .stationary, confidence: .high))
        _ = step(.stillnessTimerFired)
        // Parking a car is the end of a trip, so GPS keeps watching a while.
        #expect(m.phase == .settling)
        #expect(m.activeProfile == .settling())
        _ = step(.probeTimerFired)
        #expect(m.phase == .stationary)

        // Relaunch-style significant change with no real motion.
        _ = step(.significantChange)
        #expect(m.phase == .probing)
        _ = step(.gpsFix(speed: 0))
        _ = step(.probeTimerFired)
        // Nothing moved since the last stop, so no second settling window.
        #expect(m.phase == .stationary)

        _ = step(.disable)
        #expect(m.phase == .disabled)

        #expect(log.map(\.to) == [.probing, .moving, .settling, .stationary,
                                  .probing, .stationary, .disabled])
    }

    @Test("Every reachable phase can be disabled and returns to a clean state",
          arguments: [TrackingPhase.probing, .moving, .stationary, .settling])
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
        #expect(m.fastFixStreak == 0)
        #expect(m.lastSpeed == nil)
        #expect(m.profileSpeed == nil)
    }

    @Test("Machine is a value: copies diverge independently")
    func valueSemantics() {
        let base = TrackingStateMachine.at(.probing)
        var a = base
        var b = base
        _ = a.handle(.gpsFix(speed: 5))
        _ = a.handle(.gpsFix(speed: 5))
        _ = b.handle(.probeTimerFired)
        #expect(a.phase == .moving)
        #expect(b.phase == .stationary)
        #expect(base.phase == .probing)
    }
}
