import Foundation
import Testing
@testable import WhereIWas

/// Guideline 5.1.1(iv): a permission that was never asked for is a setup
/// step, not a problem. These pin the split the Status screen and the tab
/// badge rely on, and that each setup card asks for its own permission only.
@MainActor
struct StatusWarningTests {
    @Test func freshInstallShowsSetupCardsWithoutBadge() {
        let status = TrackingStatus(locationAuthorization: .notDetermined,
                                    motionAuthorization: .notDetermined)
        let cards = status.warnings
        #expect(cards.count == 2)
        let allSetup = cards.allSatisfy(\.isSetup)
        let allInfo = cards.allSatisfy { $0.severity == .info }
        #expect(allSetup)
        #expect(allInfo)
        #expect(!status.needsAttention)
    }

    @Test func eachSetupCardRequestsOnlyItsOwnPermission() {
        let status = TrackingStatus(locationAuthorization: .notDetermined,
                                    motionAuthorization: .notDetermined)
        let actions = Dictionary(uniqueKeysWithValues: status.warnings.map { ($0.id, $0.action) })
        #expect(actions["loc-none"] == .requestLocationPermission)
        #expect(actions["motion-none"] == .requestMotionPermission)
    }

    @Test func deniedLocationStillNeedsAttention() {
        let status = TrackingStatus(locationAuthorization: .denied,
                                    motionAuthorization: .authorized)
        #expect(status.needsAttention)
        let card = status.warnings.first { $0.id == "loc-denied" }
        #expect(card?.isSetup == false)
        #expect(card?.action == .openSettings)
    }

    @Test func allGrantedShowsNothing() {
        let status = TrackingStatus(locationAuthorization: .always,
                                    hasFullAccuracy: true,
                                    motionAuthorization: .authorized)
        #expect(status.warnings.isEmpty)
        #expect(!status.needsAttention)
    }
}
