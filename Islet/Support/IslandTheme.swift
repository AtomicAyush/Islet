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
///
/// A fill of several colours keeps one ink for all of them, so its words never change
/// colour as it moves: every colour it draws is deepened or brightened until full ink
/// reaches 7:1 on it (`deepContrast`), and every floor and cap is worked out against all
/// of them, the hardest deciding.
///
/// Opened, under a page, a card banner or Quick Ask, an island in colour (a fill of
/// several, or one colour that reads as a hue rather than as black, white or a grey) is
/// drawn under a calmer shade (`opened`): black under white words, or white under black
/// ones, whichever keeps more of the colour, laid over every colour at one opacity, so
/// the fill keeps its look as it moves while full ink reaches 12:1 on its brightest
/// moment, and every word, secondary and coloured ones included, reaches 7:1. Closed,
/// and on the ring, the colours are as chosen.
struct IslandTheme: Sendable, Equatable {
    /// The colour contrast is judged against: the island's colour, used exactly as
    /// chosen, or for a fill of several colours the one the ink stands out least on;
    /// opened, under the calmer shade.
    let island: RGB
    let accent: AccentChoice
    /// Solid, a gradient, or colours fading one into the next.
    let fill: IslandFill
    /// The colours handed to the gradient or the animation: the island's colour alone
    /// for a solid fill; otherwise each chosen colour's way to the next, cut into
    /// `piecesPerColour`, every piece fitted away from the ink. Opened, under the calmer
    /// shade, as something inside a page that wears the island's colour draws them.
    let stops: [RGB]
    /// Every colour drawn: the stops, and what is drawn between each two.
    let samples: [RGB]
    /// The theme inside an opened island in colour (`opened`).
    let isOpened: Bool
    /// Opened, the opacity of `calmColour` laid over the fill: the least that brings full
    /// ink to `openedContrast` on every colour drawn. 0 when closed, and when the fill is
    /// already that deep.
    let calm: Double
    /// What every word reaches: 4.5:1, or opened, `openedWords`.
    let wordFloor: Double
    /// White or black, whichever stands out more on the island; for a fill of several
    /// colours, the one its tone asks for. Opened, the one its calmer shade is for, which
    /// can be the other.
    let ink: RGB
    /// A light island, drawn on in black.
    let isLight: Bool
    /// Black with Feature colours: every colour passes through unchanged.
    let isDefault: Bool
    /// The strongest wash a card can be before its words drop under `wordFloor`.
    let maxSurfaceAlpha: Double
    /// The least opacity of ink that reads as words (`wordFloor`) and as a symbol (3:1)
    /// on the island itself.
    let textFloor: Double
    let graphicFloor: Double
    private let memo = Memo()

    /// What full ink reaches on every colour of a fill of several. Held to 4.5:1 alone,
    /// a bright palette would leave the island mid-toned: no room for cards, every
    /// secondary word at full ink, and the meaningful colours all but black.
    static let deepContrast = 7.0
    /// Pieces each chosen colour's way to the next is cut into.
    static let piecesPerColour = 12
    /// Colours judged between two neighbouring pieces, as the gradient or the animation
    /// draws them.
    static let samplesPerPiece = 4
    /// What full ink reaches on every colour of an opened island in colour, under the
    /// calmer shade: the brightest moment of a moving fill included.
    static let openedContrast = 12.0
    /// What every word reaches there, at today's opacity raised only as far as it needs:
    /// what full ink reaches on the closed fill. Held to 4.5:1, secondary words would sit
    /// on a moving colour at the least WCAG allows, which is where they were hard to read.
    static let openedWords = 7.0

    init(island: RGB, accent: AccentChoice, fill: IslandFill = .solid, opened: Bool = false) {
        self.accent = accent
        self.fill = fill
        var ink: RGB
        var stops: [RGB], samples: [RGB]
        if let palette = fill.palette {
            let cyclic = fill.isRotating
            let path = Self.path(through: palette.colours, cyclic: cyclic)
            ink = Self.ink(for: path, tone: fill.tone ?? .auto, preset: palette.preset)
            stops = path.map { Contrast.fittedAway($0, from: ink, to: Self.deepContrast) }
            samples = Self.between(stops, cyclic: cyclic)
        } else {
            ink = Contrast.ink(on: island)
            stops = [island]
            samples = [island]
        }
        // Every colour moved by the same amount, as the shade laid over the fill moves
        // them, so the shade can come and go over the moving fill without touching it.
        // Darker under white words or lighter under black ones, whichever keeps more of
        // the colour: a red or a blue opens a deep red or a navy rather than a pastel,
        // while a yellow, an orange or a Bright fill, which would go olive or brown, opens
        // lighter. Where they keep as much, darker.
        let isOpened = opened && Self.hasColour(island: island, fill: fill)
        var calm = 0.0
        if isOpened {
            let ways = [RGB.white, .black].map { words -> (ink: RGB, calm: Double, colour: Double) in
                let calm = Contrast.shade(samples, from: words, to: Self.openedContrast)
                let away = Self.calmColour(under: words)
                return (words, calm, samples.reduce(0) { $0 + $1.mixed(toward: away, calm).colourfulness })
            }
            let way = ways[0].colour >= ways[1].colour ? ways[0] : ways[1]
            ink = way.ink
            calm = way.calm
        }
        if calm > 0 {
            let away = Self.calmColour(under: ink)
            stops = stops.map { $0.mixed(toward: away, calm) }
            samples = samples.map { $0.mixed(toward: away, calm) }
        }
        self.isOpened = isOpened
        self.calm = calm
        self.ink = ink
        self.stops = stops
        self.samples = samples
        if fill.palette != nil {
            self.island = samples.min { RGB.contrast(ink, $0) < RGB.contrast(ink, $1) } ?? island
        } else {
            self.island = samples[0]
        }
        let wordFloor = isOpened ? Self.openedWords : Contrast.text
        self.wordFloor = wordFloor
        isLight = ink == .black
        isDefault = fill == .solid && island == .black && accent == .featureColours
        maxSurfaceAlpha = Contrast.maxSurfaceAlpha(ink, over: samples, floor: wordFloor)
        textFloor = Contrast.minAlpha(ink, on: samples, floor: wordFloor)
        graphicFloor = Contrast.minAlpha(ink, on: samples, floor: Contrast.graphic)
    }

    static func == (a: IslandTheme, b: IslandTheme) -> Bool {
        a.island == b.island && a.accent == b.accent && a.fill == b.fill && a.isOpened == b.isOpened
    }

    /// An island in colour: a fill of several, or one colour that reads as a hue rather
    /// than as black, white or a grey. Only such an island is calmed when opened, so the
    /// presets (Black, Graphite, Midnight, White, Sand) open as they always have.
    static func hasColour(island: RGB, fill: IslandFill) -> Bool {
        fill != .solid || island.chroma >= Contrast.leastChroma
    }

    /// The shade laid over an opened island in colour: black under white words, white
    /// under black ones.
    static func calmColour(under ink: RGB) -> RGB {
        ink == .white ? .black : .white
    }

    var calmColour: RGB { Self.calmColour(under: ink) }

    /// Whether the calmer shade can leave the band of a ring in `colours` clear, so the
    /// ring is drawn over the fill it was chosen for and is as bright as on the closed
    /// island. Only where the shade takes the island away from every one of its colours:
    /// a black shade under a ring lighter than every colour of the fill, or a white one
    /// under a ring darker than every colour. Anywhere else a ring at less than full
    /// brightness could come out the shaded island's own colour, or darker than it where
    /// it was lighter, so it is drawn over the shade as the island is. Asked of the closed
    /// theme.
    func calmLeavesClear(_ colours: [RGB]) -> Bool {
        let opened = self.opened
        guard opened.calm > 0, !colours.isEmpty else { return false }
        return memo.value(for: .clear(colours)) {
            let fill = Contrast.extremes(of: samples).map(\.luminance)
            let ring = colours.map(\.luminance)
            let clear = opened.calmColour == .black ? ring.min()! > fill[1] : ring.max()! < fill[0]
            return clear ? 1 : 0
        } == 1
    }

    /// The theme inside an opened island: under a page, a card banner or Quick Ask. For
    /// an island in colour, its fill under the calmer shade (`calm`) and every word at
    /// `openedWords`; any other island is opened in this theme itself, so it draws what
    /// it always has.
    var opened: IslandTheme {
        guard !isOpened, Self.hasColour(island: island, fill: fill) else { return self }
        return Self.cached(island: island, accent: accent, fill: fill, opened: true)
    }

    /// Each colour's way to the next, cut into `piecesPerColour` and mixed in sRGB, as a
    /// gradient and Core Animation mix them; back round to the first when `cyclic`.
    static func path(through colours: [RGB], cyclic: Bool) -> [RGB] {
        let next = Array(colours.dropFirst()) + (cyclic ? [colours[0]] : [])
        var path = zip(colours, next).flatMap { a, b in
            (0..<piecesPerColour).map { a.mixed(toward: b, Double($0) / Double(piecesPerColour)) }
        }
        if !cyclic, let last = colours.last { path.append(last) }
        return path
    }

    /// `stops` and what is drawn between each two, `samplesPerPiece` to a piece.
    static func between(_ stops: [RGB], cyclic: Bool) -> [RGB] {
        let sequence = stops + (cyclic ? [stops[0]] : [])
        var samples = zip(sequence, sequence.dropFirst()).flatMap { a, b in
            (0..<samplesPerPiece).map { a.mixed(toward: b, Double($0) / Double(samplesPerPiece)) }
        }
        if let last = sequence.last { samples.append(last) }
        return samples
    }

    /// White for a deep fill, black for a bright one; for `auto`, a preset's own tone, or
    /// the ink that needs the colours changed least to reach `deepContrast`.
    static func ink(for colours: [RGB], tone: IslandTone, preset: IslandPalettePreset?) -> RGB {
        switch tone {
        case .deep: return .white
        case .bright: return .black
        case .auto:
            if let preset { return preset.tone == .deep ? .white : .black }
            func shortfall(_ ink: RGB) -> Double {
                colours.reduce(0) { $0 + max(0, 1 - min(1, RGB.contrast(ink, $1) / deepContrast)) }
            }
            return shortfall(.white) <= shortfall(.black) ? .white : .black
        }
    }

    /// A chosen colour of the fill as it is drawn.
    func drawn(fillColour colour: RGB) -> RGB {
        fill == .solid ? colour : Contrast.fittedAway(colour, from: ink, to: Self.deepContrast)
    }

    /// The tone a fill of several colours is drawn in, `auto` resolved.
    var tone: IslandTone { isLight ? .bright : .deep }

    /// A fill of more than one colour.
    var isMulticolour: Bool { fill != .solid }

    /// The black island with Feature colours: exactly the island before themes.
    static let standard = IslandTheme(island: .black, accent: .featureColours)
    /// The stored preferences that give `standard`.
    static let standardIslandPref = "#000000"
    static let standardAccentPref = "feature"

    /// The same accent on black: what the resting island wears on a display with a
    /// notch, where it stands in for the notch itself.
    var resting: IslandTheme {
        isBlack ? self : IslandTheme.cached(island: .black, accent: accent)
    }

    /// The black island, whatever the accent: where colours are drawn as they always
    /// were before they are fitted.
    var isBlack: Bool { island == .black && fill == .solid }

    var colorScheme: ColorScheme { isLight ? .light : .dark }

    /// The ink as SwiftUI's own `.white` or `.black`, so the default draws exactly the
    /// colours it always has.
    var inkColor: Color { isLight ? .black : .white }

    /// The ink as AppKit's own `.white` or `.black`, for a layer that was handed it so
    /// before themes: SwiftUI's white, carried over to AppKit, blends a shade differently.
    var inkNSColor: NSColor { isLight ? .black : .white }

    var background: Color { island == .black ? .black : island.color }

    // MARK: Backdrops

    /// Every opaque colour an element on `backdrop` sits on: `colour(of:)` for a solid
    /// island; for a fill of several colours, the backdrop over each colour it draws.
    func colours(of backdrop: IslandBackdrop) -> [RGB] {
        guard fill != .solid else { return [colour(of: backdrop)] }
        switch backdrop {
        case .island: return samples
        case .surface(let alpha), .track(let alpha):
            let wash = surfaceAlpha(alpha)
            return samples.map { ink.composited(wash, over: $0) }
        case .fill(let fill): return [fill]
        }
    }

    /// The opaque colour an element on `backdrop` sits on; for a fill of several colours,
    /// the one over the colour the ink stands out least on.
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
        isDefault ? alpha : max(alpha, leastAlpha(wordFloor, on: backdrop))
    }

    func graphicAlpha(_ alpha: Double, on backdrop: IslandBackdrop = .island) -> Double {
        isDefault ? alpha : max(alpha, leastAlpha(Contrast.graphic, on: backdrop))
    }

    func surfaceAlpha(_ alpha: Double) -> Double {
        isDefault ? alpha : min(alpha, maxSurfaceAlpha)
    }

    private func leastAlpha(_ minimum: Double, on backdrop: IslandBackdrop) -> Double {
        if backdrop == .island { return minimum == wordFloor ? textFloor : graphicFloor }
        let surface = colour(of: backdrop)
        return memo.value(for: .alpha(surface, minimum)) {
            Contrast.minAlpha(ink, on: colours(of: backdrop), floor: minimum)
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
    /// to 3:1 rather than 4.5:1, keeps the colour. Opened, words reach `wordFloor`.
    func fitted(_ colour: RGB, minimum: Double = Contrast.graphic, on backdrop: IslandBackdrop = .island) -> RGB {
        if isDefault { return colour }
        let minimum = minimum >= Contrast.text ? max(minimum, wordFloor) : minimum
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
            let fit = Contrast.fitted(colour, floor: minimum, on: colours(of: backdrop), ink: ink)
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
        SystemHue.guarded.first { hue in
            stops.contains { $0.couldBeTaken(for: hue.dark) } && fitted(hue.dark) != hue.dark
        }
    }

    // MARK: Paint

    /// How the island is painted.
    var paintStyle: IslandPaintStyle {
        switch fill {
        case .solid: .solid(island)
        case .gradient(_, _, let direction): .gradient(stops, direction)
        case .rotating(let palette, _, let speed):
            .rotating(stops, period: speed.secondsPerColour * Double(palette.colours.count))
        }
    }

    /// How a bubble beside the island is painted: as the island, where the island's
    /// colours are the same all the way across; otherwise in the colour at the island's
    /// end on the bubble's side.
    func bubblePaintStyle(onLeft: Bool) -> IslandPaintStyle {
        switch fill {
        case .gradient(_, _, let direction) where direction != .down:
            .solid((onLeft ? stops.first : stops.last) ?? island)
        default: paintStyle
        }
    }

    /// The strongest wash of any of `colours` over the island that leaves full ink at
    /// 4.5:1 on every colour it draws: how bright a ring's glow may fall inward.
    func glowCap(for colours: [RGB]) -> Double {
        memo.value(for: .glow(colours)) {
            let under = stride(from: 0, to: samples.count, by: max(1, samples.count / 48)).map { samples[$0] }
            func reads(_ alpha: Double) -> Bool {
                colours.allSatisfy { c in under.allSatisfy { RGB.contrast(ink, c.composited(alpha, over: $0)) >= Contrast.text } }
            }
            guard reads(0) else { return 0 }
            var lo = 0.0, hi = 1.0
            for _ in 0..<Contrast.steps {
                let mid = (lo + hi) / 2
                if reads(mid) { lo = mid } else { hi = mid }
            }
            return lo
        }
    }

    // MARK: Cache

    /// Themes by preference value. A colour picker drag writes many values, so the
    /// cache is emptied when it fills up.
    static func cached(island: RGB, accent: AccentChoice, fill: IslandFill = .solid, opened: Bool = false) -> IslandTheme {
        if island == .black, accent == .featureColours, fill == .solid { return .standard }
        return themes.withLock { cache in
            let key = ThemeKey(island: island, accent: accent, fill: fill, opened: opened)
            if let theme = cache[key] { return theme }
            if cache.count >= 16 { cache.removeAll() }
            let theme = IslandTheme(island: island, accent: accent, fill: fill, opened: opened)
            cache[key] = theme
            return theme
        }
    }

    /// From the stored preferences: "#RRGGBB" for the island, the accent's value, and
    /// the fill's.
    static func cached(islandPref: String, accentPref: String, fillPref: String = IslandFill.standardPref) -> IslandTheme {
        cached(island: RGB(hex: islandPref) ?? .black, accent: AccentChoice(pref: accentPref), fill: IslandFill(pref: fillPref))
    }

    private struct ThemeKey: Hashable {
        let island: RGB
        let accent: AccentChoice
        let fill: IslandFill
        let opened: Bool
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
        case glow([RGB])
        case clear([RGB])
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

/// How an island, a bubble or a count's ring is painted.
enum IslandPaintStyle: Hashable, Sendable {
    case solid(RGB)
    /// A still gradient through the colours.
    case gradient([RGB], IslandGradientDirection)
    /// The colours in turn, fading from each to the next, round and round every `period`
    /// seconds.
    case rotating([RGB], period: Double)
}

extension IslandFill {
    var isRotating: Bool {
        if case .rotating = self { return true }
        return false
    }
}
