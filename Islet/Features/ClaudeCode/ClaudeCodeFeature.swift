import AppKit
import SwiftUI

/// Claude Code at work, beside the notch: a sparkle left of the camera while a session
/// works on a reply, a raised hand while one waits for permission, and right of it how
/// long the turn has been going, or while background workflows run, a ring filling as
/// they get on. Opened, a row for each session: its project, what it is doing and for
/// how long, what was asked, and its background tasks under it: each workflow with its
/// phase, a bar and the agents at work in it, or once it has ended, how; each agent sent
/// off with what it is doing and how many steps it has taken, and whether it has gone
/// quiet; each command left running. Clicking a session, or a banner its hook put up,
/// brings forward the app it runs in, at the session: in the Claude app, the session
/// itself; in Terminal or iTerm, its tab, once macOS has let Islet ask for it.
///
/// Claude Code says what it is doing through hooks, and `Scripts/claude-code-hook.sh`
/// keeps a file per session for Islet (`ClaudeSessionMonitor`), alongside the banners
/// it has always put up. Without the hook there are no files, and nothing shows. How
/// far the background tasks have got comes from the files Claude Code keeps for them
/// beside the session's transcript (`ClaudeTaskProgressReader`).
///
/// A permission a session asks shows on its page as a card with Allow, Deny and Answer
/// in the app, when the hook offers it to Islet (`ApprovalCenter`); the session then
/// shows as working once the island has answered.
///
/// A reply finishing in the session the Claude app shows, while it is in front, puts up
/// no Done banner unless Settings asks for one (`ClaudeDoneOnScreen`).
///
/// Claude's usage limits show atop the page, on the AI Usage tile and from 80% round the
/// mark (`UsageCenter`), from the Claude app's own record of them; the StopFailure hook
/// says when a turn was turned away at the limit (`islet://claudeCode/usage-limit`).
///
/// A background activity: it never takes the island from music or a timer, and sits in
/// the bubble beside them instead. There it gives way to the Sound Mixer, the other
/// background activity, but for while a session is waiting on the person.
@MainActor
final class ClaudeCodeFeature: Feature {
    let id = "claudeCode"
    let title = "Claude Code"
    let symbol = "sparkle"
    let summary = "Claude Code sessions beside the notch while they work, wait for you or work in the background."
    var islandActivity: IslandActivityInfo? { IslandActivityInfo(self, order: 70) }
    var sharedHomeTile: HomeTileInfo? { UsageCenter.tileInfo }

    /// How long a preview's made-up sessions show.
    static let previewLength: TimeInterval = 12

    let model = ClaudeCodeModel()
    let monitor: ClaudeSessionMonitor
    /// Where permissions asked are answered from the island; `nil` leaves them to
    /// Claude Code, as in tests.
    let approvals: ApprovalCenter?
    /// Claude's usage limits.
    let usage: UsageCenter
    private let clock: () -> Date
    private let openHost: @MainActor (ClaudeSessionRecord) -> Bool
    private let look: @MainActor (_ bundleID: String) -> ChatScreenLook
    private let appSessions: URL
    private lazy var activity = ClaudeCodeActivity(model: model, approvals: approvals, usage: usage) { [weak self] session in
        self?.open(session)
    }

    private var isRunning = false
    private var published: ClaudeCodeActivity.Published?
    private var previewWork: DispatchWorkItem?
    private var defaultsObserver: NSObjectProtocol?
    private var usageObserver: NSObjectProtocol?

    /// Tests give a monitor on a folder of their own, a clock, a stand-in for bringing
    /// an app forward, their own look at the screen, the Claude app's sessions and their
    /// own usage; the app gives the shared approvals.
    init(
        monitor: ClaudeSessionMonitor? = nil,
        clock: @escaping () -> Date = Date.init,
        openHost: @escaping @MainActor (ClaudeSessionRecord) -> Bool = ClaudeHostApps.open,
        look: @escaping @MainActor (_ bundleID: String) -> ChatScreenLook = { AppInFront.shared.look(for: $0) },
        appSessions: URL = ClaudeAppSessions.folder,
        approvals: ApprovalCenter? = nil,
        usage: UsageCenter? = nil
    ) {
        self.monitor = monitor ?? ClaudeSessionMonitor(now: clock)
        self.usage = usage ?? .shared
        self.clock = clock
        self.openHost = openHost
        self.look = look
        self.appSessions = appSessions
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
        // The usage line and the limit change the page's height and the right side's width.
        usageObserver = NotificationCenter.default.addObserver(
            forName: UsageCenter.didChange, object: usage, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        monitor.start()
        usage.start(.claude)
        if let approvals {
            approvals.claudeRecords = { [weak monitor] in monitor?.snapshot.records ?? [] }
            observeApprovals()
        }
        updateApprovals()
    }

    func stop() {
        isRunning = false
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        if let usageObserver { NotificationCenter.default.removeObserver(usageObserver) }
        usageObserver = nil
        usage.stop(.claude)
        monitor.stop()
        updateApprovals()
        model.update([], lastHeard: model.lastHeard)
        sync()
    }

    /// Takes Claude Code's requests while running with the setting on.
    private func updateApprovals() {
        guard let approvals else { return }
        approvals.setAccepting(.claude, isRunning && ClaudeCodePrefs.approvesFromIsland)
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
        guard let approvals, isRunning, ClaudeCodePrefs.opensForApproval, let item = approvals.front(for: .claude) else { return }
        ApprovalOpening.open(for: item, page: activity.id, center: approvals)
    }

    func settingsView() -> AnyView? {
        AnyView(ClaudeCodeSettingsView(model: model))
    }

    /// `islet://claudeCode/usage-limit`, from the StopFailure hook: a turn was turned
    /// away at the usage limit.
    func handle(_ url: URL) -> Bool {
        guard url.path().lowercased() == "/usage-limit" else { return false }
        if isRunning { usage.claudeLimitReached() }
        return true
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
        var snapshot = snapshot
        if let approvals { snapshot.records = snapshot.records.map { approvals.settle($0) } }
        let sessions = ClaudeLiveness.sessions(snapshot, now: clock())
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
    /// at the session where it can be.
    private func open(_ session: ClaudeSession) {
        guard !model.isPreviewing, !session.record.hostApp.isEmpty else { return }
        _ = openHost(session.record)
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

extension ClaudeCodeFeature: BannerSessionSource {
    /// The session by that id in the hook's files, as last read.
    private func record(_ id: String) -> ClaudeSessionRecord? {
        guard isRunning else { return nil }
        return monitor.snapshot.records.first { $0.id == id }
    }

    func openSession(_ id: String) -> Bool {
        guard let record = record(id), !record.hostApp.isEmpty else { return false }
        return openHost(record)
    }

    func skipsDone(for id: String) -> Bool {
        guard ClaudeCodePrefs.skipsDoneOnScreen, let record = record(id), record.hostApp == ClaudeHostApps.claudeApp
        else { return false }
        return ClaudeDoneOnScreen.isOnScreen(record, look: look(record.hostApp), appSessions: appSessions)
    }
}

@MainActor
final class ClaudeCodeActivity: IslandActivity {
    /// What `ActivityCenter` reads from the activity, its page's height and its rank;
    /// a change re-publishes it.
    struct Published: Equatable {
        var expanded: CGFloat
        var rank: Int
        var priority: ActivityPriority
        var atLimit = false
    }

    let id = "claudeCode"
    let name = "Claude Code"
    var spokenStatus: String? {
        let count = model.backgroundCount
        guard count > 0 else { return nil }
        let working = "\(count) at work in the background"
        guard let fraction = model.workflowFraction else { return working }
        return "\(working), \(Int((fraction * 100).rounded())) percent done"
    }
    /// In the background, but urgent while it asks a permission the island can answer:
    /// the hand then shows beside the notch whatever else is on.
    var priority: ActivityPriority { asking ? .urgent : .background }
    let symbol = "sparkle"
    /// Its page shows what each session is doing and asking, as its hooks' banners do.
    var personal: PersonalContent? { .messages }
    let model: ClaudeCodeModel
    let approvals: ApprovalCenter?
    let usage: UsageCenter?
    let open: (ClaudeSession) -> Void

    init(model: ClaudeCodeModel, approvals: ApprovalCenter?, usage: UsageCenter? = nil,
         open: @escaping (ClaudeSession) -> Void) {
        self.model = model
        self.approvals = approvals
        self.usage = usage
        self.open = open
    }

    var published: Published {
        Published(expanded: ClaudeCodeLayout.pageHeight(for: model.shown, showsText: ClaudeCodePrefs.showsPrompt,
                                                        approval: approval,
                                                        waiting: approvals?.waiting(for: .claude).count ?? 0,
                                                        isPrivate: approvals?.isPrivate ?? false,
                                                        header: usageHeader),
                  rank: rank, priority: priority, atLimit: atLimit)
    }

    /// The usage line atop the page, while it shows.
    private var usageHeader: CGFloat {
        !model.isPreviewing && usage?.status(.claude) != nil ? UsageLayout.lineHeight : 0
    }

    /// At the usage limit, when it lifts takes the right of the notch.
    private var atLimit: Bool { !model.isPreviewing && usage?.compact(.claude).atLimit == true }

    /// Claude Code's front request, while one is on show and no preview runs.
    var approval: ApprovalItem? {
        guard !model.isPreviewing else { return nil }
        return approvals?.card(for: .claude)?.item
    }

    /// Whether a request waits for an answer in the island.
    var asking: Bool { !model.isPreviewing && approvals?.front(for: .claude) != nil }

    /// Behind the Sound Mixer for the bubble while sessions work, so a prompt does not
    /// push it out each time; ahead of it while one waits on you, so the hand shows.
    var rank: Int { model.needsYou || approval != nil ? 1 : -1 }
    var compactTrailingWidth: CGFloat? { atLimit && !asking ? UsageLayout.limitTrailingWidth : ClaudeCodeLayout.trailingWidth }
    var expandedHeight: CGFloat { published.expanded }

    func compactLeading() -> AnyView { AnyView(ClaudeCodeCompactLeading(model: model, approvals: approvals, usage: usage)) }
    func compactTrailing() -> AnyView { AnyView(ClaudeCodeCompactTrailing(model: model, approvals: approvals, usage: usage)) }
    func minimal() -> AnyView { AnyView(ClaudeCodeMinimal(model: model, approvals: approvals)) }
    func expanded() -> AnyView { AnyView(ClaudeCodeExpanded(model: model, approvals: approvals, usage: usage, open: open)) }
}

/// The feature's preference keys. Unset keys read as their defaults, the same ones the
/// settings toggles declare.
enum ClaudeCodePrefs {
    /// Whether the opened page shows each session's prompt (and, once it is done, the
    /// start of the reply), and names scratch sessions by their prompt.
    static let showPrompt = "claudeCode.showPrompt"

    static var showsPrompt: Bool { UserDefaults.standard.object(forKey: showPrompt) as? Bool ?? true }

    /// Whether the git branch a session's folder is on shows beside the folder, in its
    /// row and in its hook's banners.
    static let showBranch = "claudeCode.showBranch"

    static var showsBranch: Bool { UserDefaults.standard.object(forKey: showBranch) as? Bool ?? true }

    /// Whether permissions Claude Code asks are shown in the island to answer there.
    /// On unless turned off: the hook, and the key beside it, are what opt in.
    static let approveFromIsland = "claudeCode.approveFromIsland"

    static var approvesFromIsland: Bool { UserDefaults.standard.object(forKey: approveFromIsland) as? Bool ?? true }

    /// Whether the island opens by itself for each permission asked.
    static let openForApproval = "claudeCode.openForApproval"

    static var opensForApproval: Bool { UserDefaults.standard.object(forKey: openForApproval) as? Bool ?? true }

    /// Whether a reply finishing in the session on screen in the Claude app puts up no
    /// Done banner.
    static let skipDoneOnScreen = "claudeCode.skipDoneOnScreen"

    static var skipsDoneOnScreen: Bool { UserDefaults.standard.object(forKey: skipDoneOnScreen) as? Bool ?? true }
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
/// `~/.claude/hooks/islet-notify.sh`, with its kind. A tool's use, which comes after
/// every tool call, runs it without Claude Code waiting (`async`). A copy of the script
/// from before the permission hooks would keep in its log all they hand it, commands
/// and their output too, so while one is installed they are left out of the copy.
enum ClaudeCodeHooks {
    static let script = "$HOME/.claude/hooks/islet-notify.sh"
    static let events: [(event: String, kind: String, async: Bool)] = [
        ("SessionStart", "start", false),
        ("UserPromptSubmit", "prompt", false),
        ("PermissionRequest", "permission", false),
        ("Notification", "notification", false),
        ("PostToolUse", "tool", true),
        ("PostToolUseFailure", "tool", true),
        ("Stop", "stop", false),
        ("SubagentStop", "subagent", false),
        ("TaskCompleted", "task", false),
        ("SessionEnd", "end", false),
        ("StopFailure", "failure", false),
    ]

    /// The kinds an older copy of the script does not know.
    static let newerKinds: Set<String> = ["permission", "tool", "failure"]

    /// Two lines an event, short enough to read in the README.
    static var settingsJSON: String { settingsJSON(olderScript: false) }

    /// How long Claude Code lets the permission hook wait for an answer from the island.
    static let permissionTimeout = 600

    /// The hooks, less those `olderScript` does not know. The permission hook may wait
    /// for the island's answer, so it has a long timeout, and runs the script by its
    /// whole path through `bash -p`, which takes no shell functions from the
    /// environment Claude Code was started with.
    static func settingsJSON(olderScript: Bool,
                             home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let known = events.filter { !olderScript || !newerKinds.contains($0.kind) }
        let entries = known.map { event, kind, async in
            if kind == "permission" {
                let path = home + "/.claude/hooks/islet-notify.sh"
                return #"    "\#(event)": [{ "hooks": [{ "type": "command", "timeout": \#(permissionTimeout),"# + "\n"
                    + #"      "command": "/bin/bash -p \"\#(path)\" permission --timeout \#(permissionTimeout)" }] }]"#
            }
            return #"    "\#(event)": [{ "hooks": [{ "type": "command", "timeout": 10,"# + (async ? #" "async": true,"# : "")
                + "\n" + #"      "command": "bash \"\#(script)\" \#(kind)" }] }]"#
        }
        return "{\n  \"hooks\": {\n" + entries.joined(separator: ",\n") + "\n  }\n}\n"
    }

    /// Whether the script installed is a copy from before the permission hooks; false
    /// where there is none, or it cannot be read.
    static var installedScriptIsOlder: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/hooks/islet-notify.sh")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return !text.contains("PermissionRequest")
    }

    static func copy(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(settingsJSON(olderScript: installedScriptIsOlder), forType: .string)
    }
}
