import SwiftUI

// The building blocks every screen is assembled from. They carry the theme so
// no view repeats a radius, a border or a padding; anything a screen needs
// only once stays in that screen.

// MARK: - Screen scaffolding

/// A card-based screen: a serif title, an optional trailing note, then the
/// content, over the themed ground.
///
/// `ScrollView` rather than `List`: the cards overlap the list's own
/// insets, backgrounds and separators, and fighting those costs more than
/// laying the stack out directly.
struct CardScreen<Content: View>: View {
    let title: LocalizedStringKey
    var trailing: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Palette.ink)
                    if let trailing {
                        Spacer()
                        Text(verbatim: trailing)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                content()
            }
            .padding(.horizontal, Theme.Spacing.page)
            // The floating tab bar overlaps the last card; this is what lets
            // the end of the content clear it once scrolled.
            .padding(.bottom, Theme.Spacing.section + 24)
        }
        .themedBackground()
    }
}

/// A pushed screen: the same ground and card rhythm as `CardScreen`, but the
/// title belongs to the navigation bar because there is a back button next to
/// it.
struct DetailScreen<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                content()
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.section)
        }
        .themedBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// An uppercase label above a card, optionally with an action on the right.
struct SectionHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).sectionLabelStyle()
            Spacer(minLength: Theme.Spacing.row)
            accessory()
        }
        .padding(.horizontal, 2)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.init(title: title) { EmptyView() }
    }
}

// MARK: - Cards

/// The default container: a surface with a hairline border and a soft radius.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.card
    var tone: Theme.Tone?
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.map { $0.fill } ?? Theme.Palette.surface,
                        in: .rect(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(tone.map { $0.border } ?? Theme.Palette.hairline, lineWidth: 1)
            }
    }
}

/// A card whose content is a stack of rows separated by hairlines, each row
/// carrying its own padding. Used wherever the old code had a `Section` of a
/// `List`.
struct RowCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
        }
    }
}

/// The separator between two `RowCard` rows. A `Divider` inside a plain
/// `VStack` inherits the system separator colour, which reads blue-grey next
/// to the ivory ground.
struct RowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 1)
    }
}

// MARK: - Rows

/// A label on the left, a measured value on the right.
struct ValueRow<Value: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.row) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: Theme.Spacing.row)
            value()
                .font(Theme.Typography.rowValue)
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

extension ValueRow where Value == Text {
    init(_ title: LocalizedStringKey, value: String) {
        self.init(title: title) { Text(verbatim: value) }
    }
}

/// A tunable with `-` / `+` buttons: title, an explanatory line, the current
/// value spelled out, then the stepper.
struct StepperRow<V: Strideable>: View where V.Stride: SignedNumeric {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    let value: String
    @Binding var binding: V
    let range: ClosedRange<V>
    let step: V.Stride

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.row) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Palette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.rowSubtitle)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.tight)
            Text(verbatim: value)
                .font(Theme.Typography.rowValue)
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
            Stepper(title, value: $binding, in: range, step: step)
                .labelsHidden()
        }
        .padding(.horizontal, Theme.Spacing.card)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: value))
    }
}

/// A navigation row: icon, title, a one-line summary of the current value,
/// chevron. The summary is what lets the settings hub replace a screen of
/// controls without hiding their state.
///
/// Value-based rather than view-based on purpose: screenshot mode opens the
/// technical log by seeding the stack's `path`, which only tracks values.
struct NavRow<Value: Hashable>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var summary: String?
    let value: Value

    var body: some View {
        NavigationLink(value: value) {
            HStack(spacing: 12) {
                IconBadge(systemImage: systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.Palette.ink)
                    if let summary {
                        Text(verbatim: summary)
                            .font(Theme.Typography.rowSubtitle)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                Spacer(minLength: Theme.Spacing.row)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            .padding(.horizontal, Theme.Spacing.card)
            .padding(.vertical, 12)
            .frame(minHeight: Theme.minimumTapTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The tinted square holding a row's icon.
struct IconBadge: View {
    let systemImage: String
    var tone: Theme.Tone?

    var body: some View {
        Image(systemName: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tone?.color ?? Theme.Palette.accent)
            .frame(width: 32, height: 32)
            .background(tone.map { $0.fill } ?? Theme.Palette.accent.opacity(0.12),
                        in: .rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

// MARK: - Indicators

/// A status word with its symbol, coloured by tone: the permission rows and
/// the session badges.
struct StatusPill: View {
    let text: String
    let tone: Theme.Tone
    var systemImage: String?
    /// `true` paints the tone behind the text; `false` colours the text alone.
    var filled = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
            }
            Text(verbatim: text)
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, filled ? 9 : 0)
        .padding(.vertical, filled ? 4 : 0)
        .background {
            if filled {
                Capsule().fill(tone.fill)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One headline number with its caption. Three of them sit side by side on the
/// Status hero and under the map.
struct StatTile: View {
    let value: String
    let label: LocalizedStringKey
    var onHero = false
    /// `false` for a value that is prose rather than a measurement ("12 s
    /// ago"): monospacing a sentence makes it both wider and harder to read,
    /// and it was what pushed the hero's three tiles out of balance.
    var monospaced = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(monospaced ? Theme.Typography.metric : .headline)
                .foregroundStyle(onHero ? Theme.Palette.heroInk : Theme.Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(Theme.Typography.metricLabel)
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(onHero ? Theme.Palette.heroInkMuted : Theme.Palette.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A card that needs the user to act, or tells them something is degraded.
struct AlertCard: View {
    let title: String
    let message: String
    let tone: Theme.Tone
    var systemImage: String
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        Card(tone: tone) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tone.color)
                    Text(verbatim: title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tone.color)
                }
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(ToneButtonStyle(tone: tone, prominent: tone == .critical))
                }
            }
        }
    }
}

// MARK: - Buttons

/// The filled action of the screen. Ink rather than accent: the accent is the
/// trace, and a page full of clay buttons would drown it.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.Palette.heroInk)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.Palette.hero, in: .rect(cornerRadius: Theme.Radius.control))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A button that belongs to an `AlertCard`, coloured by its tone.
struct ToneButtonStyle: ButtonStyle {
    let tone: Theme.Tone
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Theme.Palette.heroInk : tone.color)
            .padding(.horizontal, 18)
            .frame(minHeight: Theme.minimumTapTarget)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 11).fill(tone.color)
                } else {
                    RoundedRectangle(cornerRadius: 11).strokeBorder(tone.border, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

#Preview("Composants") {
    ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            SectionHeader("status.warnings.title")
            AlertCard(title: "Location access denied",
                      message: "WhereIWas cannot record anything.",
                      tone: .critical,
                      systemImage: "exclamationmark.octagon.fill",
                      actionTitle: "common.openSettings") {}
            RowCard {
                ValueRow("status.lastFix.accuracy", value: "6 m")
                RowSeparator()
                ValueRow("status.lastFix.speed", value: "21.4 km/h")
            }
            Card {
                HStack {
                    StatTile(value: "1 284", label: "status.hero.todayPoints")
                    StatTile(value: "68 %", label: "common.battery")
                }
            }
            Button("common.openSettings") {}
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(Theme.Spacing.page)
    }
    .themedBackground()
}
