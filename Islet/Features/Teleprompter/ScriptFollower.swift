import Foundation

/// Keeps the place in a script from what the speech recogniser hears, as Follow my
/// voice reads it.
///
/// The recogniser sends its guess at what has been said so far again and again, each
/// one rewriting the last few words as it hears more. So every guess is taken afresh:
/// its last few words (`tail`) are lined up against the script near the place (from
/// `behind` words back to `ahead` on), as a local alignment that allows a word missed
/// or misheard on either side, and the place moves to just after the script word the
/// newest heard word lines up with. A word the recogniser got nearly right counts for
/// less than one it got right. Of alignments that score the same, the nearest wins.
///
/// It moves only on good evidence:
///
/// - only to just after a heard word that ends a run of two in the script, or one
///   heard exactly (and not a common word) within a word or two of the last matched, so
///   a word that merely looks like one further on ("thes" for "them") moves nothing;
/// - forward on two matched words, or, for a jump of more than a few words, four besides
///   the newest, which the recogniser is still guessing at: so the start of a line said
///   again further on ("We will build…" twice) doesn't pull the place a line ahead;
/// - back (a line said again) only on four, and only once two guesses in a row agree,
///   and never for a word or two, which is the recogniser rewriting its guess;
/// - never on common words alone ("and the of"), which any script is full of;
/// - not at all when nothing lines up: silence, an aside, a word with the audience.
///
/// Where nothing near the place lines up, a paragraph skipped or a stretch not heard,
/// the whole script is searched for the newest words (`farRun` of them, heard exactly,
/// in a row, `farStrong` of them not common words), and the place moves there if they
/// are found once only and the next guess agrees.
///
/// After the place is moved by hand, the words heard before the move say nothing of
/// where the reader now is, and the recogniser often sends them again as it settles
/// its guess: only words heard since are lined up.
///
/// It knows nothing of the microphone: the harness feeds it transcripts as the
/// recogniser would.
struct ScriptFollower {
    /// The script's plain forms (`ScriptText.tokens`).
    let script: [String]
    /// The same, as scalars, for comparing letter by letter.
    private let scriptScalars: [[Unicode.Scalar]]
    /// The next token to be read.
    private(set) var position = 0

    /// How many of the newest heard words are lined up.
    static let tail = 8
    /// How far back of the place, and ahead of it, the script is searched.
    static let behind = 40
    static let ahead = 30
    /// The most a jump forward may be on two matched words; further takes four.
    static let shortJump = 6
    /// Moves back of a word or two are left be.
    static let jitter = 2
    /// How many of the newest words, heard exactly and in a row, find the place far from
    /// where it was, and how many of those must not be common words.
    static let farRun = 6
    static let farStrong = 3

    /// A place further back that one guess pointed to, waiting for the next to agree.
    private var pendingBack: Int?
    /// A place far from this one that one guess pointed to, waiting for the next to agree.
    private var pendingFar: Int?
    /// The last guess, as plain forms.
    private var lastHeard: [String] = []
    /// The guess before the place was moved by hand, until enough has been heard since.
    private var heardBeforeMove: [String]?

    init(script: [String], position: Int = 0) {
        self.script = script
        scriptScalars = script.map { Array($0.unicodeScalars) }
        self.position = min(max(0, position), script.count)
    }

    /// Puts the place at `position` (a token), for a resume, or a move by hand, after
    /// which (`forgettingHeard`) the words heard before it are no longer lined up.
    mutating func reset(to position: Int, forgettingHeard: Bool = false) {
        self.position = min(max(0, position), script.count)
        pendingBack = nil
        pendingFar = nil
        heardBeforeMove = forgettingHeard && !lastHeard.isEmpty ? lastHeard : nil
    }

    /// Takes the recogniser's latest guess at everything said, and returns the place.
    /// Only its last few words are read, however long it has grown.
    @discardableResult
    mutating func hear(_ transcript: String) -> Int {
        hear(tokens: ScriptText.plainForms(ofSpeech: Self.lastWords(of: transcript, count: Self.tail * 3)))
    }

    /// The last `count` words of `text`, found from its end.
    static func lastWords(of text: String, count: Int) -> Substring {
        var seen = 0
        var inWord = false
        var index = text.endIndex
        while index > text.startIndex {
            let before = text.index(before: index)
            if text[before].isWhitespace {
                if inWord {
                    seen += 1
                    if seen == count { return text[index...] }
                }
                inWord = false
            } else {
                inWord = true
            }
            index = before
        }
        return text[...]
    }

    /// The same, for speech already in plain forms.
    @discardableResult
    mutating func hear(tokens heardAll: [String]) -> Int {
        defer { lastHeard = heardAll }
        var heard = heardAll
        if let before = heardBeforeMove {
            let fresh = Self.freshCount(heardAll, after: before)
            if fresh >= Self.tail {
                heardBeforeMove = nil
            } else {
                heard = Array(heardAll.suffix(fresh))
            }
        }
        let tail = Array(heard.suffix(Self.tail))
        if !moveNearby(tail) { findFar(tail) }
        return position
    }

    /// Lines `heard` up near the place, and moves if the evidence is good. Returns
    /// whether it lined up well enough to say where the reader is, moved or not.
    private mutating func moveNearby(_ heard: [String]) -> Bool {
        guard let best = align(heard) else { return false }
        let delta = best.end - position
        // A long jump forward counts the newest word over the four before it.
        let needed = delta < -Self.jitter ? 4 : delta > Self.shortJump ? 5 : 2
        guard best.matched >= needed, best.strong >= 1, best.score >= 2 * needed - 1,
              delta >= -Self.jitter || best.run >= 3 else { return false }
        pendingFar = nil
        if delta < -Self.jitter {
            if let pending = pendingBack, abs(pending - best.end) <= 1 {
                position = best.end
                pendingBack = nil
            } else {
                pendingBack = best.end
            }
        } else if delta > 0 {
            position = best.end
            pendingBack = nil
        }
        return true
    }

    /// Looks for the newest words heard in the whole script, away from the place: a run
    /// of `farRun` heard exactly, ending on the newest word or, as the recogniser may still
    /// be rewriting them, a word or two before it. Moves there once two guesses in a row
    /// find it, and only where the run is found once in the script.
    private mutating func findFar(_ heard: [String]) {
        guard heard.count >= Self.farRun else { return }
        let lo = max(0, position - Self.behind), hi = min(script.count, position + Self.ahead)
        for rewritten in 0...min(2, heard.count - Self.farRun) {
            let run = Array(heard[(heard.count - rewritten - Self.farRun)..<(heard.count - rewritten)])
            guard run.filter({ !Self.commonWords.contains($0) }).count >= Self.farStrong else { continue }
            let ends = Self.ends(of: run, in: script, upTo: 2)
            guard ends.count == 1, let end = ends.first, end <= lo || end > hi else { continue }
            if let pending = pendingFar, abs(pending - end) <= 2 {
                position = end
                pendingFar = nil
                pendingBack = nil
            } else {
                pendingFar = end
            }
            return
        }
    }

    /// Where `run` ends (the token after it) each time it is in `script`, up to `limit`
    /// of them.
    static func ends(of run: [String], in script: [String], upTo limit: Int) -> [Int] {
        guard let first = run.first, run.count <= script.count else { return [] }
        var found: [Int] = []
        for start in 0...(script.count - run.count) where script[start] == first {
            var matches = true
            for offset in 1..<run.count where script[start + offset] != run[offset] {
                matches = false
                break
            }
            guard matches else { continue }
            found.append(start + run.count)
            if found.count == limit { break }
        }
        return found
    }

    /// How many of the newest words of `heard` came after `before`, an earlier guess:
    /// `before`'s last few words (less the newest one or two, which the recogniser may
    /// have rewritten since) found at their latest in `heard`, and the words after them.
    /// All of them, where `before` can't be found.
    static func freshCount(_ heard: [String], after before: [String]) -> Int {
        for rewritten in 0...min(2, max(0, before.count - 1)) {
            let anchor = Array(before.dropLast(rewritten).suffix(3))
            guard !anchor.isEmpty, heard.count >= anchor.count else { continue }
            var end = heard.count
            while end >= anchor.count {
                if Array(heard[(end - anchor.count)..<end]) == anchor { return max(0, heard.count - end - rewritten) }
                end -= 1
            }
        }
        return heard.count
    }

    private struct Alignment {
        var score: Int
        /// The token after the last one matched: where the reader is now.
        var end: Int
        /// Words lined up as the same or nearly so.
        var matched: Int
        /// Of those, ones that are not common words.
        var strong: Int
        /// How many of the newest heard words matched one script word after another,
        /// with nothing between.
        var run: Int
    }

    /// Smith–Waterman of `heard` against the script near the place. Only alignments
    /// that end on the newest heard word, and on two heard words in a row, say where the
    /// reader is now; of those, the highest score less a point for every ten tokens away
    /// from the place.
    private func align(_ heard: [String]) -> Alignment? {
        guard heard.count >= 2 else { return nil }
        let lo = max(0, position - Self.behind), hi = min(script.count, position + Self.ahead)
        guard hi > lo else { return nil }
        let heardScalars = heard.map { Array($0.unicodeScalars) }
        let n = heard.count, m = hi - lo
        let width = m + 1
        var score = [Int](repeating: 0, count: (n + 1) * width)
        var matched = score, strong = score, run = score
        // Script words passed since the last match, and before this cell's own.
        var skipped = score, skippedBefore = score
        var best: Alignment?
        var bestRank = Int.min
        for i in 1...n {
            for j in 1...m {
                let word = script[lo + j - 1]
                let s = heard[i - 1] == word ? 2 : Self.similarity(heardScalars[i - 1], scriptScalars[lo + j - 1])
                let here = i * width + j, diagonal = (i - 1) * width + j - 1, up = (i - 1) * width + j, left = here - 1
                let viaDiagonal = score[diagonal] + s
                let viaUp = score[up] - 1, viaLeft = score[left] - 1
                let value = max(0, viaDiagonal, viaUp, viaLeft)
                score[here] = value
                if value == 0 {
                    matched[here] = 0
                    strong[here] = 0
                } else if value == viaDiagonal {
                    let isMatch = s > 0
                    matched[here] = matched[diagonal] + (isMatch ? 1 : 0)
                    strong[here] = strong[diagonal] + (isMatch && !Self.commonWords.contains(word) ? 1 : 0)
                    run[here] = isMatch ? run[diagonal] + 1 : 0
                    skippedBefore[here] = skipped[diagonal]
                    skipped[here] = isMatch ? 0 : skipped[diagonal] + 1
                } else if value == viaUp {
                    matched[here] = matched[up]
                    strong[here] = strong[up]
                    skipped[here] = skipped[up]
                } else {
                    matched[here] = matched[left]
                    strong[here] = strong[left]
                    skipped[here] = skipped[left] + 1
                }
                guard i == n, s > 0, value == viaDiagonal else { continue }
                let exactNearby = s == 2 && skippedBefore[here] <= 2 && !Self.commonWords.contains(word)
                guard run[here] >= 2 || exactNearby && matched[here] >= 2 else { continue }
                let end = lo + j
                let rank = value * 10 - abs(end - position)
                if rank > bestRank {
                    bestRank = rank
                    best = Alignment(score: value, end: end, matched: matched[here], strong: strong[here], run: run[here])
                }
            }
        }
        return best
    }

    /// 2 for the same word, 1 for one nearly the same (misheard), and −1 otherwise.
    static func similarity(_ a: String, _ b: String) -> Int {
        a == b ? 2 : similarity(Array(a.unicodeScalars), Array(b.unicodeScalars))
    }

    static func similarity(_ x: [Unicode.Scalar], _ y: [Unicode.Scalar]) -> Int {
        if x == y { return 2 }
        guard min(x.count, y.count) >= 4 else { return -1 }
        let longer = max(x.count, y.count)
        // Too different in length to be within the ratio at all.
        guard Double(abs(x.count - y.count)) / Double(longer) <= nearRatio else { return -1 }
        return Double(editDistance(x, y)) / Double(longer) <= nearRatio ? 1 : -1
    }

    /// How much of a word may differ for it to count as nearly the same.
    static let nearRatio = 0.34

    static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count), current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Words every script is full of, which alone say nothing of where the reader is.
    static let commonWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from", "as", "is",
        "it", "its", "that", "this", "these", "those", "i", "we", "you", "he", "she", "they", "me", "us", "our",
        "your", "my", "be", "are", "was", "were", "been", "so", "if", "then", "than", "there", "here", "what",
        "which", "who", "do", "does", "did", "not", "no", "yes", "have", "has", "had", "will", "would", "can",
        "could", "just", "all", "about", "up", "out", "into", "now", "very", "really", "well", "um", "uh", "like",
        ScriptText.number,
    ]
}
