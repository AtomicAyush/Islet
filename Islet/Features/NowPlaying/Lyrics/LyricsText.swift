import Foundation

/// One line of a song's timed lyrics: when it is sung, and what. An empty line marks
/// a pause, often an instrumental break.
struct LyricsLine: Equatable, Codable, Sendable {
    /// Seconds from the start of the song.
    var time: TimeInterval
    var text: String
}

/// Reads lyrics as LRCLIB hands them over: timed ones in the LRC format, plain ones
/// as they were typed.
///
/// LRC files come from many hands and many tools, so the reader is forgiving: any
/// number of timestamps before a line (a chorus written once for each time it is
/// sung), minutes of any length, seconds with no fraction or one of one to three
/// digits after a point or a colon, an `[offset:]` tag, other tags such as `[ar:]`
/// and `[length:]` skipped, per-word timestamps (`<00:12.34>`) removed, a byte order
/// mark, and Windows or old Mac line endings. Lines without a timestamp are not part
/// of the timed lyrics and are left out.
enum LyricsText {
    /// The timed lines, in the order they are sung. Two lines at the same moment keep
    /// the order they were written in. Empty when nothing in `text` is timed.
    static func synced(_ text: String) -> [LyricsLine] {
        var stamped: [(line: LyricsLine, order: Int)] = []
        var offset: TimeInterval = 0
        for raw in lines(of: text) {
            var rest = Substring(raw).drop { $0 == " " || $0 == "\t" }
            var times: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let inner = rest[rest.index(after: rest.startIndex)..<close]
                if let time = timestamp(inner) {
                    times.append(time)
                    rest = rest[rest.index(after: close)...]
                } else {
                    // A tag, not a time: only an offset matters. Anything else in
                    // square brackets after a time is part of the words.
                    if times.isEmpty, let value = tag("offset", in: inner), let milliseconds = Double(value) {
                        offset = milliseconds / 1000
                    }
                    break
                }
            }
            guard !times.isEmpty else { continue }
            let words = clean(String(rest))
            for time in times {
                stamped.append((LyricsLine(time: time, text: words), stamped.count))
            }
        }
        // A positive offset makes the words come sooner, as the format defines it.
        return stamped
            .sorted { ($0.line.time, $0.order) < ($1.line.time, $1.order) }
            .map { LyricsLine(time: max(0, $0.line.time - offset), text: $0.line.text) }
    }

    /// Plain lyrics as lines, with one empty line between verses however many there
    /// were, and none at either end. Any timestamps are taken off, for plain lyrics
    /// made from timed ones.
    static func plain(_ text: String) -> [String] {
        var result: [String] = []
        for raw in lines(of: text) {
            var rest = Substring(raw)
            while rest.first == "[", let close = rest.firstIndex(of: "]"),
                  timestamp(rest[rest.index(after: rest.startIndex)..<close]) != nil {
                rest = rest[rest.index(after: close)...]
            }
            let line = clean(String(rest))
            if line.isEmpty {
                if let last = result.last, !last.isEmpty { result.append("") }
            } else {
                result.append(line)
            }
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    /// The lines of `text`, whichever line endings it uses, without a byte order mark.
    private static func lines(of text: String) -> [Substring] {
        text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    /// `mm:ss`, `mm:ss.x` to `mm:ss.xxx`, `mm:ss:xx`, and `h:mm:ss.xx`, in seconds.
    /// `nil` for anything else, such as a tag.
    static func timestamp(_ text: Substring) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        func whole(_ part: Substring) -> Double? {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit) else { return nil }
            return Double(part)
        }
        /// Seconds with an optional fraction: "07", "07.5", "07.45", "07.450".
        func seconds(_ part: Substring) -> Double? {
            let pieces = part.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count <= 2, let whole = whole(pieces[0]) else { return nil }
            guard pieces.count == 2 else { return whole }
            guard let fraction = self.fraction(pieces[1]) else { return nil }
            return whole + fraction
        }
        if parts.count == 2 {
            guard let minutes = whole(parts[0]), let seconds = seconds(parts[1]) else { return nil }
            return minutes * 60 + seconds
        }
        if parts[2].contains(".") {
            guard let hours = whole(parts[0]), let minutes = whole(parts[1]), let seconds = seconds(parts[2])
            else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        }
        // An older way of writing the hundredths, after a colon.
        guard let minutes = whole(parts[0]), let seconds = whole(parts[1]), let fraction = fraction(parts[2])
        else { return nil }
        return minutes * 60 + seconds + fraction
    }

    /// One to three digits after the point, as a fraction of a second.
    private static func fraction(_ digits: Substring) -> Double? {
        guard (1...3).contains(digits.count), digits.allSatisfy(\.isASCIIDigit) else { return nil }
        return Double("0." + digits)
    }

    /// The value of `[name:value]`, for the tag `name`, in any case.
    private static func tag(_ name: String, in inner: Substring) -> String? {
        guard let colon = inner.firstIndex(of: ":"),
              inner[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name
        else { return nil }
        return inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    /// Whether `text` reads right to left, as Hebrew and Arabic do: by its first letter
    /// with a direction of its own, as Unicode's bidirectional algorithm decides a
    /// paragraph's direction. Digits, punctuation and spaces have none, so a line opening
    /// with a number or a quote goes by the first word after it.
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if rightToLeftScripts.contains(where: { $0.contains(scalar.value) }) { return true }
            if scalar.properties.isAlphabetic { return false }
        }
        return false
    }

    /// Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic and Arabic's extended
    /// blocks, and their presentation forms.
    private static let rightToLeftScripts: [ClosedRange<UInt32>] = [
        0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFC, 0x10800...0x10FFF, 0x1E800...0x1EFFF,
    ]

    /// Without per-word timestamps, and with runs of spaces made one.
    private static func clean(_ line: String) -> String {
        var words = line
        var from = words.startIndex
        while let open = words.range(of: "<", range: from..<words.endIndex),
              let close = words.range(of: ">", range: open.upperBound..<words.endIndex) {
            if timestamp(words[open.upperBound..<close.lowerBound]) != nil {
                // Counted, since changing the words invalidates their indices.
                let at = words.distance(from: words.startIndex, to: open.lowerBound)
                words.replaceSubrange(open.lowerBound..<close.upperBound, with: " ")
                from = words.index(words.startIndex, offsetBy: at)
            } else {
                // A "<" that is part of the words.
                from = open.upperBound
            }
        }
        return words.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// A song's timed lines as the panel lists them and the island sings them: each line
/// with when it starts and when the island lets it go, and the instrumental breaks
/// long enough to mark.
///
/// A pause shorter than `minimumBreak` is not a break: the line before it stays until
/// the next one, so the island does not fold away and come back between two phrases. A
/// longer one, marked with an empty line or simply a long wait, gets a row of its own
/// (a note in the panel, nothing in the island). A line is sung for `maximumHold` at
/// most, since a file that marks no break would otherwise leave its last line up
/// through a long solo, or the whole of the outro.
struct LyricsTimeline: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        /// Its place among the rows.
        let id: Int
        let time: TimeInterval
        /// `nil` for an instrumental break.
        let text: String?
        /// When the island stops showing it, however long until the next row.
        let end: TimeInterval
        /// The words read right to left (see `LyricsText.isRightToLeft(_:)`), so the
        /// panel sets them from the right and the island scrolls them the other way.
        let isRightToLeft: Bool

        var isBreak: Bool { text == nil }
    }

    static let minimumBreak: TimeInterval = 4
    static let maximumHold: TimeInterval = 15

    let rows: [Row]

    init(_ lines: [LyricsLine]) {
        // Lines sung at the same moment (a duet written twice, a translation) share
        // a row; an empty line there says nothing.
        var events: [(time: TimeInterval, text: String?)] = []
        for line in lines.enumerated().sorted(by: { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }).map(\.element) {
            let text = line.text.isEmpty ? nil : line.text
            if let last = events.last, abs(last.time - line.time) < 0.001 {
                if let text { events[events.count - 1].text = last.text.map { $0 + "\n" + text } ?? text }
                continue
            }
            events.append((line.time, text))
        }

        var rows: [(time: TimeInterval, text: String?, end: TimeInterval)] = []
        let sung = events.indices.filter { events[$0].text != nil }
        if let first = sung.first, events[first].time >= Self.minimumBreak {
            rows.append((0, nil, events[first].time))
        }
        for (place, index) in sung.enumerated() {
            let event = events[index]
            let next = place + 1 < sung.count ? sung[place + 1] : nil
            let nextTime = next.map { events[$0].time }
            // The first empty line after it, before the next sung line.
            let marker = events[(index + 1)..<(next ?? events.endIndex)].first?.time
            var end: TimeInterval
            if let marker, (nextTime ?? .infinity) - marker >= Self.minimumBreak {
                end = marker
            } else {
                end = nextTime ?? marker ?? .infinity
            }
            end = min(end, event.time + Self.maximumHold)
            // Held to the next line after all when what is left is too short a break.
            if let nextTime, nextTime - end < Self.minimumBreak { end = nextTime }
            rows.append((event.time, event.text, end))
            // Time with nothing sung before the next line, marked or not.
            if let nextTime, nextTime - end >= Self.minimumBreak {
                rows.append((end, nil, nextTime))
            }
        }
        self.rows = rows.enumerated().map { place, row in
            Row(id: place, time: row.time, text: row.text, end: row.end,
                isRightToLeft: row.text.map(LyricsText.isRightToLeft) ?? false)
        }
    }

    var isEmpty: Bool { rows.isEmpty }

    /// The row current at `position` (seconds into the song): the last to have started.
    /// `nil` before the first.
    func row(at position: TimeInterval) -> Int? {
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].time <= position { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    /// The line the island shows at `position`: the current row while it is words
    /// and not yet let go. `nil` in a break, before the first line and after the last.
    func singing(at position: TimeInterval) -> Int? {
        guard let index = row(at: position), let row = rows[safe: index], !row.isBreak, position < row.end
        else { return nil }
        return index
    }

    /// The next moment after `position` when either answer changes: the next row
    /// starting, or the current one being let go. `nil` once nothing changes again.
    func nextChange(after position: TimeInterval) -> TimeInterval? {
        let current = row(at: position)
        let next = rows[safe: (current ?? -1) + 1]?.time
        let end = current.flatMap { rows[$0].end > position && rows[$0].end.isFinite ? rows[$0].end : nil }
        switch (next, end) {
        case let (next?, end?): return min(next, end)
        case let (next?, nil): return next
        case let (nil, end?): return end
        case (nil, nil): return nil
        }
    }
}

fileprivate extension Array {
    /// The element at `index`, or `nil` outside the array.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
