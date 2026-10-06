import Foundation

/// What may be in the words a card shows, so what is drawn is what will run. Strict
/// rules for commands, URLs, paths, keys and the header; lenient ones for a file's
/// content, where ordinary writing has more in it. Characters a reader could not see,
/// or that reorder what is drawn, withhold Allow; the card then says to check it in the
/// app.
enum ApprovalText {
    enum Rule {
        case strict
        case lenient
    }

    /// Why the text withholds Allow; `nil` if it does not.
    static func hiddenCharacter(in text: String, rule: Rule) -> Unicode.Scalar? {
        switch rule {
        case .strict: strictProblem(text)
        case .lenient: lenientProblem(text)
        }
    }

    private static func strictProblem(_ text: String) -> Unicode.Scalar? {
        var marks = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x0A || value == 0x09 { marks = 0; continue }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
                return scalar
            case .spaceSeparator where value != 0x20:
                return scalar
            case .nonspacingMark, .enclosingMark:
                marks += 1
                if marks > 2 { return scalar }
            default:
                marks = 0
            }
            if isTagOrSelector(value) || isBlank(value) { return scalar }
        }
        if let host = urlHosts(in: text).first(where: { !$0.unicodeScalars.allSatisfy(\.isASCII) }) {
            return host.unicodeScalars.first { !$0.isASCII }
        }
        return nil
    }

    private static func lenientProblem(_ text: String) -> Unicode.Scalar? {
        text.unicodeScalars.first { scalar in
            let value = scalar.value
            return (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value) || value == 0x1B
                || isTagOrSelector(value) && !(0xFE0E...0xFE0F).contains(value)
        }
    }

    /// Letters drawn as nothing at all (Hangul fillers, the blank Braille pattern, Khmer's
    /// inherent vowels, the null notehead, and whatever Unicode says may be ignored in
    /// drawing, such as the grapheme joiner), which could stand unseen in a command.
    static func isBlank(_ value: UInt32) -> Bool {
        value == 0x115F || value == 0x1160 || value == 0x3164 || value == 0xFFA0 || value == 0x2800
            || value == 0x17B4 || value == 0x17B5 || value == 0x1D159
            || Unicode.Scalar(value)?.properties.isDefaultIgnorableCodePoint == true
    }

    /// Tag characters and variation selectors, which draw as nothing; in lenient text,
    /// the two that pick an emoji's or a symbol's look are let through.
    private static func isTagOrSelector(_ value: UInt32) -> Bool {
        (0xE0000...0xE007F).contains(value) || (0xFE00...0xFE0F).contains(value) || (0xE0100...0xE01EF).contains(value)
    }

    /// Whether `url` could be read as going to more than one place: a backslash, which
    /// browsers take for a slash and others do not, or a name and `@` before its host.
    static func isUnclearAddress(_ url: String) -> Bool {
        guard !url.contains("\\") else { return true }
        guard let start = url.range(of: "://") else { return false }
        let rest = url[start.upperBound...]
        let authority = rest.prefix { !"/?#".contains($0) }
        return authority.contains("@")
    }

    /// The hosts of the URLs in `text`, as a browser reads them: a backslash ends the
    /// host as a slash does, so in `https://a.example\@b.example/` the host is
    /// `a.example`.
    static func urlHosts(in text: String) -> [String] {
        let pattern = #"[A-Za-z][A-Za-z0-9+.-]*://(?:[^/\\?#\s@]*@)?(\[[^\]\s]*\]|[^/\\?#:\s'"`)@]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The words in `text` with letters from more than one script, or letters outside
    /// ASCII, which could pass for others: shown highlighted.
    static func lookAlikeWords(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { word in
            let scripts = Set(word.unicodeScalars.compactMap(script))
            return scripts.count > 1 || scripts.contains { $0 != .latin }
                || word.unicodeScalars.contains { !$0.isASCII && $0.properties.isAlphabetic && script($0) == .latin }
        }
    }

    private enum Script { case latin, greek, cyrillic, armenian, other }

    private static func script(_ scalar: Unicode.Scalar) -> Script? {
        guard scalar.properties.isAlphabetic else { return nil }
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: return .latin
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0x400...0x52F: return .cyrillic
        case 0x530...0x58F: return .armenian
        default: return .other
        }
    }

    /// `host` as DNS carries it: each label not in ASCII as punycode (`xn--…`), so a
    /// look-alike name shows for what it is.
    static func asciiHost(_ host: String) -> String {
        host.lowercased().split(separator: ".", omittingEmptySubsequences: false).map { label in
            label.unicodeScalars.allSatisfy(\.isASCII) ? String(label) : "xn--" + punycode(String(label))
        }.joined(separator: ".")
    }

    /// RFC 3492's encoding of a label.
    static func punycode(_ input: String) -> String {
        let (base, tMin, tMax, skew, damp) = (36, 1, 26, 38, 700)
        let scalars = input.unicodeScalars.map { Int($0.value) }
        var output = String(String.UnicodeScalarView(input.unicodeScalars.filter(\.isASCII)))
        let basic = output.unicodeScalars.count
        var handled = basic
        if basic > 0 { output += "-" }
        var n = 128, delta = 0, bias = 72
        func digit(_ d: Int) -> Character { Character(Unicode.Scalar(UInt8(d < 26 ? d + 97 : d + 22))) }
        func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / count
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        while handled < scalars.count {
            let m = scalars.filter { $0 >= n }.min()!
            delta += (m - n) * (handled + 1)
            n = m
            for c in scalars {
                if c < n { delta += 1 }
                guard c == n else { continue }
                var q = delta, k = base
                while true {
                    let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta, handled + 1, handled == basic)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return output
    }
}
