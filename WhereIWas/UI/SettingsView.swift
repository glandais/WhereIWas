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

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                permissionsSection
                motionSection
                accuracySection
                profileSection
                retentionSection
                auditSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .audit: AuditLogView()
                }
            }
            .confirmationDialog("Delete samples older than \(controller.settings.retentionDays) days?",
                                isPresented: $showPurgeConfirmation, titleVisibility: .visible) {
                Button("Delete now", role: .destructive) { Task { await purge() } }
            } message: {
                Text("This cannot be undone. Export first if you need the data.")
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
            LabeledContent("Precise location") {
                permissionValue(controller.status.hasFullAccuracy
                                    ? String(localized: "precise.on", defaultValue: "On",
                                             comment: "Value of the “Precise location” row")
                                    : String(localized: "precise.off", defaultValue: "Off",
                                             comment: "Value of the “Precise location” row"),
                                ok: controller.status.hasFullAccuracy)
            }
            LabeledContent("Motion & Fitness") {
                permissionValue(controller.status.motionAuthorization.title,
                                ok: controller.status.motionAuthorization == .authorized)
            }
            if controller.status.locationAuthorization == .notDetermined
                || controller.status.motionAuthorization == .notDetermined {
                Button("Request permissions", systemImage: "hand.raised") {
                    controller.requestPermissions()
                }
            }
            Button("Open Settings", systemImage: "gear") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Background tracking requires location access set to “Always” with Precise Location on. Motion & Fitness lets the app switch GPS off while you are still.")
        }
    }

    private var motionSection: some View {
        Section {
            Stepper(value: settings.stillnessTimeout, in: 30...900, step: 30) {
                LabeledContent("Stillness before GPS off", value: Formatting.duration(controller.settings.stillnessTimeout))
            }
            Stepper(value: settings.probeTimeout, in: 15...180, step: 15) {
                LabeledContent("Probe duration", value: Formatting.duration(controller.settings.probeTimeout))
            }
            Picker("Minimum activity confidence", selection: settings.minimumActivityConfidence) {
                Text("Low").tag(ActivityConfidence.low)
                Text("Medium").tag(ActivityConfidence.medium)
                Text("High").tag(ActivityConfidence.high)
            }
            Toggle("Keep coarse updates while stationary", isOn: settings.keepCoarseUpdatesWhileStationary)
            Toggle("Show location indicator", isOn: settings.showsLocationIndicator)
        } header: {
            Text("Motion detection")
        } footer: {
            Text("Longer stillness avoids flapping at traffic lights but keeps GPS on longer after you stop. Coarse updates (3 km accuracy) cost almost nothing and keep the app alive in the background — which is why the system location indicator stays on while stationary. Turning it off hides it, but iOS still shows it whenever GPS is recording in the background.")
        }
    }

    private var accuracySection: some View {
        Section {
            VStack(alignment: .leading) {
                LabeledContent("Max horizontal accuracy", value: Formatting.accuracy(controller.settings.maxHorizontalAccuracy))
                Slider(value: settings.maxHorizontalAccuracy, in: 10...200, step: 5) {
                    Text("Max horizontal accuracy")
                } minimumValueLabel: {
                    Text("10 m").font(.caption2)
                } maximumValueLabel: {
                    Text("200 m").font(.caption2)
                }
            }
            Stepper(value: settings.maxSampleAge, in: 5...120, step: 5) {
                LabeledContent("Max sample age", value: Formatting.duration(controller.settings.maxSampleAge))
            }
            Stepper(value: settings.duplicateDistance, in: 0...20, step: 1) {
                LabeledContent("Duplicate distance", value: Formatting.distance(controller.settings.duplicateDistance))
            }
        } header: {
            Text("Sample filter")
        } footer: {
            Text("Fixes less accurate than the limit, older than the max age, or within the duplicate distance of the previous fix are discarded.")
        }
    }

    private var profileSection: some View {
        Section {
            ProfileTable(settings: controller.settings)
        } header: {
            Text("GPS profiles")
        } footer: {
            Text("Distance filter per activity. Speed above \(Formatting.speed(GPSProfile.vehicleSpeedThreshold)) always selects the driving profile; unknown activity above \(Formatting.speed(GPSProfile.runningSpeedThreshold)) uses the running filter.")
        }
    }

    /// Opt-in audit trail. Off by default: at debug verbosity it writes
    /// several rows per accepted fix.
    private var auditSection: some View {
        Section {
            Toggle("Record audit trail", isOn: settings.auditEnabled)

            if controller.settings.auditEnabled {
                Picker("Minimum severity", selection: settings.auditMinimumSeverity) {
                    ForEach(AuditSeverity.allCases, id: \.rawValue) { severity in
                        Text(verbatim: severity.displayName).tag(severity)
                    }
                }
                Toggle("Accepted fixes", isOn: settings.auditLogsAcceptedFixes)
                Toggle("Rejected fixes", isOn: settings.auditLogsRejectedFixes)
                Toggle("Validation tests", isOn: settings.auditLogsFilterChecks)
                Toggle("Motion reports", isOn: settings.auditLogsMotionEvents)
                Stepper(value: settings.auditRetentionDays, in: 0...90, step: 1) {
                    LabeledContent("Keep trail for",
                                   value: controller.settings.auditRetentionDays == 0
                                       ? String(localized: "Forever")
                                       : String(localized: "\(controller.settings.auditRetentionDays) days"))
                }
            }

            NavigationLink(value: Route.audit) {
                Label("Open audit trail", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Audit trail")
        } footer: {
            Text("Off by default. When on, the app records every location received, every validation test run on it, and every state change, in its own table with its own retention. Useful for after-action review; it costs storage and a little battery.")
        }
    }

    private var retentionSection: some View {
        Section {
            Stepper(value: settings.retentionDays, in: 0...365, step: 1) {
                LabeledContent("Keep samples for",
                               value: controller.settings.retentionDays == 0
                                   ? String(localized: "Forever")
                                   : String(localized: "\(controller.settings.retentionDays) days"))
            }
            Button(role: .destructive) {
                showPurgeConfirmation = true
            } label: {
                HStack {
                    Label("Delete old samples now", systemImage: "trash")
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
            Text("Retention")
        } footer: {
            Text("Old samples are deleted automatically by a background maintenance task, or here on demand. Sessions are kept.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersion)
            Button("Reset to defaults", role: .destructive) {
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
            purgeResult = String(localized: "Deleted \(Formatting.count(deleted)) samples.")
        } catch {
            purgeResult = String(localized: "Purge failed: \(error.localizedDescription)")
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
            Row(id: "walking", activity: .walking, title: String(localized: "Walking"), speed: nil),
            Row(id: "running", activity: .running, title: String(localized: "Running"), speed: nil),
            Row(id: "cycling", activity: .cycling, title: String(localized: "Cycling"), speed: nil),
            Row(id: "automotive", activity: .automotive, title: String(localized: "Driving"), speed: nil),
            Row(id: "unknown", activity: .unknown, title: String(localized: "Unknown, no speed"), speed: nil),
            Row(id: "unknown-fast", activity: .unknown, title: String(localized: "Unknown, \(Formatting.speed(4))"), speed: 4),
            Row(id: "any-vehicle", activity: .walking, title: String(localized: "Any, \(Formatting.speed(12))"), speed: 12)
        ]
    }

    var body: some View {
        Group {
            ForEach(rows) { row in
                ProfileRow(title: row.title,
                           systemImage: row.activity.systemImage,
                           profile: GPSProfile.profile(for: row.activity, speed: row.speed, settings: settings))
            }
            ProfileRow(title: String(localized: "Probing"),
                       systemImage: TrackingPhase.probing.systemImage,
                       profile: .probing)
            ProfileRow(title: String(localized: "Stationary (coarse)"),
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
