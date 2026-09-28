import AppKit
import SwiftUI

/// A banner someone else asked for — a shortcut, a script, a Claude Code hook — through
/// `islet://banner?…` or the Show in Islet action.
///
/// Whatever asked, everything in it has been checked by the time it exists: the text is
/// plain, on one line, trimmed and cut to length; the symbol is one macOS draws; the
/// colour is kept as given and fitted to the island as it is drawn. It carries text and
/// nothing else. Any app
/// on the Mac can open a URL, so a banner from one must not offer a link or a button,
/// which could pass for one of Islet's own and send a click somewhere it should not go.
struct CustomBanner: Equatable {
    var title: String
    var subtitle: String?
    /// An SF Symbol's name, known to exist.
    var symbol: String
    /// `nil` draws the symbol in the island's ink (white on the black island), or the
    /// accent, and the subtitle in grey.
    var tint: BannerTint?
    var duration: TimeInterval
    var style: BannerStyle
    /// A system sound's name (`Glass`, `Ping`), or `nil` for none. Banners are silent
    /// unless a sound is asked for.
    var sound: String?
    /// Active unless asked otherwise: a script's banner is something its person set up
    /// to hear about. Only a passive one gives way to a Focus that asks for quiet.
    var interruption: BannerInterruption

    static let defaultSymbol = "bell.fill"
    /// Longer than either style shows whole; the limits only stop a script from handing
    /// the island a novel to lay out.
    static let titleLimit = 60
    static let subtitleLimit = 120
    static let durationRange: ClosedRange<TimeInterval> = 1...30

    /// The sounds in /System/Library/Sounds. Only these are played: a name is looked up
    /// in the user's own sound folders too, and a banner's sound is meant to be one of
    /// the Mac's alert sounds, not any file a script can put there.
    static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    /// Long enough to read a title at a glance; a card, with more to read, stays longer.
    static func defaultDuration(for style: BannerStyle) -> TimeInterval {
        switch style {
        case .compact: 4
        case .card: 6
        }
    }
}

extension CustomBanner {
    /// Checks and cleans everything it is given. `nil` when nothing is left of the
    /// title: a banner has to say something. Anything else that does not check out
    /// falls back to its default rather than turning the banner away.
    init?(
        title: String?,
        subtitle: String? = nil,
        symbol: String? = nil,
        tint: BannerTint? = nil,
        duration: TimeInterval? = nil,
        style: BannerStyle = .compact,
        sound: String? = nil,
        interruption: BannerInterruption = .active
    ) {
        guard let title = Self.clean(title, limit: Self.titleLimit) else { return nil }
        self.init(
            title: title,
            subtitle: Self.clean(subtitle, limit: Self.subtitleLimit),
            symbol: Self.validSymbol(symbol),
            tint: tint,
            duration: Self.clampedDuration(duration, style: style),
            style: style,
            sound: Self.systemSound(named: sound),
            interruption: interruption
        )
    }

    /// Plain text on one line. Control characters, line breaks and runs of white space
    /// become single spaces; the invisible marks that reorder text (a right-to-left
    /// override, say) are dropped, since they can make a banner read differently from
    /// what it holds, and so are private-use characters, which draw whatever a font puts
    /// there (Apple's logo, in the Mac's own); the ends are trimmed; and anything over
    /// `limit` characters is cut, with an ellipsis. Characters are counted as people see
    /// them, so an emoji is one.
    ///
    /// `nil` when nothing is left that can be seen: text made only of zero-width spaces,
    /// joiners and the like would put up a banner with nothing on it.
    ///
    /// A character as people see it can hold any number of code points, so each is kept
    /// to a size real text has: accents stacked a few high at most, where a script
    /// piling up hundreds draws a smear from the top of the island to the bottom, and no
    /// character longer than the longest emoji, where hundreds of emoji joined into one
    /// run past the end of a card with nothing to cut. Only the start of the text is
    /// read, so a script that sends megabytes does not hold up the island reading them.
    static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        var marks = 0
        for scalar in text.unicodeScalars.prefix(limit * readPerCharacter) {
            let properties = scalar.properties
            if isReordering(scalar) || properties.generalCategory == .privateUse { continue }
            if properties.isWhitespace || properties.generalCategory == .control {
                pendingSpace = !scalars.isEmpty
                marks = 0
                continue
            }
            switch properties.generalCategory {
            case .nonspacingMark, .enclosingMark:
                marks += 1
                if marks > maximumMarks { continue }
            default:
                marks = 0
            }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        var cleaned = String(scalars)
        // Dropping a character can join its neighbours into another (emoji either side
        // of a joiner), so this goes again until none is left; each pass drops at least one.
        while cleaned.contains(where: { $0.unicodeScalars.count > maximumScalarsPerCharacter }) {
            cleaned = String(cleaned.filter { $0.unicodeScalars.count <= maximumScalarsPerCharacter })
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard cleaned.unicodeScalars.contains(where: isVisible) else { return nil }
        guard cleaned.count > limit else { return cleaned }
        let cut = String(cleaned.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }

    /// Accents on one letter. Written languages put two or three on a letter at most
    /// (Vietnamese, Thai, pointed Hebrew); an emoji's keycap and style take two.
    static let maximumMarks = 3
    /// Code points in one character: the longest emoji (a couple, each with a skin
    /// tone, kissing) has ten, and a flag of a region, seven.
    static let maximumScalarsPerCharacter = 16
    /// Code points read for each character a banner keeps, which leaves room for the
    /// white space, accents and joiners that cleaning takes out.
    static let readPerCharacter = 32

    /// The bidirectional marks, embeddings, overrides and isolates.
    private static func isReordering(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    /// Whether `scalar` draws something on its own. Not white space, formatting
    /// (joiners, zero-width spaces, tags), anything Unicode says to draw as nothing
    /// (variation selectors, the Hangul fillers), an accent with no letter under it, or
    /// the blank braille pattern, a symbol that draws nothing.
    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .control, .format, .privateUse, .surrogate, .nonspacingMark, .spaceSeparator,
             .lineSeparator, .paragraphSeparator:
            return false
        default:
            return !properties.isWhitespace && !properties.isDefaultIgnorableCodePoint && scalar.value != 0x2800
        }
    }

    /// The symbol asked for, if macOS has one by that name and it is not one of Apple's
    /// own marks, or the bell. Names are lower case letters, digits and dots, and none
    /// is longer than 100 characters; anything else is not looked up at all.
    static func validSymbol(_ name: String?) -> String {
        guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(),
              !name.isEmpty, name.count <= 100,
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." }),
              !isReserved(name),
              NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        else { return defaultSymbol }
        return name
    }

    /// Apple's logo, and the marks for Apple's own services (Apple Intelligence,
    /// HomeKit and the rest under `apple.`). A banner under one would read as macOS
    /// speaking, and any app on the Mac can open the URL that puts it up. Terminal's
    /// glyph, which `terminal` also names, is a picture of a window and stays.
    static func isReserved(_ name: String) -> Bool {
        name == "applelogo" || (name.hasPrefix("apple.") && !name.hasPrefix("apple.terminal"))
    }

    /// Seconds, held between one and thirty. Missing or not a number, the style's own.
    static func clampedDuration(_ seconds: TimeInterval?, style: BannerStyle) -> TimeInterval {
        guard let seconds, seconds.isFinite else { return defaultDuration(for: style) }
        return min(max(seconds, durationRange.lowerBound), durationRange.upperBound)
    }

    /// The system sound by that name, whatever its case, or `nil`.
    static func systemSound(named name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return systemSounds.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// How a custom banner takes the island over.
enum BannerStyle: String, CaseIterable, Sendable {
    /// Either side of the notch, as a Focus or a headset announces itself.
    case compact
    /// A card that drops below the notch, with room for a subtitle of a few lines.
    case card
}

// MARK: - URLs

/// What an `islet://banner` URL asks for.
///
///     islet://banner?title=Build%20finished&subtitle=12%20s&symbol=hammer.fill&tint=orange
///     islet://banner/dismiss
///
/// The show URL takes `title` (required), `subtitle`, `symbol`, `tint` (a colour's name,
/// or hex as `ff9500` or `%23ff9500`; `color` and `colour` are read too), `duration` in
/// seconds, `style` (`compact` or `card`), `sound` (a system sound's name) and
/// `interruption` (`passive` lets a Focus hold it back). Names are read in any case, the
/// last of a repeated one wins, and anything unknown is ignored.
enum BannerRequest: Equatable {
    case show(CustomBanner)
    case dismiss

    /// `nil` for a path it does not know, and for a banner with no title.
    init?(url: URL) {
        var path = url.path().lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        switch path {
        case "":
            break
        case "/dismiss":
            self = .dismiss
            return
        default:
            return nil
        }

        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name.lowercased()] = item.value ?? ""
        }

        let style = BannerStyle(rawValue: query["style"]?.lowercased() ?? "") ?? .compact
        guard let banner = CustomBanner(
            title: query["title"],
            subtitle: query["subtitle"],
            symbol: query["symbol"],
            tint: Self.tint(["tint", "colour", "color"].compactMap { query[$0] }, fragment: url.fragment()),
            duration: query["duration"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) },
            style: style,
            sound: query["sound"],
            interruption: query["interruption"]?.lowercased() == "passive" ? .passive : .active
        ) else { return nil }
        self = .show(banner)
    }

    /// The first of `tint`, `colour` and `color` that says something, so an empty one a
    /// script left in (`tint=&colour=red`) does not hide the one it filled in.
    ///
    /// `tint=#34c759` typed as is ends the query at the `#`, leaving the tint empty and
    /// the colour in the URL's fragment. With the tint last, as it usually is, that
    /// colour is still what was meant, so it is taken from there.
    private static func tint(_ values: [String], fragment: String?) -> BannerTint? {
        if let value = values.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return BannerTint(value)
        }
        guard !values.isEmpty, let fragment else { return nil }
        return BannerTint(hex: fragment)
    }
}

// MARK: - Colours

/// The colours a banner can be asked for by name: the system colours the island draws
/// a Focus in, and white.
enum BannerColour: String, CaseIterable, Sendable {
    case white, red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    /// The colour asked for. White is the island's own ink (white on the black island,
    /// black on a light one) whatever the accent.
    var tint: BannerTint? {
        .named(self)
    }

    /// The same colour as one of the island's hues; `nil` for white.
    var hue: SystemHue? {
        SystemHue(rawValue: rawValue)
    }
}

extension FeatureTint {
    /// A banner with no colour of its own: the island's ink, white on the black island.
    static let banner = FeatureTint.neutral
}

/// A banner's colour: its symbol's, and its subtitle's beside the notch. It is the
/// person's, so it never takes the accent: it keeps its hue on every island and is
/// only fitted, darkened or lightened as far as it must be to stand out.
enum BannerTint: Equatable {
    case named(BannerColour)
    /// sRGB components, from 0 to 1, as given.
    case rgb(RGB)

    /// A name (`green`, `grey` too) or hex. `nil` for anything else.
    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let colour = BannerColour(rawValue: text == "grey" ? "gray" : text) {
            self = .named(colour)
        } else {
            self.init(hex: text)
        }
    }

    /// `#rgb` or `#rrggbb`, the `#` optional, kept as given: it is fitted to the island
    /// only as it is drawn.
    init?(hex text: String) {
        var hex = Substring(text.trimmingCharacters(in: .whitespaces))
        if hex.hasPrefix("#") { hex = hex.dropFirst() }
        guard hex.count == 3 || hex.count == 6, hex.allSatisfy(\.isASCII), hex.allSatisfy(\.isHexDigit),
              var value = UInt32(hex, radix: 16)
        else { return nil }
        if hex.count == 3 {
            // #f90 is #ff9900: each digit doubled.
            let r = value >> 8 & 0xF, g = value >> 4 & 0xF, b = value & 0xF
            value = (r * 17) << 16 | (g * 17) << 8 | b * 17
        }
        self = .rgb(RGB(hex: value))
    }

    /// What the banner's symbol (`minimum` 3:1) or subtitle (4.5:1) is drawn in on
    /// `theme`'s island, against `backdrop`. A named colour is one of the island's hues;
    /// white is the island's ink for the symbol, and the subtitle is the grey of a banner
    /// with no colour, as it always was.
    /// A hex colour is fitted against the island as it is drawn; on the black island it
    /// starts from what it always was there, lifted just enough to stand out on black,
    /// so the accent never changes it.
    func ink(minimum: Double, on backdrop: IslandBackdrop = .island, in theme: IslandTheme) -> IslandInk {
        switch self {
        case .named(let colour):
            guard let hue = colour.hue else {
                return minimum >= Contrast.text ? .text(0.6, on: backdrop) : .graphic(1, on: backdrop)
            }
            return .hue(hue, minimum: minimum, on: backdrop)
        case .rgb(let colour):
            return .fitted(theme.island == RGB.black ? Self.lifted(colour) : colour, minimum: minimum, on: backdrop)
        }
    }

    typealias Components = (red: Double, green: Double, blue: Double)

    /// The least relative luminance a colour keeps: the system indigo's, the darkest of
    /// the named colours, which has about four times black's contrast.
    static let minimumLuminance = 0.15

    /// `colour`, or where it is darker than the minimum, as little white mixed in as
    /// brings it there: a colour too dark to make out on black (black itself, a navy,
    /// even pure blue) mixed with white, which keeps its hue, until it stands out as
    /// well as the system's own indigo does.
    static func lifted(_ colour: RGB) -> RGB {
        let lifted = lifted((colour.red, colour.green, colour.blue))
        return RGB(lifted.red, lifted.green, lifted.blue)
    }

    static func lifted(_ colour: Components) -> Components {
        func mixed(_ amount: Double) -> Components {
            (
                colour.red + (1 - colour.red) * amount,
                colour.green + (1 - colour.green) * amount,
                colour.blue + (1 - colour.blue) * amount
            )
        }
        guard luminance(colour) < minimumLuminance else { return colour }
        // Luminance only grows with white mixed in, so halving the range homes in on
        // the least amount that is enough.
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if luminance(mixed(middle)) < minimumLuminance { low = middle } else { high = middle }
        }
        return mixed(high)
    }

    /// Relative luminance, as WCAG defines it for sRGB.
    static func luminance(_ colour: Components) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(colour.red) + 0.7152 * linear(colour.green) + 0.0722 * linear(colour.blue)
    }
}
