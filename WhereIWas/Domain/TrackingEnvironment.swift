import SwiftUI

/// SwiftUI environment key carrying the ``TrackingControlling`` instance.
///
/// The app root injects the real `TrackingCoordinator`; previews get
/// ``NoopTrackingController`` by default. Views read it with
/// `@Environment(\.trackingController) private var controller`.
private struct TrackingControllerKey: EnvironmentKey {
    static let defaultValue: any TrackingControlling = MainActor.assumeIsolated { NoopTrackingController() }
}

extension EnvironmentValues {
    public var trackingController: any TrackingControlling {
        get { self[TrackingControllerKey.self] }
        set { self[TrackingControllerKey.self] = newValue }
    }
}
