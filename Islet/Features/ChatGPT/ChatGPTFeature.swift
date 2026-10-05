import AppKit
import SwiftUI

/// ChatGPT at work, beside the notch: a speech bubble left of the camera while a chat or
/// a Codex thread works on a reply, a raised hand while one waits for permission, a
/// question mark while one asks something, and right of it how long the turn has been
/// going; or while agents are at work, how many, beside a ring filling as its plan or
/// its agents get done, else a spinner. In the bubble, the mark sits in that ring while
/// there is one. Opened, a row for each session:
/// its project (or for a plain chat, the start of the prompt), what it is doing and for
/// how long, what was asked, the turn's steps so far, its goal, its plan as a checklist,
/// the agents it has sent off, with what each is doing, and the commands it has left
/// running. Clicking a session brings forward the app it runs in, and in the ChatGPT
/// app, the chat itself.
///
/// ChatGPT says what it is doing through Codex's hooks, and `Scripts/chatgpt-hook.sh`
/// keeps a file per session for Islet (`ChatGPTSessionMonitor`), alongside the banners
/// it puts up. Without the hooks, and until the person trusts them in ChatGPT, there are
/// no files, and nothing shows. A turn that fails fires no hook; its end is read from the
/// thread's rollout file (`ChatGPTRollout`), and so is the end of a command left
/// running that no hook reports. A thread's goal and its queued prompts are read from
/// Codex's own databases (`ChatGPTCodexData`), read-only.
///
/// A background activity: it never takes the island from music or a timer, and sits in
/// the bubble beside them instead, as Claude Code does. There it gives way to the Sound
/// Mixer, but for while a session is waiting on the person.
@MainActor
final class ChatGPTFeature: Feature {
    let id = "chatGPT"
    let title = "ChatGPT"
    let symbol = "text.bubble"
    let summary = "What ChatGPT and Codex are doing, from their hooks."
    var islandActivity: IslandActivityInfo? { IslandActivityInfo(self, order: 75) }

    /// How long a preview's made-up sessions show.
    static let previewLength: TimeInterval = 12

    let model = ChatGPTModel()
    let monitor: ChatGPTSessionMonitor
    private let clock: () -> Date
    private let openHost: @MainActor (_ bundleID: String, _ session: String) -> Bool
    private lazy var activity = ChatGPTActivity(model: model) { [weak self] session in self?.open(session) }

    private var isRunning = false
    private var published: ChatGPTActivity.Published?
    private var previewWork: DispatchWorkItem?
    private var defaultsObserver: NSObjectProtocol?

    /// Tests give a monitor on a folder of their own, a clock, and a stand-in for
    /// bringing an app forward.
    init(
        monitor: ChatGPTSessionMonitor? = nil,
        clock: @escaping () -> Date = Date.init,
        openHost: @escaping @MainActor (_ bundleID: String, _ session: String) -> Bool = ChatGPTHostApps.open
    ) {
        self.monitor = monitor ?? ChatGPTSessionMonitor(now: clock)
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
        AnyView(ChatGPTSettingsView(model: model))
    }

    /// Made-up sessions, not the person's, for twelve seconds. Clicking one does nothing.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Chat working through a plan") { [weak self] in
                self?.preview(ChatGPTSamples.working(now: Date()))
            },
            FeaturePreview(title: "Chat needing permission") { [weak self] in
                self?.preview(ChatGPTSamples.needsPermission(now: Date()))
            },
            FeaturePreview(title: "Several chats and agents") { [weak self] in
                self?.preview(ChatGPTSamples.several(now: Date()))
            },
            FeaturePreview(title: "Chat with tasks at work") { [weak self] in
                self?.preview(ChatGPTSamples.progress(now: Date()))
            },
        ]
    }

    // MARK: Island

    private func received(_ snapshot: ChatGPTSessionSnapshot) {
        let sessions = ChatGPTLiveness.sessions(snapshot, now: clock())
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

    /// A session's row was clicked: the app it runs in comes forward, if it is running,
    /// at the chat itself in the ChatGPT app.
    private func open(_ session: ChatGPTSession) {
        guard !model.isPreviewing, !session.record.hostApp.isEmpty else { return }
        _ = openHost(session.record.hostApp, session.id)
    }

    private func preview(_ samples: [ChatGPTSession]) {
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
final class ChatGPTActivity: IslandActivity {
    /// What `ActivityCenter` reads from the activity, its page's height and its rank;
    /// a change re-publishes it.
    struct Published: Equatable {
        var expanded: CGFloat
        var rank: Int
    }

    let id = "chatGPT"
    let name = "ChatGPT"
    var spokenStatus: String? {
        guard let session = model.displayed else { return nil }
        var parts: [String]
        switch session.state {
        case .needsPermission: return "Needs permission"
        case .waitingForInput: return "Has a question"
        case .working:
            parts = [session.record.step.map(ChatGPTToolWords.doing) ?? "Working"]
            if !session.plan.isEmpty {
                parts.append("\(session.record.planDone) of \(session.plan.count) plan steps done")
            }
        case .idle:
            parts = []
        }
        // The agents at work and how far they have got, as the compact island reads them,
        // its plan said already. Commands left running are left to the opened page.
        let agents = model.runningAgentCount
        if agents > 0 {
            parts.append(ChatGPTText.background(agents: agents, fraction: session.plan.isEmpty ? model.fraction : nil))
        } else if session.state == .idle {
            parts.append("Working on the goal")
        }
        return parts.joined(separator: ", ")
    }
    let priority = ActivityPriority.background
    let symbol = "text.bubble.fill"
    /// Its page shows what each session was asked, as its hooks' banners do.
    var personal: PersonalContent? { .messages }
    let model: ChatGPTModel
    let open: (ChatGPTSession) -> Void

    init(model: ChatGPTModel, open: @escaping (ChatGPTSession) -> Void) {
        self.model = model
        self.open = open
    }

    var published: Published {
        Published(expanded: ChatGPTLayout.pageHeight(for: model.shown, showsText: ChatGPTPrefs.showsPrompt),
                  rank: rank)
    }

    /// Behind the Sound Mixer for the bubble while sessions work, so a prompt does not
    /// push it out each time; ahead of it while one waits on you, so the hand shows.
    var rank: Int { model.needsYou ? 1 : -1 }
    var compactTrailingWidth: CGFloat? { ChatGPTLayout.trailingWidth }
    var expandedHeight: CGFloat { published.expanded }

    func compactLeading() -> AnyView { AnyView(ChatGPTCompactLeading(model: model)) }
    func compactTrailing() -> AnyView { AnyView(ChatGPTCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(ChatGPTMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(ChatGPTExpanded(model: model, open: open)) }
}

/// Bringing a session's app forward. The ChatGPT app opens the chat itself from its own
/// link for it, codex://threads/<id>, the id being the one the hooks name the session by;
/// any other app, or a session whose id is not the UUID such a link takes, comes forward
/// as it is.
@MainActor
enum ChatGPTHostApps {
    static let chatGPT = "com.openai.codex"

    /// Returns whether the app was running.
    static func open(_ bundleID: String, session: String) -> Bool {
        guard bundleID == chatGPT,
              UUID(uuidString: session) != nil,
              let url = URL(string: "codex://threads/\(session)"),
              let appURL = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
        else { return ClaudeHostApps.activate(bundleID) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        return true
    }
}

/// The feature's preference keys. Unset keys read as their defaults, the same ones the
/// settings toggles declare.
enum ChatGPTPrefs {
    /// Whether the opened page shows each session's prompt (and, once it is done, the
    /// start of the reply), and names plain chats by their prompt.
    static let showPrompt = "chatGPT.showPrompt"

    static var showsPrompt: Bool { UserDefaults.standard.object(forKey: showPrompt) as? Bool ?? true }
}

/// The hooks Codex needs in `~/.codex/hooks.json`, as Settings copies them and the
/// README shows them: each event runs the hook script, installed as
/// `~/.codex/hooks/islet-notify.sh`, with its kind. The tools' two run in the
/// background, since they come with every tool; Interrupt and SessionEnd get the
/// longest Codex allows them.
///
/// The lines never change: Codex asks the person to trust a hook again whenever its
/// command, timeout or place changes. A new version of the script is copied over the old
/// one instead.
enum ChatGPTHooks {
    static let script = "$HOME/.codex/hooks/islet-notify.sh"
    static let events: [(event: String, kind: String, timeout: Int, async: Bool)] = [
        ("SessionStart", "start", 10, false),
        ("UserPromptSubmit", "prompt", 10, false),
        ("PreToolUse", "tool-start", 10, true),
        ("PermissionRequest", "permission", 10, false),
        ("PostToolUse", "tool-end", 10, true),
        ("Stop", "stop", 10, false),
        ("Interrupt", "interrupt", 3, false),
        ("SubagentStart", "agent-start", 10, false),
        ("SubagentStop", "agent-stop", 10, false),
        ("SessionEnd", "end", 3, false),
    ]

    /// Two lines an event, short enough to read in the README.
    static var settingsJSON: String {
        let entries = events.map { event, kind, timeout, async in
            #"    "\#(event)": [{ "hooks": [{ "type": "command", "timeout": \#(timeout),"#
                + (async ? #" "async": true,"# : "") + "\n"
                + #"      "command": "bash \"\#(script)\" \#(kind)" }] }]"#
        }
        return "{\n  \"hooks\": {\n" + entries.joined(separator: ",\n") + "\n  }\n}\n"
    }

    static func copy(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(settingsJSON, forType: .string)
    }
}
