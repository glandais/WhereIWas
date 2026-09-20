import SwiftUI

/// What is kept, for how long, and the opt-in technical log.
struct DataSettingsView: View {
    @Environment(\.trackingController) private var controller

    @State private var showPurgeConfirmation = false
    @State private var purgeResult: String?
    @State private var isPurging = false

    private var settings: Binding<TrackingSettings> {
        Binding(get: { controller.settings }, set: { controller.settings = $0 })
    }

    private var current: TrackingSettings { controller.settings }

    var body: some View {
        DetailScreen(title: "settings.retention.title") {
            retentionSection
            auditSection
        }
        .confirmationDialog(String(localized: "settings.purge.title",
                                   defaultValue: "Delete samples older than \(current.retentionDays) days?"),
                            isPresented: $showPurgeConfirmation, titleVisibility: .visible) {
            Button("settings.purge.confirm", role: .destructive) { Task { await purge() } }
        } message: {
            Text("settings.purge.message")
        }
    }

    // MARK: Sections

    private var retentionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            RowCard {
                StepperRow(title: "settings.retention.keepSamples",
                           subtitle: "settings.retention.keepSamples.hint",
                           value: current.retentionDays == 0
                               ? String(localized: "settings.retention.forever", defaultValue: "Forever")
                               : String(localized: "settings.retention.days",
                                        defaultValue: "\(current.retentionDays) days"),
                           binding: settings.retentionDays,
                           range: 0...365,
                           step: 1)
                RowSeparator()
                ValueRow("settings.retention.stored",
                         value: Formatting.count(controller.status.stats.totalSamples))
                RowSeparator()
                Button {
                    showPurgeConfirmation = true
                } label: {
                    HStack(spacing: Theme.Spacing.row) {
                        Label("settings.purge.action", systemImage: "trash")
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(current.retentionDays == 0 || isPurging
                                             ? Theme.Palette.inkMuted
                                             : Theme.Tone.critical.color)
                        Spacer()
                        if isPurging { ProgressView() }
                    }
                    .padding(.horizontal, Theme.Spacing.card)
                    .padding(.vertical, 12)
                    .frame(minHeight: Theme.minimumTapTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(current.retentionDays == 0 || isPurging)
            }

            if let purgeResult {
                Text(verbatim: purgeResult)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.horizontal, 2)
            }

            Text("settings.retention.footer")
                .font(.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
                .padding(.horizontal, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Opt-in technical log. Off by default: at debug verbosity it writes
    /// several rows per accepted fix.
    private var auditSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            SectionHeader("audit.title")
            RowCard {
                toggleRow("settings.audit.enable", isOn: settings.auditEnabled)

                if current.auditEnabled {
                    RowSeparator()
                    HStack(spacing: Theme.Spacing.row) {
                        Text("audit.minimumSeverity")
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(Theme.Palette.ink)
                        Spacer(minLength: Theme.Spacing.tight)
                        Picker("audit.minimumSeverity", selection: settings.auditMinimumSeverity) {
                            ForEach(AuditSeverity.allCases, id: \.rawValue) { severity in
                                Text(verbatim: severity.displayName).tag(severity)
                            }
                        }
                        .labelsHidden()
                    }
                    .padding(.horizontal, Theme.Spacing.card)
                    .padding(.vertical, 8)

                    RowSeparator()
                    toggleRow("settings.audit.acceptedFixes", isOn: settings.auditLogsAcceptedFixes)
                    RowSeparator()
                    toggleRow("settings.audit.rejectedFixes", isOn: settings.auditLogsRejectedFixes)
                    RowSeparator()
                    toggleRow("settings.audit.validationTests", isOn: settings.auditLogsFilterChecks)
                    RowSeparator()
                    toggleRow("settings.audit.motionReports", isOn: settings.auditLogsMotionEvents)
                    RowSeparator()
                    StepperRow(title: "settings.audit.keepTrail",
                               value: current.auditRetentionDays == 0
                                   ? String(localized: "settings.retention.forever", defaultValue: "Forever")
                                   : String(localized: "settings.retention.days",
                                            defaultValue: "\(current.auditRetentionDays) days"),
                               binding: settings.auditRetentionDays,
                               range: 0...90,
                               step: 1)
                }

                RowSeparator()
                NavRow(title: "settings.audit.open",
                       systemImage: "doc.text.magnifyingglass",
                       value: SettingsRoute.audit)
            }

            Text("settings.audit.footer")
                .font(.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
                .padding(.horizontal, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.Palette.ink)
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, 10)
        .frame(minHeight: Theme.minimumTapTarget)
    }

    // MARK: Actions

    private func purge() async {
        isPurging = true
        defer { isPurging = false }
        do {
            let deleted = try await controller.purgeNow()
            purgeResult = String(localized: "settings.purge.result",
                                 defaultValue: "Samples deleted: \(Formatting.count(deleted))")
        } catch {
            purgeResult = String(localized: "settings.purge.failed",
                                 defaultValue: "Deletion failed: \(error.localizedDescription)")
        }
    }
}

#Preview {
    NavigationStack {
        DataSettingsView()
    }
    .environment(\.trackingController, PreviewTrackingController())
}
