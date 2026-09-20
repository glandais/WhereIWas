import SwiftUI

/// Design tokens of the "field notebook" direction: a warm ivory ground, ink
/// text, and a single clay accent kept for the live trace and the recording
/// state. Green, amber and red are reserved for severity and never used for
/// decoration, so a coloured row always means something.
///
/// Every colour is a two-appearance color set in `Assets.xcassets`, so dark
/// mode is a lookup rather than a branch in the views. Tinted backgrounds are
/// derived with `opacity` from the tone itself instead of being their own
/// assets: one source of truth per tone, and the tint follows the appearance.
enum Theme {

    // MARK: Colours

    enum Palette {
        /// Page background.
        static let ground = Color("Ground")
        /// Card background sitting on `ground`.
        static let surface = Color("Surface")
        /// Inset background inside a card (segmented tracks, stat tiles).
        static let sunken = Color("SurfaceSunken")
        /// The inverted card of the Status screen.
        static let hero = Color("HeroSurface")
        /// Text on `hero`.
        static let heroInk = Color("HeroInk")
        /// Secondary text on `hero`.
        static let heroInkMuted = Color("HeroInkMuted")
        /// Primary text.
        static let ink = Color("Ink")
        /// Secondary text. Contrast-checked against `ground` and `surface`.
        static let inkMuted = Color("InkMuted")
        /// Hairline separators and card borders.
        static let hairline = Color("Hairline")
        /// The one accent: the trace, the recording state, selected controls.
        static let accent = Color("AccentColor")
    }

    /// Severity, never decoration.
    enum Tone: Hashable {
        case neutral, positive, caution, critical

        var color: Color {
            switch self {
            case .neutral: return Theme.Palette.inkMuted
            case .positive: return Color("Positive")
            case .caution: return Color("Caution")
            case .critical: return Color("Critical")
            }
        }

        /// Fill behind the tone's own text. Kept light: the text is the tone
        /// colour at full strength, which needs a pale ground to stay legible.
        var fill: Color { color.opacity(0.12) }

        /// Border of a card carrying this tone.
        var border: Color { color.opacity(0.35) }
    }

    /// Colours encoding an activity on the map's track and its breakdown.
    ///
    /// The single-accent rule gives way here and only here: a breakdown needs
    /// as many distinguishable hues as it has categories, and painting them
    /// all clay would say nothing. Cycling keeps the accent, so the trace of a
    /// ride still reads as *the* trace.
    enum Track {
        static let onFoot = Color("TrackFoot")
        static let cycling = Theme.Palette.accent
        static let vehicle = Color("TrackVehicle")
        static let idle = Theme.Palette.inkMuted.opacity(0.45)
    }

    // MARK: Typography
    //
    // Every style starts from a system text style so Dynamic Type scales it.
    // The sizes quoted in the mockups are the reference at the default text
    // size on a 390 pt wide screen, not fixed values.

    enum Typography {
        /// Screen title. Serif on purpose: it is the one editorial note in an
        /// otherwise utilitarian interface.
        static let screenTitle = Font.system(.largeTitle, design: .serif)
        /// The tracking phase on the Status hero card.
        static let heroState = Font.system(.title, design: .serif).weight(.medium)
        /// Uppercase label above a group of cards.
        static let sectionLabel = Font.caption2.weight(.bold)
        /// Title of a row inside a card.
        static let rowTitle = Font.subheadline.weight(.semibold)
        /// Explanatory line under a row title.
        static let rowSubtitle = Font.caption
        /// A measured value shown next to its label.
        static let rowValue = Font.system(.callout, design: .monospaced)
        /// The headline number of a stat tile.
        static let metric = Font.system(.title3, design: .monospaced)
        /// Caption under a stat tile's number.
        static let metricLabel = Font.caption2
        /// Coordinates, audit codes: anything meant to be read character by
        /// character.
        static let code = Font.system(.caption, design: .monospaced)
    }

    // MARK: Metrics

    enum Spacing {
        /// Gap between rows inside a card.
        static let tight: CGFloat = 6
        /// Gap between elements of a row.
        static let row: CGFloat = 10
        /// Padding inside a card.
        static let card: CGFloat = 16
        /// Gap between cards.
        static let section: CGFloat = 16
        /// Horizontal page margin.
        static let page: CGFloat = 20
    }

    enum Radius {
        static let card: CGFloat = 18
        static let hero: CGFloat = 20
        static let control: CGFloat = 12
        static let tile: CGFloat = 12
    }

    /// Minimum hit target, as the HIG asks.
    static let minimumTapTarget: CGFloat = 44
}

extension View {
    /// Paints the screen's ground and hides the system list background under
    /// it. Applied once per screen, at the top of the hierarchy.
    func themedBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.ground)
    }

    /// A section label: uppercase, tracked, muted.
    func sectionLabelStyle() -> some View {
        self
            .font(Theme.Typography.sectionLabel)
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Theme.Palette.inkMuted)
    }
}
