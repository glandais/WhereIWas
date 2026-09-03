import SwiftUI

/// Root of the UI: a `TabView` hosting the four screens.
struct RootView: View {
    enum Tab: Hashable { case status, map, export, settings }

    @Environment(\.trackingController) private var controller
    @State private var selection: Tab

    init(initialTab: Tab = .status) {
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            StatusView()
                .tabItem { Label("Status", systemImage: "location.circle") }
                .tag(Tab.status)
                .badge(controller.status.needsAttention ? "!" : nil)

            MapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Tab.map)

            ExportView()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
                .tag(Tab.export)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }
}

#Preview("Moving") {
    RootView()
        .environment(\.trackingController, PreviewTrackingController())
}

#Preview("Needs attention") {
    RootView()
        .environment(\.trackingController, PreviewTrackingController(phase: .stationary, warnings: true))
}

#if SCREENSHOTS
extension RootView.Tab {
    /// The audit trail lives inside Settings, so it opens that tab and lets
    /// `SettingsView` push the detail itself.
    init(_ screen: ScreenshotScreen) {
        switch screen {
        case .status: self = .status
        case .map: self = .map
        case .export: self = .export
        case .settings, .audit: self = .settings
        }
    }
}
#endif
