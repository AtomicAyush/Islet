import SwiftUI

extension View {
    /// Hidden from VoiceOver while `isHidden`, and otherwise left be: a plain
    /// `accessibilityHidden(false)` shows again whatever inside it hides itself. macOS 14
    /// has only the plain one.
    @ViewBuilder
    func accessibilityHidden(when isHidden: Bool) -> some View {
        if #available(macOS 15, *) {
            accessibilityHidden(true, isEnabled: isHidden)
        } else {
            accessibilityHidden(isHidden)
        }
    }
}

/// A filled circular button in the iPhone Live Activity style: a glyph on a disc of its
/// own colour, which brightens under the pointer.
struct RoundButton: View {
    let symbol: String
    let tint: IslandInk
    let diameter: CGFloat
    let action: () -> Void
    @Environment(\.islandTheme) private var theme
    @State private var isHovering = false

    /// A button in one of the island's colours: its ink, unless the button shows a
    /// feature's state (`.accent(.timer)`) or a colour that means something
    /// (`.hue(.muted)`). The glyph is fitted against its disc as drawn, so it stands out
    /// from it on any island.
    init(symbol: String, tint: IslandInk = .text(1), diameter: CGFloat = 38, action: @escaping () -> Void) {
        self.symbol = symbol
        self.tint = tint
        self.diameter = diameter
        self.action = action
    }

    var body: some View {
        let wash = isHovering ? 0.3 : 0.2
        let colours = theme.onWash(tint, wash: wash)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.38, weight: .bold))
                .foregroundStyle(colours.mark)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(colours.wash))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

extension IslandTheme {
    /// The shadow of something lying on the island, such as an indicator's card: black
    /// at `alpha`, and half that on a light island, where a heavy one reads as dirt.
    func shadow(_ alpha: Double) -> Color {
        .black.opacity(isLight ? alpha / 2 : alpha)
    }

    /// A mark drawn on a wash of its own colour, as a round button's glyph is on its
    /// disc, a picked tab's on its pill and a pill button's word on its capsule: the mark,
    /// and the wash, `wash` of the mark's colour laid on `backdrop` (the island, or a card
    /// or tile under the button). The mark is measured against the wash and what is under
    /// it together, so it still stands out from it; a wash of the ink is a surface, capped
    /// as cards are (`surface(_:on:)`). A coloured wash is kept faint enough that the mark
    /// can still reach its floor on it (`readableWash`); where that leaves less than half
    /// of it (a mid-tone island) the wash is the lift instead, and the mark keeps its
    /// colour, fitted against that. In the default theme they are exactly the mark's
    /// colour and that colour at `wash`, as before themes.
    func onWash(_ ink: IslandInk, wash: Double, on backdrop: IslandBackdrop = .island) -> (mark: Color, wash: Color) {
        if isDefault {
            let mark = ink.color(in: self)
            return (mark, mark.opacity(wash))
        }
        func coloured(_ source: RGB, _ minimum: Double) -> (mark: Color, wash: Color) {
            let colour = fitted(source, minimum: minimum, on: backdrop)
            let base = self.colour(of: backdrop)
            let alpha = readableWash(wash, of: colour, over: base, minimum: minimum)
            guard alpha >= wash / 2 else {
                let behind = lift.composited(wash, over: base)
                return (ink.on(.fill(behind)).color(in: self), lift.color.opacity(wash))
            }
            let behind = colour.composited(alpha, over: base)
            return (ink.on(.fill(behind)).color(in: self), colour.color.opacity(alpha))
        }
        switch ink {
        case .text(let alpha, _), .graphic(let alpha, _):
            return (ink.on(backdrop.stacked(wash * alpha)).color(in: self), surface(wash * alpha, on: backdrop))
        case .accent(let tint, let minimum, _):
            let own = accentSource(tint)
            if own == self.ink {
                // An accent that is the ink itself.
                return (ink.on(backdrop.stacked(wash)).color(in: self), surface(wash, on: backdrop))
            }
            return coloured(own, minimum)
        case .hue(let hue, let minimum, _):
            return coloured(hue.dark, minimum)
        case .fitted(let colour, let minimum, _):
            return coloured(colour, minimum)
        case .decorative, .surface, .background, .onFill, .fill:
            let mark = ink.color(in: self)
            return (mark, mark.opacity(wash))
        }
    }
}

extension IslandInk {
    /// The same colour, measured against `backdrop` rather than the backdrop it was
    /// first meant for: a mark moved onto a button's disc or a picked capsule.
    func on(_ backdrop: IslandBackdrop) -> IslandInk {
        switch self {
        case .text(let alpha, _): .text(alpha, on: backdrop)
        case .graphic(let alpha, _): .graphic(alpha, on: backdrop)
        case .accent(let tint, let minimum, _): .accent(tint, minimum: minimum, on: backdrop)
        case .hue(let hue, let minimum, _): .hue(hue, minimum: minimum, on: backdrop)
        case .fitted(let colour, let minimum, _): .fitted(colour, minimum: minimum, on: backdrop)
        case .decorative, .surface, .background, .onFill, .fill: self
        }
    }
}

/// How far something has come, as a ring that fills in `tint` over a faint track of
/// it, eased from one look to the next: a download's, a copy's.
struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat
    /// One of the island's colours: a feature's accent, as a rule.
    let tint: IslandInk

    var body: some View {
        ZStack {
            Circle().stroke(IslandStyle(ink: tint).opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(IslandStyle(ink: tint), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// The island's wings for things under way, a download's or a copy's: the icon of the
/// newest left of the camera, and its ring right of it, with a count beside the ring
/// while several go at once.
enum ProgressWingLayout {
    static let compactIcon: CGFloat = 20
    static let compactMark: CGFloat = 16
    /// Room for the count beside the ring while several are under way.
    static let countedTrailingWidth: CGFloat = 60
    static let expandedHeight: CGFloat = 76

    /// Between the ring and the island's outer end, in a row `rowHeight` tall: the icon
    /// on the left is centred in the default wing, so the ring is centred in the same
    /// width at the right, whatever the notch's height, and stays there when the count
    /// widens its wing.
    static func trailingInset(rowHeight: CGFloat) -> CGFloat {
        max(0, (IslandLayout.defaultSide(for: CGSize(width: 0, height: rowHeight)) - compactMark) / 2)
    }
}

/// Left of the notch: the newest one's icon, `ProgressWingLayout.compactIcon` across,
/// springing in when another takes its place.
struct ProgressWingLeading<Icon: View>: View {
    /// Which one the icon is for; `nil` for none.
    let id: String?
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        ZStack {
            if let id {
                icon()
                    .id(id)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: id)
    }
}

/// Right of the notch: the newest one's ring (`mark`), with how many are under way
/// when there are several.
struct ProgressWingTrailing<Mark: View>: View {
    let count: Int
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 5) {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.islandText(0.6))
                        .fixedSize()
                        .transition(.opacity)
                }
                mark()
                    .frame(width: ProgressWingLayout.compactMark, height: ProgressWingLayout.compactMark)
            }
            .padding(.trailing, ProgressWingLayout.trailingInset(rowHeight: proxy.size.height))
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
    }
}

/// Under a file's icon from the system, on a light island: Finder's white page of paper
/// all but vanishes on a white or pale island, so there it lies on a faint plate of the
/// ink, the size of the icon's box, which gives it an edge. On a dark island nothing,
/// as before themes.
struct FileIconBacking: ViewModifier {
    let size: CGFloat
    @Environment(\.islandTheme) private var theme

    static let plate = 0.1

    func body(content: Content) -> some View {
        content.background {
            if theme.isLight {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(.islandDecorative(Self.plate))
            }
        }
    }
}

extension View {
    /// A file's icon, `size` across, kept in sight on a light island (`FileIconBacking`).
    func fileIconBacking(size: CGFloat) -> some View {
        modifier(FileIconBacking(size: size))
    }
}
