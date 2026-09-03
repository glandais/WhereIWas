import SwiftUI
import UIKit

/// Main screen: tracking toggle, state, last fix, counters, battery,
/// permission warnings and the recent transition log.
struct StatusView: View {
    @Environment(\.trackingController) private var controller
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var samplesToday: Int?
    @State private var transitions: [StateTransitionRecord] = []
    @State private var now = Date.now

    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var status: TrackingStatus { controller.status }

    var body: some View {
        NavigationStack {
            List {
                trackingSection
                if status.needsAttention { warningsSection }
                stateSection
                lastFixSection
                countersSection
                transitionsSection
            }
            .navigationTitle("WhereIWas")
            .refreshable { await reload() }
            .task(id: status.lastTransition) { await reload() }
            .task(id: status.acceptedCount) { await reloadTodayCount() }
            .onReceive(clock) { now = $0 }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await reload() } }
            }
        }
    }

    // MARK: Sections

    private var trackingSection: some View {
        Section {
            Toggle(isOn: Binding(get: { status.isEnabled },
                                 set: { controller.setTrackingEnabled($0) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Record my location")
                        .font(.title3.weight(.semibold))
                    Text(status.isEnabled ? "On — runs in the background and after restarts."
                                          : "Off — nothing is recorded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(.green)
            .accessibilityHint("Turns background location recording on or off")
        }
    }

    private var warningsSection: some View {
        Section("Needs attention") {
            ForEach(status.warnings) { warning in
                VStack(alignment: .leading, spacing: 6) {
                    Label(warning.title, systemImage: warning.systemImage)
                        .font(.headline)
                        .foregroundStyle(warning.color)
                    Text(warning.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let action = warning.action {
                        Button(action == .openSettings ? "Open Settings" : "Grant permissions") {
                            perform(action)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var stateSection: some View {
        Section("State") {
            HStack(spacing: 14) {
                Image(systemName: status.phase.systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(status.phase.color)
                    .frame(minWidth: 44)
                    .symbolEffect(.pulse, isActive: status.phase == .probing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.phase.title)
                        .font(.title2.weight(.bold))
                    Text(status.phase.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            if let profile = status.activeProfile {
                LabeledContent("GPS profile") {
                    Text(verbatim: "\(profile.displayName) · \(profile.desiredAccuracy.title) · \(Formatting.distance(profile.distanceFilter))")
                        .multilineTextAlignment(.trailing)
                }
            } else {
                LabeledContent("GPS profile") { Text("GPS off") }
            }

            LabeledContent("Activity") {
                // A `Label` here stretches the row to fill the rest of the
                // section (it loses its intrinsic height inside the value
                // slot), which is what left half the Status screen blank.
                HStack(spacing: 6) {
                    Image(systemName: status.lastActivity.systemImage)
                    Text(verbatim: "\(status.lastActivity.title) (\(status.lastActivityConfidence.title))")
                }
            }

            if status.isStale(now: now) {
                Label("No new fix for a while. If the app was force-quit, reopen it to resume tracking.",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var lastFixSection: some View {
        Section("Last fix") {
            if let fix = status.lastFix {
                LabeledContent("When") {
                    VStack(alignment: .trailing) {
                        Text(Formatting.relative(fix.timestamp, to: now))
                        Text(Formatting.time(fix.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Position", value: Formatting.coordinate(fix.latitude, fix.longitude))
                LabeledContent("Accuracy", value: Formatting.accuracy(fix.horizontalAccuracy))
                LabeledContent("Speed", value: Formatting.speed(fix.validSpeed))
                LabeledContent("Course", value: Formatting.course(fix.course))
                LabeledContent("Altitude") {
                    Text(verbatim: "\(Formatting.altitude(fix.altitude)) \(Formatting.accuracy(fix.verticalAccuracy))")
                }
                if let source = status.lastFixSource {
                    LabeledContent("Source", value: source.title)
                }
            } else {
                Text("No fix yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var countersSection: some View {
        Section("Samples") {
            LabeledContent("Today", value: samplesToday.map(Formatting.count) ?? "—")
            LabeledContent("Total stored", value: Formatting.count(status.stats.totalSamples))
            LabeledContent("Pending upload", value: Formatting.count(status.stats.pendingUpload))
            LabeledContent("Accepted / rejected since launch",
                           value: "\(Formatting.count(status.acceptedCount)) / \(Formatting.count(status.rejectedCount))")
            LabeledContent("Sessions", value: Formatting.count(status.stats.sessionCount))
            if let oldest = status.stats.oldestSample {
                LabeledContent("Oldest sample", value: Formatting.dateTime(oldest))
            }
            LabeledContent("Battery") {
                Label(Formatting.battery(status.batteryLevel),
                      systemImage: batterySymbol(level: status.batteryLevel, state: status.batteryState))
                    .foregroundStyle((status.batteryLevel ?? 1) < 0.2 ? .red : .primary)
            }
        }
    }

    private var transitionsSection: some View {
        Section {
            if transitions.isEmpty {
                Text("No transitions recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(transitions) { record in
                    TransitionRow(record: record, now: now)
                }
            }
        } header: {
            Text("Recent transitions")
        } footer: {
            Text("Moving → stationary requires \(Formatting.duration(controller.settings.stillnessTimeout)) of stillness; any motion switches GPS back on immediately.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.from.title)
                    .foregroundStyle(record.from.color)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.to.title)
                    .foregroundStyle(record.to.color)
                    .fontWeight(.semibold)
                Spacer()
                Text(Formatting.relative(record.timestamp, to: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(Formatting.transitionReason(record.reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if let battery = record.batteryLevel {
                    Text(Formatting.battery(battery))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
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
