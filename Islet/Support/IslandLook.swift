import SwiftUI

/// Appearance › Fill: the island in one colour, a still gradient, or colours fading one
/// into the next. Whatever it is, the island keeps one ink (`IslandTheme`), chosen for
/// every colour the fill passes through, so its words never change colour as it moves.
enum IslandFill: Hashable, Sendable {
    /// The island colour, as chosen. The default.
    case solid
    case gradient(IslandPalette, IslandTone, IslandGradientDirection)
    case rotating(IslandPalette, IslandTone, IslandMotionSpeed)

    /// The stored preference that gives `solid`.
    static let standardPref = "solid"

    /// Reads the stored preference: "solid", "gradient;<palette>;<tone>;<direction>" or
    /// "rotating;<palette>;<tone>;<speed>", where the palette is a preset's name or two to
    /// six "#RRGGBB" joined by commas. Anything else is `solid`.
    init(pref: String) {
        let parts = pref.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let palette = IslandPalette(pref: parts[1]) else {
            self = .solid
            return
        }
        let tone = IslandTone(rawValue: parts[2])
        switch parts[0] {
        case "gradient":
            self = .gradient(palette, tone ?? .auto, IslandGradientDirection(rawValue: parts[3]) ?? .down)
        case "rotating":
            self = .rotating(palette, tone ?? .auto, IslandMotionSpeed(rawValue: parts[3]) ?? .slow)
        default:
            self = .solid
        }
    }

    var prefValue: String {
        switch self {
        case .solid: Self.standardPref
        case .gradient(let p, let t, let d): "gradient;\(p.prefValue);\(t.rawValue);\(d.rawValue)"
        case .rotating(let p, let t, let s): "rotating;\(p.prefValue);\(t.rawValue);\(s.rawValue)"
        }
    }

    var palette: IslandPalette? {
        switch self {
        case .solid: nil
        case .gradient(let p, _, _), .rotating(let p, _, _): p
        }
    }

    var tone: IslandTone? {
        switch self {
        case .solid: nil
        case .gradient(_, let t, _), .rotating(_, let t, _): t
        }
    }

    /// The same fill with another palette, tone, direction or speed, for Settings.
    func with(palette: IslandPalette? = nil, tone: IslandTone? = nil,
              direction: IslandGradientDirection? = nil, speed: IslandMotionSpeed? = nil) -> IslandFill {
        switch self {
        case .solid: self
        case .gradient(let p, let t, let d): .gradient(palette ?? p, tone ?? t, direction ?? d)
        case .rotating(let p, let t, let s): .rotating(palette ?? p, tone ?? t, speed ?? s)
        }
    }
}

/// The colours of a gradient, a rotation or a ring, in order: a preset's, or two to six
/// picked. A rotation fades from the last back to the first.
struct IslandPalette: Hashable, Sendable {
    let preset: IslandPalettePreset?
    let colours: [RGB]

    static let customRange = 2...6

    init(preset: IslandPalettePreset) {
        self.preset = preset
        colours = preset.colours
    }

    /// Two to six picked colours; nil for any other count.
    init?(custom colours: [RGB]) {
        guard Self.customRange.contains(colours.count) else { return nil }
        preset = nil
        self.colours = colours
    }

    init?(pref: String) {
        if let preset = IslandPalettePreset(rawValue: pref) {
            self.init(preset: preset)
            return
        }
        let colours = pref.split(separator: ",").compactMap { RGB(hex: String($0)) }
        guard colours.count == pref.split(separator: ",").count else { return nil }
        self.init(custom: colours)
    }

    var prefValue: String { preset?.rawValue ?? colours.map(\.hex).joined(separator: ",") }

    var name: String { preset?.name ?? "Custom" }
}

/// The palettes offered in Settings. Every one is at its best on a deep island, but for
/// Pastel, which is light by nature.
enum IslandPalettePreset: String, CaseIterable, Identifiable, Sendable {
    case rainbow, sunset, ocean, aurora, ember, night, pastel

    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    var colours: [RGB] {
        switch self {
        case .rainbow: [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x32ADE6, 0x007AFF, 0xAF52DE].map(RGB.init(hex:))
        case .sunset: [0xFF6B6B, 0xFFB86B, 0xC850C0, 0x4158D0].map(RGB.init(hex:))
        case .ocean: [0x0FB9B1, 0x2D98DA, 0x3867D6, 0x8854D0].map(RGB.init(hex:))
        case .aurora: [0x00F5A0, 0x00D9F5, 0x7B61FF].map(RGB.init(hex:))
        case .ember: [0xFF512F, 0xF09819, 0xDD2476].map(RGB.init(hex:))
        case .night: [0x0B1D3A, 0x2A1B4D, 0x0E3B43].map(RGB.init(hex:))
        case .pastel: [0xF9D5E5, 0xD5E8F9, 0xD8F5DF, 0xFFF1C1].map(RGB.init(hex:))
        }
    }

    /// The tone the palette is drawn in until another is chosen.
    var tone: IslandTone { self == .pastel ? .bright : .deep }
}

/// How a multi-colour fill is drawn: deep, under white words, or bright, under black
/// ones. Every colour it passes through is darkened or lightened until the words read
/// clearly on it; `auto` is whichever of the two changes the colours least.
enum IslandTone: String, CaseIterable, Sendable {
    case deep, bright, auto
}

/// Which way a gradient runs: down from the camera housing, across the island from left
/// to right, or from its top left corner to its bottom right.
enum IslandGradientDirection: String, CaseIterable, Sendable {
    case down, across, diagonal

    var title: String { rawValue.capitalized }
}

/// How fast colours move: for a fill, seconds to fade from one colour to the next; for a
/// ring, seconds for a colour to travel once round the island.
enum IslandMotionSpeed: String, CaseIterable, Sendable {
    case slow, medium, fast

    var title: String { rawValue.capitalized }

    var secondsPerColour: Double {
        switch self {
        case .slow: 12
        case .medium: 6
        case .fast: 3
        }
    }

    var secondsPerLap: Double {
        switch self {
        case .slow: 20
        case .medium: 10
        case .fast: 5
        }
    }
}

/// Appearance › Ring: a band of colour round the island's visible edge, like a strip of
/// lights, over whatever fill the island has. Only its colours move, never its
/// brightness, so it never reads as the island asking for attention.
struct IslandRing: Hashable, Sendable {
    enum Colouring: Hashable, Sendable {
        /// One colour, held.
        case steady(RGB)
        /// Colours travelling round the island.
        case rotating(IslandRingPalette)
    }

    var colouring: Colouring
    var speed: IslandMotionSpeed = .slow
    var thickness: IslandRingThickness = .regular
    /// How far the ring's light spreads inward, from none (0) to strong (1).
    var glow: Double = 0.35
    /// 0.4 to 1.
    var brightness: Double = 0.9

    /// The stored preference with no ring, the default.
    static let offPref = "off"
    static let glowRange = 0.0...1.0
    static let brightnessRange = 0.4...1.0

    /// Reads the stored preference: "off", "steady;#RRGGBB;<thickness>;<glow>;<brightness>"
    /// or "rotating;<palette>;<speed>;<thickness>;<glow>;<brightness>", where the palette
    /// is "island", a preset's name, or colours as a fill's are. Anything else is no ring.
    init?(pref: String) {
        let parts = pref.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let tail: ArraySlice<String>
        switch parts.first {
        case "steady" where parts.count == 5:
            guard let colour = RGB(hex: parts[1]) else { return nil }
            colouring = .steady(colour)
            tail = parts[2...]
        case "rotating" where parts.count == 6:
            guard let palette = IslandRingPalette(pref: parts[1]) else { return nil }
            colouring = .rotating(palette)
            speed = IslandMotionSpeed(rawValue: parts[2]) ?? .slow
            tail = parts[3...]
        default:
            return nil
        }
        let values = Array(tail)
        thickness = IslandRingThickness(rawValue: values[0]) ?? .regular
        // "nan" and "inf" read as numbers, and are no more a glow than "abc" is.
        glow = Double(values[1]).flatMap { $0.isFinite ? $0 : nil }.map {
            min(max($0, Self.glowRange.lowerBound), Self.glowRange.upperBound)
        } ?? 0.35
        brightness = Double(values[2]).flatMap { $0.isFinite ? $0 : nil }.map {
            min(max($0, Self.brightnessRange.lowerBound), Self.brightnessRange.upperBound)
        } ?? 0.9
    }

    init(colouring: Colouring) {
        self.colouring = colouring
    }

    var prefValue: String {
        let look = "\(thickness.rawValue);\(String(format: "%.2f", glow));\(String(format: "%.2f", brightness))"
        switch colouring {
        case .steady(let colour): return "steady;\(colour.hex);\(look)"
        case .rotating(let palette): return "rotating;\(palette.prefValue);\(speed.rawValue);\(look)"
        }
    }

    /// The colours drawn round `theme`'s island, as chosen. Only the island's own colours
    /// are changed, lightened on a deep island and darkened on a bright one, so the ring
    /// stands out from the fill it runs round.
    func colours(on theme: IslandTheme) -> [RGB] {
        switch colouring {
        case .steady(let colour): return [colour]
        case .rotating(.palette(let palette)): return palette.colours
        case .rotating(.island):
            guard theme.stops.count > 1 else { return IslandPalettePreset.rainbow.colours }
            // Toward the ink: lighter on a deep island, darker on a bright one.
            return theme.stops.enumerated().filter { $0.offset % 3 == 0 }.map { $0.element.mixed(toward: theme.ink, 0.35) }
        }
    }
}

/// The colours a rotating ring runs through: the island's own, when it has several, or
/// a palette.
enum IslandRingPalette: Hashable, Sendable {
    case island
    case palette(IslandPalette)

    init?(pref: String) {
        if pref == "island" {
            self = .island
        } else if let palette = IslandPalette(pref: pref) {
            self = .palette(palette)
        } else {
            return nil
        }
    }

    var prefValue: String {
        switch self {
        case .island: "island"
        case .palette(let palette): palette.prefValue
        }
    }
}

enum IslandRingThickness: String, CaseIterable, Sendable {
    case thin, regular, bold

    var title: String { rawValue.capitalized }

    var width: CGFloat {
        switch self {
        case .thin: 1.5
        case .regular: 2.5
        case .bold: 3.5
        }
    }
}

extension EnvironmentValues {
    /// The ring round the island, when there is one and the island wears its colours.
    @Entry var islandRing: IslandRing? = nil
}
