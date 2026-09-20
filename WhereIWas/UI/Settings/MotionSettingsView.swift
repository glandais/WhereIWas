import SwiftUI

/// The three durations that decide when GPS goes off and comes back, the
/// confidence threshold under them, and a live preview of the profile table
/// they feed.
struct MotionSettingsView: View {
    @Environment(\.trackingController) private var controller

    private var settings: Binding<TrackingSettings> {
        Binding(get: { controller.settings }, set: { controller.settings = $0 })
    }

    private var current: TrackingSettings { controller.settings }

    var body: some View {
        DetailScreen(title: "settings.motion.title") {
            VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                Text("settings.motion.intro")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)

                RowCard {
                    StepperRow(title: "settings.motion.stillness",
                               subtitle: "settings.motion.stillness.hint",
                               value: Formatting.duration(current.stillnessTimeout),
                               binding: settings.stillnessTimeout,
                               range: 30...900,
                               step: 30)
                    RowSeparator()
                    StepperRow(title: "settings.motion.probeDuration",
                               subtitle: "settings.motion.probeDuration.hint",
                               value: Formatting.duration(current.probeTimeout),
                               binding: settings.probeTimeout,
                               range: 15...180,
                               step: 15)
                    RowSeparator()
                    StepperRow(title: "settings.motion.settling",
                               subtitle: "settings.motion.settling.hint",
                               value: current.settlingTimeout == 0
                                   ? String(localized: "settings.motion.settling.off", defaultValue: "Off")
                                   : Formatting.duration(current.settlingTimeout),
                               binding: settings.settlingTimeout,
                               range: 0...1800,
                               step: 60)
                    RowSeparator()
                    HStack(spacing: Theme.Spacing.row) {
                        Text("settings.motion.minimumConfidence")
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(Theme.Palette.ink)
                        Spacer(minLength: Theme.Spacing.tight)
                        Picker("settings.motion.minimumConfidence", selection: settings.minimumActivityConfidence) {
                            Text("settings.confidence.low").tag(ActivityConfidence.low)
                            Text("settings.confidence.medium").tag(ActivityConfidence.medium)
                            Text("settings.confidence.high").tag(ActivityConfidence.high)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(.horizontal, Theme.Spacing.card)
                    .padding(.vertical, 10)
                }

                Text("settings.motion.footer")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                SectionHeader(title: "settings.profiles.title") {
                    Text("settings.profiles.columnHint")
                        .font(.caption2)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                RowCard {
                    ProfileTable(settings: current)
                }
                Text(verbatim: String(localized: "settings.profiles.footer",
                                      defaultValue: "Distance filter per activity. With an unknown activity, speed decides: the running filter above \(Formatting.speed(GPSProfile.runningSpeedThreshold)), the driving one above \(Formatting.speed(GPSProfile.vehicleSpeedThreshold)). Cycling and running keep their own filter up to \(Formatting.speed(GPSProfile.cyclingVehicleSpeedThreshold))."))
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Pure preview of `GPSProfile.profile(for:speed:settings:)`, one row per
/// case: activity on the left, the distance filter it produces on the right
/// with its accuracy level under it.
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
            // 15 m/s clears the cycling override too, so the row is true of
            // every activity, as its title says.
            Row(id: "any-vehicle", activity: .walking, title: String(localized: "settings.profiles.anySpeed", defaultValue: "Any, \(Formatting.speed(15))"), speed: 15)
        ]
    }

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 { RowSeparator() }
            ProfileRow(title: row.title,
                       systemImage: row.activity.systemImage,
                       profile: GPSProfile.profile(for: row.activity, speed: row.speed, settings: settings))
        }
        RowSeparator()
        ProfileRow(title: String(localized: "common.probing", defaultValue: "Probing"),
                   systemImage: TrackingPhase.probing.systemImage,
                   profile: .probing)
        RowSeparator()
        ProfileRow(title: String(localized: "phase.settling", defaultValue: "Just stopped"),
                   systemImage: TrackingPhase.settling.systemImage,
                   profile: .settling(settings))
    }
}

private struct ProfileRow: View {
    let title: String
    let systemImage: String
    let profile: GPSProfile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: Theme.Spacing.tight)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: Formatting.distance(profile.distanceFilter))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.Palette.ink)
                Text(verbatim: profile.desiredAccuracy.title)
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        MotionSettingsView()
    }
    .environment(\.trackingController, PreviewTrackingController())
}
