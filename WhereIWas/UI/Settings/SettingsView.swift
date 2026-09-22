import SwiftUI
import UIKit

/// Where the settings stack can go. Declared once, at the root, so any screen
/// inside it can push any other — and so screenshot mode can open the
/// technical log by seeding the path.
enum SettingsRoute: Hashable {
    case motion, quality, data, audit
}

/// The settings hub: permissions, then one row per group with the current
/// value spelled out under its title.
///
/// The old screen was a single `Form` of eight sections — every tunable the
/// app has, in one scroll. Splitting it costs one tap and buys a screen a
/// reader can take in at a glance; the summaries keep the state visible.
struct SettingsView: View {
    @Environment(\.trackingController) private var controller
    @Environment(\.openURL) private var openURL

    @State private var path: [SettingsRoute] = {
        #if SCREENSHOTS
        return ScreenshotMode.isActive && ScreenshotMode.screen == .audit ? [.audit] : []
        #else
        return []
        #endif
    }()

    private var settings: TrackingSettings { controller.settings }

    /// The unit system needs one extra step over `settings.unitSystem`:
    /// `Formatting` reads a static, so it is updated *before* the store write
    /// that triggers the redraw. Every measurement on screen is then formatted
    /// with the new system in the same pass, without waiting for `RootView`'s
    /// `onChange`.
    private var unitSystem: Binding<UnitSystem> {
        Binding(get: { controller.settings.unitSystem },
                set: { newValue in
                    Formatting.unitSystem = newValue
                    var updated = controller.settings
                    updated.unitSystem = newValue
                    controller.settings = updated
                })
    }

    var body: some View {
        NavigationStack(path: $path) {
            CardScreen(title: "settings.title") {
                permissionsSection
                recordingSection
                dataSection
                aboutSection
            }
            .navigationBarHidden(true)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .motion: MotionSettingsView()
                case .quality: QualitySettingsView()
                case .data: DataSettingsView()
                case .audit: AuditLogView()
                }
            }
        }
    }

    // MARK: Sections

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            SectionHeader("settings.permissions.title")
            RowCard {
                permissionRow(String(localized: "settings.permission.location", defaultValue: "Location",
                                     comment: "Title of the location permission row; the iOS system permission, not the audit category"),
                              value: controller.status.locationAuthorization.title,
                              ok: controller.status.locationAuthorization == .always)
                RowSeparator()
                permissionRow(String(localized: "settings.permission.precise", defaultValue: "Precise Location"),
                              value: controller.status.hasFullAccuracy
                                  ? String(localized: "precise.on", defaultValue: "On",
                                           comment: "Value of the “Precise location” row")
                                  : String(localized: "precise.off", defaultValue: "Off",
                                           comment: "Value of the “Precise location” row"),
                              ok: controller.status.hasFullAccuracy)
                RowSeparator()
                permissionRow(String(localized: "settings.permission.motion", defaultValue: "Motion & Fitness"),
                              value: controller.status.motionAuthorization.title,
                              ok: controller.status.motionAuthorization == .authorized)
                if controller.status.locationAuthorization == .notDetermined
                    || controller.status.motionAuthorization == .notDetermined {
                    RowSeparator()
                    // One prompt per tap: location first, then motion on
                    // the next tap, each named by the row above it.
                    actionRow("settings.permissions.continue", systemImage: "hand.raised") {
                        if controller.status.locationAuthorization == .notDetermined {
                            controller.requestLocationPermission()
                        } else {
                            controller.requestMotionPermission()
                        }
                    }
                }
                RowSeparator()
                actionRow("common.openSettings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            Text("settings.permissions.footer")
                .font(.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
                .padding(.horizontal, 2)
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            SectionHeader("settings.recording.title")
            RowCard {
                NavRow(title: "settings.motion.title",
                       systemImage: "figure.walk.motion",
                       summary: motionSummary,
                       value: SettingsRoute.motion)
                RowSeparator()
                NavRow(title: "settings.filter.title",
                       systemImage: "scope",
                       summary: qualitySummary,
                       value: SettingsRoute.quality)
                RowSeparator()
                HStack(spacing: Theme.Spacing.row) {
                    Text("settings.units.title")
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.Palette.ink)
                    Spacer(minLength: Theme.Spacing.row)
                    Picker("settings.units.title", selection: unitSystem) {
                        Text(String(localized: "units.metric", defaultValue: "Metric",
                                    comment: "Unit system choice: meters, kilometers, km/h"))
                            .tag(UnitSystem.metric)
                        Text(String(localized: "units.imperial", defaultValue: "Imperial",
                                    comment: "Unit system choice: feet, miles, mph"))
                            .tag(UnitSystem.imperial)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, Theme.Spacing.card)
                .padding(.vertical, 10)
            }
            // The unit picker sits inline here rather than behind one of the
            // rows above, so this footer is the only place left to say that
            // switching it changes the display and nothing that was recorded.
            Text("settings.units.footer")
                .font(.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
                .padding(.horizontal, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            SectionHeader("settings.data.title")
            RowCard {
                NavRow(title: "settings.retention.title",
                       systemImage: "externaldrive",
                       summary: retentionSummary,
                       value: SettingsRoute.data)
                RowSeparator()
                NavRow(title: "audit.title",
                       systemImage: "doc.text.magnifyingglass",
                       summary: auditSummary,
                       value: SettingsRoute.audit)
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            SectionHeader("settings.about.title")
            RowCard {
                ValueRow("settings.about.version", value: appVersion)
                RowSeparator()
                // Guideline 5.1.1(i): the policy must be reachable from inside
                // the app, not only from the store listing.
                actionRow("settings.about.privacy", systemImage: "lock.shield") {
                    if let url = URL(string: "https://glandais.github.io/WhereIWas/privacy/") { openURL(url) }
                }
                RowSeparator()
                Button {
                    controller.settings = TrackingSettings()
                } label: {
                    HStack {
                        Text("settings.about.reset")
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(Theme.Tone.critical.color)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.card)
                    .padding(.vertical, 12)
                    .frame(minHeight: Theme.minimumTapTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Summaries
    //
    // One line per group, so the hub hides a screen of controls without
    // hiding what they are set to.

    private var motionSummary: String {
        String(localized: "settings.motion.summary",
               defaultValue: "Stillness \(Formatting.duration(settings.stillnessTimeout)) · probe \(Formatting.duration(settings.probeTimeout))",
               comment: "Summary line of the motion detection row in the settings hub")
    }

    private var qualitySummary: String {
        String(localized: "settings.filter.summary",
               defaultValue: "Within \(Formatting.accuracy(settings.maxHorizontalAccuracy)) · duplicates \(Formatting.distance(settings.duplicateDistance))",
               comment: "Summary line of the sample quality row in the settings hub")
    }

    private var retentionSummary: String {
        let kept = settings.retentionDays == 0
            ? String(localized: "settings.retention.forever", defaultValue: "Forever")
            : String(localized: "settings.retention.days", defaultValue: "\(settings.retentionDays) days")
        return String(localized: "settings.retention.summary",
                      defaultValue: "\(kept) · \(Formatting.count(controller.status.stats.totalSamples)) points",
                      comment: "Summary line of the retention row in the settings hub")
    }

    private var auditSummary: String {
        settings.auditEnabled
            ? String(localized: "settings.audit.summary.on", defaultValue: "Recording",
                     comment: "Summary of the technical log row when the trail is being written")
            : String(localized: "settings.audit.summary.off", defaultValue: "Off",
                     comment: "Summary of the technical log row when the trail is not being written")
    }

    // MARK: Rows

    private func permissionRow(_ title: String, value: String, ok: Bool) -> some View {
        HStack(spacing: Theme.Spacing.row) {
            Text(verbatim: title)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: Theme.Spacing.row)
            StatusPill(text: value,
                       tone: ok ? .positive : .caution,
                       systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func actionRow(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.row) {
                Label(title, systemImage: systemImage)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Palette.accent)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.card)
            .padding(.vertical, 12)
            .frame(minHeight: Theme.minimumTapTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(\.trackingController, PreviewTrackingController())
}
