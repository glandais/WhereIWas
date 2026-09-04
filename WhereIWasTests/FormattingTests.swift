import Foundation
import Testing
@testable import WhereIWas

/// `Formatting.transitionReason` parses machine text built by
/// `TrackingCoordinator.describe(_:)`. Nothing in the compiler ties the two
/// together, so these tests fail loudly if the vocabulary drifts apart.
@MainActor
struct TransitionReasonTests {
    /// Every input description the coordinator can emit must be recognised.
    @Test(arguments: [
        TrackingInput.enable,
        .disable,
        .stillnessTimerFired,
        .probeTimerFired,
        .significantChange,
        .visit,
        .motionHint,
        .gpsFix(speed: 4.3),
        .gpsFix(speed: nil)
    ] + ActivityKind.allCases.map { TrackingInput.motionActivity(kind: $0, confidence: .high) })
    func everyInputDescriptionIsTranslated(_ input: TrackingInput) {
        let token = TrackingCoordinator.describe(input)
        #expect(Formatting.reasonAtom(token) != token,
                "unrecognised transition token: \(token)")
    }

    /// The reasons the coordinator passes explicitly, alongside the input.
    @Test(arguments: ["user", "launch", "relaunch (location event)",
                      "visit arrival", "visit departure",
                      "steps(12)", "accelerometer(0.05g)"])
    func everyExplicitReasonIsTranslated(_ token: String) {
        #expect(Formatting.reasonAtom(token) != token,
                "unrecognised transition token: \(token)")
    }

    @Test func composedReasonKeepsItsShape() {
        let translated = Formatting.transitionReason("visit [visit arrival]")
        #expect(translated.hasSuffix("]"))
        #expect(translated.contains(" ["))
        #expect(translated != "visit [visit arrival]")
    }

    @Test func unknownTokenPassesThrough() {
        #expect(Formatting.transitionReason("something new") == "something new")
        #expect(Formatting.transitionReason("something [new]") == "something [new]")
    }
}

/// The audit trail persists a *code* plus its parameters, never English
/// prose, and `Formatting.auditSummary` turns the two into a sentence.
/// Nothing in the compiler ties a producer's code to an entry in that table,
/// so these tests fail loudly if one is added without a sentence.
@MainActor
struct AuditSummaryTests {
    private func hasSentence(_ name: String, _ arguments: [String] = []) -> Bool {
        Formatting.auditSummaryIfKnown(name: name, arguments: arguments) != nil
    }

    /// Every effect the state machine can order.
    @Test(arguments: [
        TrackingEffect.startGPS(.probing),
        .startGPS(.stationaryCoarse),
        .stopGPS,
        .startStillnessTimer(seconds: 120),
        .cancelStillnessTimer,
        .startProbeTimer(seconds: 45),
        .cancelProbeTimer,
        .startSignificantChange,
        .stopSignificantChange,
        .startMotionUpdates,
        .stopMotionUpdates,
        .log("anything")
    ])
    func everyEffectHasASentence(_ effect: TrackingEffect) {
        let name = "effect.\(TrackingCoordinator.effectName(effect))"
        #expect(hasSentence(name, TrackingCoordinator.arguments(for: effect)), "no sentence for \(name)")
    }

    /// Every GPS profile the machine can ask for is named, not left as its
    /// English label.
    @Test(arguments: ActivityKind.allCases)
    func everyGPSProfileIsNamed(_ kind: ActivityKind) {
        let profile = GPSProfile.profile(for: kind, speed: nil)
        #expect(Formatting.profileName(profile.label) != profile.label,
                "untranslated profile: \(profile.label)")
    }

    @Test(arguments: [
        MotionEvent.activity(kind: .walking, confidence: .high, timestamp: .now),
        .steps(count: 42, timestamp: .now),
        .accelerometerBurst(isMoving: true, magnitude: 0.052, timestamp: .now),
        .accelerometerBurst(isMoving: false, magnitude: 0.004, timestamp: .now),
        .authorizationChanged(.authorized)
    ])
    func everyMotionEventHasASentence(_ event: MotionEvent) {
        let name = TrackingCoordinator.eventName(event)
        #expect(hasSentence(name, TrackingCoordinator.arguments(for: event)), "no sentence for \(name)")
    }

    /// The activity report names the activity and its confidence, translated.
    @Test(arguments: ActivityKind.allCases)
    func everyActivityIsNamed(_ kind: ActivityKind) {
        let event = MotionEvent.activity(kind: kind, confidence: .low, timestamp: .now)
        let sentence = Formatting.auditSummary(name: TrackingCoordinator.eventName(event),
                                               arguments: TrackingCoordinator.arguments(for: event))
        #expect(sentence.contains(kind.title))
        #expect(!sentence.contains(kind.rawValue) || kind.title == kind.rawValue)
    }

    @Test(arguments: [
        LocationRejection.invalidAccuracy,
        .poorAccuracy(meters: 88),
        .stale(ageSeconds: 12),
        .futureTimestamp,
        .duplicate,
        .outOfOrder
    ])
    func everyRejectionHasASentence(_ reason: LocationRejection) {
        let arguments = LocationEngine.arguments(for: reason)
        #expect(Formatting.auditRejectionIfKnown(arguments) != nil, "no sentence for \(arguments)")
        #expect(hasSentence("fix.rejected", arguments))
    }

    /// The codes the producers write directly, with the arguments they carry.
    @Test(arguments: [
        ("app.launched", [String]()),
        ("app.relaunched", []),
        ("audit.enabled", []),
        ("audit.exported", ["12", "text"]),
        ("maintenance.purge", ["5", "3"]),
        ("state.transition", ["stationary", "moving"]),
        ("permission.motion", ["authorized"]),
        ("permission.location", ["always"]),
        ("location.significantChange", []),
        ("location.visit.arrival", []),
        ("location.visit.departure", []),
        ("location.error", ["kCLErrorDomain 1"]),
        ("monitoring.started", []),
        ("indicator.shown", []),
        ("indicator.hidden", []),
        ("gps.started", ["walking"]),
        ("gps.changed", ["automotive"]),
        ("gps.stopped", []),
        ("fix.accepted", []),
        ("store.insert", ["12"]),
        ("store.insertFailed", ["12"])
    ])
    func everyCodeHasASentence(_ event: (name: String, arguments: [String])) {
        #expect(hasSentence(event.name, event.arguments), "no sentence for \(event.name)")
    }

    /// A state transition reads as two translated phase names.
    @Test func transitionUsesPhaseTitles() {
        let sentence = Formatting.auditSummary(name: "state.transition",
                                               arguments: [TrackingPhase.stationary.rawValue,
                                                           TrackingPhase.moving.rawValue])
        #expect(sentence == "\(TrackingPhase.stationary.title) → \(TrackingPhase.moving.title)")
    }

    @Test(arguments: LocationFilter.checkNames)
    func everyCheckNameIsTranslated(_ name: String) {
        #expect(Formatting.checkNameIfKnown("check.\(name)") != nil, "unrecognised check: \(name)")
    }

    @Test(arguments: [FilterCheck.Verdict.passed, .failed, .skipped, .notApplicable])
    func everyVerdictIsTranslated(_ verdict: FilterCheck.Verdict) {
        #expect(Formatting.checkVerdictIfKnown(verdict.rawValue) != nil)
    }

    /// Only the verdict moves: the numbers behind it are data.
    @Test func verdictKeepsItsMeasurements() {
        #expect(Formatting.checkVerdict("failed (88.00 vs <= 50.00 m)").hasSuffix(" (88.00 vs <= 50.00 m)"))
    }

    /// An unknown code still reads as something, and says what it was.
    @Test func unknownCodeFallsBackToItsRawForm() {
        #expect(Formatting.auditSummaryIfKnown(name: "brand.new", arguments: []) == nil)
        #expect(Formatting.auditSummary(name: "brand.new", arguments: []) == "brand.new")
        #expect(Formatting.auditSummary(name: "brand.new", arguments: ["a", "b"]) == "brand.new a b")
        #expect(Formatting.auditRejection(["brandNew"]) == "brandNew")
        #expect(Formatting.checkName("check.brandNew") == "brandNew")
        #expect(Formatting.checkVerdict("undecided (1 vs 2)") == "undecided (1 vs 2)")
    }
}

@MainActor
struct CoordinateFormattingTests {
    /// Coordinates must not pick up a locale decimal separator: in French it
    /// is a comma, and so is the separator between the two values.
    @Test func coordinatesUseADotInEveryLocale() {
        #expect(Formatting.coordinate(48.85837, 2.29448) == "48.85837, 2.29448")
        #expect(Formatting.coordinate(-33.86785, 151.20732) == "-33.86785, 151.20732")
    }
}

/// The unit system setting drives the measurement helpers, not the machine's
/// locale.
///
/// Assertions are on the *magnitude*, not on the unit symbol: the symbols are
/// themselves localized (feet abbreviate to "pi" in French, mph to "mi/h"), so
/// asserting "ft" would only pass on an English machine. A length that comes
/// out ~3.28× larger can only be feet, and a speed ~1.61× smaller can only be
/// miles per hour.
@MainActor
struct UnitSystemFormattingTests {
    /// Formats `body` once per system, restoring the previous setting even if
    /// an expectation fails.
    private func inBothSystems(_ body: () -> String) -> (metric: String, imperial: String) {
        let previous = Formatting.unitSystem
        defer { Formatting.unitSystem = previous }
        Formatting.unitSystem = .metric
        let metric = body()
        Formatting.unitSystem = .imperial
        let imperial = body()
        return (metric, imperial)
    }

    /// The leading number of a formatted measurement, whatever the locale's
    /// decimal separator ("," in French) and grouping separator (a narrow
    /// no-break space) are.
    ///
    /// The separators are read from the current locale rather than guessed:
    /// treating "," as a decimal point is right in French and wrong in
    /// English, where "1,234 m" would come back as 1.234. That matters because
    /// the simulator's system locale is not a constant — `scripts/screenshots.sh`
    /// moves it per capture (see LEDGER D16) and restores it on exit, so a
    /// run interrupted mid-flight leaves the device in another language.
    private func magnitude(_ text: String) throws -> Double {
        let locale = Locale.current
        let decimal = Character(locale.decimalSeparator ?? ".")
        let grouping = locale.groupingSeparator.flatMap { $0.first }
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
            } else if character == decimal {
                digits.append(".")
            } else if character == grouping {
                continue
            } else if character.isWhitespace || character.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
                continue
            } else if !digits.isEmpty {
                break
            }
        }
        return try #require(Double(digits), "no number in \(text)")
    }

    @Test("Distances are kilometers in metric and miles in imperial")
    func distance() throws {
        let (metric, imperial) = inBothSystems { Formatting.distance(5_000) }
        #expect(metric.contains("km"))
        #expect(!imperial.contains("km"))
        // 5 km is 3.1 mi.
        #expect(try magnitude(metric) == 5)
        #expect(try abs(magnitude(imperial) - 3.1) < 0.2)
    }

    @Test("Short distances are meters in metric and feet in imperial")
    func shortDistance() throws {
        let (metric, imperial) = inBothSystems { Formatting.distance(12) }
        #expect(metric != imperial)
        #expect(try magnitude(metric) == 12)
        // 12 m is 39.4 ft.
        #expect(try abs(magnitude(imperial) - 39.4) < 0.5)
    }

    @Test("Speeds are km/h in metric and mph in imperial")
    func speed() throws {
        let (metric, imperial) = inBothSystems { Formatting.speed(10) }
        #expect(metric.contains("km"))
        #expect(!imperial.contains("km"))
        // 10 m/s is 36 km/h, i.e. 22.4 mph.
        #expect(try magnitude(metric) == 36)
        #expect(try abs(magnitude(imperial) - 22.4) < 0.5)
    }

    @Test("Altitude follows the unit system")
    func altitude() throws {
        let (metric, imperial) = inBothSystems { Formatting.altitude(1_234) }
        #expect(metric != imperial)
        #expect(try magnitude(metric) == 1_234)
        // 1234 m is 4049 ft.
        #expect(try abs(magnitude(imperial) - 4_049) < 2)
    }

    @Test("Accuracy follows the unit system and keeps its ± prefix")
    func accuracy() throws {
        let (metric, imperial) = inBothSystems { Formatting.accuracy(50) }
        #expect(metric.hasPrefix("±"))
        #expect(imperial.hasPrefix("±"))
        #expect(try magnitude(metric) == 50)
        // 50 m is 164 ft.
        #expect(try abs(magnitude(imperial) - 164) < 2)
    }

    @Test("Accuracy keeps its dash for a non-positive value in both systems")
    func accuracyUnavailable() {
        let (metric, imperial) = inBothSystems { Formatting.accuracy(-1) }
        #expect(metric == "—")
        #expect(imperial == "—")
    }

    @Test("Coordinates ignore the unit system entirely")
    func coordinatesAreUnaffected() {
        let (metric, imperial) = inBothSystems { Formatting.coordinate(48.85837, 2.29448) }
        #expect(metric == "48.85837, 2.29448")
        #expect(imperial == metric)
    }

    @Test("Setting the unit system twice is idempotent")
    func repeatedAssignment() {
        let previous = Formatting.unitSystem
        defer { Formatting.unitSystem = previous }
        Formatting.unitSystem = .imperial
        let once = Formatting.distance(5_000)
        Formatting.unitSystem = .imperial
        #expect(Formatting.distance(5_000) == once)
    }

    @Test("deviceDefault is one of the two cases and the raw values are stable")
    func deviceDefaultIsOneOfTheTwoCases() {
        #expect(UnitSystem.allCases.contains(UnitSystem.deviceDefault))
        #expect(UnitSystem(rawValue: "metric") == .metric)
        #expect(UnitSystem(rawValue: "imperial") == .imperial)
    }
}
