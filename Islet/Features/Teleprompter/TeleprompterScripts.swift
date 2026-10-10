import AppKit
import Observation
import UniformTypeIdentifiers

/// One script: its words, a name for it, and the place it was left at, so reading it
/// again carries on from there.
struct TeleprompterScript: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var text: String
    var modified: Date
    /// The word reading last stopped at; 0 for the start.
    var lastWord: Int

    init(id: UUID = UUID(), title: String, text: String, modified: Date = Date(), lastWord: Int = 0) {
        self.id = id
        self.title = title
        self.text = text
        self.modified = modified
        self.lastWord = lastWord
    }

    /// The title, or the script's first words when it has none.
    var shownTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let words = text.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " ")
        return words.isEmpty ? "Untitled script" : words
    }

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }

    /// A script to try it with, and the one a preview reads. Never saved unless the
    /// person edits it.
    static let sample = TeleprompterScript(
        title: "Welcome",
        text: """
        Good morning, everyone, and thank you for joining us today.
        Over the last 12 months our team has shipped more than forty features, and I'd like to walk you through the three that mattered most.
        [pause]
        The first is the new onboarding flow, which cut the time to a first project from eleven minutes to under four.
        The second is offline sync. People told us they work on trains and planes, so the app now keeps working without a network.
        The third is accessibility: every screen now works with VoiceOver, and we doubled the contrast of our smallest text.
        [look up]
        Let's start with onboarding.
        """
    )
}

/// The scripts kept, in `scripts.json` under Application Support/Islet/Teleprompter,
/// written whole and atomically as they change, and which one was read last.
///
/// Editing writes after a moment's pause in the typing rather than at every key.
@MainActor
@Observable
final class TeleprompterScripts {
    private(set) var scripts: [TeleprompterScript] = []
    /// The script chosen, which Start reads: the one last read or edited.
    var selectedID: UUID? {
        didSet { if selectedID != oldValue { scheduleSave() } }
    }

    /// Told as a script is added, edited, deleted or chosen, so a reading not under way
    /// can show it.
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    /// How long after the last change the file is written.
    @ObservationIgnored var saveDelay: TimeInterval = 0.8

    private struct Stored: Codable {
        var scripts: [TeleprompterScript]
        var selected: UUID?
    }

    nonisolated static var standardFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Islet/Teleprompter", isDirectory: true)
    }

    init(folder: URL = TeleprompterScripts.standardFolder) {
        file = folder.appendingPathComponent("scripts.json")
        load()
    }

    var selected: TeleprompterScript? {
        scripts.first { $0.id == selectedID } ?? scripts.first
    }

    func script(id: UUID) -> TeleprompterScript? {
        scripts.first { $0.id == id }
    }

    // MARK: Changes

    /// Adds a script and chooses it.
    @discardableResult
    func add(title: String = "", text: String = "") -> TeleprompterScript {
        let script = TeleprompterScript(title: title, text: text)
        scripts.insert(script, at: 0)
        selectedID = script.id
        scheduleSave()
        return script
    }

    func update(_ id: UUID, title: String? = nil, text: String? = nil) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        if let title { scripts[index].title = title }
        if let text, text != scripts[index].text {
            scripts[index].text = text
            // An edit may have moved every word; reading starts over.
            scripts[index].lastWord = 0
        }
        scripts[index].modified = Date()
        scheduleSave()
    }

    /// Where reading stopped, to carry on from next time.
    func remember(place word: Int, in id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }), scripts[index].lastWord != word else { return }
        scripts[index].lastWord = max(0, word)
        scheduleSave()
    }

    func delete(_ id: UUID) {
        scripts.removeAll { $0.id == id }
        if selectedID == id { selectedID = scripts.first?.id }
        scheduleSave()
    }

    // MARK: Importing

    /// The kinds of file Import takes.
    static let importTypes: [UTType] = [.plainText, .text, .rtf, UTType("net.daringfireball.markdown") ?? .plainText,
                                        UTType("org.openxmlformats.wordprocessingml.document") ?? .data]

    enum ImportError: LocalizedError {
        case unreadable(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Islet couldn't read \(name) as text."
            case .empty(let name): "\(name) has no words in it."
            }
        }
    }

    /// The words of a file, as plain text: a text or Markdown file as it is (Markdown's
    /// marks for headings, emphasis and lists taken off), a rich text or Word file
    /// without its formatting.
    nonisolated static func plainText(of url: URL) throws -> String {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        var text: String
        switch ext {
        case "rtf", "rtfd", "docx", "doc", "odt", "html", "htm":
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            guard let attributed = try? NSAttributedString(url: url, options: options, documentAttributes: nil) else {
                throw ImportError.unreadable(name)
            }
            text = attributed.string
        default:
            guard let data = try? Data(contentsOf: url),
                  let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
                    ?? String(data: data, encoding: .isoLatin1) else {
                throw ImportError.unreadable(name)
            }
            text = ext == "md" || ext == "markdown" ? plainMarkdown(decoded) : decoded
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { throw ImportError.empty(name) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Markdown read aloud: headings', quotes' and lists' marks off the start of each
    /// line, emphasis and code marks out, and a link's words kept without its address.
    nonisolated static func plainMarkdown(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = Substring(raw)
            while let first = line.first, "#>".contains(first) { line = line.dropFirst() }
            line = line.drop { $0 == " " }
            for mark in ["- ", "* ", "+ "] where line.hasPrefix(mark) { line = line.dropFirst(2) }
            var plain = String(line)
            // [words](address) → words
            if let link = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#) {
                plain = link.stringByReplacingMatches(
                    in: plain, range: NSRange(plain.startIndex..., in: plain), withTemplate: "$1"
                )
            }
            for mark in ["**", "__", "`"] { plain = plain.replacingOccurrences(of: mark, with: "") }
            lines.append(plain)
        }
        return lines.joined(separator: "\n")
    }

    /// Adds a script from a file, named after it, and chooses it.
    @discardableResult
    func importScript(from url: URL) throws -> TeleprompterScript {
        let text = try Self.plainText(of: url)
        return add(title: url.deletingPathExtension().lastPathComponent, text: text)
    }

    // MARK: Storage

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data) else {
            // Kept aside rather than overwritten by the next save, in case it can be put
            // right by hand.
            let aside = file.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            return
        }
        scripts = stored.scripts
        selectedID = stored.selected ?? stored.scripts.first?.id
    }

    private func scheduleSave() {
        changed()
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// Writes at once: as Islet quits, or the feature stops, with a change waiting.
    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Stored(scripts: scripts, selected: selectedID))
            try data.write(to: file, options: .atomic)
        } catch {
            IslandLog.app.error("Teleprompter scripts not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether a change is waiting to be written.
    var hasUnsavedChanges: Bool { saveWork != nil }
}
