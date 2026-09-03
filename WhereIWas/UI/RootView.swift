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
                .tabItem { Label("status.tab", systemImage: "location.circle") }
                .tag(Tab.status)
                .badge(controller.status.needsAttention ? "common.attentionBadge" : nil)

            MapView()
                .tabItem { Label("map.title", systemImage: "map") }
                .tag(Tab.map)

            ExportView()
                .tabItem { Label("common.export", systemImage: "square.and.arrow.up") }
                .tag(Tab.export)

            SettingsView()
                .tabItem { Label("settings.title", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // The formatting helpers are static, so the unit setting has to be
        // pushed into `Formatting` rather than read from it. `initial: true`
        // makes this the launch application too; the Settings picker also
        // writes it synchronously in its setter so the row it is on redraws
        // in the very same pass.
        .onChange(of: controller.settings.unitSystem, initial: true) { _, newValue in
            Formatting.unitSystem = newValue
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
