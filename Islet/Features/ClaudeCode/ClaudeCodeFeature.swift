import AppKit
import SwiftUI

/// Claude Code at work, beside the notch: a sparkle left of the camera while a session
/// works on a reply, a raised hand while one waits for permission, and right of it how
/// long the turn has been going, or how many background workflows are running.
/// Opened, a row for each session: its project, what it is doing and for how long,
/// what was asked, and its workflows under it. Clicking a session brings forward the
/// app it runs in.
///
/// Claude Code says what it is doing through hooks, and `Scripts/claude-code-hook.sh`
/// keeps a file per session for Islet (`ClaudeSessionMonitor`), alongside the banners
/// it has always put up. Without the hook there are no files, and nothing shows.
///
/// A background activity: it never takes the island from music or a timer, and sits in
/// the bubble beside them instead. There it gives way to the Sound Mixer, the other
/// background activity, but for while a session is waiting on the person.
@MainActor
final class ClaudeCodeFeature: Feature {
    let id = "claudeCode"
    let title = "Claude Code"
    let symbol = "sparkle"
    let summary = "Claude Code sessions beside the notch while they work, wait for you or run workflows."

    /// How long a preview's made-up sessions show.
    static let previewLength: TimeInterval = 12

    let model = ClaudeCodeModel()
    let monitor: ClaudeSessionMonitor
    private let clock: () -> Date
    private let openHost: @MainActor (String) -> Bool
    private lazy var activity = ClaudeCodeActivity(model: model) { [weak self] session in self?.open(session) }

    private var isRunning = false
    private var published: ClaudeCodeActivity.Published?
    private var previewWork: DispatchWorkItem?
    private var defaultsObserver: NSObjectProtocol?

    /// Tests give a monitor on a folder of their own, a clock, and a stand-in for
    /// bringing an app forward.
    init(
        monitor: ClaudeSessionMonitor? = nil,
        clock: @escaping () -> Date = Date.init,
        openHost: @escaping @MainActor (String) -> Bool = ClaudeHostApps.activate
    ) {
        self.monitor = monitor ?? ClaudeSessionMonitor(now: clock)
        self.clock = clock
        self.openHost = openHost
        model.onChange = { [weak self] in self?.sync() }
        self.monitor.onChange = { [weak self] snapshot in self?.received(snapshot) }
    }

    func start() {
        isRunning = true
        // Showing or hiding the prompts changes the opened page's height.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        monitor.start()
    }

    func stop() {
        isRunning = false
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        monitor.stop()
        model.update([], lastHeard: model.lastHeard)
        sync()
    }

    func settingsView() -> AnyView? {
        AnyView(ClaudeCodeSettingsView(model: model))
    }

    /// Made-up sessions, not the person's, for twelve seconds. Clicking one does nothing.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Session working") { [weak self] in
                self?.preview(ClaudeCodeSamples.working(now: Date()))
            },
            FeaturePreview(title: "Session needing permission") { [weak self] in
                self?.preview(ClaudeCodeSamples.needsPermission(now: Date()))
            },
            FeaturePreview(title: "Several sessions and workflows") { [weak self] in
                self?.preview(ClaudeCodeSamples.several(now: Date()))
            },
        ]
    }

    // MARK: Island

    private func received(_ snapshot: ClaudeSessionSnapshot) {
        let sessions = ClaudeLiveness.sessions(snapshot, now: clock())
        model.update(isRunning ? sessions : [], lastHeard: snapshot.lastHeard)
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

    /// A session's row was clicked: the app it runs in comes forward, if it is running.
    private func open(_ session: ClaudeSession) {
        guard !model.isPreviewing, !session.record.hostApp.isEmpty else { return }
        _ = openHost(session.record.hostApp)
    }

    private func preview(_ samples: [ClaudeSession]) {
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

@MainActor
final class ClaudeCodeActivity: IslandActivity {
    /// What `ActivityCenter` reads from the activity, its page's height and its rank;
    /// a change re-publishes it.
    struct Published: Equatable {
        var expanded: CGFloat
        var rank: Int
    }

    let id = "claudeCode"
    let priority = ActivityPriority.background
    let symbol = "sparkle"
    let model: ClaudeCodeModel
    let open: (ClaudeSession) -> Void

    init(model: ClaudeCodeModel, open: @escaping (ClaudeSession) -> Void) {
        self.model = model
        self.open = open
    }

    var published: Published {
        Published(expanded: ClaudeCodeLayout.pageHeight(for: model.shown, showsText: ClaudeCodePrefs.showsPrompt),
                  rank: rank)
    }

    /// Behind the Sound Mixer for the bubble while sessions work, so a prompt does not
    /// push it out each time; ahead of it while one waits on you, so the hand shows.
    var rank: Int { model.needsYou ? 1 : -1 }
    var compactTrailingWidth: CGFloat? { ClaudeCodeLayout.trailingWidth }
    var expandedHeight: CGFloat { published.expanded }

    func compactLeading() -> AnyView { AnyView(ClaudeCodeCompactLeading(model: model)) }
    func compactTrailing() -> AnyView { AnyView(ClaudeCodeCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(ClaudeCodeMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(ClaudeCodeExpanded(model: model, open: open)) }
}

/// The feature's preference keys. Unset keys read as their defaults, the same ones the
/// settings toggles declare.
enum ClaudeCodePrefs {
    /// Whether the opened page shows each session's prompt (and, once it is done, the
    /// start of the reply), and names scratch sessions by their prompt.
    static let showPrompt = "claudeCode.showPrompt"

    static var showsPrompt: Bool { UserDefaults.standard.object(forKey: showPrompt) as? Bool ?? true }
}

/// The apps Claude Code runs in, by the bundle id its hooks are given.
@MainActor
enum ClaudeHostApps {
    private static var names: [String: String] = [:]

    /// "Terminal", "Claude": the app's name, or `nil` for one not installed.
    static func name(for bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        if let name = names[bundleID] { return name }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
        var name = running
        if name == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let shown = FileManager.default.displayName(atPath: url.path)
            name = shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
        }
        if let name { names[bundleID] = name }
        return name
    }

    /// Brings the app forward, if it is running; returns whether it was. Through
    /// Launch Services, as a click on its Dock icon would, since an app in the
    /// background (Islet always is) may no longer activate another directly.
    static func activate(_ bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else {
            app.activate()
        }
        return true
    }
}

/// The hooks Claude Code needs in `~/.claude/settings.json`, as Settings copies them and
/// the README shows them: each event runs the hook script, installed as
/// `~/.claude/hooks/islet-notify.sh`, with its kind.
enum ClaudeCodeHooks {
    static let script = "$HOME/.claude/hooks/islet-notify.sh"
    static let events: [(event: String, kind: String)] = [
        ("SessionStart", "start"),
        ("UserPromptSubmit", "prompt"),
        ("Notification", "notification"),
        ("Stop", "stop"),
        ("SubagentStop", "subagent"),
        ("TaskCompleted", "task"),
        ("SessionEnd", "end"),
    ]

    /// Two lines an event, short enough to read in the README.
    static var settingsJSON: String {
        let entries = events.map { event, kind in
            #"    "\#(event)": [{ "hooks": [{ "type": "command", "timeout": 10,"# + "\n"
                + #"      "command": "bash \"\#(script)\" \#(kind)" }] }]"#
        }
        return "{\n  \"hooks\": {\n" + entries.joined(separator: ",\n") + "\n  }\n}\n"
    }

    static func copy(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(settingsJSON, forType: .string)
    }
}
