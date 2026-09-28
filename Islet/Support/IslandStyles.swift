import AppKit
import SwiftUI

/// One of the island's colours, named by what it is for rather than by its value, so
/// it can be stored in a model (an indicator, an alert, a banner) and still follow the
/// island's colour when that changes. `color(in:)` gives the value for a theme; views
/// use the `.island…` shape styles below, which read the theme from the environment.
enum IslandInk: Hashable, Sendable {
    /// Words: ink at today's opacity, raised only as far as 4.5:1 needs.
    case text(Double, on: IslandBackdrop = .island)
    /// Symbols, rings, progress fills, meaningful strokes and disabled-but-visible
    /// controls: raised only as far as 3:1 needs.
    case graphic(Double, on: IslandBackdrop = .island)
    /// Tracks, dividers, placeholders and hover washes: ink at the opacity given.
    case decorative(Double)
    /// A card, chip or row fill, capped so full ink on it still reads.
    case surface(Double)
    /// The island's own colour.
    case background
    /// A feature's highlights: its own colour under Feature colours, otherwise the
    /// accent; fitted to 3:1, or to 4.5:1 for coloured words.
    case accent(FeatureTint, minimum: Double = Contrast.graphic, on: IslandBackdrop = .island)
    /// A colour that means something, fitted only for contrast.
    case hue(SystemHue, minimum: Double = Contrast.graphic, on: IslandBackdrop = .island)
    /// A colour someone chose (a banner, calendar or shortcut colour), fitted only for
    /// contrast.
    case fitted(RGB, minimum: Double = Contrast.graphic, on: IslandBackdrop = .island)
    /// Words on a filled button or badge of this colour: black or white.
    case onFill(RGB)
    /// The fill itself, moved away from its label if neither black nor white reads
    /// on it.
    case fill(RGB)

    func color(in theme: IslandTheme) -> Color {
        switch self {
        case .text(let alpha, let backdrop): theme.text(alpha, on: backdrop)
        case .graphic(let alpha, let backdrop): theme.graphic(alpha, on: backdrop)
        case .decorative(let alpha): theme.decorative(alpha)
        case .surface(let alpha): theme.surface(alpha)
        case .background: theme.background
        case .accent(let tint, let minimum, let backdrop): theme.accent(tint, minimum: minimum, on: backdrop)
        case .hue(let hue, let minimum, let backdrop): theme.hue(hue, minimum: minimum, on: backdrop)
        case .fitted(let colour, let minimum, let backdrop): theme.fitted(colour, minimum: minimum, on: backdrop).color
        case .onFill(let fill): theme.onFill(fill).label == .black ? .black : .white
        case .fill(let fill): theme.onFill(fill).fill.color
        }
    }

    /// The same colour for AppKit and Core Animation, which do not see the environment.
    func nsColor(in theme: IslandTheme) -> NSColor {
        NSColor(color(in: theme))
    }

    /// What this colour is measured against.
    var backdrop: IslandBackdrop {
        switch self {
        case .text(_, let backdrop), .graphic(_, let backdrop), .accent(_, _, let backdrop),
             .hue(_, _, let backdrop), .fitted(_, _, let backdrop): backdrop
        case .onFill(let fill): .fill(fill)
        case .decorative, .surface, .background, .fill: .island
        }
    }
}

/// A shape style that resolves an `IslandInk` against the theme in the environment.
struct IslandStyle: ShapeStyle, Hashable, Sendable {
    let ink: IslandInk
    var alpha: Double = 1

    func resolve(in environment: EnvironmentValues) -> Color {
        let colour = ink.color(in: environment.islandTheme)
        return alpha == 1 ? colour : colour.opacity(alpha)
    }

    /// This style at a further opacity, as `Color.opacity(_:)` would give it.
    func opacity(_ amount: Double) -> IslandStyle {
        IslandStyle(ink: ink, alpha: alpha * amount)
    }

    /// A level's fill dimmed to `amount` while muted (1 is not dimmed).
    func dimmedLevel(_ amount: Double, on track: IslandBackdrop) -> IslandDimmedLevel {
        IslandDimmedLevel(level: self, amount: amount, track: track)
    }
}

/// A faint outline in an island colour, such as a battery's body round its level: the
/// colour at `alpha` over what it lies on, as before themes on the black island with
/// Feature colours. Anywhere else that mix is fitted to 3:1 against what it lies on,
/// since an opacity laid over a fitted colour would undo the fitting.
struct IslandFaint: ShapeStyle, Hashable, Sendable {
    let ink: IslandInk
    let alpha: Double

    func resolve(in environment: EnvironmentValues) -> Color {
        let theme = environment.islandTheme
        guard !theme.isDefault, let colour = RGB(NSColor(ink.color(in: theme))) else {
            return IslandStyle(ink: ink, alpha: alpha).resolve(in: environment)
        }
        let backdrop = ink.backdrop
        return theme.fitted(colour.composited(alpha, over: theme.colour(of: backdrop)), on: backdrop).color
    }
}

extension ShapeStyle where Self == IslandFaint {
    /// `ink` at `alpha`, still at 3:1 against what it lies on.
    static func islandFaint(_ ink: IslandInk, _ alpha: Double) -> IslandFaint {
        IslandFaint(ink: ink, alpha: alpha)
    }
}

/// A level's fill dimmed while muted, to little more than its track. On the black island
/// with Feature colours it is the fill at that opacity, as before themes. Anywhere else an
/// opacity laid over a fitted colour would undo the fitting, so it is the ink at that
/// opacity instead, raised to 3:1 against the track: plainly quieter than the lit fill,
/// and still there to be read.
struct IslandDimmedLevel: ShapeStyle, Hashable, Sendable {
    let level: IslandStyle
    let amount: Double
    let track: IslandBackdrop

    func resolve(in environment: EnvironmentValues) -> Color {
        guard amount < 1, !environment.islandTheme.isDefault else {
            return level.opacity(amount).resolve(in: environment)
        }
        return IslandStyle(ink: .graphic(amount, on: track)).resolve(in: environment)
    }
}

extension ShapeStyle where Self == IslandStyle {
    /// Words at full strength: today's `.white`.
    static var islandPrimary: IslandStyle { IslandStyle(ink: .text(1)) }
    /// Words at today's `.white.opacity(alpha)`, raised to 4.5:1 where needed.
    static func islandText(_ alpha: Double, on backdrop: IslandBackdrop = .island) -> IslandStyle {
        IslandStyle(ink: .text(alpha, on: backdrop))
    }
    /// Symbols, rings and meaningful strokes, raised to 3:1 where needed.
    static func islandGraphic(_ alpha: Double = 1, on backdrop: IslandBackdrop = .island) -> IslandStyle {
        IslandStyle(ink: .graphic(alpha, on: backdrop))
    }
    /// Tracks, dividers, placeholders and hover washes: no floor.
    static func islandDecorative(_ alpha: Double) -> IslandStyle { IslandStyle(ink: .decorative(alpha)) }
    /// A card, chip or row fill.
    static func islandSurface(_ alpha: Double) -> IslandStyle { IslandStyle(ink: .surface(alpha)) }
    /// The island's own colour.
    static var islandBackground: IslandStyle { IslandStyle(ink: .background) }
    /// A feature's symbols, rings, progress and selected states.
    static func islandAccent(_ tint: FeatureTint, on backdrop: IslandBackdrop = .island) -> IslandStyle {
        IslandStyle(ink: .accent(tint, on: backdrop))
    }
    /// A feature's coloured words.
    static func islandAccentText(_ tint: FeatureTint, on backdrop: IslandBackdrop = .island) -> IslandStyle {
        IslandStyle(ink: .accent(tint, minimum: Contrast.text, on: backdrop))
    }
    /// A colour that means something, as a symbol, dot or ring.
    static func islandHue(_ hue: SystemHue, on backdrop: IslandBackdrop = .island) -> IslandStyle {
        IslandStyle(ink: .hue(hue, on: backdrop))
    }
    /// A colour that means something, as words.
    static func islandHueText(_ hue: SystemHue, on backdrop: IslandBackdrop = .island) -> IslandStyle {
        IslandStyle(ink: .hue(hue, minimum: Contrast.text, on: backdrop))
    }
    /// A colour someone chose, fitted only for contrast.
    static func islandFitted(_ colour: RGB, minimum: Double = Contrast.graphic, on backdrop: IslandBackdrop = .island) -> IslandStyle {
        IslandStyle(ink: .fitted(colour, minimum: minimum, on: backdrop))
    }
    /// Words on a filled button or badge of `fill`.
    static func islandOnFill(_ fill: RGB) -> IslandStyle { IslandStyle(ink: .onFill(fill)) }
    /// A filled button or badge, with room for its label.
    static func islandFill(_ fill: RGB) -> IslandStyle { IslandStyle(ink: .fill(fill)) }
    /// Any island colour.
    static func island(_ ink: IslandInk) -> IslandStyle { IslandStyle(ink: ink) }
}
