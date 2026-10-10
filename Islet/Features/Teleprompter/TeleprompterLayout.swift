import AppKit

/// The script broken into lines at a text size, and the sums that turn a place among
/// the words into a place on screen.
///
/// Lines are broken here rather than by the text view, so the teleprompter knows which
/// word starts each line and can keep the line being read at the eye line. Each line is
/// drawn on its own, at the same size and weight it was measured in, so it fits.
///
/// At a set pace each line takes its words' time, in beats (a beat is a word at the
/// pace), but never less than `shortestLine` of a full line's: a short line, at the end
/// of a paragraph or a cue on its own, holds the eye line a moment rather than racing
/// past, and the scroll's speed changes little from one line to the next. A cue's word
/// counts for `cueBeats`, time to act on it.
struct ScriptLines: Equatable {
    struct Line: Equatable {
        /// The words on the line, as indices into `ScriptText.words`.
        var words: Range<Int>
    }

    let lines: [Line]
    let wordCount: Int
    /// Where each line starts, in beats, and after them the end: line `i` runs from
    /// `beats[i]` to `beats[i + 1]`.
    let beats: [Double]

    /// The least a line takes, as a share of a full line's words.
    static let shortestLine = 0.6
    static let cueBeats = 2.0

    /// Breaks `text` into lines no wider than `width` points, each word measured by
    /// `measure` (its width, with the space after it). A word wider than the line has
    /// one to itself; a paragraph in the script starts a new line.
    init(text: ScriptText, width: CGFloat, measure: (String) -> CGFloat) {
        wordCount = text.wordCount
        var lines: [Line] = []
        var start = 0
        var used: CGFloat = 0
        let space = measure(" ")
        for (index, word) in text.words.enumerated() {
            let wordWidth = measure(word.text)
            let needed = used == 0 ? wordWidth : used + space + wordWidth
            if index > start, word.startsParagraph || needed > width {
                lines.append(Line(words: start..<index))
                start = index
                used = wordWidth
            } else {
                used = needed
            }
        }
        if start < text.wordCount { lines.append(Line(words: start..<text.wordCount)) }
        self.lines = lines
        beats = Self.beats(of: lines, in: text)
    }

    /// Each line's start in beats, and the end.
    private static func beats(of lines: [Line], in text: ScriptText) -> [Double] {
        // A full line's words: the middle count of the lines broken for width, or of all
        // of them where every line is a paragraph of its own.
        let broken = lines.indices.dropLast().filter { !text.words[lines[$0 + 1].words.lowerBound].startsParagraph }
        let counts = (broken.isEmpty ? Array(lines.indices) : broken).map { lines[$0].words.count }.sorted()
        let full = counts.isEmpty ? 1 : Double(counts[counts.count / 2])
        let shortest = max(1, full * shortestLine)
        var beats = [0.0]
        beats.reserveCapacity(lines.count + 1)
        for line in lines {
            let own = line.words.reduce(0.0) { sum, word in sum + (text.words[word].isCue ? cueBeats : 1) }
            beats.append(beats[beats.count - 1] + max(own, shortest))
        }
        return beats
    }

    /// Lines at `size`, measured in the font the page draws them in.
    @MainActor
    init(text: ScriptText, width: CGFloat, size: CGFloat) {
        let font = TeleprompterLayout.font(size: size)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        self.init(text: text, width: width) { NSAttributedString(string: $0, attributes: attributes).size().width.rounded(.up) }
    }

    var isEmpty: Bool { lines.isEmpty }

    /// The line holding word `word`; the last line for the end of the script.
    func line(ofWord word: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        guard word < wordCount else { return lines.count - 1 }
        var low = 0, high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lines[middle].words.lowerBound <= max(0, word) { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Where `word` (fractional, for the pace's steady progress) is as a line and the
    /// part of it read: 2.5 is halfway through the third line. At the end, just past
    /// the last line.
    func linePosition(ofWord word: Double) -> Double {
        guard !lines.isEmpty else { return 0 }
        if word >= Double(wordCount) { return Double(lines.count) }
        let index = line(ofWord: Int(max(0, word)))
        let line = lines[index].words
        let into = (max(0, word) - Double(line.lowerBound)) / Double(max(1, line.count))
        return Double(index) + min(max(into, 0), 1)
    }

    /// The place among the words at line position `position`, the other way about from
    /// `linePosition(ofWord:)`: for scrolling by hand.
    func word(atLinePosition position: Double) -> Double {
        guard !lines.isEmpty else { return 0 }
        let clamped = min(max(position, 0), Double(lines.count))
        let index = Int(clamped.rounded(.down))
        guard index < lines.count else { return Double(wordCount) }
        let line = lines[index].words
        return Double(line.lowerBound) + (clamped - Double(index)) * Double(line.count)
    }

    /// The first word of line `index`, or the end past the last.
    func firstWord(ofLine index: Int) -> Int {
        guard index >= 0 else { return 0 }
        guard index < lines.count else { return wordCount }
        return lines[index].words.lowerBound
    }

    // MARK: Beats

    /// The whole script, in beats.
    var totalBeats: Double { beats[beats.count - 1] }

    /// The line at `beat`; the last line for the end.
    func line(atBeat beat: Double) -> Int {
        guard !lines.isEmpty else { return 0 }
        var low = 0, high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if beats[middle] <= beat { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The beat at which `word` (fractional) is reached: as far through its line's beats
    /// as through its words.
    func beat(ofWord word: Double) -> Double {
        guard !lines.isEmpty else { return 0 }
        guard word < Double(wordCount) else { return totalBeats }
        let index = line(ofWord: Int(max(0, word)))
        let range = lines[index].words
        let into = min(max((max(0, word) - Double(range.lowerBound)) / Double(max(1, range.count)), 0), 1)
        return beats[index] + into * (beats[index + 1] - beats[index])
    }

    /// The words read at `beat` (fractional), the other way about.
    func word(atBeat beat: Double) -> Double {
        guard !lines.isEmpty else { return 0 }
        guard beat < totalBeats else { return Double(wordCount) }
        let index = line(atBeat: beat)
        let span = beats[index + 1] - beats[index]
        let into = span > 0 ? min(max((beat - beats[index]) / span, 0), 1) : 0
        let range = lines[index].words
        return Double(range.lowerBound) + into * Double(range.count)
    }
}

/// The teleprompter's measures: the page's text column, text sizes, words per minute.
enum TeleprompterLayout {
    /// The text column's width: about nine words of English at the standard size, so
    /// the eyes stay near the camera from one end of a line to the other.
    static let textWidth: CGFloat = 476
    static let sizes: ClosedRange<CGFloat> = 16...32
    static let standardSize: CGFloat = 22
    static let lineCounts: ClosedRange<Int> = 2...5
    static let standardLines = 3
    static let paces: ClosedRange<Int> = 60...260
    static let standardPace = 140
    static let paceStep = 10
    static let sizeStep: CGFloat = 2
    /// The row under the script: progress and time, or the controls under the pointer.
    static let footerHeight: CGFloat = 26
    /// Above the eye line, the half of the line before it, fading.
    static let lineAbove: CGFloat = 0.5
    /// The most the page may be: the opened island's canvas, less the notch row and the
    /// island's own margin.
    static let tallestPage: CGFloat = 240

    static func lineHeight(size: CGFloat) -> CGFloat { (size * 1.32).rounded() }

    @MainActor
    static func font(size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .medium) }

    /// How many lines show below and at the eye line, at `size`, of the `wanted`: fewer
    /// where the page would be taller than the island has room for.
    static func shownLines(wanted: Int, size: CGFloat) -> Int {
        let line = lineHeight(size: size)
        let room = Int(((tallestPage - footerHeight - 6) / line - lineAbove).rounded(.down))
        return max(1, min(wanted, room))
    }

    /// The page's height below the notch row.
    static func pageHeight(lines wanted: Int, size: CGFloat) -> CGFloat {
        let line = lineHeight(size: size)
        return (CGFloat(shownLines(wanted: wanted, size: size)) + lineAbove) * line + footerHeight + 6
    }
}

/// Reading at a set pace: how far through the script the reader is at any moment, in
/// the lines' beats (`ScriptLines.beats`), from where and when the pace last started or
/// changed.
struct PaceClock: Equatable {
    /// Beats read when it last started, or the pace last changed.
    var startBeat: Double
    var startDate: Date
    var wordsPerMinute: Int

    /// Each line change in `lineChanges` comes this long after the moment itself, so the
    /// line drawn then is the new one, whatever the sums round to.
    static let afterLineChange: TimeInterval = 0.001

    func beat(at date: Date) -> Double {
        startBeat + Double(wordsPerMinute) / 60 * max(0, date.timeIntervalSince(startDate))
    }

    /// The same reading, now at `pace` from `date`, carrying on from where it is then.
    func repaced(_ pace: Int, at date: Date) -> PaceClock {
        PaceClock(startBeat: beat(at: date), startDate: date, wordsPerMinute: pace)
    }

    /// When the reading reaches `beat`.
    func date(reaching beat: Double) -> Date {
        let rate = Double(wordsPerMinute) / 60
        guard rate > 0 else { return .distantFuture }
        return startDate.addingTimeInterval(max(0, (beat - startBeat) / rate))
    }

    /// The moments, from `date`, at which the reading moves on to each line after the
    /// one it is on, to the end: for drawing a line at a time, saving energy or with
    /// Reduce Motion.
    func lineChanges(after date: Date, in lines: ScriptLines) -> [Date] {
        let here = lines.line(atBeat: beat(at: date))
        guard here < lines.lines.count else { return [] }
        return (here + 1...lines.lines.count).map {
            self.date(reaching: lines.beats[$0]).addingTimeInterval(Self.afterLineChange)
        }
    }
}

extension TimeInterval {
    /// "2:05 left"-style reading time: "0:45", "12:30", "1:02:03".
    var readingTimeText: String {
        guard isFinite else { return "--:--" }
        let total = Int(Swift.max(0, self.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
