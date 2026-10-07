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
/// running. Clicking a session, or a banner its hook put up, brings forward the app it
/// runs in, and in the ChatGPT app, the chat itself.
///
/// ChatGPT says what it is doing through Codex's hooks, and `Scripts/chatgpt-hook.sh`
/// keeps a file per session for Islet (`ChatGPTSessionMonitor`), alongside the banners
/// it puts up. Without the hooks, and until the person trusts them in ChatGPT, there are
/// no files, and nothing shows. A turn that fails fires no hook; its end is read from the
/// thread's rollout file (`ChatGPTRollout`), and so is the end of a command left
/// running that no hook reports. A thread's goal and its queued prompts are read from
/// Codex's own databases (`ChatGPTCodexData`), read-only.
///
/// A permission a chat asks shows on its page as a card with Allow, Deny and Answer in
/// ChatGPT, when the hook offers it to Islet (`ApprovalCenter`). Codex asks in the app
/// only once the hook gives up, so the card lasts only as long as the hook waits; the
/// chat then shows as working once the island has answered.
///
/// A reply finishing in the chat the ChatGPT app most likely shows, while it is in
/// front, puts up no banner unless Settings asks for one (`ChatGPTDoneOnScreen`). Turned
/// off, or with nothing to judge by, it does as the hook did before it left this to
/// Islet: no reply banner while the app is in front.
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
    /// Where permissions asked are answered from the island; `nil` leaves them to
    /// ChatGPT, as in tests.
    let approvals: ApprovalCenter?
    private let clock: () -> Date
    private let openHost: @MainActor (_ bundleID: String, _ session: String) -> Bool
    private let look: @MainActor (_ bundleID: String) -> ChatScreenLook
    /// The chat Islet last put the person at in the ChatGPT app, from a click on its row,
    /// its banner or Answer in ChatGPT, and when: the one move between chats Islet sees.
    private var openedChat: ChatGPTDoneOnScreen.Visit?
    private lazy var activity = ChatGPTActivity(model: model, approvals: approvals) { [weak self] session in
        self?.open(session)
    }

    private var isRunning = false
    private var published: ChatGPTActivity.Published?
    private var previewWork: DispatchWorkItem?
    private var defaultsObserver: NSObjectProtocol?

    /// Tests give a monitor on a folder of their own, a clock, a stand-in for bringing
    /// an app forward and their own look at the screen; the app gives the shared
    /// approvals.
    init(
        monitor: ChatGPTSessionMonitor? = nil,
        clock: @escaping () -> Date = Date.init,
        openHost: @escaping @MainActor (_ bundleID: String, _ session: String) -> Bool = ChatGPTHostApps.open,
        look: @escaping @MainActor (_ bundleID: String) -> ChatScreenLook = { AppInFront.shared.look(for: $0) },
        approvals: ApprovalCenter? = nil
    ) {
        self.monitor = monitor ?? ChatGPTSessionMonitor(now: clock)
        self.clock = clock
        self.openHost = openHost
        self.look = look
        self.approvals = approvals
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
            MainActor.assumeIsolated {
                self?.updateApprovals()
                self?.sync()
            }
        }
        monitor.start()
        if let approvals {
            approvals.chatGPTRecords = { [weak monitor] in monitor?.snapshot.records ?? [] }
            observeApprovals()
        }
        updateApprovals()
    }

    func stop() {
        isRunning = false
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        monitor.stop()
        updateApprovals()
        model.update([], lastHeard: model.lastHeard)
        sync()
    }

    /// Takes ChatGPT's requests while running with the setting on, for as long as
    /// Settings says.
    private func updateApprovals() {
        guard let approvals else { return }
        approvals.waits.chatGPT = ChatGPTPrefs.approvalWaitSeconds
        approvals.setAccepting(.chatgpt, isRunning && ChatGPTPrefs.approvesFromIsland)
    }

    /// Re-publishes the activity as cards come and go, and works out the sessions again
    /// as answers settle.
    private func observeApprovals() {
        guard let approvals, isRunning else { return }
        withObservationTracking {
            _ = approvals.items
            _ = approvals.settled
            _ = approvals.decided
            _ = approvals.held
            _ = approvals.isPrivate
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.received(self.monitor.snapshot)
                    self.sync()
                    self.openForRequest()
                    self.observeApprovals()
                }
            }
        }
    }

    /// Opens the island on the page for a request just come, as Settings asks.
    private func openForRequest() {
        guard let approvals, isRunning, ChatGPTPrefs.opensForApproval, let item = approvals.front(for: .chatgpt) else { return }
        ApprovalOpening.open(for: item, page: activity.id, center: approvals)
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
        var snapshot = snapshot
        if let approvals { snapshot.records = snapshot.records.map { approvals.settle($0) } }
        let sessions = ChatGPTLiveness.sessions(snapshot, now: clock())
        model.update(isRunning ? sessions : [], lastHeard: snapshot.lastHeard)
    }

    /// Puts up, re-publishes or ends the activity to match the model and the settings.
    private func sync() {
        let center = ActivityCenter.shared
        let wanted = (!model.shown.isEmpty || activity.approval != nil) && (isRunning || model.isPreviewing)
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
        _ = openChat(session.record.hostApp, session.id)
    }

    /// Brings the app forward at the chat. A chat opened in the ChatGPT app is noted as
    /// the one the person is at now (`ChatGPTDoneOnScreen`).
    private func openChat(_ hostApp: String, _ id: String) -> Bool {
        guard openHost(hostApp, id) else { return false }
        if case .thread = ChatGPTHostApps.target(hostApp, session: id) {
            openedChat = ChatGPTDoneOnScreen.Visit(id: id, at: clock())
        }
        return true
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

extension ChatGPTFeature: BannerSessionSource {
    func openSession(_ id: String) -> Bool {
        guard isRunning, let record = monitor.snapshot.records.first(where: { $0.id == id }),
              !record.hostApp.isEmpty
        else { return false }
        return openChat(record.hostApp, record.id)
    }

    /// The hook sends every reply in the ChatGPT app here, in front or not, for Islet to
    /// tell whether its chat is the one on screen. Where Islet cannot tell (the activity
    /// turned off, its records not yet read as Islet starts, or ChatGPT in front since
    /// before Islet watched), it does as the hook used to: no banner while the app is in
    /// front.
    func skipsDone(for id: String) -> Bool {
        let screen = look(ChatGPTHostApps.chatGPT)
        guard isRunning else { return screen.shows(ChatGPTHostApps.chatGPT) }
        guard ChatGPTPrefs.skipsDoneOnScreen else { return false }
        let records = monitor.snapshot.records
        let record = records.first { $0.id == id }
        // Codex in a terminal or an editor: the hook has had its say already.
        if let record, record.hostApp != ChatGPTHostApps.chatGPT { return false }
        guard record != nil, screen.frontSince != nil else { return screen.shows(ChatGPTHostApps.chatGPT) }
        return ChatGPTDoneOnScreen.isOnScreen(id, records: records, look: screen, opened: openedChat)
    }
}

/// Whether a reply that finished in a chat is in front of the person. The ChatGPT app
/// says nowhere which chat it shows, so it is taken to be the one the person last went
/// to: the one they last sent a prompt in (not a turn Codex started itself), or the one
/// Islet last opened for them, whichever came later, with the app in front since then
/// and a window up. Moving to another chat in the app without sending anything is the
/// one thing that misleads it, and a prompt they queued in a chat they have since left,
/// which ChatGPT sends later. In a terminal or an editor no chat is taken to be on
/// screen.
enum ChatGPTDoneOnScreen {
    /// A chat the person went to, and when: by sending a prompt in it, or by Islet
    /// opening it for them.
    struct Visit: Equatable {
        var id: String
        var at: Date
    }

    /// How long the app may take to come to the front after Islet asks it to open a
    /// chat, when it was not in front already.
    static let openingGrace: TimeInterval = 5

    static func isOnScreen(
        _ id: String, records: [ChatGPTSessionRecord], look: ChatScreenLook, opened: Visit? = nil
    ) -> Bool {
        guard let record = records.first(where: { $0.id == id }), record.hostApp == ChatGPTHostApps.chatGPT,
              look.shows(record.hostApp), let front = look.frontSince
        else { return false }
        var visits = records.filter { $0.hostApp == record.hostApp }.compactMap { other in
            other.prompted.map { Visit(id: other.id, at: $0) }
        }
        if let opened { visits.append(opened) }
        guard let last = visits.max(by: { $0.at < $1.at }), last.id == id,
              !visits.contains(where: { $0.id != id && $0.at >= last.at })
        else { return false }
        return front <= last.at.addingTimeInterval(last == opened ? openingGrace : 0)
    }
}

/// Where a click on a session's row or banner takes the person.
enum ChatGPTOpenTarget: Equatable {
    /// The ChatGPT app at the chat, by its link for it, `codex://threads/<id>`.
    case thread(URL)
    /// The app as it is.
    case app(String)
}

@MainActor
final class ChatGPTActivity: IslandActivity {
    /// What `ActivityCenter` reads from the activity, its page's height and its rank;
    /// a change re-publishes it.
    struct Published: Equatable {
        var expanded: CGFloat
        var rank: Int
        var priority: ActivityPriority
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
    /// In the background, but urgent while it asks a permission the island can answer:
    /// the hand then shows beside the notch whatever else is on.
    var priority: ActivityPriority { asking ? .urgent : .background }
    let symbol = "text.bubble.fill"
    /// Its page shows what each session was asked, as its hooks' banners do.
    var personal: PersonalContent? { .messages }
    let model: ChatGPTModel
    let approvals: ApprovalCenter?
    let open: (ChatGPTSession) -> Void

    init(model: ChatGPTModel, approvals: ApprovalCenter? = nil, open: @escaping (ChatGPTSession) -> Void) {
        self.model = model
        self.approvals = approvals
        self.open = open
    }

    var published: Published {
        Published(expanded: ChatGPTLayout.pageHeight(for: model.shown, showsText: ChatGPTPrefs.showsPrompt,
                                                        approval: approval,
                                                        waiting: approvals?.waiting(for: .chatgpt).count ?? 0,
                                                        isPrivate: approvals?.isPrivate ?? false),
                  rank: rank, priority: priority)
    }

    /// ChatGPT's front request, while one is on show and no preview runs.
    var approval: ApprovalItem? {
        guard !model.isPreviewing else { return nil }
        return approvals?.card(for: .chatgpt)?.item
    }

    /// Whether a request waits for an answer in the island.
    var asking: Bool { !model.isPreviewing && approvals?.front(for: .chatgpt) != nil }

    /// Behind the Sound Mixer for the bubble while sessions work, so a prompt does not
    /// push it out each time; ahead of it while one waits on you, so the hand shows.
    var rank: Int { model.needsYou || approval != nil ? 1 : -1 }
    var compactTrailingWidth: CGFloat? { ChatGPTLayout.trailingWidth }
    var expandedHeight: CGFloat { published.expanded }

    func compactLeading() -> AnyView { AnyView(ChatGPTCompactLeading(model: model, approvals: approvals)) }
    func compactTrailing() -> AnyView { AnyView(ChatGPTCompactTrailing(model: model, approvals: approvals)) }
    func minimal() -> AnyView { AnyView(ChatGPTMinimal(model: model, approvals: approvals)) }
    func expanded() -> AnyView { AnyView(ChatGPTExpanded(model: model, approvals: approvals, open: open)) }
}

/// Bringing a session's app forward. The ChatGPT app opens the chat itself from its own
/// link for it, codex://threads/<id>, the id being the one the hooks name the session by;
/// any other app, or a session whose id is not the UUID such a link takes, comes forward
/// as it is.
@MainActor
enum ChatGPTHostApps {
    nonisolated static let chatGPT = "com.openai.codex"

    /// Where a click on the session goes.
    nonisolated static func target(_ bundleID: String, session: String) -> ChatGPTOpenTarget {
        guard bundleID == chatGPT, UUID(uuidString: session) != nil,
              let url = URL(string: "codex://threads/\(session)")
        else { return .app(bundleID) }
        return .thread(url)
    }

    /// Returns whether the app was running.
    static func open(_ bundleID: String, session: String) -> Bool {
        guard case .thread(let url) = target(bundleID, session: session),
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

    /// Whether permissions ChatGPT asks are shown in the island to answer there. On
    /// unless turned off: the hook, and the key beside it, are what opt in.
    static let approveFromIsland = "chatGPT.approveFromIsland"

    static var approvesFromIsland: Bool { UserDefaults.standard.object(forKey: approveFromIsland) as? Bool ?? true }

    /// Whether the island opens by itself for each permission asked.
    static let openForApproval = "chatGPT.openForApproval"

    static var opensForApproval: Bool { UserDefaults.standard.object(forKey: openForApproval) as? Bool ?? true }

    /// Whether a reply finishing in the chat taken to be on screen in the ChatGPT app
    /// puts up no banner.
    static let skipDoneOnScreen = "chatGPT.skipDoneOnScreen"

    static var skipsDoneOnScreen: Bool { UserDefaults.standard.object(forKey: skipDoneOnScreen) as? Bool ?? true }

    /// How long, in seconds, ChatGPT may wait for the island before asking in the app,
    /// as far as the hook line's timeout allows.
    static let approvalWait = "chatGPT.approvalWait"
    static let approvalWaits = [15, 30, 60]
    static let defaultApprovalWait = 30

    static var approvalWaitSeconds: Int {
        let seconds = UserDefaults.standard.object(forKey: approvalWait) as? Int ?? defaultApprovalWait
        return approvalWaits.contains(seconds) ? seconds : defaultApprovalWait
    }
}

/// The hooks Codex needs in `~/.codex/hooks.json`, as Settings copies them and the
/// README shows them: each event runs the hook script, installed as
/// `~/.codex/hooks/islet-notify.sh`, with its kind. The tools' two run in the
/// background, since they come with every tool; Interrupt and SessionEnd get the
/// longest Codex allows them.
///
/// The lines never change: Codex asks the person to trust a hook again whenever its
/// command, timeout or place changes. A new version of the script is copied over the old
/// one instead. The one exception is the person's own choice to let ChatGPT wait longer
/// for the island (`longerWaitJSON`), which they trust once.
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

    /// How long ChatGPT lets the permission hook wait on the longer line.
    static let longerTimeout = 90

    /// The permission hook on a line that lets it wait for the island: a timeout long
    /// enough for Settings' longest wait, said to the hook so it ends in time, a status
    /// while it waits, and the script by its whole path through `bash -p`, which takes
    /// no shell functions from the environment Codex was started with.
    static func longerWaitJSON(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let path = home + "/.codex/hooks/islet-notify.sh"
        return "{\n  \"hooks\": {\n"
            + #"    "PermissionRequest": [{ "hooks": [{ "type": "command", "timeout": \#(longerTimeout),"# + "\n"
            + #"      "statusMessage": "Waiting for your answer in Islet","# + "\n"
            + #"      "command": "/bin/bash -p \"\#(path)\" permission --timeout \#(longerTimeout)" }] }]"# + "\n  }\n}\n"
    }

    static func copyLongerWait(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(longerWaitJSON(), forType: .string)
    }
}
