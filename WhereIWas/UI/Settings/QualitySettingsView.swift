import SwiftUI

/// The three tests every fix has to pass before it is stored.
struct QualitySettingsView: View {
    @Environment(\.trackingController) private var controller

    private var settings: Binding<TrackingSettings> {
        Binding(get: { controller.settings }, set: { controller.settings = $0 })
    }

    private var current: TrackingSettings { controller.settings }

    var body: some View {
        DetailScreen(title: "settings.filter.title") {
            VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                RowCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.filter.maxAccuracy")
                                    .font(Theme.Typography.rowTitle)
                                    .foregroundStyle(Theme.Palette.ink)
                                Text("settings.filter.maxAccuracy.hint")
                                    .font(Theme.Typography.rowSubtitle)
                                    .foregroundStyle(Theme.Palette.inkMuted)
                            }
                            Spacer(minLength: Theme.Spacing.tight)
                            Text(verbatim: Formatting.accuracy(current.maxHorizontalAccuracy))
                                .font(Theme.Typography.rowValue)
                                .foregroundStyle(Theme.Palette.ink)
                        }
                        Slider(value: settings.maxHorizontalAccuracy, in: 10...200, step: 5) {
                            Text("settings.filter.maxAccuracy")
                        } minimumValueLabel: {
                            // Hardcoded "10 m" / "200 m" would ignore both the
                            // locale and the unit setting.
                            Text(verbatim: Formatting.distance(10))
                                .font(.caption2)
                                .foregroundStyle(Theme.Palette.inkMuted)
                        } maximumValueLabel: {
                            Text(verbatim: Formatting.distance(200))
                                .font(.caption2)
                                .foregroundStyle(Theme.Palette.inkMuted)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.card)
                    .padding(.vertical, 12)

                    RowSeparator()

                    StepperRow(title: "settings.filter.maxAge",
                               subtitle: "settings.filter.maxAge.hint",
                               value: Formatting.duration(current.maxSampleAge),
                               binding: settings.maxSampleAge,
                               range: 5...120,
                               step: 5)

                    RowSeparator()

                    StepperRow(title: "settings.filter.duplicateDistance",
                               subtitle: "settings.filter.duplicateDistance.hint",
                               value: Formatting.distance(current.duplicateDistance),
                               binding: settings.duplicateDistance,
                               range: 0...20,
                               step: 1)
                }

                Text("settings.filter.footer")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    NavigationStack {
        QualitySettingsView()
    }
    .environment(\.trackingController, PreviewTrackingController())
}
