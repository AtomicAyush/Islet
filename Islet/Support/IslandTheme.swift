import SwiftUI

/// Appearance › Accent: the one colour the island's symbols, rings, progress, highlights
/// and selected states are drawn in. Never used for colours that mean something.
enum AccentChoice: Hashable, Sendable {
    /// Each feature keeps its own colour, as it always has. The default.
    case featureColours
    /// The island's ink: white on a dark island, black on a light one.
    case mono
    /// One colour for every feature.
    case colour(RGB)

    /// Reads the stored preference: "feature", "mono" or "#RRGGBB". Anything else is
    /// Feature colours.
    init(pref: String) {
        switch pref {
        case "mono": self = .mono
        default: self = RGB(hex: pref).map(AccentChoice.colour) ?? .featureColours
        }
    }

    var prefValue: String {
        switch self {
        case .featureColours: "feature"
        case .mono: "mono"
        case .colour(let c): c.hex
        }
    }

    /// The accent presets. Each is at least 25° of hue away from the privacy lights'
    /// green, orange, purple and blue and from the failure red, so a ring beside the
    /// notch is never taken for one of them (`IslandTheme.accentClash` stays quiet).
    ///
    /// Indigo is Do Not Disturb's colour and Mint is close to Presentation Mode's teal,
    /// on purpose left unguarded: a Focus and Presentation Mode always show their own
    /// symbol (a moon, an eye) beside the notch, so a ring in the same colour is never
    /// taken for them, where a privacy light is a bare dot that can only be told by
    /// its colour.
    static let presets: [(name: String, colour: RGB)] = [
        ("Pink", RGB(hex: 0xFF4FA3)),
        ("Indigo", RGB(hex: 0x5E5CE6)),
        ("Mint", RGB(hex: 0x63E6E2)),
        ("Lime", RGB(hex: 0xB4E61E)),
    ]
}

/// Appearance › Island colour presets. Any other colour can be picked as well.
enum IslandColourPreset: String, CaseIterable, Identifiable {
    case black, graphite, midnight, white, sand

    var id: String { rawValue }

    var name: String {
        switch self {
        case .black: "Black"
        case .graphite: "Graphite"
        case .midnight: "Midnight"
        case .white: "White"
        case .sand: "Sand"
        }
    }

    var colour: RGB {
        switch self {
        case .black: .black
        case .graphite: RGB(hex: 0x2C2C2E)
        case .midnight: RGB(hex: 0x1C2340)
        case .white: .white
        case .sand: RGB(hex: 0xE8DCC8)
        }
    }
}

/// What an element is drawn on, so its contrast is measured against what is actually
/// behind it.
enum IslandBackdrop: Hashable, Sendable {
    /// The island itself.
    case island
    /// A card, chip or row: `surface(alpha)` over the island.
    case surface(Double)
    /// Something opaque of another colour, such as a filled button.
    case fill(RGB)
    /// A level's track, `surface(alpha)` over the island, for the fill inside it. The
    /// fill's ends lie on the track and its long edges on the island, so a colour is
    /// fitted against both; ink is measured against the track, the harder of the two.
    case track(Double)
}

/// The island's colours for one choice of island colour and accent: worked out once
/// when the preferences change, put in the environment at the island's root (and in
/// Settings), and read by views through the `.island…` shape styles. Views never read
/// UserDefaults for a colour.
///
/// Every call site keeps today's opacity; the theme only raises it as far as the
/// contrast floor needs (4.5:1 for words, 3:1 for symbols and rings). On the black
/// island with Feature colours, the default, every role returns exactly what the island
/// drew before themes, so it looks the same to the pixel.
struct IslandTheme: Sendable, Equatable {
    /// The island's colour, used exactly as chosen.
    let island: RGB
    let accent: AccentChoice
    /// White or black, whichever stands out more on the island.
    let ink: RGB
    /// A light island, drawn on in black.
    let isLight: Bool
    /// Black with Feature colours: every colour passes through unchanged.
    let isDefault: Bool
    /// The strongest wash a card can be before its words drop under 4.5:1.
    let maxSurfaceAlpha: Double
    /// The least opacity of ink that reads as words (4.5:1) and as a symbol (3:1) on
    /// the island itself.
    let textFloor: Double
    let graphicFloor: Double
    private let memo = Memo()

    init(island: RGB, accent: AccentChoice) {
        self.island = island
        self.accent = accent
        ink = Contrast.ink(on: island)
        isLight = ink == .black
        isDefault = island == .black && accent == .featureColours
        maxSurfaceAlpha = Contrast.maxSurfaceAlpha(ink, over: island)
        textFloor = Contrast.minAlpha(ink, on: island, floor: Contrast.text)
        graphicFloor = Contrast.minAlpha(ink, on: island, floor: Contrast.graphic)
    }

    static func == (a: IslandTheme, b: IslandTheme) -> Bool {
        a.island == b.island && a.accent == b.accent
    }

    /// The black island with Feature colours: exactly the island before themes.
    static let standard = IslandTheme(island: .black, accent: .featureColours)
    /// The stored preferences that give `standard`.
    static let standardIslandPref = "#000000"
    static let standardAccentPref = "feature"

    /// The same accent on black: what the resting island wears on a display with a
    /// notch, where it stands in for the notch itself.
    var resting: IslandTheme {
        island == .black ? self : IslandTheme.cached(island: .black, accent: accent)
    }

    /// The black island, whatever the accent: where colours are drawn as they always
    /// were before they are fitted.
    var isBlack: Bool { island == .black }

    var colorScheme: ColorScheme { isLight ? .light : .dark }

    /// The ink as SwiftUI's own `.white` or `.black`, so the default draws exactly the
    /// colours it always has.
    var inkColor: Color { isLight ? .black : .white }

    /// The ink as AppKit's own `.white` or `.black`, for a layer that was handed it so
    /// before themes: SwiftUI's white, carried over to AppKit, blends a shade differently.
    var inkNSColor: NSColor { isLight ? .black : .white }

    var background: Color { island == .black ? .black : island.color }

    // MARK: Backdrops

    /// The opaque colour an element on `backdrop` sits on.
    func colour(of backdrop: IslandBackdrop) -> RGB {
        switch backdrop {
        case .island: island
        case .surface(let alpha), .track(let alpha): ink.composited(surfaceAlpha(alpha), over: island)
        case .fill(let fill): fill
        }
    }

    // MARK: Ink roles

    /// Words: today's `.white.opacity(alpha)`, raised only as far as 4.5:1 needs.
    func text(_ alpha: Double = 1, on backdrop: IslandBackdrop = .island) -> Color {
        ink(at: textAlpha(alpha, on: backdrop))
    }

    /// Symbols, rings, progress fills, meaningful strokes and disabled-but-visible
    /// controls: raised only as far as 3:1 needs.
    func graphic(_ alpha: Double = 1, on backdrop: IslandBackdrop = .island) -> Color {
        ink(at: graphicAlpha(alpha, on: backdrop))
    }

    /// Full ink as plain `.white` or `.black`, exactly as views wrote it before themes.
    private func ink(at alpha: Double) -> Color {
        alpha >= 1 ? inkColor : inkColor.opacity(alpha)
    }

    /// Tracks, dividers, placeholders and hover washes: ink at `alpha`, no floor.
    func decorative(_ alpha: Double) -> Color {
        inkColor.opacity(alpha)
    }

    /// A card, chip or row fill: ink at `alpha`, capped so full ink on it still reads.
    func surface(_ alpha: Double) -> Color {
        inkColor.opacity(surfaceAlpha(alpha))
    }

    func textAlpha(_ alpha: Double, on backdrop: IslandBackdrop = .island) -> Double {
        isDefault ? alpha : max(alpha, leastAlpha(Contrast.text, on: backdrop))
    }

    func graphicAlpha(_ alpha: Double, on backdrop: IslandBackdrop = .island) -> Double {
        isDefault ? alpha : max(alpha, leastAlpha(Contrast.graphic, on: backdrop))
    }

    func surfaceAlpha(_ alpha: Double) -> Double {
        isDefault ? alpha : min(alpha, maxSurfaceAlpha)
    }

    private func leastAlpha(_ minimum: Double, on backdrop: IslandBackdrop) -> Double {
        if backdrop == .island { return minimum == Contrast.text ? textFloor : graphicFloor }
        let surface = colour(of: backdrop)
        return memo.value(for: .alpha(surface, minimum)) {
            Contrast.minAlpha(ink, on: surface, floor: minimum)
        }
    }

    // MARK: Colours

    /// The colour a feature's highlights start from, before fitting.
    func accentSource(_ tint: FeatureTint) -> RGB {
        switch accent {
        case .featureColours:
            if case .colour(let own) = tint { return own }
            return ink
        case .mono: return ink
        case .colour(let chosen): return chosen
        }
    }

    /// A feature's symbols, rings, progress and selected states (3:1), or its coloured
    /// words with `minimum: Contrast.text`.
    func accent(_ tint: FeatureTint, minimum: Double = Contrast.graphic, on backdrop: IslandBackdrop = .island) -> Color {
        let source = accentSource(tint)
        if source == ink { return inkColor }
        return drawn(fitted(source, minimum: minimum, on: backdrop))
    }

    /// A colour that means something: kept as it is wherever it already stands out
    /// (always, in the default theme), otherwise fitted for contrast. Never the accent.
    func hue(_ hue: SystemHue, minimum: Double = Contrast.graphic, on backdrop: IslandBackdrop = .island) -> Color {
        drawn(fitted(hue.dark, minimum: minimum, on: backdrop))
    }

    /// A worked-out colour as drawn: the ink as SwiftUI's own white or black, like every
    /// other use of the ink.
    private func drawn(_ colour: RGB) -> Color {
        colour == ink ? inkColor : colour.color
    }

    /// Any colour (the accent, a feature's colour, a semantic hue, a person's banner or
    /// calendar colour) kept as close as it can be: moved toward the ink only as far as
    /// `minimum` against the backdrop needs. Unchanged in the default theme.
    ///
    /// Words that could reach 4.5:1 only by all but losing their hue are drawn in the ink
    /// instead. That happens on a mid-tone island, such as a grey or a system blue, where
    /// the ink itself only just reads: a red or orange word would come out near black,
    /// which says nothing a plain word doesn't. The symbol or dot beside such words, held
    /// to 3:1 rather than 4.5:1, keeps the colour.
    func fitted(_ colour: RGB, minimum: Double = Contrast.graphic, on backdrop: IslandBackdrop = .island) -> RGB {
        if isDefault { return colour }
        if case .track(let alpha) = backdrop {
            // First against the island, then on from there against the track. Moving
            // toward the ink only adds to the contrast with the island once the colour is
            // past it, so the second step never undoes the first, and a colour lighter
            // than an island drawn on in black ends up darker than both, as the symbol
            // beside the level does, rather than passing against the track alone.
            return fitted(fitted(colour, minimum: minimum, on: .island), minimum: minimum, on: .surface(alpha))
        }
        let surface = self.colour(of: backdrop)
        return memo.colour(for: .fit(colour, minimum, surface)) {
            let fit = Contrast.fitted(colour, floor: minimum, on: surface, ink: ink)
            let losesHue = minimum >= Contrast.text && colour.chroma >= Contrast.leastChroma
                && fit.chroma < Contrast.leastChroma && fit.chroma < colour.chroma / 2
            return losesHue ? ink : fit
        }
    }

    /// Words on a filled button or badge: the label (black or white) and the fill to
    /// draw under it, moved away from the label if neither reaches 4.5:1. In the
    /// default theme the fill is kept as it is.
    func onFill(_ fill: RGB) -> (label: RGB, fill: RGB) {
        if isDefault { return (Contrast.ink(on: fill), fill) }
        return memo.pair(for: fill) { Contrast.onFill(fill) }
    }

    /// The meaningful colour a chosen accent could be mistaken for, if any: within 25°
    /// of hue of a privacy light or the failure red, both clearly saturated.
    var accentClash: SystemHue? {
        guard case .colour(let chosen) = accent else { return nil }
        return SystemHue.guarded.first { chosen.couldBeTaken(for: $0.dark) }
    }

    /// The meaningful colour the island's own could be mistaken for, if any: within 25°
    /// of hue of a privacy light or the failure red, both clearly saturated, and too
    /// close to stand out on it as it is, so that it is drawn darker or lighter there. On
    /// a display without a notch the resting island wears its colour.
    var islandClash: SystemHue? {
        SystemHue.guarded.first { island.couldBeTaken(for: $0.dark) && fitted($0.dark) != $0.dark }
    }

    // MARK: Cache

    /// Themes by preference value. A colour picker drag writes many values, so the
    /// cache is emptied when it fills up.
    static func cached(island: RGB, accent: AccentChoice) -> IslandTheme {
        if island == .black, accent == .featureColours { return .standard }
        return themes.withLock { cache in
            let key = ThemeKey(island: island, accent: accent)
            if let theme = cache[key] { return theme }
            if cache.count >= 16 { cache.removeAll() }
            let theme = IslandTheme(island: island, accent: accent)
            cache[key] = theme
            return theme
        }
    }

    /// From the stored preferences: "#RRGGBB" for the island, and the accent's value.
    static func cached(islandPref: String, accentPref: String) -> IslandTheme {
        cached(island: RGB(hex: islandPref) ?? .black, accent: AccentChoice(pref: accentPref))
    }

    private struct ThemeKey: Hashable {
        let island: RGB
        let accent: AccentChoice
    }

    private static let themes = Locked([ThemeKey: IslandTheme]())
}

/// Colours worked out on demand, kept so views that redraw every frame never search
/// twice. Shared between copies of one theme, and locked: shape styles resolve off the
/// main thread too.
private final class Memo: Sendable {
    enum Key: Hashable {
        case alpha(RGB, Double)
        case fit(RGB, Double, RGB)
    }

    private let values = Locked([Key: Double]())
    private let colours = Locked([Key: RGB]())
    private let pairs = Locked([RGB: [RGB]]())

    func value(for key: Key, _ make: () -> Double) -> Double {
        if let v = values.withLock({ $0[key] }) { return v }
        let v = make()
        values.withLock { if $0.count > 512 { $0.removeAll() }; $0[key] = v }
        return v
    }

    func colour(for key: Key, _ make: () -> RGB) -> RGB {
        if let c = colours.withLock({ $0[key] }) { return c }
        let c = make()
        colours.withLock { if $0.count > 512 { $0.removeAll() }; $0[key] = c }
        return c
    }

    func pair(for fill: RGB, _ make: () -> (label: RGB, fill: RGB)) -> (label: RGB, fill: RGB) {
        if let p = pairs.withLock({ $0[fill] }) { return (p[0], p[1]) }
        let p = make()
        pairs.withLock { if $0.count > 512 { $0.removeAll() }; $0[fill] = [p.label, p.fill] }
        return p
    }
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private struct IslandThemeKey: EnvironmentKey {
    static let defaultValue = IslandTheme.standard
}

extension EnvironmentValues {
    /// The island's colours, put in at the island's root and in Settings.
    var islandTheme: IslandTheme {
        get { self[IslandThemeKey.self] }
        set { self[IslandThemeKey.self] = newValue }
    }
}
