import Foundation

/// Hindi written in Devanagari, spelled the way Hinglish spells it: in plain Latin
/// letters, as Hindi is typed in messages and printed on lyric sites — "dil",
/// "pyaar", "zindagi", "samajhna" — rather than the scholar's transliteration
/// (ISO 15919 gives "dila", "pyāra", "samajhanā"), which spells every letter and
/// sounds none of the words right.
///
/// It goes by rules, with a handful of everyday words spelled their own way
/// (`exceptions`). A word is read into sounds, the vowels speech leaves out are left
/// out, and what remains is spelled with Hinglish's habits:
///
/// - **The inherent a.** Every consonant carries an "a" unless a sign says otherwise,
///   and speech drops it at the end of a word (दिल: dil, not dila) and between a
///   vowel and consonant on one side and a consonant and vowel on the other (Ohala's
///   rule, applied from the end of the word, so समझना is samajhna and बदलना badalna).
///   It stays after a written cluster ending in य, व, or र after त or द, as Sanskrit
///   words keep it (satya, mitra, chandra), but not in a word with an Urdu letter
///   (fikr); after a nasal that closes the syllable before a stop, since three
///   consonants in a row are more than Hindi says (zindagi), unless a verb ending
///   follows (rangna) or the next consonant is one a stop runs into, र, ल, य, व or a
///   flap (jangli, santra, angdaai); and after the prefix बे (bewafa, not bewfa). A
///   plural or oblique noun (-en, -on) keeps its stem's spelling (nafrat, nafraten).
/// - **Long vowels.** आ is "aa" where it is heard long — in a word's first syllable
///   before a consonant (jaana, aankhen), in a closing syllable (pyaar, deedaar) and
///   as a word on its own ("aa") — and "a" elsewhere (mera, deewana, kahan). ई and ऊ
///   are "ee" and "oo" before a consonant (jeena, door) and "i" and "u" at the end of
///   a word (zindagi, tu), as Hinglish spells them.
/// - **Consonants.** Retroflex and dental are spelled alike (t, d), छ is "chh" but
///   "ch" at the end of a word (chhota, kuch), ज्ञ is "gy" (gyaan), and the dotted
///   letters are the Urdu sounds they write (क़ q, ख़ kh, ग़ gh, ज़ z, फ़ f). ड़ and ढ़
///   are "d" and "dh" (ladki, padhna), as they are typed, rather than the "r" and "rh"
///   of older romanisation. व is "w" before a, o and ai and after a consonant (waqt,
///   khwaab), and "v" otherwise (vishwaas, naav), and between i, ee or e and a short
///   a (jeevan, sevak).
/// - **Nasals.** ं and ँ are "n", or "m" before p, b and m (ambar), and silent before
///   a nasal consonant (maine).
/// - **The a before h.** Where dropping vowels leaves ह closing a syllable, the a
///   before it is heard, and spelled, as "e": kehna, pehla, mehfil, shehar, yeh.
///
/// Words that are not Devanagari, spaces, punctuation and digits are left as they
/// are; in a line with Devanagari words, Devanagari digits become ASCII ones and a
/// danda a full stop.
enum Hinglish {
    /// `line` with every word in Devanagari spelled out, and everything else as it
    /// was. A line that starts with a Devanagari word starts with a capital, as a
    /// line of lyrics does; one that starts with a number or a word in another
    /// script does not gain one further in.
    static func romanise(_ line: String) -> String {
        guard containsDevanagari(line) else { return line }
        var output = ""
        var word: [Unicode.Scalar] = []
        // A letter or a number has been written, so the line has begun.
        var hasBegun = false
        func endWord() {
            guard !word.isEmpty else { return }
            var spelled = spell(word)
            word.removeAll()
            if !hasBegun, let first = spelled.first {
                spelled = first.uppercased() + spelled.dropFirst()
            }
            if !spelled.isEmpty { hasBegun = true }
            output += spelled
        }
        for scalar in line.unicodeScalars {
            if isWordScalar(scalar) || (!word.isEmpty && isJoiner(scalar)) {
                word.append(scalar)
                continue
            }
            endWord()
            switch scalar.value {
            case 0x0966...0x096F:
                output += String(scalar.value - 0x0966)
                hasBegun = true
            case 0x0964, 0x0965, 0x0970:
                // A danda follows a space in much Hindi typing; a full stop does not.
                while output.last == " " { output.removeLast() }
                output += "."
            default:
                output.unicodeScalars.append(scalar)
                if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { hasBegun = true }
            }
        }
        endWord()
        return output
    }

    /// Whether `text` has a Devanagari letter or sign in it. The danda and the
    /// digits alone do not count: Gurmukhi and Bengali end their lines with the same
    /// danda, and those lines are shown as they are.
    static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isWordScalar)
    }

    // MARK: Words

    /// The letters, signs and marks words are made of: everything in the block but
    /// the danda, the digits and the abbreviation sign.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0900...0x0963, 0x0971...0x097F: true
        default: false
        }
    }

    /// Zero-width joiners and non-joiners, which change how a word is drawn and
    /// nothing of how it sounds.
    private static func isJoiner(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x200C || scalar.value == 0x200D
    }

    /// Words spelled their own way, more often than not because Hinglish spells them
    /// apart from an English word (men, ham) or as they are said rather than written.
    /// हम's forms go with it (humse, not hamse beside hum), and the pronouns that end
    /// in ें are spelled like में (humein, tumhein), as they nearly always are typed;
    /// nouns and verbs keep the rules' -en (aankhen).
    private static let exceptions: [String: String] = {
        let words = [
            "नहीं": "nahi",
            "हूँ": "hoon", "हूं": "hoon",
            "में": "mein",
            "हम": "hum", "हमें": "humein", "हमसे": "humse", "हमको": "humko", "हमने": "humne",
            "तुम्हें": "tumhein", "उन्हें": "unhein", "इन्हें": "inhein", "जिन्हें": "jinhein",
            "वह": "woh",
            // The call, as in "ae dil", and the hum.
            "ऐ": "ae", "हम्म": "hmm",
            // Said otherwise than the rules would read them.
            "चाय": "chai", "कई": "kai", "माँ": "maa", "मां": "maa", "महल": "mahal",
            "मेहंदी": "mehndi", "मेंहदी": "mehndi", "सिंह": "singh", "वंदना": "vandana",
            // Two words the rules would read as one.
            "हमसफ़र": "humsafar",
        ]
        return Dictionary(words.map { (String(String.UnicodeScalarView(letters(of: Array($0.key.unicodeScalars)))), $0.value) },
                          uniquingKeysWith: { first, _ in first })
    }()

    /// One word, spelled out.
    static func spell(_ word: [Unicode.Scalar]) -> String {
        let letters = letters(of: word)
        if let known = exceptions[String(String.UnicodeScalarView(letters))] { return known }
        var sounds = read(letters)
        leaveOutVowels(&sounds)
        return write(sounds)
    }

    /// `word` with each dotted letter as its letter and the dot, however it was typed
    /// (Unicode keeps some as one character and some as two), and without joiners.
    private static func letters(of word: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var letters: [Unicode.Scalar] = []
        for scalar in word where !isJoiner(scalar) {
            if let base = dottedLetters[scalar.value], let letter = Unicode.Scalar(base) {
                letters.append(letter)
                letters.append(nukta)
            } else {
                letters.append(scalar)
            }
        }
        return letters
    }

    /// The letters Unicode also has with their dot built in, and the letter each is.
    private static let dottedLetters: [UInt32: UInt32] = [
        0x0929: 0x0928, 0x0931: 0x0930, 0x0934: 0x0933,
        0x0958: 0x0915, 0x0959: 0x0916, 0x095A: 0x0917, 0x095B: 0x091C,
        0x095C: 0x0921, 0x095D: 0x0922, 0x095E: 0x092B, 0x095F: 0x092F,
    ]

    private static let nukta = Unicode.Scalar(0x093C)!
    private static let virama: UInt32 = 0x094D

    // MARK: Sounds

    enum Vowel: Equatable {
        case a, aa, i, ii, u, uu, ri, e, ai, o, au

        /// The short vowels, which a nasal can close a syllable after.
        var isShort: Bool { self == .a || self == .i || self == .u }
    }

    struct Consonant: Equatable {
        /// The letter, without a dot.
        let letter: UInt32
        let hasNukta: Bool

        /// k, g, ch, j, t, d, p, b and their breathy forms, and q, ड़ and ढ़.
        var isStop: Bool {
            switch letter {
            case 0x0915...0x0918, 0x091A...0x091D, 0x091F...0x0922, 0x0924...0x0927, 0x092A...0x092D:
                !hasNukta || letter == 0x0915 || letter == 0x0921 || letter == 0x0922
            default: false
            }
        }

        /// र, ल, य, व and the flaps ड़ and ढ़, which a stop before them runs straight
        /// into, as the two start a syllable together (jangli, santra, angdaai).
        var runsOn: Bool {
            switch letter {
            case 0x092F, 0x0930, 0x0932, 0x0935: true
            case 0x0921, 0x0922: hasNukta
            default: false
            }
        }

        var isLabial: Bool { !hasNukta && (0x092A...0x092E).contains(letter) }
        var isNasal: Bool { [0x0919, 0x091E, 0x0923, 0x0928, 0x092E].contains(letter) }
        func `is`(_ letter: UInt32) -> Bool { self.letter == letter && !hasNukta }
    }

    /// One sound of a word: a consonant, or a vowel with what is written on it.
    struct Sound {
        enum Kind: Equatable {
            case consonant(Consonant)
            case vowel(Vowel)
        }

        var kind: Kind
        /// A consonant's own a, written with no sign at all.
        var isInherent = false
        /// A vowel written as a letter of its own, rather than as a sign on a consonant.
        var standsAlone = false
        var isNasal = false
        var hasVisarga = false
        /// Left out, as speech leaves it out.
        var isDropped = false

        var consonant: Consonant? {
            if case .consonant(let consonant) = kind { consonant } else { nil }
        }
        var vowel: Vowel? {
            if case .vowel(let vowel) = kind { vowel } else { nil }
        }
        var isVowel: Bool { vowel != nil }
        var isConsonant: Bool { consonant != nil }

        /// A plain inherent a, which speech may leave out.
        var isDroppable: Bool {
            isInherent && !isNasal && !hasVisarga && !isDropped
        }
    }

    /// The word's sounds, in order: each consonant followed by its vowel (the
    /// inherent a when no sign gives another, none after a virama), and the vowels
    /// written as letters. A nasal sign or visarga marks the vowel before it.
    static func read(_ letters: [Unicode.Scalar]) -> [Sound] {
        var sounds: [Sound] = []
        var index = 0
        func peek() -> UInt32? { index < letters.count ? letters[index].value : nil }
        while index < letters.count {
            let value = letters[index].value
            index += 1
            if isConsonantLetter(value) {
                var hasNukta = false
                if peek() == nukta.value {
                    hasNukta = true
                    index += 1
                }
                sounds.append(Sound(kind: .consonant(Consonant(letter: value, hasNukta: hasNukta))))
                if peek() == virama {
                    index += 1
                } else if let next = peek(), let vowel = vowelSigns[next] {
                    sounds.append(Sound(kind: .vowel(vowel)))
                    index += 1
                } else {
                    sounds.append(Sound(kind: .vowel(.a), isInherent: true))
                }
            } else if let vowel = vowelLetters[value] {
                sounds.append(Sound(kind: .vowel(vowel), standsAlone: true))
            } else if let vowel = vowelSigns[value] {
                // A sign with no consonant to sit on: sounded as the vowel it is.
                sounds.append(Sound(kind: .vowel(vowel), standsAlone: true))
            } else if value == 0x0900 || value == 0x0901 || value == 0x0902 {
                if let last = sounds.indices.last, sounds[last].isVowel { sounds[last].isNasal = true }
            } else if value == 0x0903 {
                if let last = sounds.indices.last, sounds[last].isVowel { sounds[last].hasVisarga = true }
            } else if value == 0x0950 {
                // ॐ
                sounds.append(Sound(kind: .vowel(.o), standsAlone: true))
                sounds.append(Sound(kind: .consonant(Consonant(letter: 0x092E, hasNukta: false))))
            }
            // Anything else — a stray dot or virama, an accent, the avagraha that
            // draws a vowel out — has no sound of its own.
        }
        return sounds
    }

    private static func isConsonantLetter(_ value: UInt32) -> Bool {
        (0x0915...0x0939).contains(value) || (0x0978...0x097F).contains(value)
    }

    private static let vowelLetters: [UInt32: Vowel] = [
        0x0904: .e, 0x0905: .a, 0x0906: .aa, 0x0907: .i, 0x0908: .ii, 0x0909: .u, 0x090A: .uu,
        0x090B: .ri, 0x090C: .ri, 0x090D: .e, 0x090E: .e, 0x090F: .e, 0x0910: .ai, 0x0911: .o,
        0x0912: .o, 0x0913: .o, 0x0914: .au, 0x0960: .ri, 0x0961: .ri, 0x0972: .a,
        0x0973: .e, 0x0974: .o, 0x0975: .au, 0x0976: .u, 0x0977: .uu,
    ]

    private static let vowelSigns: [UInt32: Vowel] = [
        0x093A: .e, 0x093B: .o, 0x093E: .aa, 0x093F: .i, 0x0940: .ii, 0x0941: .u, 0x0942: .uu,
        0x0943: .ri, 0x0944: .ri, 0x0945: .e, 0x0946: .e, 0x0947: .e, 0x0948: .ai, 0x0949: .o,
        0x094A: .o, 0x094B: .o, 0x094C: .au, 0x094E: .e, 0x094F: .au, 0x0955: .e, 0x0956: .u,
        0x0957: .uu, 0x0962: .ri, 0x0963: .ri,
    ]

    // MARK: The inherent a

    /// Leaves out the inherent a's that speech leaves out: the last one, then those
    /// between a vowel and a consonant and a consonant and a vowel, from the end of
    /// the word back, so that of two in a row it is the later that goes (samajhna,
    /// not samjhana). A stem after the prefix बे is a word of its own.
    ///
    /// A plural or oblique ending, -ें or -ों on a consonant, would otherwise take the
    /// stem's last a out and so keep the one before it (nafarten), spelling the stem
    /// apart from the singular a line away (nafrat). So the stem goes first, ending
    /// as the singular does, and the ending's own pass follows: nafraten, dhadkanon.
    static func leaveOutVowels(_ sounds: inout [Sound]) {
        let start = stemAfterPrefix(sounds) ?? 0
        if let last = sounds.last, sounds.count >= 3, sounds[sounds.count - 2].isConsonant, !last.standsAlone,
           last.isNasal, last.vowel == .e || last.vowel == .o {
            var singular = sounds
            singular[singular.count - 1] = Sound(kind: .vowel(.a), isInherent: true)
            leaveOutVowels(&singular, from: start)
            for index in sounds.indices.dropLast() where singular[index].isDropped {
                sounds[index].isDropped = true
            }
        }
        leaveOutVowels(&sounds, from: start)
    }

    private static func leaveOutVowels(_ sounds: inout [Sound], from start: Int) {
        let end = sounds.count
        guard end - start >= 2 else { return }
        let vowels = sounds[start...].filter(\.isVowel).count
        // A word of one syllable keeps its only vowel (na).
        if sounds[end - 1].isDroppable, vowels > 1, !keepsLastVowel(sounds, from: start) {
            sounds[end - 1].isDropped = true
        }
        var index = end - 2
        while index >= start + 2 {
            defer { index -= 1 }
            guard sounds[index].isDroppable,
                  let before = sounds[index - 1].consonant, sounds[index - 2].isVowel, !sounds[index - 2].isDropped,
                  let after = sounds[index + 1].consonant, index + 2 < end, sounds[index + 2].isVowel,
                  !sounds[index + 2].isDropped
            else { continue }
            let vowelBefore = sounds[index - 2]
            let closedByNasal = vowelBefore.isNasal && vowelBefore.vowel?.isShort == true && before.isStop
            if closedByNasal, !after.runsOn, !isVerbEnding(sounds, at: index + 1) { continue }
            sounds[index].isDropped = true
        }
    }

    /// Whether the last a stays: after a cluster ending in य or व (satya, tattva), or
    /// in र after त or द (mitra, chandra), as Sanskrit words keep it. A word with an
    /// Urdu letter drops it all the same (fikr).
    private static func keepsLastVowel(_ sounds: [Sound], from start: Int) -> Bool {
        let end = sounds.count
        guard end - start >= 3, let last = sounds[end - 2].consonant, let before = sounds[end - 3].consonant,
              !sounds[start...].contains(where: { $0.consonant?.hasNukta == true })
        else { return false }
        if last.is(0x092F) || last.is(0x0935) { return true }
        return last.is(0x0930) && (before.is(0x0924) || before.is(0x0926))
    }

    /// Whether the consonant at `index` starts a verb's ending: -na, -ne, -ni, -ta,
    /// -te, -ti, closing the word (rangna, rangta).
    private static func isVerbEnding(_ sounds: [Sound], at index: Int) -> Bool {
        guard index + 2 == sounds.count, let consonant = sounds[index].consonant,
              consonant.is(0x0928) || consonant.is(0x0924),
              let vowel = sounds[index + 1].vowel
        else { return false }
        return vowel == .aa || vowel == .e || vowel == .ii
    }

    /// Where the stem starts after the prefix बे ("without"), when the stem's first
    /// a would otherwise be taken for one between syllables: bewafa, beqaraar,
    /// bekhabar. Not before ह, where the word is more often not the prefix at all
    /// (behtar), nor before a verb ending (bechna).
    private static func stemAfterPrefix(_ sounds: [Sound]) -> Int? {
        guard sounds.count >= 6, sounds[0].consonant?.is(0x092C) == true, sounds[1].vowel == .e, !sounds[1].standsAlone,
              let first = sounds[2].consonant, !first.is(0x0939), sounds[3].isDroppable, sounds[4].isConsonant,
              !(sounds.count == 6 && isVerbEnding(sounds, at: 4))
        else { return nil }
        return 2
    }

    // MARK: Spelling

    /// The sounds left, spelled.
    static func write(_ sounds: [Sound]) -> String {
        let heard = sounds.indices.filter { !sounds[$0].isDropped }
        let syllables = heard.filter { sounds[$0].isVowel }.count
        let stem = stemAfterPrefix(sounds)
        var output = ""
        for (place, index) in heard.enumerated() {
            let sound = sounds[index]
            let previous = place > 0 ? sounds[heard[place - 1]] : nil
            let next = place + 1 < heard.count ? sounds[heard[place + 1]] : nil
            switch sound.kind {
            case .consonant(let consonant):
                let isJoined = index > 0 && sounds[index - 1].isConsonant
                // A stem's first letter is spelled as it would start a word.
                let before = index == stem ? nil : previous
                output += spelling(of: consonant, after: before, before: next, isJoined: isJoined)
            case .vowel(let vowel):
                if let previous, let before = previous.vowel, glides(from: before, to: vowel) { output += "y" }
                let isFirst = !heard[..<place].contains { sounds[$0].isVowel }
                let isLast = !heard[(place + 1)...].contains { sounds[$0].isVowel }
                output += spelling(of: vowel, sound: sound, at: index, in: sounds, next: next,
                                   isFirst: isFirst, isLast: isLast, syllables: syllables, isWordStart: place == 0)
                if sound.isNasal, next?.consonant?.isNasal != true {
                    output += next?.consonant?.isLabial == true ? "m" : "n"
                }
                if sound.hasVisarga, next == nil { output += "h" }
            }
        }
        return output
    }

    /// `isJoined`: written joined to the consonant before, with no vowel between.
    private static func spelling(of consonant: Consonant, after previous: Sound?, before next: Sound?, isJoined: Bool) -> String {
        let letter = consonant.letter
        if consonant.hasNukta, let dotted = dottedSpellings[letter] { return dotted }
        switch letter {
        case 0x091A:
            // च before छ is only the stop's hold (achha), and before च, a c (baccha).
            if next?.consonant?.is(0x091B) == true { return "" }
            if next?.consonant?.is(0x091A) == true { return "c" }
            return "ch"
        case 0x091B:
            // Hinglish ends a word in "ch" (kuch), but keeps "chh" after च.
            return next == nil && previous?.consonant?.is(0x091A) != true ? "ch" : "chh"
        case 0x091C:
            // ज्ञ is said, and spelled, gy.
            return next?.consonant?.is(0x091E) == true ? "g" : "j"
        case 0x091E:
            return previous?.consonant?.is(0x091C) == true ? "y" : "n"
        case 0x0935:
            // Joined to र, as Sanskrit writes it, v (parvat); after any other
            // consonant, or र whose a speech leaves out, w (khwaab, darwaza).
            if let before = previous?.consonant { return isJoined && before.is(0x0930) ? "v" : "w" }
            // Between i, ee or e and a short a, v (jeevan, sevak).
            if let before = previous?.vowel, [.i, .ii, .e, .ai].contains(before), next?.vowel == .a { return "v" }
            switch next?.vowel {
            case .a?, .aa?, .o?, .au?, .ai?: return "w"
            default: return "v"
            }
        default:
            return consonantSpellings[letter] ?? ""
        }
    }

    private static func spelling(
        of vowel: Vowel, sound: Sound, at index: Int, in sounds: [Sound], next: Sound?,
        isFirst: Bool, isLast: Bool, syllables: Int, isWordStart: Bool
    ) -> String {
        let beforeConsonant = next?.isConsonant == true
        switch vowel {
        case .a:
            return sound.isInherent && soundsAsE(at: index, in: sounds, syllables: syllables) ? "e" : "a"
        case .aa:
            if isWordStart && sound.standsAlone { return "aa" }
            if beforeConsonant { return isFirst || isLast ? "aa" : "a" }
            // Said long at the end of a word of one syllable only when nasal (haan).
            return next == nil && syllables == 1 && sound.isNasal ? "aa" : "a"
        case .ii: return beforeConsonant ? "ee" : "i"
        case .uu: return beforeConsonant ? "oo" : "u"
        case .i: return "i"
        case .u: return "u"
        case .ri: return "ri"
        case .e: return "e"
        case .ai: return "ai"
        case .o: return "o"
        case .au: return "au"
        }
    }

    /// Whether the inherent a at `index`, before ह, is said as e: where ह closes the
    /// syllable once the a after it is left out (kehna, mehfil), in a word of one
    /// syllable (yeh), and in a word ending a-ह-a and a consonant (shehar, lehar).
    private static func soundsAsE(at index: Int, in sounds: [Sound], syllables: Int) -> Bool {
        let h = index + 1
        guard h < sounds.count, sounds[h].consonant?.is(0x0939) == true else { return false }
        let after = h + 1 < sounds.count ? sounds[h + 1] : nil
        // ह's own a left out, before a consonant.
        if let after, after.isDropped, h + 2 < sounds.count, sounds[h + 2].isConsonant { return true }
        // The word ends with ह.
        if after == nil || (after?.isDropped == true && h + 2 == sounds.count) { return syllables == 1 }
        // a-ह-a and a last consonant.
        if let after, after.isInherent, !after.isDropped, !after.isNasal, h + 2 < sounds.count,
           sounds[h + 2].isConsonant, h + 3 == sounds.count || (h + 4 == sounds.count && sounds[h + 3].isDropped) {
            return true
        }
        return false
    }

    /// Whether a y is heard between two vowels: after a, aa, i, ee or o before e
    /// (gaye, jaaye, liye, khoye), and after a before i or ee (gayi).
    private static func glides(from before: Vowel, to vowel: Vowel) -> Bool {
        switch (before, vowel) {
        case (.a, .e), (.aa, .e), (.i, .e), (.ii, .e), (.o, .e), (.a, .i), (.a, .ii): true
        default: false
        }
    }

    private static let consonantSpellings: [UInt32: String] = [
        0x0915: "k", 0x0916: "kh", 0x0917: "g", 0x0918: "gh", 0x0919: "n",
        0x091D: "jh",
        0x091F: "t", 0x0920: "th", 0x0921: "d", 0x0922: "dh", 0x0923: "n",
        0x0924: "t", 0x0925: "th", 0x0926: "d", 0x0927: "dh", 0x0928: "n",
        0x092A: "p", 0x092B: "ph", 0x092C: "b", 0x092D: "bh", 0x092E: "m",
        0x092F: "y", 0x0930: "r", 0x0932: "l", 0x0933: "l",
        0x0936: "sh", 0x0937: "sh", 0x0938: "s", 0x0939: "h",
        0x0979: "z", 0x097A: "y", 0x097B: "g", 0x097C: "j", 0x097E: "d", 0x097F: "b",
    ]

    /// The dotted letters: Urdu's sounds, and the flapped ड़ and ढ़.
    private static let dottedSpellings: [UInt32: String] = [
        0x0915: "q", 0x0916: "kh", 0x0917: "gh", 0x091C: "z", 0x091D: "zh",
        0x0921: "d", 0x0922: "dh", 0x092B: "f", 0x092F: "y",
    ]
}
