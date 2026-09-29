import AppKit
import SwiftUI

/// A colour as three sRGB components in 0...1: what the island's colours are worked out
/// in. Drawing one at an opacity over another mixes their encoded values, which is what
/// SwiftUI's `.opacity(_:)` does on screen, so the sums below match what is drawn.
struct RGB: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From 8-bit components, as today's `x / 255` literals give them. Labelled, so
    /// `RGB(1, 1, 1)` can never be read as three bytes.
    init(bytes red255: Int, _ green255: Int, _ blue255: Int) {
        self.init(Double(red255) / 255, Double(green255) / 255, Double(blue255) / 255)
    }

    /// `0xRRGGBB`.
    init(hex: UInt32) {
        self.init(bytes: Int(hex >> 16 & 0xFF), Int(hex >> 8 & 0xFF), Int(hex & 0xFF))
    }

    /// "#RRGGBB" or "RRGGBB", as stored in preferences.
    init?(hex text: String) {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// Any colour AppKit can express in sRGB (a picked colour, a system colour).
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(
            min(max(Double(srgb.redComponent), 0), 1),
            min(max(Double(srgb.greenComponent), 0), 1),
            min(max(Double(srgb.blueComponent), 0), 1)
        )
    }

    static let black = RGB(0.0, 0.0, 0.0)
    static let white = RGB(1.0, 1.0, 1.0)

    /// "#RRGGBB", rounded to the nearest 8-bit step.
    var hex: String {
        func byte(_ c: Double) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var cgColor: CGColor { nsColor.cgColor }

    /// Relative luminance, as WCAG defines it for sRGB.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio between two colours, from 1 to 21.
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// This colour at `alpha` drawn over the opaque `base`.
    func composited(_ alpha: Double, over base: RGB) -> RGB {
        RGB(red * alpha + base.red * (1 - alpha),
            green * alpha + base.green * (1 - alpha),
            blue * alpha + base.blue * (1 - alpha))
    }

    /// This colour moved toward `other` by `amount` (0 is this colour, 1 is `other`).
    /// Moving toward white or black keeps the hue and changes only the lightness.
    func mixed(toward other: RGB, _ amount: Double) -> RGB {
        RGB(red + (other.red - red) * amount,
            green + (other.green - green) * amount,
            blue + (other.blue - blue) * amount)
    }

    /// How coloured this is: the spread between its strongest and weakest component,
    /// 0 for a grey. Under about 0.2 a colour reads as grey, black or white rather than
    /// as its hue.
    var chroma: Double { max(red, green, blue) - min(red, green, blue) }

    /// Hue in degrees and saturation, HSV-style: for telling whether two colours look
    /// alike, as a picked accent and the camera's green do.
    var hueAndSaturation: (hue: Double, saturation: Double) {
        let hi = max(red, green, blue), lo = min(red, green, blue)
        let delta = hi - lo
        guard hi > 0, delta > 0 else { return (0, 0) }
        var hue: Double
        if hi == red {
            hue = (green - blue) / delta
        } else if hi == green {
            hue = 2 + (blue - red) / delta
        } else {
            hue = 4 + (red - green) / delta
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, delta / hi)
    }

    /// Whether this colour could be taken for `other`: both clearly saturated, and
    /// within 25° of hue of each other.
    func couldBeTaken(for other: RGB) -> Bool {
        let a = hueAndSaturation, b = other.hueAndSaturation
        let apart = abs(a.hue - b.hue).truncatingRemainder(dividingBy: 360)
        return a.saturation > 0.35 && b.saturation > 0.35 && min(apart, 360 - apart) < 25
    }
}

/// The contrast the island keeps, and the searches that find the least change reaching
/// it. Each search is a bisection of 24 steps, finer than one 8-bit step.
enum Contrast {
    /// WCAG 1.4.3, for words.
    static let text = 4.5
    /// WCAG 1.4.11, for symbols, rings, progress and meaningful strokes.
    static let graphic = 3.0
    /// The chroma under which a colour no longer reads as its hue. Words in a colour
    /// above it that could reach 4.5:1 only by falling under it, and by losing more than
    /// half their colour on the way, are drawn in the ink instead.
    static let leastChroma = 0.2
    static let steps = 24

    /// White or black, whichever stands out more against `background`. The crossover
    /// is at a relative luminance of about 0.179, where both give about 4.58:1, so full
    /// ink always meets 4.5:1 on the colour it was chosen for.
    static func ink(on background: RGB) -> RGB {
        RGB.contrast(.white, background) >= RGB.contrast(.black, background) ? .white : .black
    }

    /// The least opacity of `ink` over `surface` that reaches `floor`; 1 if even full
    /// ink can't.
    static func minAlpha(_ ink: RGB, on surface: RGB, floor: Double) -> Double {
        guard RGB.contrast(ink, surface) >= floor else { return 1 }
        var lo = 0.0, hi = 1.0
        for _ in 0..<steps {
            let mid = (lo + hi) / 2
            if RGB.contrast(ink.composited(mid, over: surface), surface) >= floor { hi = mid } else { lo = mid }
        }
        return hi
    }

    /// The strongest wash of `ink` over `base` that still leaves full ink at 4.5:1 on
    /// it: how far a card or chip can move toward the ink before its words suffer.
    static func maxSurfaceAlpha(_ ink: RGB, over base: RGB) -> Double {
        guard RGB.contrast(ink, ink.composited(0, over: base)) >= text else { return 0 }
        var lo = 0.0, hi = 1.0
        for _ in 0..<steps {
            let mid = (lo + hi) / 2
            if RGB.contrast(ink, ink.composited(mid, over: base)) >= text { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// `colour` unchanged if it already reaches `floor` against `surface`; otherwise
    /// moved toward `ink` only as far as it needs, which keeps its hue.
    static func fitted(_ colour: RGB, floor: Double, on surface: RGB, ink: RGB) -> RGB {
        guard RGB.contrast(colour, surface) < floor else { return colour }
        var lo = 0.0, hi = 1.0
        for _ in 0..<steps {
            let mid = (lo + hi) / 2
            if RGB.contrast(colour.mixed(toward: ink, mid), surface) >= floor { hi = mid } else { lo = mid }
        }
        return colour.mixed(toward: ink, hi)
    }

    // MARK: Over several colours

    // A fill of several colours (a gradient, or colours fading one into the next) is
    // judged against every colour it draws. Each form below is its one-colour namesake
    // for a single colour, so a solid island works out exactly what it always has.

    /// The least opacity of `ink` that reaches `floor` on every one of `surfaces`.
    static func minAlpha(_ ink: RGB, on surfaces: [RGB], floor: Double) -> Double {
        if surfaces.count == 1 { return minAlpha(ink, on: surfaces[0], floor: floor) }
        return surfaces.map { minAlpha(ink, on: $0, floor: floor) }.max() ?? 1
    }

    /// The strongest wash of `ink` that leaves full ink at 4.5:1 over every one of `bases`.
    static func maxSurfaceAlpha(_ ink: RGB, over bases: [RGB]) -> Double {
        if bases.count == 1 { return maxSurfaceAlpha(ink, over: bases[0]) }
        return bases.map { maxSurfaceAlpha(ink, over: $0) }.min() ?? 0
    }

    /// `colour` moved toward `ink` only as far as it needs to reach `floor` against every
    /// one of `surfaces`. An opaque colour's contrast depends on luminance alone, so only
    /// the darkest and the lightest of them can decide it.
    static func fitted(_ colour: RGB, floor: Double, on surfaces: [RGB], ink: RGB) -> RGB {
        if surfaces.count == 1 { return fitted(colour, floor: floor, on: surfaces[0], ink: ink) }
        let ends = extremes(of: surfaces)
        func passes(_ c: RGB) -> Bool { ends.allSatisfy { RGB.contrast(c, $0) >= floor } }
        guard !passes(colour) else { return colour }
        var lo = 0.0, hi = 1.0
        for _ in 0..<steps {
            let mid = (lo + hi) / 2
            if passes(colour.mixed(toward: ink, mid)) { hi = mid } else { lo = mid }
        }
        return colour.mixed(toward: ink, hi)
    }

    /// The darkest and the lightest of `colours`.
    static func extremes(of colours: [RGB]) -> [RGB] {
        guard let darkest = colours.min(by: { $0.luminance < $1.luminance }),
              let lightest = colours.max(by: { $0.luminance < $1.luminance }) else { return [] }
        return [darkest, lightest]
    }

    /// `colour` unchanged if `ink` already reaches `target` on it; otherwise moved away
    /// from the ink, toward black under white words or white under black ones, only as far
    /// as it needs. How a multi-colour fill's colours are deepened or brightened.
    static func fittedAway(_ colour: RGB, from ink: RGB, to target: Double) -> RGB {
        guard RGB.contrast(ink, colour) < target else { return colour }
        let away: RGB = ink == .white ? .black : .white
        var lo = 0.0, hi = 1.0
        for _ in 0..<steps {
            let mid = (lo + hi) / 2
            if RGB.contrast(ink, colour.mixed(toward: away, mid)) >= target { hi = mid } else { lo = mid }
        }
        return colour.mixed(toward: away, hi)
    }

    /// Words on a filled button or badge: black or white, whichever is clearer. If
    /// neither reaches 4.5:1, the fill is moved away from the label until it does; the
    /// label stays pure black or white.
    static func onFill(_ fill: RGB) -> (label: RGB, fill: RGB) {
        let label = ink(on: fill)
        guard RGB.contrast(label, fill) < text else { return (label, fill) }
        let away: RGB = label == .white ? .black : .white
        var lo = 0.0, hi = 1.0
        for _ in 0..<steps {
            let mid = (lo + hi) / 2
            if RGB.contrast(label, fill.mixed(toward: away, mid)) >= text { hi = mid } else { lo = mid }
        }
        return (label, fill.mixed(toward: away, hi))
    }
}
