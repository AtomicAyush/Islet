import Foundation

/// A script as the teleprompter reads it: the words shown, in order, and beside them
/// the plain forms the voice is matched against.
///
/// A word is whatever the script has between spaces, punctuation and all, as it is
/// shown. Its plain form folds case and accents, drops punctuation and apostrophes
/// ("Don't" is "dont"), splits at hyphens and slashes, and turns any number, in digits
/// or in words, into one mark, so "12" is heard as "twelve" and "twenty-five" as "25";
/// a run of number words is one number. Words in square brackets are cues for the
/// reader (`[pause]`, `[look up]`): shown, dimmed, and never listened for.
struct ScriptText: Equatable {
    struct Word: Equatable {
        /// As shown.
        var text: String
        /// Inside square brackets: a cue, shown and never matched.
        var isCue = false
        /// The first word after a blank line or a line break in the script, which starts
        /// a new line on screen.
        var startsParagraph = false
    }

    private(set) var words: [Word] = []
    /// The plain forms the voice is matched against, in order (`ScriptFollower`).
    private(set) var tokens: [String] = []
    /// For each token, the word it comes from: the first of a run of number words.
    private(set) var tokenWords: [Int] = []
    /// For each word, the first token at or after it, so a place among the words can be
    /// turned into one among the tokens.
    private(set) var wordTokens: [Int] = []

    init(_ text: String) {
        var inCue = false
        var newParagraph = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let pieces = line.split(whereSeparator: \.isWhitespace)
            if pieces.isEmpty {
                newParagraph = true
                continue
            }
            for piece in pieces {
                let raw = String(piece)
                let opens = raw.hasPrefix("[")
                if opens { inCue = true }
                words.append(Word(text: raw, isCue: inCue, startsParagraph: newParagraph))
                newParagraph = false
                if raw.contains("]") { inCue = false }
            }
            // A single line break starts a new line on screen too: scripts are written
            // a thought to a line as often as a paragraph to one.
            newParagraph = true
        }

        wordTokens.reserveCapacity(words.count)
        for (index, word) in words.enumerated() {
            wordTokens.append(tokens.count)
            guard !word.isCue else { continue }
            for token in Self.plainForms(of: word.text) {
                // A run of numbers is one number, whichever way each is written.
                if token == Self.number, tokens.last == Self.number { continue }
                tokens.append(token)
                tokenWords.append(index)
            }
        }
    }

    var isEmpty: Bool { tokens.isEmpty }
    var wordCount: Int { words.count }

    /// The word a token comes from; the end of the script for the token after the last.
    func word(forToken token: Int) -> Int {
        guard token < tokenWords.count else { return words.count }
        return tokenWords[max(0, token)]
    }

    /// The first token at or after `word`; the token count past the last word.
    func token(forWord word: Int) -> Int {
        guard word < wordTokens.count else { return tokens.count }
        return wordTokens[max(0, word)]
    }

    /// The words of the script, not cues, rare enough to be worth telling the speech
    /// recogniser about: names and jargon it might otherwise hear as something else.
    /// Longer words first, then the rarer of equal length, each once, at most `limit`.
    func vocabulary(limit: Int = 100) -> [String] {
        var counts: [String: (shown: String, count: Int)] = [:]
        var startsSentence = true
        for word in words where !word.isCue {
            defer { startsSentence = word.text.last.map { ".!?:;".contains($0) } ?? false }
            let shown = word.text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard shown.count >= 4, shown.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
            let key = shown.lowercased()
            guard !ScriptFollower.commonWords.contains(key) else { continue }
            // A capital where no sentence starts is likely a name, or one inside the word
            // ("VoiceOver"); a long word is likely jargon.
            let capitalised = shown.first?.isUppercase == true && !startsSentence && !word.startsParagraph
            let innerCapital = shown.dropFirst().contains(where: \.isUppercase)
            guard capitalised || innerCapital || shown.count >= 9 else { continue }
            counts[key, default: (shown, 0)].count += 1
        }
        return counts.values
            .sorted { $0.shown.count != $1.shown.count ? $0.shown.count > $1.shown.count : $0.count < $1.count }
            .prefix(limit)
            .map(\.shown)
    }

    // MARK: Plain forms

    /// The mark every number becomes.
    static let number = "#"

    /// Number words, which the recogniser may write as digits and the script as words
    /// or the other way about. "One" is among them, so "one of the three" is heard as
    /// two numbers either side of "of the"; both sides fold alike, so it still matches.
    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
        "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
        "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million",
        "billion", "percent",
    ]

    /// What the voice is matched against for one word as written: none for punctuation
    /// alone, several for "twelve-month" or "and/or".
    static func plainForms(of word: String) -> [String] {
        let folded = word.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_GB")
        )
        var forms: [String] = []
        for part in folded.split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "—" || $0 == "/" }) {
            let kept = String(part.filter { $0.isLetter || $0.isNumber })
            guard !kept.isEmpty else { continue }
            if kept.allSatisfy(\.isNumber) || numberWords.contains(kept) || isOrdinalNumber(kept) {
                // "twenty-five" is one number.
                if forms.last != number { forms.append(number) }
            } else {
                forms.append(kept)
            }
        }
        return forms
    }

    /// "1st", "22nd", "3rd", "40th": digits with an ordinal's ending.
    private static func isOrdinalNumber(_ word: String) -> Bool {
        let digits = word.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        return ["st", "nd", "rd", "th", "s"].contains(String(word.dropFirst(digits.count)))
    }

    /// Heard speech in plain forms, for matching: the same folding as the script's, a
    /// run of numbers made one.
    static func plainForms(ofSpeech speech: some StringProtocol) -> [String] {
        var out: [String] = []
        for piece in speech.split(whereSeparator: \.isWhitespace) {
            for token in plainForms(of: String(piece)) {
                if token == number, out.last == number { continue }
                out.append(token)
            }
        }
        return out
    }
}
