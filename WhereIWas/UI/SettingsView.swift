import SwiftUI
import UIKit

/// Tunables of the state machine and the sample filter, permissions,
/// retention and a live preview of the GPS profile table.
struct SettingsView: View {
    @Environment(\.trackingController) private var controller
    @Environment(\.openURL) private var openURL

    /// Routes pushed on top of Settings. Only used to let screenshot mode
    /// open the audit trail without a tap; a plain `NavigationLink` would do
    /// otherwise.
    enum Route: Hashable { case audit }

    @State private var path: [Route] = {
        #if SCREENSHOTS
        return ScreenshotMode.isActive && ScreenshotMode.screen == .audit ? [.audit] : []
        #else
        return []
        #endif
    }()

    @State private var showPurgeConfirmation = false
    @State private var purgeResult: String?
    @State private var isPurging = false

    private var settings: Binding<TrackingSettings> {
        Binding(get: { controller.settings }, set: { controller.settings = $0 })
    }

    /// The unit system needs one extra step over `settings.unitSystem`:
    /// `Formatting` reads a static, so it is updated *before* the store write
    /// that triggers the redraw. Every measurement on screen — this Form
    /// included — is then formatted with the new system in the same pass,
    /// without waiting for `RootView`'s `onChange`.
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
            Form {
                permissionsSection
                motionSection
                unitsSection
                accuracySection
                profileSection
                retentionSection
                auditSection
                aboutSection
            }
            .navigationTitle("settings.title")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .audit: AuditLogView()
                }
            }
            .confirmationDialog(String(localized: "settings.purge.title",
                                       defaultValue: "Delete samples older than \(controller.settings.retentionDays) days?"),
                                isPresented: $showPurgeConfirmation, titleVisibility: .visible) {
                Button("settings.purge.confirm", role: .destructive) { Task { await purge() } }
            } message: {
                Text("settings.purge.message")
            }
        }
    }

    // MARK: Sections

    private var permissionsSection: some View {
        Section {
            LabeledContent(String(localized: "settings.permission.location", defaultValue: "Location",
                                  comment: "Title of the location permission row; the iOS system permission, not the audit category")) {
                permissionValue(controller.status.locationAuthorization.title,
                                ok: controller.status.locationAuthorization == .always)
            }
            LabeledContent("settings.permission.precise") {
                permissionValue(controller.status.hasFullAccuracy
                                    ? String(localized: "precise.on", defaultValue: "On",
                                             comment: "Value of the “Precise location” row")
                                    : String(localized: "precise.off", defaultValue: "Off",
                                             comment: "Value of the “Precise location” row"),
                                ok: controller.status.hasFullAccuracy)
            }
            LabeledContent("settings.permission.motion") {
                permissionValue(controller.status.motionAuthorization.title,
                                ok: controller.status.motionAuthorization == .authorized)
            }
            if controller.status.locationAuthorization == .notDetermined
                || controller.status.motionAuthorization == .notDetermined {
                Button("settings.permissions.request", systemImage: "hand.raised") {
                    controller.requestPermissions()
                }
            }
            Button("common.openSettings", systemImage: "gear") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } header: {
            Text("settings.permissions.title")
        } footer: {
            Text("settings.permissions.footer")
        }
    }

    private var motionSection: some View {
        Section {
            Stepper(value: settings.stillnessTimeout, in: 30...900, step: 30) {
                LabeledContent("settings.motion.stillness", value: Formatting.duration(controller.settings.stillnessTimeout))
            }
            Stepper(value: settings.probeTimeout, in: 15...180, step: 15) {
                LabeledContent("settings.motion.probeDuration", value: Formatting.duration(controller.settings.probeTimeout))
            }
            Picker("settings.motion.minimumConfidence", selection: settings.minimumActivityConfidence) {
                Text("settings.confidence.low").tag(ActivityConfidence.low)
                Text("settings.confidence.medium").tag(ActivityConfidence.medium)
                Text("settings.confidence.high").tag(ActivityConfidence.high)
            }
            Toggle("settings.motion.keepCoarse", isOn: settings.keepCoarseUpdatesWhileStationary)
            Toggle("settings.motion.showIndicator", isOn: settings.showsLocationIndicator)
        } header: {
            Text("settings.motion.title")
        } footer: {
            Text("settings.motion.footer")
        }
    }

    private var unitsSection: some View {
        Section {
            Picker(selection: unitSystem) {
                Text(String(localized: "units.metric", defaultValue: "Metric",
                            comment: "Unit system choice: meters, kilometers, km/h"))
                    .tag(UnitSystem.metric)
                Text(String(localized: "units.imperial", defaultValue: "Imperial",
                            comment: "Unit system choice: feet, miles, mph"))
                    .tag(UnitSystem.imperial)
            } label: {
                Text(String(localized: "settings.units.title", defaultValue: "Units",
                            comment: "Title of the unit system picker in Settings"))
            }
        } footer: {
            Text(String(localized: "settings.units.footer",
                        defaultValue: "Changes how distances, speeds, altitudes and accuracies are displayed. Recorded samples and exports are unaffected: they always store meters and meters per second.",
                        comment: "Footer under the unit system picker"))
        }
    }

    private var accuracySection: some View {
        Section {
            VStack(alignment: .leading) {
                LabeledContent("settings.filter.maxAccuracy", value: Formatting.accuracy(controller.settings.maxHorizontalAccuracy))
                Slider(value: settings.maxHorizontalAccuracy, in: 10...200, step: 5) {
                    Text("settings.filter.maxAccuracy")
                } minimumValueLabel: {
                    // Hardcoded "10 m" / "200 m" would ignore both the
                    // locale and the unit setting.
                    Text(Formatting.distance(10)).font(.caption2)
                } maximumValueLabel: {
                    Text(Formatting.distance(200)).font(.caption2)
                }
            }
            Stepper(value: settings.maxSampleAge, in: 5...120, step: 5) {
                LabeledContent("settings.filter.maxAge", value: Formatting.duration(controller.settings.maxSampleAge))
            }
            Stepper(value: settings.duplicateDistance, in: 0...20, step: 1) {
                LabeledContent("settings.filter.duplicateDistance", value: Formatting.distance(controller.settings.duplicateDistance))
            }
        } header: {
            Text("settings.filter.title")
        } footer: {
            Text("settings.filter.footer")
        }
    }

    private var profileSection: some View {
        Section {
            ProfileTable(settings: controller.settings)
        } header: {
            Text("settings.profiles.title")
        } footer: {
            Text(verbatim: String(localized: "settings.profiles.footer",
                                  defaultValue: "Distance filter per activity. Speed above \(Formatting.speed(GPSProfile.vehicleSpeedThreshold)) always selects the driving profile; unknown activity above \(Formatting.speed(GPSProfile.runningSpeedThreshold)) uses the running filter."))
        }
    }

    /// Opt-in audit trail. Off by default: at debug verbosity it writes
    /// several rows per accepted fix.
    private var auditSection: some View {
        Section {
            Toggle("settings.audit.enable", isOn: settings.auditEnabled)

            if controller.settings.auditEnabled {
                Picker("audit.minimumSeverity", selection: settings.auditMinimumSeverity) {
                    ForEach(AuditSeverity.allCases, id: \.rawValue) { severity in
                        Text(verbatim: severity.displayName).tag(severity)
                    }
                }
                Toggle("settings.audit.acceptedFixes", isOn: settings.auditLogsAcceptedFixes)
                Toggle("settings.audit.rejectedFixes", isOn: settings.auditLogsRejectedFixes)
                Toggle("settings.audit.validationTests", isOn: settings.auditLogsFilterChecks)
                Toggle("settings.audit.motionReports", isOn: settings.auditLogsMotionEvents)
                Stepper(value: settings.auditRetentionDays, in: 0...90, step: 1) {
                    LabeledContent("settings.audit.keepTrail",
                                   value: controller.settings.auditRetentionDays == 0
                                       ? String(localized: "settings.retention.forever", defaultValue: "Forever")
                                       : String(localized: "settings.retention.days",
                                                defaultValue: "\(controller.settings.auditRetentionDays) days"))
                }
            }

            NavigationLink(value: Route.audit) {
                Label("settings.audit.open", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("audit.title")
        } footer: {
            Text("settings.audit.footer")
        }
    }

    private var retentionSection: some View {
        Section {
            Stepper(value: settings.retentionDays, in: 0...365, step: 1) {
                LabeledContent("settings.retention.keepSamples",
                               value: controller.settings.retentionDays == 0
                                   ? String(localized: "settings.retention.forever", defaultValue: "Forever")
                                   : String(localized: "settings.retention.days",
                                            defaultValue: "\(controller.settings.retentionDays) days"))
            }
            Button(role: .destructive) {
                showPurgeConfirmation = true
            } label: {
                HStack {
                    Label("settings.purge.action", systemImage: "trash")
                    if isPurging { Spacer(); ProgressView() }
                }
            }
            .disabled(controller.settings.retentionDays == 0 || isPurging)
            if let purgeResult {
                Text(verbatim: purgeResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("settings.retention.title")
        } footer: {
            Text("settings.retention.footer")
        }
    }

    private var aboutSection: some View {
        Section("settings.about.title") {
            LabeledContent("settings.about.version", value: appVersion)
            Button("settings.about.reset", role: .destructive) {
                controller.settings = TrackingSettings()
            }
        }
    }

    // MARK: Helpers

    private func permissionValue(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? Color.green : Color.orange)
            .labelStyle(.titleAndIcon)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func purge() async {
        isPurging = true
        defer { isPurging = false }
        do {
            let deleted = try await controller.purgeNow()
            purgeResult = String(localized: "settings.purge.result",
                                 defaultValue: "Deleted \(Formatting.count(deleted)) samples.")
        } catch {
            purgeResult = String(localized: "settings.purge.failed",
                                 defaultValue: "Purge failed: \(error.localizedDescription)")
        }
    }
}

/// Pure preview of `GPSProfile.profile(for:speed:settings:)`, one list row
/// per case: activity on the left, distance filter and accuracy on the right.
/// A `Group` body so the rows land as real list cells instead of one cramped
/// three-column grid, which truncated both the titles and the accuracy names.
private struct ProfileTable: View {
    let settings: TrackingSettings

    private struct Row: Identifiable {
        let id: String
        let activity: ActivityKind
        let title: String
        let speed: Double?
    }

    private var rows: [Row] {
        [
            Row(id: "walking", activity: .walking, title: String(localized: "activity.walking", defaultValue: "Walking"), speed: nil),
            Row(id: "running", activity: .running, title: String(localized: "activity.running", defaultValue: "Running"), speed: nil),
            Row(id: "cycling", activity: .cycling, title: String(localized: "activity.cycling", defaultValue: "Cycling"), speed: nil),
            Row(id: "automotive", activity: .automotive, title: String(localized: "activity.driving", defaultValue: "Driving"), speed: nil),
            Row(id: "unknown", activity: .unknown, title: String(localized: "settings.profiles.unknownNoSpeed", defaultValue: "Unknown, no speed"), speed: nil),
            Row(id: "unknown-fast", activity: .unknown, title: String(localized: "settings.profiles.unknownSpeed", defaultValue: "Unknown, \(Formatting.speed(4))"), speed: 4),
            Row(id: "any-vehicle", activity: .walking, title: String(localized: "settings.profiles.anySpeed", defaultValue: "Any, \(Formatting.speed(12))"), speed: 12)
        ]
    }

    var body: some View {
        Group {
            ForEach(rows) { row in
                ProfileRow(title: row.title,
                           systemImage: row.activity.systemImage,
                           profile: GPSProfile.profile(for: row.activity, speed: row.speed, settings: settings))
            }
            ProfileRow(title: String(localized: "common.probing", defaultValue: "Probing"),
                       systemImage: TrackingPhase.probing.systemImage,
                       profile: .probing)
            ProfileRow(title: String(localized: "profile.stationaryCoarse", defaultValue: "Stationary (coarse)"),
                       systemImage: TrackingPhase.stationary.systemImage,
                       profile: .stationaryCoarse)
        }
    }
}

/// One profile line: title on the left, the distance filter on the right with
/// the accuracy level under it.
private struct ProfileRow: View {
    let title: String
    let systemImage: String
    let profile: GPSProfile

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Formatting.distance(profile.distanceFilter))
                    .monospacedDigit()
                Text(profile.desiredAccuracy.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    SettingsView()
        .environment(\.trackingController, PreviewTrackingController())
}
