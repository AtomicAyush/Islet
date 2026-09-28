import SwiftUI

// Chips, pills and badges that lie on a card or a tile rather than on the island itself:
// a preset in a home tile, a Mute button in an indicator card, an Allow chip on a hidden
// icon's plate. Each wash adds to the one under it, and what is drawn on it is measured
// against both together. On an island with little room for washes (a mid-tone blue, where
// the card under it has used it all) a second wash of the ink would vanish, so it goes the
// other way instead, toward white on an island drawn on in black: the pill keeps its shape
// and its words read better still.

extension IslandBackdrop {
    /// What something lies on once a chip or row of the ink at `alpha` is laid on this
    /// backdrop: a pill's label in a home tile is measured against
    /// `IslandBackdrop.homeTile.stacked(0.12)`. Two shades of the ink make one,
    /// `1 - (1 - a)(1 - b)` of it. On an opaque fill the chip is measured as the fill.
    func stacked(_ alpha: Double) -> IslandBackdrop {
        switch self {
        case .island: .surface(alpha)
        case .surface(let under), .track(let under): .surface(1 - (1 - under) * (1 - alpha))
        case .fill: self
        }
    }
}

extension IslandTheme {
    /// The colour a wash goes toward where there is no room left for more ink: white on
    /// an island drawn on in black, black on one drawn on in white.
    var lift: RGB { isLight ? .white : .black }

    /// A chip or row of the ink at `alpha` laid on `backdrop`. Where the wash under it
    /// leaves no room for that much ink before full ink on it stops reading, it is the
    /// lift at `alpha` instead, which only adds to the contrast `backdrop.stacked(alpha)`
    /// is measured for. In the default theme exactly the ink at `alpha`, as before themes.
    func surface(_ alpha: Double, on backdrop: IslandBackdrop) -> Color {
        guard !isDefault else { return surface(alpha) }
        switch backdrop {
        case .island:
            return surface(alpha)
        case .surface(let under), .track(let under):
            let below = surfaceAlpha(under)
            let room = below >= 1 ? 0 : max(0, 1 - (1 - maxSurfaceAlpha) / (1 - below))
            return room >= alpha ? inkColor.opacity(alpha) : lift.color.opacity(alpha)
        case .fill(let fill):
            return inkColor.opacity(min(alpha, Contrast.maxSurfaceAlpha(ink, over: fill)))
        }
    }

    /// How strong a wash of `colour` over `base` can be with full ink on it still at
    /// `minimum` (4.5:1, for words): `alpha`, or less where the wash would take the
    /// backdrop too far toward the ink. A lit drop tile is a wash of this kind, and
    /// `onWash` keeps a coloured button's capsule to it; on a mid-tone island, where full
    /// ink only just reads on the island itself, even a faint one can be too much.
    /// `alpha` itself in the default theme.
    func readableWash(_ alpha: Double, of colour: RGB, over base: RGB, minimum: Double = Contrast.text) -> Double {
        guard !isDefault else { return alpha }
        func reads(_ wash: Double) -> Bool {
            RGB.contrast(ink, colour.composited(wash, over: base)) >= minimum
        }
        if reads(alpha) { return alpha }
        guard reads(0) else { return 0 }
        var low = 0.0, high = alpha
        for _ in 0..<Contrast.steps {
            let mid = (low + high) / 2
            if reads(mid) { low = mid } else { high = mid }
        }
        return low
    }
}

/// A chip or row laid on a card or tile: `.islandSurface(0.12, on: .homeTile)`.
struct IslandStackedSurface: ShapeStyle, Hashable, Sendable {
    let alpha: Double
    let backdrop: IslandBackdrop

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.islandTheme.surface(alpha, on: backdrop)
    }
}

extension ShapeStyle where Self == IslandStackedSurface {
    /// A chip, capsule or plate on `backdrop`, such as a preset pill in a home tile. What
    /// sits on it is measured against `backdrop.stacked(alpha)`; on the island itself it
    /// is `.islandSurface(alpha)`.
    static func islandSurface(_ alpha: Double, on backdrop: IslandBackdrop) -> IslandStackedSurface {
        IslandStackedSurface(alpha: alpha, backdrop: backdrop)
    }
}

/// A symbol or word on a wash of its own colour, as a badge's symbol lies on its disc
/// and a pill button's word on its capsule: both colours come from
/// `IslandTheme.onWash`, so the mark stands out from the wash on any island.
struct IslandWashed<Background: Shape>: ViewModifier {
    let ink: IslandInk
    let wash: Double
    var backdrop: IslandBackdrop = .island
    let shape: Background
    @Environment(\.islandTheme) private var theme

    func body(content: Content) -> some View {
        let colours = theme.onWash(ink, wash: wash, on: backdrop)
        content
            .foregroundStyle(colours.mark)
            .background(shape.fill(colours.wash))
    }
}

extension View {
    /// Draws this in `ink` on a `shape` filled with `wash` of the same colour, laid on
    /// `backdrop`.
    func islandWashed(_ ink: IslandInk, wash: Double, in shape: some Shape, on backdrop: IslandBackdrop = .island) -> some View {
        modifier(IslandWashed(ink: ink, wash: wash, backdrop: backdrop, shape: shape))
    }
}
