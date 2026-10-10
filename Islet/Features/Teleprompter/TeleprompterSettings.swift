import AppKit
import Carbon.HIToolbox
import Speech
import SwiftUI
import UniformTypeIdentifiers

/// The keys that work in any app while a reading is under way, as system hot keys: the
/// call app never sees them, and they need no Accessibility. They are registered from
/// Start to Stop and at no other time, so they take nothing from other apps the rest
/// of the day.
enum TeleprompterHotKey: String, CaseIterable, Identifiable {
    case startPause
    case lineBack
    case lineOn
    case slower
    case faster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startPause: "Start or pause"
        case .lineBack: "Back a line"
        case .lineOn: "On a line"
        case .slower: "Slower"
        case .faster: "Faster"
        }
    }

    /// ⌃⌥ with Space and the arrows: clear of the system's and of the usual call apps'.
    var standard: KeyCombo {
        let modifiers = UInt32(controlKey | optionKey)
        switch self {
        case .startPause: return KeyCombo(keyCode: UInt32(kVK_Space), modifiers: modifiers)
        case .lineBack: return KeyCombo(keyCode: UInt32(kVK_UpArrow), modifiers: modifiers)
        case .lineOn: return KeyCombo(keyCode: UInt32(kVK_DownArrow), modifiers: modifiers)
        case .slower: return KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: modifiers)
        case .faster: return KeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: modifiers)
        }
    }

    /// Its id among Islet's hot keys (`InputHotKey`).
    var hotKeyID: UInt32 {
        InputHotKey.firstOtherID + UInt32(Self.allCases.firstIndex(of: self) ?? 0)
    }

    var key: String { "teleprompter.key.\(rawValue)" }

    /// The combination kept for it: the standard one until another is chosen, `nil` for
    /// None.
    func combo(in defaults: UserDefaults) -> KeyCombo? {
        guard let values = defaults.array(forKey: key) as? [Int] else { return standard }
        guard values.count == 2, let code = UInt32(exactly: values[0]), let mods = UInt32(exactly: values[1]) else {
            return nil
        }
        return KeyCombo(keyCode: code, modifiers: mods)
    }

    func store(_ combo: KeyCombo?, in defaults: UserDefaults) {
        defaults.set(combo?.stored ?? [], forKey: key)
    }
}

/// The teleprompter's options in Settings: the scripts, how it moves, how it looks, and
/// what it keeps from screen sharing.
struct TeleprompterSettingsView: View {
    let scripts: TeleprompterScripts
    /// Combinations another app has, by hot key, as last registered.
    let keyProblems: [TeleprompterHotKey: String]
    @AppStorage(TeleprompterSettings.Key.mode) private var mode = TeleprompterMode.follow
    @AppStorage(TeleprompterSettings.Key.wordsPerMinute) private var wordsPerMinute = TeleprompterLayout.standardPace
    @AppStorage(TeleprompterSettings.Key.textSize) private var textSize = Double(TeleprompterLayout.standardSize)
    @AppStorage(TeleprompterSettings.Key.lines) private var lines = TeleprompterLayout.standardLines
    @AppStorage(TeleprompterSettings.Key.countdown) private var countdown = 3
    @AppStorage(TeleprompterSettings.Key.mirror) private var mirror = false
    @AppStorage(TeleprompterSettings.Key.hideFromCapture) private var hideFromCapture = true
    @AppStorage(TeleprompterSettings.Key.language) private var language = VoiceLanguage.automatic
    @AppStorage(TeleprompterSettings.Key.shortcuts) private var shortcuts = true
    @State private var languages: [Locale] = []
    @State private var keys: [TeleprompterHotKey: KeyCombo?] = [:]

    static let hideFootnote = "Asks macOS to keep the script out of screenshots and recordings. Some apps, QuickTime among them, may still capture it."
    static let followFootnote = "Listens through the microphone while it runs, and recognises your voice on this Mac: nothing you say is sent anywhere. Pausing turns the microphone off. Headphones keep a call's voices from moving it."

    var body: some View {
        TeleprompterScriptEditor(scripts: scripts)

        Picker(selection: $mode) {
            ForEach(TeleprompterMode.allCases) { Text($0.title).tag($0) }
        } label: {
            Text("Moves")
            if mode == .follow { Text(Self.followFootnote) }
        }
        if mode == .follow {
            Picker("Language", selection: $language) {
                Text("Same as the script").tag(VoiceLanguage.automatic)
                ForEach(languages, id: \.identifier) { locale in
                    Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
                }
                if language != VoiceLanguage.automatic, !languages.contains(where: { $0.identifier == language }) {
                    Text(Locale.current.localizedString(forIdentifier: language) ?? language).tag(language)
                }
            }
            .task { languages = await Self.recognisedLanguages() }
        }
        LabeledContent("Words a minute") {
            HStack(spacing: 6) {
                SettingsNumberField(value: $wordsPerMinute, range: TeleprompterLayout.paces, label: "Words a minute")
                Stepper("Words a minute", value: $wordsPerMinute, in: TeleprompterLayout.paces, step: TeleprompterLayout.paceStep)
                    .labelsHidden()
            }
        }
        Picker("Text size", selection: $textSize) {
            ForEach(Array(stride(from: TeleprompterLayout.sizes.lowerBound, through: TeleprompterLayout.sizes.upperBound, by: 2)), id: \.self) { size in
                Text("\(Int(size)) pt").tag(Double(size))
            }
        }
        Picker("Lines shown", selection: $lines) {
            ForEach(Array(TeleprompterLayout.lineCounts), id: \.self) { Text("\($0)").tag($0) }
        }
        Picker("Countdown", selection: $countdown) {
            Text("None").tag(0)
            Text("3 seconds").tag(3)
            Text("5 seconds").tag(5)
        }
        Toggle("Mirror the text", isOn: $mirror)
        Toggle(isOn: $hideFromCapture) {
            Text("Hide from screen sharing")
            Text(Self.hideFootnote)
        }
        Toggle(isOn: $shortcuts) {
            Text("Keyboard shortcuts while it runs")
            Text("Work in any app, and the app in front never sees them.")
        }
        if shortcuts {
            ForEach(TeleprompterHotKey.allCases) { hotKey in
                LabeledContent(hotKey.title) {
                    ShortcutRecorder(combo: combo(for: hotKey), problem: keyProblems[hotKey]) { combo in
                        hotKey.store(combo, in: .standard)
                        keys[hotKey] = .some(combo)
                    }
                }
            }
        }
    }

    private func combo(for hotKey: TeleprompterHotKey) -> KeyCombo? {
        if let chosen = keys[hotKey] { return chosen }
        return hotKey.combo(in: .standard)
    }

    /// The languages this Mac recognises on its own, by name.
    static func recognisedLanguages() async -> [Locale] {
        var locales: [Locale]
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            locales = await SpeechTranscriber.supportedLocales
        } else {
            locales = SFSpeechRecognizer.supportedLocales().filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
        }
        let current = Locale.current
        return locales.sorted {
            (current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                .localizedStandardCompare(current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier) == .orderedAscending
        }
    }
}

/// The scripts: one chosen from the list, its name and words to edit, and a new one
/// pasted in or imported from a file.
struct TeleprompterScriptEditor: View {
    let scripts: TeleprompterScripts
    @State private var importProblem: String?

    var body: some View {
        LabeledContent("Script") {
            HStack(spacing: 6) {
                Picker("Script", selection: selection) {
                    ForEach(scripts.scripts) { script in
                        Text(script.shownTitle).tag(Optional(script.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .disabled(scripts.scripts.isEmpty)
                Menu {
                    Button("New Script") { scripts.add() }
                    Button("Paste as New Script") { paste() }
                    Button("Import…") { importFile() }
                    if let id = scripts.selected?.id {
                        Divider()
                        Button("Delete Script", role: .destructive) { scripts.delete(id) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add, import or delete a script")
            }
        }
        if let problem = importProblem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let script = scripts.selected {
            TextField("Name", text: Binding(
                get: { scripts.script(id: script.id)?.title ?? "" },
                set: { scripts.update(script.id, title: $0) }
            ), prompt: Text(script.shownTitle))
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: Binding(
                    get: { scripts.script(id: script.id)?.text ?? "" },
                    set: { scripts.update(script.id, text: $0) }
                ))
                .font(.system(size: 13))
                .frame(height: 150)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                Text("\(script.wordCount) words. Words in [square brackets] are cues: shown, never listened for. A new line starts a new line on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No scripts yet. Add one with +, paste one in, or import a text, Markdown, RTF or Word file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selection: Binding<UUID?> {
        Binding(get: { scripts.selected?.id }, set: { scripts.selectedID = $0 })
    }

    private func paste() {
        importProblem = nil
        guard let text = NSPasteboard.general.string(forType: .string),
              text.contains(where: { $0.isLetter || $0.isNumber }) else {
            importProblem = "There's no text on the clipboard."
            return
        }
        scripts.add(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func importFile() {
        importProblem = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = TeleprompterScripts.importTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a script: text, Markdown, RTF or Word."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try scripts.importScript(from: url)
        } catch {
            importProblem = error.localizedDescription
        }
    }
}
