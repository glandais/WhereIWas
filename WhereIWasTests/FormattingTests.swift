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

@MainActor
struct CoordinateFormattingTests {
    /// Coordinates must not pick up a locale decimal separator: in French it
    /// is a comma, and so is the separator between the two values.
    @Test func coordinatesUseADotInEveryLocale() {
        #expect(Formatting.coordinate(48.85837, 2.29448) == "48.85837, 2.29448")
        #expect(Formatting.coordinate(-33.86785, 151.20732) == "-33.86785, 151.20732")
    }
}
