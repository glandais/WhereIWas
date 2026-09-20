import Combine
import SwiftUI
import UIKit

/// Home screen: the recording switch and the tracking state on one inverted
/// hero card, whatever needs the user's hand next, the last fix, and the
/// recent state changes.
///
/// The counters the old screen carried (total stored, accepted/rejected,
/// session count, oldest sample, fix source) are gone on purpose: they answered
/// questions a daily reader never asks, and the ones that matter after an
/// incident are in the export and the technical log.
struct StatusView: View {
    @Environment(\.trackingController) private var controller
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var samplesToday: Int?
    @State private var transitions: [StateTransitionRecord] = []
    @State private var now = Date.now

    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var status: TrackingStatus { controller.status }
    private var warnings: [StatusWarning] { status.warnings(now: now) }

    var body: some View {
        NavigationStack {
            CardScreen(title: "status.title", trailing: Formatting.day(now)) {
                heroCard
                if !warnings.isEmpty { warningsSection }
                lastFixSection
                transitionsSection
            }
            .navigationBarHidden(true)
            .refreshable { await reload() }
            .task(id: status.lastTransition) { await reload() }
            .task(id: status.acceptedCount) { await reloadTodayCount() }
            .onReceive(clock) { now = $0 }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await reload() } }
            }
        }
    }

    // MARK: Hero

    /// The one card that answers "is it recording, and what is it doing?".
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("status.tracking.toggle")
                    .sectionLabelStyle()
                    .foregroundStyle(Theme.Palette.heroInkMuted)
                Spacer(minLength: Theme.Spacing.row)
                Toggle(isOn: Binding(get: { status.isEnabled },
                                     set: { controller.setTrackingEnabled($0) })) {
                    Text("status.tracking.toggle")
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.Tone.positive.color)
                .accessibilityHint("status.tracking.hint")
            }

            HStack(spacing: 14) {
                Image(systemName: status.phase.systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(status.isEnabled ? Theme.Palette.accent : Theme.Palette.heroInkMuted)
                    .frame(width: 46, height: 46)
                    .background((status.isEnabled ? Theme.Palette.accent : Theme.Palette.heroInkMuted)
                                    .opacity(0.16), in: .circle)
                    .symbolEffect(.pulse, isActive: status.phase == .probing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.phase.title)
                        .font(Theme.Typography.heroState)
                        .foregroundStyle(Theme.Palette.heroInk)
                    Text(status.phase.explanation)
                        .font(.footnote)
                        .foregroundStyle(Theme.Palette.heroInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            Rectangle()
                .fill(Theme.Palette.heroInk.opacity(0.14))
                .frame(height: 1)

            HStack(alignment: .top, spacing: Theme.Spacing.row) {
                StatTile(value: status.lastFix.map { Formatting.relative($0.timestamp, to: now) } ?? "—",
                         label: "status.lastFix.title", onHero: true, monospaced: false)
                StatTile(value: samplesToday.map(Formatting.count) ?? "—",
                         label: "status.hero.todayPoints", onHero: true)
                StatTile(value: Formatting.battery(status.batteryLevel),
                         label: "common.battery", onHero: true)
            }

            profileLine
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.hero, in: .rect(cornerRadius: Theme.Radius.hero))
    }

    /// What CoreLocation is actually running, in one sentence. The activity
    /// that picked it rides along: on its own row it read like a second state.
    private var profileLine: some View {
        HStack(spacing: 8) {
            Image(systemName: status.appliedProfile == nil ? "location.slash" : status.lastActivity.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.heroInkMuted)
            Text(verbatim: profileSummary)
                .font(.caption)
                .foregroundStyle(Theme.Palette.heroInkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.heroInk.opacity(0.07), in: .rect(cornerRadius: Theme.Radius.tile))
        .accessibilityElement(children: .combine)
    }

    private var profileSummary: String {
        guard let profile = status.appliedProfile else {
            return String(localized: "status.state.gpsOff", defaultValue: "GPS off")
        }
        return String(localized: "status.hero.profile",
                      defaultValue: "\(profile.displayName) · \(profile.desiredAccuracy.title) · every \(Formatting.distance(profile.distanceFilter))",
                      comment: "Profile summary on the Status hero card: profile name, accuracy level, distance filter")
    }

    // MARK: Sections

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            SectionHeader("status.warnings.title")
            ForEach(warnings) { warning in
                AlertCard(title: warning.title,
                          message: warning.message,
                          tone: warning.tone,
                          systemImage: warning.systemImage,
                          actionTitle: actionTitle(for: warning),
                          action: warning.action.map { action in { perform(action) } })
            }
        }
    }

    private func actionTitle(for warning: StatusWarning) -> LocalizedStringKey? {
        switch warning.action {
        case .openSettings: return "common.openSettings"
        case .requestPermissions: return "status.warning.grantPermissions"
        case nil: return nil
        }
    }

    private var lastFixSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            SectionHeader(title: "status.lastFix.title") {
                if let fix = status.lastFix {
                    Text(verbatim: Formatting.time(fix.timestamp))
                        .font(Theme.Typography.code)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
            if let fix = status.lastFix {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: Formatting.coordinate(fix.latitude, fix.longitude))
                            .font(Theme.Typography.rowValue)
                            .foregroundStyle(Theme.Palette.ink)
                            .textSelection(.enabled)
                        // A two-column grid rather than four rows: these are
                        // four short measurements, and stacked they pushed the
                        // state changes off the first screen entirely.
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                            GridRow {
                                fixCell("status.lastFix.accuracy", Formatting.accuracy(fix.horizontalAccuracy))
                                fixCell("status.lastFix.speed", Formatting.speed(fix.validSpeed))
                            }
                            GridRow {
                                fixCell("status.lastFix.altitude", Formatting.altitude(fix.altitude))
                                fixCell("status.lastFix.course", Formatting.course(fix.course))
                            }
                        }
                    }
                }
            } else {
                Card {
                    Text("status.lastFix.none")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
        }
    }

    private func fixCell(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.Palette.ink)
        }
        .gridCellColumns(1)
        .accessibilityElement(children: .combine)
    }

    private var transitionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            SectionHeader("status.transitions.title")
            RowCard {
                if transitions.isEmpty {
                    Text("status.transitions.empty")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .padding(Theme.Spacing.card)
                } else {
                    ForEach(Array(transitions.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { RowSeparator() }
                        TransitionRow(record: record, now: now, isLatest: index == 0)
                    }
                }
            }
            Text(verbatim: String(localized: "status.transitions.footer",
                                  defaultValue: "Moving → stationary requires \(Formatting.duration(controller.settings.stillnessTimeout)) of stillness; any motion switches GPS back on immediately."))
                .font(.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
                .padding(.horizontal, 2)
        }
    }

    // MARK: Actions

    private func perform(_ action: StatusWarning.Action) {
        switch action {
        case .requestPermissions:
            controller.requestPermissions()
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
    }

    private func reload() async {
        now = .now
        transitions = (try? await controller.recentTransitions(limit: 20)) ?? []
        await reloadTodayCount()
    }

    private func reloadTodayCount() async {
        let start = Calendar.current.startOfDay(for: .now)
        let interval = DateInterval(start: start, end: start.addingTimeInterval(86_400))
        samplesToday = (try? await controller.samples(in: interval))?.count
    }
}

private struct TransitionRow: View {
    let record: StateTransitionRecord
    let now: Date
    let isLatest: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.row) {
            Circle()
                .fill(isLatest ? Theme.Palette.accent : Theme.Palette.inkMuted.opacity(0.5))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(record.from.title) → \(record.to.title)")
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Palette.ink)
                Text(verbatim: Formatting.transitionReason(record.reason))
                    .font(Theme.Typography.rowSubtitle)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.row)
            Text(verbatim: Formatting.time(record.timestamp))
                .font(Theme.Typography.code)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Moving") {
    StatusView()
        .environment(\.trackingController, PreviewTrackingController())
}

#Preview("Warnings") {
    StatusView()
        .environment(\.trackingController, PreviewTrackingController(phase: .stationary, warnings: true))
}

#Preview("Disabled") {
    StatusView()
        .environment(\.trackingController, PreviewTrackingController(phase: .disabled))
}
