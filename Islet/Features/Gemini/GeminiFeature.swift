import AppKit
import SwiftUI

/// Gemini at work, in Google Antigravity and in Gemini CLI, beside the notch: a wand left
/// of the camera while an agent works on a conversation, a question mark while one has stopped to ask
/// something, a warning while one has stopped on an error or run out of quota, and right
/// of it how long the run has been going, or a ring filling as its task list gets done.
/// Opened, a row for each conversation, labelled with where it runs (Antigravity, or the
/// terminal a Gemini CLI session is in): its title (Antigravity's, the start of what was
/// asked, or a CLI session's latest prompt), its workspace and model, what it is doing and
/// for how long, the tools it has used so far, and its task list as a checklist. Clicking
/// one, or a banner its hook put up, brings Antigravity forward, which can't be asked from
/// outside to open a conversation; or for a CLI session, Terminal or iTerm at its tab, as
/// for Claude Code in a terminal (`GeminiCLIHost`).
///
/// Antigravity says what its agents do through its hooks, and
/// `Scripts/antigravity-hook.sh` keeps a file per conversation for Islet
/// (`GeminiSessionMonitor`), alongside the banners it puts up. The hook only tells:
/// it answers each event with the answer that leaves Antigravity's own course alone, and
/// is never asked about a tool before it runs. So nothing is approved from the island.
/// Each conversation's title and task list come from Antigravity's own files, read-only
/// (`GeminiData`). Gemini CLI tells Islet through its own hooks
/// (`Scripts/gemini-cli-hook.sh`), into the same folder, each file marked as the CLI's: it
/// answers every event with the answer that changes nothing, and Gemini CLI gives a hook no
/// way to allow a tool, so its permissions are told, not answered. Without the hooks there
/// are no files, and nothing shows.
///
/// An agent finishing in the conversation Antigravity has in front puts up no banner
/// unless Settings asks for one (`GeminiDoneOnScreen`): Antigravity names the
/// conversation it shows in its window's title, which Islet reads through Accessibility.
/// For a CLI session the tab in front of Terminal or iTerm says, where Islet may already
/// ask them (`GeminiTerminalFront`). Where it cannot be told, the banner shows.
///
/// A question the agent puts, or a tool waiting for leave, sends no hook event while
/// it waits; Antigravity's list of conversations says so, and the feature puts up the
/// banner for it itself (`GeminiWaitBanner`), while Antigravity is not in front.
///
/// Gemini's quota shows atop the page, on the AI Usage tile and from 80% round the mark
/// (`UsageCenter`), asked of Antigravity while it is open (`GeminiUsage`); a hook event
/// from Antigravity is a moment to ask again.
///
/// A background activity: it never takes the island from music or a timer, and sits in
/// the bubble beside them instead, as Claude Code and ChatGPT do. There it gives way to
/// the Sound Mixer, but for while a conversation is waiting on the person.
@MainActor
final class GeminiFeature: Feature {
    let id = "gemini"
    let title = "Gemini"
    let symbol = "wand.and.stars"
    let summary = "What Gemini's agents in Google Antigravity and Gemini CLI are doing, from their hooks."
    var islandActivity: IslandActivityInfo? { IslandActivityInfo(self, order: 77) }
    var sharedHomeTile: HomeTileInfo? { UsageCenter.tileInfo }

    /// How long a preview's made-up conversations show.
    static let previewLength: TimeInterval = 12

    let model = GeminiModel()
    let monitor: GeminiSessionMonitor
    /// Gemini's quota.
    let usage: UsageCenter
    private let clock: () -> Date
    private let activate: @MainActor (_ bundleID: String) -> Bool
    private let look: @MainActor (_ bundleID: String) -> ChatScreenLook
    private let windowTitle: @MainActor (_ bundleID: String) -> String?
    private let titles: () -> [String: String]?
    private let announce: @MainActor (CustomBanner) -> Void
    private let openCLI: @MainActor (GeminiSessionRecord) -> Bool
    private let terminalTab: @MainActor (_ bundleID: String) -> GeminiTerminalTab?
    /// The conversations whose wait has had its banner, and what they wait for.
    private var announced: [String: GeminiWaiting] = [:]
    private lazy var activity = GeminiActivity(model: model, usage: usage) { [weak self] session in
        self?.open(session)
    }

    private var isRunning = false
    private var published: GeminiActivity.Published?
    private var previewWork: DispatchWorkItem?
    private var defaultsObserver: NSObjectProtocol?
    private var usageObserver: NSObjectProtocol?
    /// When Antigravity's hook was last heard from, as the quota was last nudged.
    private var nudged: Date?

    /// Tests give a monitor on a folder of their own, a clock, a stand-in for bringing
    /// Antigravity forward, their own look at the screen, its window's title and the
    /// conversations' titles, a stand-in for putting up a banner, and for a CLI session,
    /// stand-ins for bringing its terminal forward and for the tab a terminal has in front,
    /// and their own usage.
    init(
        monitor: GeminiSessionMonitor? = nil,
        clock: @escaping () -> Date = Date.init,
        activate: @escaping @MainActor (_ bundleID: String) -> Bool = ClaudeHostApps.activate,
        look: @escaping @MainActor (_ bundleID: String) -> ChatScreenLook = { AppInFront.shared.look(for: $0) },
        windowTitle: @escaping @MainActor (_ bundleID: String) -> String? = GeminiWindowTitle.read,
        titles: @escaping () -> [String: String]? = GeminiWindowTitle.conversationTitles,
        announce: @escaping @MainActor (CustomBanner) -> Void = { banner in
            FeatureRegistry.shared.feature(BannerFeature.self)?.show(banner)
        },
        openCLI: @escaping @MainActor (GeminiSessionRecord) -> Bool = GeminiCLIHost.open,
        terminalTab: @escaping @MainActor (_ bundleID: String) -> GeminiTerminalTab? = GeminiTerminalFront.frontTab,
        usage: UsageCenter? = nil
    ) {
        self.monitor = monitor ?? GeminiSessionMonitor(now: clock)
        self.usage = usage ?? .shared
        self.clock = clock
        self.activate = activate
        self.look = look
        self.windowTitle = windowTitle
        self.titles = titles
        self.announce = announce
        self.openCLI = openCLI
        self.terminalTab = terminalTab
        model.onChange = { [weak self] in self?.sync() }
        self.monitor.onChange = { [weak self] snapshot in self?.received(snapshot) }
    }

    func start() {
        isRunning = true
        AppInFront.shared.start()
        // Showing or hiding the prompts changes the opened page's height.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        // The usage line and the limit change the page's height and the right side's width.
        usageObserver = NotificationCenter.default.addObserver(
            forName: UsageCenter.didChange, object: usage, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        monitor.start()
        usage.start(.gemini)
    }

    func stop() {
        isRunning = false
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        if let usageObserver { NotificationCenter.default.removeObserver(usageObserver) }
        usageObserver = nil
        usage.stop(.gemini)
        nudged = nil
        monitor.stop()
        announced = [:]
        model.update([], lastHeard: model.lastHeard, lastHeardCLI: model.lastHeardCLI)
        sync()
    }

    func settingsView() -> AnyView? {
        AnyView(GeminiSettingsView(model: model))
    }

    /// Made-up conversations, not the person's, for twelve seconds. Clicking one does
    /// nothing.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Agent working through its tasks") { [weak self] in
                self?.preview(GeminiSamples.working(now: Date()))
            },
            FeaturePreview(title: "Agent asking a question") { [weak self] in
                self?.preview(GeminiSamples.asking(now: Date()))
            },
            FeaturePreview(title: "Agent out of quota") { [weak self] in
                self?.preview(GeminiSamples.quota(now: Date()))
            },
            FeaturePreview(title: "Several agents") { [weak self] in
                self?.preview(GeminiSamples.several(now: Date()))
            },
            FeaturePreview(title: "Gemini CLI asking permission") { [weak self] in
                self?.preview(GeminiSamples.cliPermission(now: Date()))
            },
            FeaturePreview(title: "Gemini CLI beside Antigravity") { [weak self] in
                self?.preview(GeminiSamples.together(now: Date()))
            },
        ]
    }

    // MARK: Island

    private func received(_ snapshot: GeminiSessionSnapshot) {
        // An agent at work in Antigravity uses the quota: a moment to ask again.
        if isRunning, let heard = snapshot.lastHeard, heard != nudged {
            nudged = heard
            usage.geminiEvent()
        }
        let sessions = GeminiLiveness.sessions(snapshot, now: clock())
        model.update(isRunning ? sessions : [], lastHeard: snapshot.lastHeard, lastHeardCLI: snapshot.lastHeardCLI)
        if isRunning { announceWaits(sessions) }
    }

    /// Puts up a banner for each conversation newly waiting on the person where only
    /// Antigravity's list says so, as the hook hears nothing until the wait is over; a
    /// wait the hook told of has had its banner from the hook, as every CLI session's has.
    /// Only while Antigravity is not in front, where the person sees the wait already.
    private func announceWaits(_ sessions: [GeminiSession]) {
        var waiting: [String: GeminiWaiting] = [:]
        for session in sessions where session.state == .needsInput && !session.record.isCLI {
            if let kind = session.waiting { waiting[session.id] = kind }
        }
        let fresh = sessions.filter { session in
            waiting[session.id].map { announced[session.id] != $0 } ?? false
        }
        announced = waiting
        guard !fresh.isEmpty, !look(GeminiHostApp.antigravity).shows(GeminiHostApp.antigravity) else { return }
        for session in fresh {
            if let banner = GeminiWaitBanner.banner(for: session) { announce(banner) }
        }
    }

    /// Puts up, re-publishes or ends the activity to match the model and the settings.
    private func sync() {
        let center = ActivityCenter.shared
        let wanted = !model.shown.isEmpty && (isRunning || model.isPreviewing)
        if wanted {
            let current = activity.published
            if !center.isShowing(id: activity.id) || current != published {
                published = current
                center.show(activity)
            }
        } else if center.isShowing(id: activity.id) {
            center.end(id: activity.id)
            published = nil
        }
    }

    /// A conversation's row was clicked: Antigravity comes forward, if it is running, or a
    /// CLI session's terminal, at its tab.
    private func open(_ session: GeminiSession) {
        guard !model.isPreviewing else { return }
        if session.record.isCLI {
            _ = openCLI(session.record)
        } else {
            _ = activate(GeminiHostApp.antigravity)
        }
    }

    private func preview(_ samples: [GeminiSession]) {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.previewWork = nil
                self?.model.endPreview()
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewLength, execute: work)
        model.beginPreview(samples)
    }
}

extension GeminiFeature: BannerSessionSource {
    /// Brings Antigravity forward for a conversation Islet has a file of; Antigravity
    /// can't be asked for the conversation itself. For a CLI session, its terminal at its
    /// tab.
    func openSession(_ id: String) -> Bool {
        guard isRunning, let record = monitor.snapshot.records.first(where: { $0.id == id }) else { return false }
        return record.isCLI ? openCLI(record) : activate(GeminiHostApp.antigravity)
    }

    /// Whether the agent finishing in conversation `id` is in front of the person: Settings
    /// asks for no banner then, Antigravity is in front with a window up and the screen
    /// awake, and its window's title names the conversation. Whatever cannot be read
    /// (the title, for want of Accessibility; the conversation's title, not yet in
    /// Antigravity's list) leaves the banner to show.
    func skipsDone(for id: String) -> Bool {
        guard GeminiPrefs.skipsDoneOnScreen else { return false }
        if let record = monitor.snapshot.records.first(where: { $0.id == id }), record.isCLI {
            return isRunning && cliOnScreen(record)
        }
        let screen = look(GeminiHostApp.antigravity)
        guard screen.shows(GeminiHostApp.antigravity),
              let window = windowTitle(GeminiHostApp.antigravity),
              let titles = titles(),
              let title = titles[id]
        else { return false }
        let others = titles.compactMap { $0.key == id ? nil : $0.value }
        return GeminiDoneOnScreen.isOnScreen(conversation: title, window: window, others: others)
    }

    /// Whether a CLI session's tab is in front of the person: Terminal or iTerm in front
    /// with a window up and the screen awake, and the tab its front window shows the
    /// session's. Any other app, or a tab that can't be told, leaves the banner to show.
    private func cliOnScreen(_ record: GeminiSessionRecord) -> Bool {
        guard [ClaudeHostApps.terminal, ClaudeHostApps.iTerm].contains(record.hostApp), !record.tty.isEmpty,
              look(record.hostApp).shows(record.hostApp),
              let tab = terminalTab(record.hostApp)
        else { return false }
        return GeminiTerminalFront.matches(record, tab)
    }
}

/// Whether a conversation is the one Antigravity's window shows. Antigravity titles its
/// window with the conversation's title, the project's and its own name, each after a
/// " - ": "<conversation's title> - <project> - Antigravity", without the project where
/// there is none. The conversation's title is Antigravity's, whole, from its list of
/// conversations; white space is compared as the window shows it, a run of it as one
/// space. Where another conversation's title is longer and names the window as well
/// ("Fix the parser - tests" beside "Fix the parser"), the window is that one's. Two
/// conversations with the same title can't be told apart, and either counts as on
/// screen. A title that doesn't fit the pattern (a project with " - " in its name, say)
/// counts as not on screen, so the banner shows.
enum GeminiDoneOnScreen {
    static func isOnScreen(conversation title: String, window: String, others: [String] = []) -> Bool {
        let window = plain(window)
        let title = plain(title)
        guard names(title, window: window) else { return false }
        return !others.contains { other in
            let other = plain(other)
            return other.count > title.count && names(other, window: window)
        }
    }

    /// Whether `window` is titled for a conversation titled `title`.
    static func names(_ title: String, window: String) -> Bool {
        guard !title.isEmpty, window.hasPrefix(title) else { return false }
        let rest = window.dropFirst(title.count)
        if rest.isEmpty { return true }
        guard rest.hasPrefix(" - ") else { return false }
        let parts = rest.dropFirst(3).components(separatedBy: " - ")
        return parts.count <= 2 && parts.last?.hasPrefix("Antigravity") == true
    }

    /// `text` with each run of white space as one space, and none at either end, as a
    /// window's title shows it.
    static func plain(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The banner for a conversation waiting on the person where only Antigravity's list
/// of conversations says so: a question, a tool waiting for leave, or a subagent
/// waiting. It names the conversation, so a click brings Antigravity forward.
enum GeminiWaitBanner {
    static func banner(for session: GeminiSession) -> CustomBanner? {
        let record = session.record
        let branch = GeminiPrefs.showsBranch ? SessionBranch.bannerSuffix(record.branch) : ""
        let at = record.project.isEmpty ? "" : " · " + record.project + branch
        let (title, symbol): (String, String) = switch session.waiting {
        case .question?: ("Gemini has a question", "questionmark.bubble.fill")
        case .approval?: ("Gemini is waiting for approval", "hand.raised.fill")
        case .plan?: ("Gemini has a plan for you", "checklist")
        case .input?, nil: ("Gemini needs your input", "questionmark.bubble.fill")
        }
        let named = GeminiText.firstWords(session.title, limit: 100) ?? "Antigravity is waiting for you"
        return CustomBanner(title: title + at, subtitle: named, symbol: symbol, tint: .named(.orange),
                            style: .card, activity: "gemini", session: session.id)
    }
}

/// Antigravity, the app Gemini's agents run in.
enum GeminiHostApp {
    nonisolated static let antigravity = "com.google.antigravity"
}

/// What the screen and Antigravity's own files say, for `GeminiDoneOnScreen`: the title
/// of the window Antigravity has in front, read through Accessibility (never written,
/// and never asked of any other app), and a conversation's title, read-only from
/// Antigravity's list of conversations.
enum GeminiWindowTitle {
    /// The focused window's title of the app `bundleID`, asked with a timeout of half a
    /// second at most, so a busy app never holds Islet up; `nil` without Accessibility,
    /// or when it says none.
    @MainActor
    static func read(_ bundleID: String) -> String? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let timeout = MenuBarAccessibility.readTimeout
        guard let value = MenuBarAccessibility.value(kAXFocusedWindowAttribute, of: element, timeout: timeout),
              let window = MenuBarAccessibility.element(value),
              let title = MenuBarAccessibility.value(kAXTitleAttribute, of: window, timeout: timeout),
              CFGetTypeID(title) == CFStringGetTypeID()
        else { return nil }
        let text = (title as! String).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The conversations' titles in Antigravity's list, whole, as they are now, by
    /// conversation id; `nil` when the list can't be read.
    static func conversationTitles() -> [String: String]? {
        GeminiData.titles(GeminiData.antigravityFolder().appendingPathComponent(GeminiData.summariesFile))
    }
}

@MainActor
final class GeminiActivity: IslandActivity {
    /// What `ActivityCenter` reads from the activity, its page's height and its rank;
    /// a change re-publishes it.
    struct Published: Equatable {
        var expanded: CGFloat
        var rank: Int
        var atLimit = false
    }

    let id = "gemini"
    let name = "Gemini"
    var spokenStatus: String? {
        guard let session = model.displayed else { return nil }
        var parts = [GeminiText.status(session)]
        if let tasks = session.tasks, session.state == .working {
            parts.append("\(tasks.done) of \(tasks.items.count) tasks done")
        }
        return parts.joined(separator: ", ")
    }
    /// In the background: Antigravity asks nothing the island can answer.
    var priority: ActivityPriority { .background }
    let symbol = "wand.and.stars"
    /// Its page shows each conversation's title, which is what was asked in a few words.
    var personal: PersonalContent? { .messages }
    let model: GeminiModel
    let usage: UsageCenter?
    let open: (GeminiSession) -> Void

    init(model: GeminiModel, usage: UsageCenter? = nil, open: @escaping (GeminiSession) -> Void) {
        self.model = model
        self.usage = usage
        self.open = open
    }

    var published: Published {
        Published(expanded: GeminiLayout.pageHeight(for: model.shown, showsText: GeminiPrefs.showsPrompt, header: usageHeader),
                  rank: rank, atLimit: atLimit)
    }

    /// The usage line atop the page, while it shows.
    private var usageHeader: CGFloat {
        !model.isPreviewing && usage?.status(.gemini) != nil ? UsageLayout.lineHeight : 0
    }

    /// At the quota's limit, when it lifts takes the right of the notch.
    private var atLimit: Bool { !model.isPreviewing && usage?.compact(.gemini).atLimit == true }

    /// Behind the Sound Mixer for the bubble while conversations work; ahead of it while
    /// one waits on the person, so the question shows.
    var rank: Int { model.needsYou ? 1 : -1 }
    var compactTrailingWidth: CGFloat? { atLimit ? UsageLayout.limitTrailingWidth : GeminiLayout.trailingWidth }
    var expandedHeight: CGFloat { published.expanded }

    func compactLeading() -> AnyView { AnyView(GeminiCompactLeading(model: model, usage: usage)) }
    func compactTrailing() -> AnyView { AnyView(GeminiCompactTrailing(model: model, usage: usage)) }
    func minimal() -> AnyView { AnyView(GeminiMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(GeminiExpanded(model: model, usage: usage, open: open)) }
}

/// The feature's preference keys. Unset keys read as their defaults, the same ones the
/// settings toggles declare.
enum GeminiPrefs {
    /// Whether rows go by each conversation's title (what was asked, in Antigravity's
    /// words) rather than by its workspace alone.
    static let showPrompt = "gemini.showPrompt"

    static var showsPrompt: Bool { UserDefaults.standard.object(forKey: showPrompt) as? Bool ?? true }

    /// Whether the git branch a conversation's workspace is on shows beside the
    /// workspace, in its row and in its banners.
    static let showBranch = "gemini.showBranch"

    static var showsBranch: Bool { UserDefaults.standard.object(forKey: showBranch) as? Bool ?? true }

    /// Whether an agent finishing in the conversation on screen puts up no banner.
    static let skipDoneOnScreen = "gemini.skipDoneOnScreen"

    static var skipsDoneOnScreen: Bool { UserDefaults.standard.object(forKey: skipDoneOnScreen) as? Bool ?? true }
}

/// The hook Antigravity needs in `~/.gemini/config/hooks.json`, as Settings shows and
/// copies it and the README gives it: one named hook, "islet", running the hook script,
/// copied to `~/.gemini/hooks/islet-antigravity.sh`, with its kind for each of three
/// events. No PreToolUse: every answer Antigravity's documentation gives a PreToolUse
/// hook overrules its own decision, and Islet's hook only tells. Islet never writes
/// `~/.gemini`; the person adds it.
enum GeminiHooks {
    static let name = "islet"
    static let scriptName = "islet-antigravity.sh"
    static let script = "~/.gemini/hooks/" + scriptName
    static let file = "~/.gemini/config/hooks.json"
    /// Each event, the kind it hands the script, and whether it is a tool's event, which
    /// takes a matcher.
    static let events: [(event: String, kind: String, tool: Bool)] = [
        ("PreInvocation", "invocation", false),
        ("PostToolUse", "tool", true),
        ("Stop", "stop", false),
    ]
    /// Seconds; the script ends within three.
    static let timeout = 5

    static var entryJSON: String {
        // Two lines a handler, short enough to read in Settings and the README.
        let entries = events.map { event, kind, tool in
            let indent = tool ? "        " : "      "
            let handler = indent + #"{ "type": "command", "timeout": \#(timeout),"# + "\n"
                + indent + #"  "command": "/bin/bash \#(script) \#(kind)" }"#
            return tool
                ? "    \"\(event)\": [\n      { \"matcher\": \"*\", \"hooks\": [\n\(handler)\n      ] }\n    ]"
                : "    \"\(event)\": [\n\(handler)\n    ]"
        }
        return "{\n  \"\(name)\": {\n" + entries.joined(separator: ",\n") + "\n  }\n}\n"
    }

    static func copy(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(entryJSON, forType: .string)
    }
}

/// Whether Islet's hook is set up, from `~/.gemini/config/hooks.json` and the script
/// beside it, read-only.
struct GeminiHookSetup: Equatable {
    enum Status: Equatable {
        /// No hooks.json.
        case noFile
        /// One that is not JSON, or too big to be one.
        case unreadable
        /// No hook in it runs Islet's script.
        case notAdded
        /// Islet's hook is there, turned off.
        case disabled
        /// On some of its events, not all.
        case partial(missing: [String])
        /// In hooks.json, without the script it runs.
        case scriptMissing
        case ready
    }

    var status: Status
    /// Whether Islet's script is also on PreToolUse, which its entry leaves out.
    var onPreToolUse = false

    /// What `home`'s `.gemini` says.
    static func check(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> GeminiHookSetup {
        let file = home.appendingPathComponent(".gemini/config/hooks.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else {
            return GeminiHookSetup(status: .noFile)
        }
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576,
              let data = FileManager.default.contents(atPath: file.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return GeminiHookSetup(status: .unreadable) }
        let script = home.appendingPathComponent(".gemini/hooks/" + GeminiHooks.scriptName)
        return check(object, scriptExists: FileManager.default.fileExists(atPath: script.path))
    }

    /// What a hooks.json's contents say: the events that run Islet's script, in named
    /// hooks not turned off.
    static func check(_ hooks: [String: Any], scriptExists: Bool) -> GeminiHookSetup {
        var on: Set<String> = []
        var off = false
        for case let spec as [String: Any] in hooks.values {
            var found: Set<String> = []
            for event in GeminiHooks.events.map(\.event) + ["PreToolUse", "PostInvocation"] {
                guard let entries = spec[event] as? [[String: Any]] else { continue }
                let handlers = entries.flatMap { entry in
                    [entry] + ((entry["hooks"] as? [[String: Any]]) ?? [])
                }
                if handlers.contains(where: { ($0["command"] as? String)?.contains(GeminiHooks.scriptName) == true }) {
                    found.insert(event)
                }
            }
            guard !found.isEmpty else { continue }
            if spec["enabled"] as? Bool == false { off = true } else { on.formUnion(found) }
        }
        let preToolUse = on.contains("PreToolUse")
        if on.isEmpty { return GeminiHookSetup(status: off ? .disabled : .notAdded) }
        let missing = GeminiHooks.events.map(\.event).filter { !on.contains($0) }
        if !missing.isEmpty { return GeminiHookSetup(status: .partial(missing: missing), onPreToolUse: preToolUse) }
        return GeminiHookSetup(status: scriptExists ? .ready : .scriptMissing, onPreToolUse: preToolUse)
    }

    /// The line Settings shows.
    var words: String {
        var line: String
        switch status {
        case .noFile: line = "Not set up: there's no \(GeminiHooks.file) yet"
        case .unreadable: line = "Not set up: \(GeminiHooks.file) isn't JSON Islet can read"
        case .notAdded: line = "Not set up: no hook in \(GeminiHooks.file) runs \(GeminiHooks.scriptName)"
        case .disabled: line = "Turned off: Islet's hook has \"enabled\": false"
        case .partial(let missing):
            line = "Partly set up: no \(missing.joined(separator: " or ")) hook runs \(GeminiHooks.scriptName)"
        case .scriptMissing: line = "Not set up: the hook is there, but \(GeminiHooks.script) is missing"
        case .ready: line = "Set up"
        }
        if onPreToolUse {
            line += ". It is on PreToolUse too, which Islet's entry leaves out: take it off there"
        }
        return line
    }
}
