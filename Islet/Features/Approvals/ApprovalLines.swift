import AppKit
import Foundation

/// One part of a card's body: a command, a file's new content, an edit's old or new
/// words, a key the card has no layout for. Drawn as written, every line of it.
struct ApprovalSection: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        /// What the tool is to run or write: its real lines numbered when there are
        /// several.
        case code
        /// The model's own words about it, in secondary text.
        case prose
        /// A setting of the call, `key = value`, in secondary text.
        case field
        /// An edit's words taken out, and put in.
        case removed
        case added
    }

    /// A caption above, or `nil`.
    var label: String?
    var text: String
    var style: Style
    /// Words drawn bold where they appear: a fetched page's host.
    var bold: [String] = []

    var numbered: Bool { style == .code && ApprovalLines.realLines(text).count > 1 }
}

/// A line as drawn: the real line's number on its first part (shown for a numbered
/// section, an edit's `−` or `+` in its place), its text, and whether it carries on in
/// the next line (a soft wrap, drawn with `↩`).
struct ApprovalLine: Equatable, Sendable {
    var number: Int?
    var text: String
    var wraps: Bool
    /// How tall it is drawn: taller than `ApprovalLines.lineHeight` for letters drawn
    /// from a taller face.
    var height: CGFloat = ApprovalLines.lineHeight
}

/// Lays a section's text out in lines of a monospaced face, wrapped at a column so every
/// wrap is known and marked, never left to the text system. Letters the face does not
/// have are drawn from another, wider or taller, so each line is measured as drawn and
/// wrapped sooner, or given more height, where it needs. What a reader could not
/// see (controls, zero-width and format characters, bidi overrides) is drawn as its code
/// point, so the line shows what it holds and in the order it is held.
enum ApprovalLines {
    static let fontSize: CGFloat = 11.5
    static let lineHeight: CGFloat = 15
    static let labelHeight: CGFloat = 14
    static let sectionSpacing: CGFloat = 5
    /// The body's padding inside its wash.
    static let padding: CGFloat = 8

    /// A character's width in the face: 1, or 2 for East Asian wide letters and emoji.
    static let advance: CGFloat = ("M" as NSString).size(withAttributes: [.font: font]).width

    /// The columns of text a line of `width` points holds beside a gutter of `gutter`
    /// columns, with one kept for the wrap mark.
    static func columns(width: CGFloat, gutter: Int) -> Int {
        max(8, Int(((width - 2 * padding) / advance).rounded(.down)) - gutter - 1)
    }

    /// The gutter for `section`: its last line number's digits and a space.
    static func gutter(_ section: ApprovalSection) -> Int {
        guard section.numbered else { return section.style == .removed || section.style == .added ? 2 : 0 }
        return String(realLines(section.text).count).count + 1
    }

    static func lines(_ section: ApprovalSection, width: CGFloat) -> [ApprovalLine] {
        let gutter = gutter(section)
        return lines(section.text, columns: columns(width: width, gutter: gutter))
    }

    static func lines(_ text: String, columns: Int) -> [ApprovalLine] {
        let key = "\(columns)|\(text)" as NSString
        if let kept = laidOut.object(forKey: key) { return kept.lines }
        let room = CGFloat(columns) * advance + 0.5
        var result: [ApprovalLine] = []
        for (index, real) in realLines(text).enumerated() {
            var parts: [(text: String, width: Int)] = []
            var first = true
            // Lines of `parts` as drawn: each as much as fits, measured. The last part of a
            // real line is laid out whole; otherwise what did not fit is handed back, to
            // start the next line.
            func lay(last: Bool) {
                while !parts.isEmpty {
                    var count = parts.count
                    if count > 1, drawn(parts.map(\.text).joined()).width > room {
                        var (low, high) = (1, count - 1)
                        while low < high {
                            let middle = (low + high + 1) / 2
                            if drawn(parts.prefix(middle).map(\.text).joined()).width <= room { low = middle } else { high = middle - 1 }
                        }
                        count = low
                    }
                    let line = parts.prefix(count).map(\.text).joined()
                    parts.removeFirst(count)
                    result.append(ApprovalLine(number: first ? index + 1 : nil, text: line, wraps: !parts.isEmpty || !last,
                                               height: max(lineHeight, drawn(line).height)))
                    first = false
                    if !last { return }
                }
            }
            for character in real {
                let shown = visible(character)
                let width = shown == String(character) ? self.width(of: character) : shown.count
                if parts.reduce(0, { $0 + $1.width }) + width > columns, !parts.isEmpty { lay(last: false) }
                parts.append((shown, width))
            }
            lay(last: true)
            if first { result.append(ApprovalLine(number: index + 1, text: "", wraps: false)) }
        }
        laidOut.setObject(LaidOut(lines: result), forKey: key)
        return result
    }

    private final class LaidOut: NSObject {
        let lines: [ApprovalLine]
        init(lines: [ApprovalLine]) { self.lines = lines }
    }

    /// Texts laid out lately: a card's body is laid out for its height and again as drawn.
    private static let laidOut: NSCache<NSString, LaidOut> = {
        let cache = NSCache<NSString, LaidOut>()
        cache.countLimit = 64
        return cache
    }()

    static let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

    /// How wide and tall `text` is drawn in the face, other faces standing in for the
    /// letters it lacks.
    static func drawn(_ text: String) -> CGSize {
        guard !text.isEmpty else { return CGSize(width: 0, height: lineHeight) }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return CGSize(width: CGFloat(width), height: (ascent + descent + leading).rounded(.up))
    }

    /// The real lines of `text`; one ended by `\r\n` keeps a `␍` at its end, drawn as
    /// the return it holds.
    static func realLines(_ text: String) -> [String] {
        var lines: [String] = []
        var line = ""
        for character in text {
            if character == "\n" || character == "\r\n" {
                lines.append(character == "\r\n" ? line + "\u{240D}" : line)
                line = ""
            } else {
                line.append(character)
            }
        }
        lines.append(line)
        return lines
    }

    /// The height of `sections` laid out at `width`, padding included.
    static func height(_ sections: [ApprovalSection], width: CGFloat) -> CGFloat {
        guard !sections.isEmpty else { return 2 * padding }
        let parts = sections.map { section in
            (section.label == nil ? 0 : labelHeight) + lines(section, width: width).map(\.height).reduce(0, +)
        }
        return parts.reduce(0, +) + CGFloat(sections.count - 1) * sectionSpacing + 2 * padding
    }

    /// `character` as drawn: itself, or for what a reader could not see, its code points
    /// (`‹U+202E›`). An emoji keeps its joiners and selectors; a tab is an arrow and
    /// spaces; a letter with more than two marks above it has the marks spelt out.
    static func visible(_ character: Character) -> String {
        if character == "\t" { return "⇥   " }
        let scalars = character.unicodeScalars
        if isEmoji(character) { return String(character) }
        let marks = scalars.filter { $0.properties.generalCategory == .nonspacingMark }.count
        guard scalars.contains(where: { hidden($0) }) || marks > 2 else { return String(character) }
        return scalars.map { scalar in
            hidden(scalar) || (marks > 2 && scalar.properties.generalCategory == .nonspacingMark)
                ? "‹U+" + String(format: "%04X", scalar.value) + "›" : String(scalar)
        }.joined()
    }

    /// Whether `character` is an emoji drawn as one: shown as an emoji by itself, or
    /// asked to be by its selector or a keycap, every joiner in it between two emoji
    /// that are not digits or `#` and `*` (which Unicode counts as emoji too).
    static func isEmoji(_ character: Character) -> Bool {
        let scalars = Array(character.unicodeScalars)
        guard let first = scalars.first, first.properties.isEmoji else { return false }
        let pictured = first.properties.isEmojiPresentation || scalars.contains { $0.value == 0xFE0F }
            || scalars.last?.value == 0x20E3
        guard pictured else { return false }
        for (index, scalar) in scalars.enumerated() {
            switch scalar.value {
            case 0xFE0F, 0x20E3: continue
            case 0x200D:
                guard index > 0, index + 1 < scalars.count else { return false }
                let before = scalars[index - 1], after = scalars[index + 1]
                let emoji = { (s: Unicode.Scalar) in s.properties.isEmoji && !s.isASCII }
                guard emoji(after), emoji(before) || before.value == 0xFE0F else { return false }
            default:
                if hidden(scalar) { return false }
            }
        }
        return true
    }

    private static func hidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: true
        case .spaceSeparator: scalar.value != 0x20
        default: (0xFE00...0xFE0F).contains(scalar.value) || (0xE0000...0xE01EF).contains(scalar.value)
            || ApprovalText.isBlank(scalar.value)
        }
    }

    private static func width(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        if scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && character.unicodeScalars.count > 1) {
            return 2
        }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
