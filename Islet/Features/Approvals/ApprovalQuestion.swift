import Foundation

/// A question Claude asks you (its AskUserQuestion tool), as the island shows it: the
/// question, a word or two heading it, and two to four options, of which one may be
/// chosen, or several where it says so. Claude Code adds "Other" itself: words of the
/// person's own, in place of an option or beside those chosen.
struct ApprovalQuestion: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        var label: String
        var description: String
        /// A mockup to look at beside the option: never drawn in the island, which then
        /// leaves the question to the app.
        var preview: String?
    }

    var text: String
    var header: String
    var options: [Option]
    var multiSelect: Bool
}

/// What the person chose for one question: options by their number, and words of
/// their own as typed.
struct ApprovalChoice: Equatable, Sendable {
    var options: Set<Int> = []
    var other = ""

    /// The words as sent: composed, every space an ordinary one (a full-width or
    /// no-break space typed reads the same), without the spaces either side; "" for none.
    var words: String {
        var scalars = String.UnicodeScalarView()
        for scalar in other.precomposedStringWithCanonicalMapping.unicodeScalars {
            scalars.append(scalar.properties.generalCategory == .spaceSeparator ? " " : scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    var isAnswered: Bool { !options.isEmpty || !words.isEmpty }
}

/// Reading Claude's questions from the tool's input, and Islet's answer to them.
///
/// The answer names options by their numbers, never their words: the hook puts in the
/// labels from its own copy of the input, so an answer can only ever be one of the
/// options shown, or the person's own words. Those are one line of at most
/// `wordsLimit` characters with nothing a reader could not see, which the hook checks
/// again.
enum ApprovalQuestions {
    static let questions = 1...4
    static let options = 2...4
    static let wordsLimit = 300
    /// The most of each part the hook takes (`approval_asks`): anything longer is never
    /// offered.
    static let textLimit = 1000
    static let labelLimit = 200

    /// The questions in `input`, or `nil` for input not in the shape the hook offers:
    /// only `questions`, `title` and `metadata`, each question a choice of two to four
    /// options, nothing the card has no place for. A `kind` other than "choice" (a text
    /// or number question), a key unknown in a question or an option, a question asked
    /// twice or a label given twice in one question, make it `nil`.
    static func parse(_ input: [String: ApprovalValue]) -> (questions: [ApprovalQuestion], title: String)? {
        guard Set(input.keys).isSubset(of: ["questions", "title", "metadata"]),
              case .array(let items)? = input["questions"], questions.contains(items.count)
        else { return nil }
        var title = ""
        if let value = input["title"] {
            guard let text = value.string else { return nil }
            title = text
        }
        if let value = input["metadata"] {
            guard case .object(let fields) = value, Set(fields.keys).isSubset(of: ["source"]),
                  fields["source"].map({ $0.string != nil }) ?? true
            else { return nil }
        }
        var parsed: [ApprovalQuestion] = []
        for item in items {
            guard case .object(let fields) = item,
                  Set(fields.keys).isSubset(of: ["question", "header", "options", "multiSelect", "kind"]),
                  let text = fields["question"]?.string, !text.isEmpty,
                  fields["kind"].map({ $0 == .string("choice") }) ?? true,
                  case .array(let list)? = fields["options"], options.contains(list.count)
            else { return nil }
            var header = ""
            if let value = fields["header"] {
                guard let words = value.string else { return nil }
                header = words
            }
            var multiSelect = false
            if let value = fields["multiSelect"] {
                guard case .bool(let flag) = value else { return nil }
                multiSelect = flag
            }
            var choices: [ApprovalQuestion.Option] = []
            for entry in list {
                guard case .object(let option) = entry,
                      Set(option.keys).isSubset(of: ["label", "description", "preview"]),
                      let label = option["label"]?.string, !label.isEmpty,
                      option["description"].map({ $0.string != nil }) ?? true,
                      option["preview"].map({ $0.string != nil }) ?? true
                else { return nil }
                choices.append(.init(label: label, description: option["description"]?.string ?? "",
                                     preview: option["preview"]?.string))
            }
            guard Set(choices.map(\.label)).count == choices.count else { return nil }
            parsed.append(ApprovalQuestion(text: text, header: header, options: choices, multiSelect: multiSelect))
        }
        guard Set(parsed.map(\.text)).count == parsed.count else { return nil }
        return (parsed, title)
    }

    /// The newest Unicode the hook's check knows (/usr/bin/jq's tables): a character
    /// added since is unassigned to it, so turned away there. Islet turns it away first.
    static let hookUnicode = (major: 15, minor: 0)

    /// What keeps `words` from going as an answer, `nil` for nothing: more than
    /// `wordsLimit` characters (as the hook counts them, by code point) or only spaces
    /// (`.tooLong`, `.blank`), or a character a reader could not see or that the hook
    /// does not know. One line, every space an ordinary one, no control, format, bidi,
    /// zero-width, tag or private character, nothing drawn as nothing, no more than two
    /// marks stacked on a letter. An emoji's own joiners are let through: the
    /// presentation selector after an emoji, the keycap after a digit, # or *, and the
    /// zero-width joiner between two emoji (❤️, 1️⃣, 👨‍👩‍👧). The hook applies
    /// the same rule, step for step (`approval_choices`).
    static func wordsProblem(_ words: String) -> WordsProblem? {
        guard !words.isEmpty else { return nil }
        let all = Array(words.unicodeScalars)
        guard all.count <= wordsLimit else { return .tooLong }
        guard words.contains(where: { !$0.isWhitespace }) else { return .blank }
        for scalar in all {
            guard let age = scalar.properties.age,
                  (age.major, age.minor) <= hookUnicode else { return .character(scalar) }
        }
        let isEmoji = { (s: Unicode.Scalar) in s.properties.isEmoji }
        let isPictured = { (s: Unicode.Scalar) in s.properties.isEmoji && !s.isASCII }
        // A keycap: a digit, # or *, the presentation selector if any, then U+20E3.
        var rest: [Unicode.Scalar] = []
        var index = 0
        while index < all.count {
            let keyed = index > 0 && "0123456789#*".unicodeScalars.contains(all[index - 1])
            if keyed, all[index].value == 0xFE0F, index + 1 < all.count, all[index + 1].value == 0x20E3 {
                index += 2
                continue
            }
            if keyed, all[index].value == 0x20E3 { index += 1; continue }
            rest.append(all[index])
            index += 1
        }
        // The presentation selector after an emoji.
        rest = rest.enumerated().filter { at, scalar in
            !(scalar.value == 0xFE0F && at > 0 && isEmoji(rest[at - 1]))
        }.map(\.element)
        // The joiner between two emoji.
        rest = rest.enumerated().filter { at, scalar in
            !(scalar.value == 0x200D && at > 0 && at + 1 < rest.count && isPictured(rest[at - 1]) && isPictured(rest[at + 1]))
        }.map(\.element)
        var marks = 0
        for scalar in rest {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
                return .character(scalar)
            case .spaceSeparator where scalar.value != 0x20:
                return .character(scalar)
            case .nonspacingMark, .enclosingMark, .spacingMark:
                // Every kind of mark: Unicode moves some from one kind to another (U+1171E
                // was nonspacing in the hook's tables, is spacing in Islet's).
                marks += 1
                if marks > 2 { return .character(scalar) }
            default:
                marks = 0
            }
            if ApprovalText.isBlank(scalar.value) { return .character(scalar) }
        }
        return nil
    }

    enum WordsProblem: Equatable {
        case tooLong
        case blank
        case character(Unicode.Scalar)

        /// In a few words, short enough to sit beside the buttons, naming the character:
        /// itself where it can be seen, and its code.
        var words: String {
            switch self {
            case .tooLong: return "Keep your own answer under \(ApprovalQuestions.wordsLimit) characters"
            case .blank: return "Your own answer needs more than spaces"
            case .character(let scalar):
                let code = "U+" + String(format: "%04X", scalar.value)
                let seen: Bool = switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate,
                     .spaceSeparator, .nonspacingMark, .enclosingMark, .spacingMark: false
                default: !ApprovalText.isBlank(scalar.value)
                }
                return seen ? "Can't send “\(Character(scalar))” (\(code))" : "Can't send hidden \(code)"
            }
        }
    }

    /// Why `choices` cannot be sent for `questions`, in a few words; `nil` when they can:
    /// one for each question, each answered, one option or the person's words alone
    /// where only one is taken, every option one there is, the words allowed.
    static func problem(_ choices: [ApprovalChoice], for questions: [ApprovalQuestion]) -> String? {
        guard choices.count == questions.count else { return "Choose an answer to each question" }
        for (choice, question) in zip(choices, questions) {
            guard choice.isAnswered else {
                return questions.count == 1 ? "Choose an answer first" : "Choose an answer to each question"
            }
            if let problem = wordsProblem(choice.words) { return problem.words }
            guard choice.options.allSatisfy(question.options.indices.contains) else { return "Choose again" }
            if !question.multiSelect, choice.options.count + (choice.words.isEmpty ? 0 : 1) > 1 {
                return "Choose one answer, or write your own"
            }
        }
        return nil
    }

    /// The choices as the answer file carries them: `[{"o": [1]}, {"o": [0, 2], "other": "…"}]`,
    /// the numbers ascending.
    static func wire(_ choices: [ApprovalChoice]) -> [[String: Any]] {
        choices.map { choice in
            var entry: [String: Any] = ["o": choice.options.sorted()]
            if !choice.words.isEmpty { entry["other"] = choice.words }
            return entry
        }
    }

    /// What the signature covers of the choices, which the hook works out from the file
    /// the same way: for each question in order, its number, `=`, the options' numbers
    /// ascending and joined by commas, and for words of the person's own `:` and their
    /// UTF-8 in base64; the questions joined by `;`. "0=1;1=0,2:T25l".
    static func signed(_ choices: [ApprovalChoice]) -> String {
        choices.enumerated().map { index, choice in
            var part = "\(index)=" + choice.options.sorted().map(String.init).joined(separator: ",")
            if !choice.words.isEmpty { part += ":" + Data(choice.words.utf8).base64EncodedString() }
            return part
        }.joined(separator: ";")
    }

    /// Whether two of a question's labels could be taken for each other: the same once
    /// capitals, accents and widths are set aside, spaces either side dropped and runs
    /// of them read as one, and letters from other scripts that look like Latin ones
    /// read as those ("Yes" and "Yеs" with a Cyrillic е, "No" and "Νo" with a Greek Ν,
    /// "Yes" and "Yes ").
    static func looksAlike(_ labels: [String]) -> Bool {
        let skeletons = labels.map(skeleton)
        return Set(skeletons).count < skeletons.count
    }

    private static func skeleton(_ text: String) -> String {
        // Capitals first, whose small letters can look like other Latin ones (Greek Ν
        // is an N, its small ν a v).
        var latin = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { latin.append(capitalLookAlikes[scalar] ?? scalar) }
        let folded = String(latin).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        var space = false
        for scalar in folded.unicodeScalars where !scalar.properties.isDefaultIgnorableCodePoint {
            if scalar.properties.isWhitespace || ApprovalText.isBlank(scalar.value) {
                space = true
                continue
            }
            if space, !scalars.isEmpty { scalars.append(" ") }
            space = false
            scalars.append(lookAlikes[scalar] ?? scalar)
        }
        return String(scalars)
    }

    /// Capitals of Greek and Cyrillic drawn like Latin ones, and the Latin letters
    /// (small) they pass for.
    private static let capitalLookAlikes: [Unicode.Scalar: Unicode.Scalar] = table([
        (0x0391, "a"), (0x0392, "b"), (0x0395, "e"), (0x0396, "z"), (0x0397, "h"), (0x0399, "l"), (0x039A, "k"),
        (0x039C, "m"), (0x039D, "n"), (0x039F, "o"), (0x03A1, "p"), (0x03A4, "t"), (0x03A5, "y"), (0x03A7, "x"),
        (0x03F9, "c"), (0x037F, "j"),
        (0x0410, "a"), (0x0412, "b"), (0x0415, "e"), (0x0401, "e"), (0x0405, "s"), (0x0406, "l"), (0x0407, "l"),
        (0x0408, "j"), (0x041A, "k"), (0x041C, "m"), (0x041D, "h"), (0x041E, "o"), (0x0420, "p"), (0x0421, "c"),
        (0x0422, "t"), (0x0423, "y"), (0x0425, "x"), (0x04AE, "y"), (0x04BA, "h"), (0x04C0, "l"), (0x051A, "q"),
        (0x051C, "w"), (0x0417, "3"),
    ])

    /// Small letters of Cyrillic and Greek drawn like Latin ones, and the Latin letters
    /// they pass for.
    private static let lookAlikes: [Unicode.Scalar: Unicode.Scalar] = {
        var map = table([
            (0x0430, "a"), (0x0432, "b"), (0x0435, "e"), (0x0451, "e"), (0x0456, "i"), (0x0457, "i"), (0x0458, "j"),
            (0x043A, "k"), (0x043C, "m"), (0x043D, "h"), (0x043E, "o"), (0x0440, "p"), (0x0441, "c"), (0x0442, "t"),
            (0x0443, "y"), (0x0445, "x"), (0x0455, "s"), (0x0501, "d"), (0x051B, "q"), (0x051D, "w"), (0x04BB, "h"),
            (0x04AF, "y"), (0x04CF, "l"), (0x0261, "g"), (0x03B1, "a"), (0x03B2, "b"), (0x03B5, "e"), (0x03B9, "i"),
            (0x03BA, "k"), (0x03BD, "v"), (0x03BF, "o"), (0x03C1, "p"), (0x03C4, "t"), (0x03C5, "u"), (0x03C7, "x"),
            (0x0131, "i"), (0x217C, "l"), (0x0399, "i"), (0x039F, "o"), (0x041E, "o"), (0x0406, "i"),
        ])
        // Digits that pass for letters, and the other way about, read alike too.
        map["0"] = "o"
        map["1"] = "l"
        map["i"] = "l"
        return map
    }()

    private static func table(_ pairs: [(UInt32, Character)]) -> [Unicode.Scalar: Unicode.Scalar] {
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (code, latin) in pairs {
            if let scalar = Unicode.Scalar(code) { map[scalar] = latin.unicodeScalars.first! }
        }
        return map
    }
}

/// The sizes of a question's card, laid out line by line as the request's body is
/// (`ApprovalLines`), so its height is known before it is drawn.
enum ApprovalQuestionLayout {
    /// Between one question and the next.
    static let questionSpacing: CGFloat = 12
    /// Between a question and its options.
    static let optionsTop: CGFloat = 6
    /// Between options.
    static let optionSpacing: CGFloat = 4
    /// An option's padding above and below its words.
    static let optionPadding: CGFloat = 5
    /// The option's mark (a circle, or a square where several may be chosen), and the
    /// room either side of its words.
    static let markWidth: CGFloat = 24
    static let optionTrailing: CGFloat = 8
    /// The field for words of the person's own.
    static let fieldHeight: CGFloat = 24
    /// Between the title and the first question.
    static let titleSpacing: CGFloat = 8

    /// The width an option's words are laid out to, as `ApprovalLines` takes a width
    /// (its padding either side included): the body's, less the mark and the room after
    /// the words.
    static func optionTextWidth(_ width: CGFloat) -> CGFloat {
        width - markWidth - optionTrailing
    }

    /// The question's own words, its header above them.
    static func questionSection(_ question: ApprovalQuestion, index: Int, count: Int) -> ApprovalSection {
        var label = question.header
        if count > 1 { label = (label.isEmpty ? "Question" : label) + " · \(index + 1) of \(count)" }
        if question.multiSelect { label += label.isEmpty ? "Choose any" : " · choose any" }
        return ApprovalSection(label: label.isEmpty ? nil : label, text: question.text, style: .plain)
    }

    /// An option's label and what it says of itself.
    static func optionSections(_ option: ApprovalQuestion.Option) -> [ApprovalSection] {
        [ApprovalSection(label: nil, text: option.label, style: .plain)]
            + (option.description.isEmpty ? [] : [ApprovalSection(label: nil, text: option.description, style: .prose)])
    }

    /// The height of `sections` without the body's padding.
    static func textHeight(_ sections: [ApprovalSection], width: CGFloat) -> CGFloat {
        ApprovalLines.height(sections, width: width) - 2 * ApprovalLines.padding
    }

    static func optionHeight(_ option: ApprovalQuestion.Option, width: CGFloat) -> CGFloat {
        textHeight(optionSections(option), width: optionTextWidth(width)) + 2 * optionPadding
    }

    static func titleHeight(_ title: String, width: CGFloat) -> CGFloat {
        title.isEmpty ? 0 : textHeight([ApprovalSection(label: nil, text: title, style: .prose)], width: width) + titleSpacing
    }

    static func questionHeight(_ question: ApprovalQuestion, index: Int, count: Int, width: CGFloat) -> CGFloat {
        textHeight([questionSection(question, index: index, count: count)], width: width) + optionsTop
            + question.options.map { optionHeight($0, width: width) }.reduce(0, +)
            + CGFloat(question.options.count) * optionSpacing + fieldHeight
    }

    /// All of it, padding included, at the body's `width`.
    static func height(_ questions: [ApprovalQuestion], title: String, width: CGFloat) -> CGFloat {
        let parts = questions.enumerated().map { questionHeight($1, index: $0, count: questions.count, width: width) }
        return 2 * ApprovalLines.padding + titleHeight(title, width: width) + parts.reduce(0, +)
            + CGFloat(max(0, questions.count - 1)) * questionSpacing
    }
}
