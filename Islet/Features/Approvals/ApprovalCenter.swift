import AppKit
import Foundation
import Observation

/// An answer to a request.
enum ApprovalDecision: String, Sendable {
    case allow
    case deny
    /// Leave it to the app, which asks as it always has.
    case pass
}

/// A request on show, with what the card needs of it.
struct ApprovalItem: Equatable, Identifiable, Sendable {
    var request: ApprovalRequest
    var body: ApprovalBody
    /// When it first came; the queue is blocking requests first, then the oldest.
    var arrived: Date
    /// Which session asks, beside its folder: when the agent started
    /// (`ApprovalSessionLabel`), so two sessions in one folder are told apart.
    var session: String = ""
    var id: String { request.id }
}

/// A few words telling one session from another in the same folder: "since 10:42".
/// The branch beside the folder is the session's own (`ApprovalBranch`).
enum ApprovalSessionLabel {
    static func make(_ request: ApprovalRequest, startTime: (Int32) -> Date?,
                     locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        guard request.agentPid > 1, let started = startTime(request.agentPid) else { return "" }
        let label = "since " + time(started, locale: locale, timeZone: timeZone)
        return ApprovalText.hiddenCharacter(in: label, rule: .strict) == nil ? label : ""
    }

    /// The time, short, as the Mac's clock gives it, in only what the card's strict rule
    /// takes: the clock's own spaces, such as the narrow no-break one before AM or PM on a
    /// 12-hour clock or the no-break one some languages put there, as plain ones, and
    /// without the marks that set the direction of its words. These are Islet's words, not
    /// the agent's, so the rule stays as strict for everything the agent sends; it still
    /// checks the label, which shows only if it passes.
    static func time(_ date: Date, locale: Locale = .autoupdatingCurrent,
                     timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let shown = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
        var scalars = String.UnicodeScalarView()
        for scalar in shown.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .spaceSeparator: scalars.append(" ")
            case .format: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

/// The git branch a card names beside its folder, as the session's row does: the one in
/// Islet's own file for the session that asks (`branch`, which the agent's hook keeps at
/// each event), found by the session's id among that agent's sessions. Never anything
/// the request says, so a request cannot name a branch of its own. None while the
/// agent's Show the git branch is off, for a session with no file or no branch, or for a
/// name that could pass the rest off as more of the line: one with white space, `~ ^ : ?
/// * [ \` (which git never lets a branch's name hold), anything a reader could not see,
/// or punctuation, a symbol or a digit from outside ASCII (but the ellipsis a long name
/// is cut at), which could stand in for the line's own ` · ` or a time's colon.
enum ApprovalBranch {
    /// The most of a branch's name the card shows, cut in the middle as the rows cut
    /// it, so the folder keeps its room.
    static let limit = 32
    /// What git never lets a branch's name hold, besides white space.
    private static let forbidden = Set("~^:?*[\\".unicodeScalars)
    /// The ellipsis where a long name was cut in the middle, by the hook, the session's
    /// file or the card.
    private static let cut: Unicode.Scalar = "\u{2026}"

    /// The branch for `request` from Claude Code's sessions.
    static func of(_ request: ApprovalRequest, claude records: [ClaudeSessionRecord], showsBranch: Bool) -> String? {
        guard request.agent == .claude, showsBranch, !request.sessionId.isEmpty else { return nil }
        return shown(records.first { $0.id == request.sessionId }?.branch)
    }

    /// The branch for `request` from ChatGPT's sessions.
    static func of(_ request: ApprovalRequest, chatGPT records: [ChatGPTSessionRecord], showsBranch: Bool) -> String? {
        guard request.agent == .chatgpt, showsBranch, !request.sessionId.isEmpty else { return nil }
        return shown(records.first { $0.id == request.sessionId }?.branch)
    }

    /// `branch` as the card shows it, or `nil` for none.
    static func shown(_ branch: String?) -> String? {
        guard let branch, !branch.isEmpty,
              ApprovalText.hiddenCharacter(in: branch, rule: .strict) == nil,
              !branch.unicodeScalars.contains(where: { $0.properties.isWhitespace || forbidden.contains($0) || !isAllowed($0) })
        else { return nil }
        return SessionBranch.middle(branch, limit: limit)
    }

    /// Whether a branch's name may hold `scalar`: anything in ASCII and the ellipsis
    /// where a long name was cut, and from beyond them only letters and the marks that
    /// go on them, which the card then marks.
    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII || scalar == cut { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    /// Whether `branch`, as `shown` gives it, has letters that could pass for others, or
    /// marks on letters: all it may hold from outside ASCII besides the ellipsis where it
    /// was cut. The card marks it as it marks such words in a request.
    static func isLookAlike(_ branch: String) -> Bool {
        branch.unicodeScalars.contains { !$0.isASCII && $0 != cut }
    }
}

/// A card answered from the island, shown as answered for a moment with its buttons
/// off, so the person sees their click took.
struct ApprovalDecided: Equatable, Sendable {
    var item: ApprovalItem
    var decision: ApprovalDecision
}

/// A permission answered from the island, kept in memory until the session's file
/// moves on: Claude Code says nothing of a denial, and the hook's note of the asking
/// stays until a tool starts a couple of seconds later, so the session would go on
/// showing as needing permission. ChatGPT's hook notes the asking as before, and
/// nothing but the next tool's event or the turn's end clears it.
struct ApprovalSettled: Equatable, Sendable {
    var agent: ApprovalAgent = .claude
    var sessionId: String
    var agentId: String
    var tool: String
    var pendingInput: String
    var answeredAt: Date
}

/// The requests hooks have offered, and the answers to them. One for all of Islet, so
/// an answer on one display takes the card from every display.
///
/// It reads `Requests/` as files arrive and once a second checks each request's hook is
/// still running, its time not up, and for Claude Code whether it was answered in the
/// app (`ClaudeApprovalWatch`); once a minute it clears what hooks left. It keeps
/// `presence.json` saying whether it takes requests, and passes every blocking request
/// back to its app when the person is not there to answer it.
@MainActor
@Observable
final class ApprovalCenter {
    enum Refusal: Error, Equatable {
        case notFound, notArmed, allowWithheld, cannotSign, changed, late, unwritable
    }

    /// Islet's own, which also reads whether the island shows on the display with the
    /// pointer: one hidden for a full-screen app there shows no card.
    static let shared: ApprovalCenter = {
        let center = ApprovalCenter()
        center.readConditions = {
            let island = IslandManager.shared.focusedController?.model
            return (!ActivityCenter.shared.heldBack.isEmpty, !ActivityCenter.shared.mayHoldBack.isEmpty,
                    island.map { $0.mode != .hidden } ?? false)
        }
        return center
    }()

    /// The queue: blocking requests first, then the oldest.
    private(set) var items: [ApprovalItem] = []
    /// Answers given from the island, settled until their sessions move on.
    private(set) var settled: [ApprovalSettled] = []
    /// The requests, Claude's prompt running beside them, whose card has been on screen
    /// without a sign for 10 seconds, which then reads "Claude may have answered
    /// already".
    private(set) var maybeAnswered: Set<String> = []
    /// Whether the folder is Islet's and the lock held: requests are taken.
    private(set) var isRunning = false
    /// Each agent's card kept in front while the pointer is in the island, or brought
    /// forward from those waiting: a request arriving meanwhile waits behind it.
    private(set) var held: [ApprovalAgent: String] = [:]
    /// Each agent's card just answered from the island, for `decidedFor`.
    private(set) var decided: [ApprovalAgent: ApprovalDecided] = [:]
    /// Presentation Mode is on or the screen is captured: a card says only that the
    /// agent asks, and to answer in its app.
    private(set) var isPrivate = false
    /// The requests the island opened by itself for, and when it finished opening, by
    /// `ProcessInfo.systemUptime`: their Allow waits longer, and for the pointer.
    private(set) var openedFor: [String: TimeInterval] = [:]

    @ObservationIgnored let folder: ApprovalFolder
    @ObservationIgnored let signer: ApprovalSigner
    /// The agents whose requests are taken, as their settings say.
    @ObservationIgnored var accepting: Set<ApprovalAgent> = [] {
        didSet { if accepting != oldValue { agentsChanged(from: oldValue) } }
    }
    /// The Claude Code sessions as last read, for the signals of an answer in the app.
    @ObservationIgnored var claudeRecords: () -> [ClaudeSessionRecord] = { [] }
    /// The ChatGPT sessions as last read, for letting go of answers once they move on.
    @ObservationIgnored var chatGPTRecords: () -> [ChatGPTSessionRecord] = { [] }
    /// The conditions beyond the lock and the frontmost app: Presentation Mode, the
    /// screen captured, the island showing where the pointer is.
    @ObservationIgnored var readConditions: () -> (presenting: Bool, captured: Bool, visible: Bool) = {
        (!ActivityCenter.shared.heldBack.isEmpty, !ActivityCenter.shared.mayHoldBack.isEmpty, true)
    }
    /// How long a blocking request may wait, by Settings: ChatGPT's, and the
    /// terminal's.
    @ObservationIgnored var waits = (chatGPT: 30, terminal: 30) {
        didSet { if waits != oldValue { conditionsChanged() } }
    }

    @ObservationIgnored private let presence: ApprovalPresence
    @ObservationIgnored private let lock = ApprovalLock()
    @ObservationIgnored private let conditionWatch = ApprovalConditionWatch()
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let startTime: (Int32) -> Date?
    @ObservationIgnored private let watchesConditions: Bool
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastSweep = Date.distantPast
    /// Requests answered or withdrawn, so a card cannot come back in the moment before
    /// its hook deletes the file; and requests refused, not read again.
    @ObservationIgnored private var remembered: [String: Date] = [:]
    @ObservationIgnored private var watchMemory = ClaudeApprovalWatch.Memory()
    @ObservationIgnored private var isLooking = false
    /// When each card was first on screen, for "may have answered already".
    @ObservationIgnored private var onScreenSince: [String: Date] = [:]
    /// When each blocking request's card was last on screen or under the pointer.
    @ObservationIgnored private var lastSeen: [String: Date] = [:]
    @ObservationIgnored private var conditions = ApprovalConditions()
    /// The requests the island has been asked whether to open for, once each.
    @ObservationIgnored private var openingAsked: Set<String> = []

    /// How long an answered request's id is kept.
    static let rememberFor: TimeInterval = 120
    /// How long a card shows with no sign before saying Claude may have answered.
    static let quietFor: TimeInterval = 10
    /// How long a blocking request's card may go unseen before the app asks itself.
    static let unseenFor: TimeInterval = 12
    /// How long a settled answer lasts at most.
    static let settledFor: TimeInterval = 600
    /// How long a ChatGPT session's Passed marks outlast its latest.
    static let passedFor: TimeInterval = 86400
    /// How long an answered card stays, answered, before the next.
    static let decidedFor: TimeInterval = 0.8
    /// How soon after a request arrives the island may still open by itself for it.
    static let openWithin: TimeInterval = 3

    /// Tests give a folder, a key store and files, a clock and a stand-in for process
    /// start times, and keep the system's conditions out of it.
    init(folder: ApprovalFolder = .standard,
         signer: ApprovalSigner? = nil,
         now: @escaping () -> Date = Date.init,
         startTime: @escaping (Int32) -> Date? = ClaudeProcess.startTime(of:),
         watchesConditions: Bool = true) {
        self.folder = folder
        self.signer = signer ?? ApprovalSigner(store: ApprovalKeychain(), keyFiles: ApprovalSigner.standardKeyFiles())
        self.presence = ApprovalPresence(folder: folder)
        self.now = now
        self.startTime = startTime
        self.watchesConditions = watchesConditions
    }

    var front: ApprovalItem? { items.first }

    /// `agent`'s requests, in the queue's order.
    func items(for agent: ApprovalAgent) -> [ApprovalItem] { items.filter { $0.request.agent == agent } }

    /// The request `agent`'s card shows: the one held in front, or the first.
    func front(for agent: ApprovalAgent) -> ApprovalItem? {
        let mine = items(for: agent)
        if let id = held[agent], let item = mine.first(where: { $0.id == id }) { return item }
        return mine.first
    }

    /// The card on `agent`'s page: the one just answered while it shows so, else the front
    /// request.
    func card(for agent: ApprovalAgent) -> (item: ApprovalItem, decided: ApprovalDecision?)? {
        if let done = decided[agent] { return (done.item, done.decision) }
        return front(for: agent).map { ($0, nil) }
    }

    /// `agent`'s requests behind its card.
    func waiting(for agent: ApprovalAgent) -> [ApprovalItem] {
        let shown = card(for: agent)?.item.id
        return items(for: agent).filter { $0.id != shown }
    }

    /// Keeps `id` in front of `agent`'s queue (the pointer is in the island, or it was
    /// brought forward), or with `nil` lets the queue's order stand again.
    func hold(_ id: String?, for agent: ApprovalAgent) {
        if held[agent] != id { held[agent] = id }
    }

    /// Whether the island should open by itself for `item`: asked once a request, while it
    /// is new, with the person at the Mac, not presenting, the island showing and the
    /// app that asks not in front.
    func takeOpening(_ item: ApprovalItem) -> Bool {
        guard isRunning, !openingAsked.contains(item.id) else { return false }
        openingAsked.insert(item.id)
        let c = conditions
        return now().timeIntervalSince(item.arrived) < Self.openWithin && !c.locked && !c.presenting && !c.captured
            && c.visible && (item.request.hostApp.isEmpty || c.frontmost != item.request.hostApp)
    }

    /// The island opened by itself for `id`, finishing at `time`; `nil` when it did not
    /// open after all.
    func openedByItself(_ id: String, finishing time: TimeInterval?) { openedFor[id] = time }

    // MARK: Running

    /// Takes requests, if the folder can be made Islet's and no other Islet holds it.
    func start() {
        guard !isRunning else { return }
        guard folder.prepare(), lock.take(folder.lock) else {
            IslandLog.app.info("Approvals: folder unusable or held by another Islet")
            return
        }
        isRunning = true
        sweep()
        if watchesConditions {
            conditionWatch.onChange = { [weak self] in self?.conditionsChanged() }
            conditionWatch.start()
        }
        let watcher = FolderWatcher(url: folder.requests, debounce: 0.05) { [weak self] in self?.refresh() }
        self.watcher = watcher
        watcher.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        conditionsChanged()
    }

    /// Stops taking requests: every one on show goes back to its app, and the presence
    /// file goes. Called when approvals are turned off and when Islet quits.
    func stop() {
        guard isRunning else { return }
        for item in items { write(item.request, .pass) }
        items = []
        held = [:]
        openedFor = [:]
        presence.withdraw()
        watcher?.stop()
        watcher = nil
        timer?.invalidate()
        timer = nil
        conditionWatch.stop()
        lock.release()
        isRunning = false
    }

    /// Takes `agent`'s requests or stops: running while any agent's are taken.
    func setAccepting(_ agent: ApprovalAgent, _ on: Bool) {
        if on { accepting.insert(agent) } else { accepting.remove(agent) }
        if accepting.isEmpty { stop() } else { start() }
    }

    /// `record` with the permissions answered from the island taken from its pending
    /// list, and a session left needing none of them working again.
    func settle(_ record: ClaudeSessionRecord) -> ClaudeSessionRecord {
        let answered = settled.filter { $0.agent == .claude && $0.sessionId == record.id && !$0.pendingInput.isEmpty }
        guard !answered.isEmpty else { return record }
        var record = record
        let before = record.pending.count
        record.pending.removeAll { entry in
            answered.contains { $0.agentId == entry.agentId && $0.tool == entry.tool && $0.pendingInput == entry.input }
        }
        if record.pending.count < before, record.pending.isEmpty, record.state == .needsPermission {
            record.state = .working
            record.since = max(record.since, answered.map(\.answeredAt).max() ?? record.since)
        }
        return record
    }

    /// `record` shown as working while the permission it asks was answered from the
    /// island: until its file says anything else, or asks again.
    func settle(_ record: ChatGPTSessionRecord) -> ChatGPTSessionRecord {
        guard record.state == .needsPermission,
              let answeredAt = settled.filter({ $0.agent == .chatgpt && $0.sessionId == record.id })
                  .map(\.answeredAt).max(),
              record.since <= answeredAt
        else { return record }
        var record = record
        record.state = .working
        record.since = answeredAt
        return record
    }

    /// Forgets answers whose sessions have moved on: for Claude Code, their entries gone
    /// from the file written since; for ChatGPT, the file no longer asking what was
    /// answered.
    private func pruneSettled() {
        guard !settled.isEmpty else { return }
        let records = Dictionary(claudeRecords().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let chatGPT = Dictionary(chatGPTRecords().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = settled.filter { answer in
            if answer.agent == .chatgpt {
                guard let record = chatGPT[answer.sessionId] else { return true }
                return record.state == .needsPermission && record.since <= answer.answeredAt
            }
            guard let record = records[answer.sessionId] else { return true }
            let listed = record.pending.contains {
                $0.agentId == answer.agentId && $0.tool == answer.tool && $0.input == answer.pendingInput
            }
            return listed || record.updated <= answer.answeredAt
        }
        if kept != settled { settled = kept }
    }

    private func agentsChanged(from old: Set<ApprovalAgent>) {
        for item in items where !accepting.contains(item.request.agent) { withdraw(item.id) }
        conditionsChanged()
    }

    // MARK: Requests

    /// Reads the requests folder for requests not yet on show.
    func refresh() {
        guard isRunning else { return }
        let date = now()
        let known = Set(items.map(\.id))
        var added = false
        for name in ApprovalFiles.names(in: folder.requests) where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard ApprovalFolder.isID(id), !known.contains(id), remembered[id] == nil else { continue }
            switch ApprovalRequestReader.read(folder.request(id), now: date, startTime: startTime) {
            case .success(let request):
                guard accepting.contains(request.agent), date < request.deadline else {
                    write(request, .pass)
                    continue
                }
                guard ApprovalBody.isShown(request.tool, agent: request.agent) else {
                    write(request, .pass)
                    continue
                }
                let item = ApprovalItem(request: request, body: ApprovalBody.make(request), arrived: date,
                                        session: ApprovalSessionLabel.make(request, startTime: startTime))
                items.append(item)
                IslandLog.app.info("Approvals: request \(id, privacy: .public) for \(request.tool, privacy: .public)")
                announce(item)
                added = true
            case .failure(.hookGone), .failure(.hookStartedElsewhen):
                // A hook gone leaves its request: no one waits for it.
                ApprovalFiles.remove(folder.request(id))
            case .failure:
                remembered[id] = date
            }
        }
        // A request whose file has gone was ended by its hook.
        let present = Set(ApprovalFiles.names(in: folder.requests))
        // Only a change is assigned: the cards watch the queue.
        let kept = items.filter { present.contains($0.id + ".json") }
        let removed = kept.count != items.count
        if removed { items = kept }
        if added || removed { sortQueue() }
    }

    /// Says the request has come, for VoiceOver: what is asked and where, never the
    /// command itself; while presenting, only that it asks.
    private func announce(_ item: ApprovalItem) {
        guard watchesConditions, NSWorkspace.shared.isVoiceOverEnabled else { return }
        let words = Self.spoken(item, isPrivate: isPrivate)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// "Claude asks to run a command in Islet".
    static func spoken(_ item: ApprovalItem, isPrivate: Bool) -> String {
        let agent = item.request.agent.name
        guard !isPrivate else { return "\(agent) needs permission" }
        let headline = item.body.headline
        let what = headline.prefix(1).lowercased() + headline.dropFirst()
        let project = item.request.project.isEmpty ? "" : " in \(item.request.project)"
        return "\(agent) asks to \(what)\(project)"
    }

    private func sortQueue() {
        items.sort { a, b in
            if a.request.isBlocking != b.request.isBlocking { return a.request.isBlocking }
            if a.arrived != b.arrived { return a.arrived < b.arrived }
            return a.id < b.id
        }
    }

    /// Once a second: requests whose hooks have gone or whose time is up leave; Claude
    /// Code's are checked for an answer in the app.
    func tick() {
        guard isRunning else { return }
        let date = now()
        for item in items {
            if !ApprovalRequestReader.hookAlive(item.request, startTime: startTime) {
                ApprovalFiles.remove(folder.request(item.id))
                forget(item.id, at: date)
            } else if date >= item.request.deadline {
                forget(item.id, at: date)
            }
        }
        // Only a change is assigned: the agents' pages watch these.
        let fresh = settled.filter { date.timeIntervalSince($0.answeredAt) <= Self.settledFor }
        if fresh.count != settled.count { settled = fresh }
        pruneSettled()
        conditionsChanged()
        if date.timeIntervalSince(lastSweep) >= 60 { sweep() }
        lookForAnswersInApp()
        releaseUnseen(at: date)
        for item in items where !item.request.isBlocking && !maybeAnswered.contains(item.id) {
            if let since = onScreenSince[item.id], date.timeIntervalSince(since) >= Self.quietFor {
                maybeAnswered.insert(item.id)
            }
        }
    }

    /// Leaves to its app a blocking request whose card has gone unseen for
    /// `unseenFor`, neither on screen nor under the pointer, while the person works in
    /// another app: they are not looking at the island, and the app waits to ask.
    private func releaseUnseen(at date: Date) {
        let own = Bundle.main.bundleIdentifier ?? ""
        for item in items where item.request.isBlocking {
            if onScreenSince[item.id] != nil || held[item.request.agent] == item.id {
                lastSeen[item.id] = date
                continue
            }
            let since = lastSeen[item.id] ?? item.arrived
            if date.timeIntervalSince(since) >= Self.unseenFor, own.isEmpty || conditions.frontmost != own {
                IslandLog.app.info("Approvals: \(item.id, privacy: .public) unseen, left to the app")
                withdraw(item.id)
            }
        }
    }

    /// Reads the signals of an answer in the Claude app, off the main thread.
    func lookForAnswersInApp() {
        let requests = items.map(\.request).filter { $0.agent == .claude }
        guard !requests.isEmpty, !isLooking else { return }
        isLooking = true
        let records = claudeRecords()
        var memory = watchMemory
        let startTime = startTime
        let roots = ClaudeApprovalWatch.transcriptRoots()
        DispatchQueue.global(qos: .utility).async {
            let signals = ClaudeApprovalWatch.look(requests, records: records, memory: &memory, roots: roots,
                                                   hookAlive: { ApprovalRequestReader.hookAlive($0, startTime: startTime) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.isLooking = false
                    self.watchMemory = memory
                    self.answeredInApp(signals)
                }
            }
        }
    }

    /// Withdraws the cards a signal says were answered in the app.
    func answeredInApp(_ signals: [String: ClaudeApprovalSignal]) {
        for (id, signal) in signals where items.contains(where: { $0.id == id }) {
            IslandLog.app.info("Approvals: \(id, privacy: .public) answered in the app (\(signal.rawValue, privacy: .public))")
            withdraw(id)
        }
    }

    /// The card for `id` came on screen, or went: for "may have answered already", and
    /// how long a blocking one has gone unseen.
    func cardShown(_ id: String, _ shown: Bool) {
        if shown {
            if onScreenSince[id] == nil { onScreenSince[id] = now() }
        } else {
            onScreenSince[id] = nil
            if items.contains(where: { $0.id == id }) { lastSeen[id] = now() }
        }
    }

    // MARK: Answers

    /// Whether Allow can be offered for `item` at all: nothing in it withholds Allow,
    /// and Islet can sign for its agent (`canSign`).
    func offersAllow(_ item: ApprovalItem) -> Bool {
        item.body.offersAllow && canSign(for: item.request.agent)
    }

    /// Whether Islet can sign `agent`'s Allow and Deny, or has yet to read its key.
    func canSign(for agent: ApprovalAgent) -> Bool {
        let status = signer.status(for: agent)
        return status == .ready || status == .unread
    }

    /// Answers `id` from the island. Allow needs the token of an armed, real click for
    /// this very request, and the request file as it was read.
    @discardableResult
    func answer(_ id: String, _ decision: ApprovalDecision, click: ApprovalClick? = nil) -> Result<Void, Refusal> {
        guard let item = items.first(where: { $0.id == id }) else { return .failure(.notFound) }
        let request = item.request
        if decision == .allow {
            guard let click, click.id == id, click.digest == request.digest else { return .failure(.notArmed) }
            guard item.body.offersAllow else { return .failure(.allowWithheld) }
            guard ApprovalFiles.stamp(folder.request(id)) == request.stamp else { return .failure(.changed) }
        }
        guard now() < request.deadline else { return .failure(.late) }
        if case .failure(let refusal) = write(request, decision) { return .failure(refusal) }
        forget(id, at: now())
        if decision != .pass {
            let agent = request.agent
            decided[agent] = ApprovalDecided(item: item, decision: decision)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.decidedFor) { [weak self] in
                MainActor.assumeIsolated {
                    if self?.decided[agent]?.item.id == id { self?.decided[agent] = nil }
                }
            }
            settled.append(ApprovalSettled(agent: request.agent, sessionId: request.sessionId, agentId: request.agentId,
                                           tool: request.tool, pendingInput: request.pendingInput, answeredAt: now()))
        }
        IslandLog.app.info("Approvals: \(id, privacy: .public) answered \(decision.rawValue, privacy: .public)")
        return .success(())
    }

    /// Takes the card away and leaves the request to the app.
    func withdraw(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        write(item.request, .pass)
        forget(id, at: now())
    }

    /// Leaves every blocking request to its app at once: the person is not there to
    /// answer in the island.
    func passAllBlocking() {
        for item in items where item.request.isBlocking { withdraw(item.id) }
    }

    /// Writes the answer file: an Allow or Deny signed, a pass not, since the hook takes
    /// anything but a signed allow or deny as one. So only a click reads the key, and a
    /// pass never brings up the Keychain.
    @discardableResult
    private func write(_ request: ApprovalRequest, _ decision: ApprovalDecision) -> Result<Void, Refusal> {
        let answered = Int64(max(min(now().timeIntervalSince1970, request.deadline.timeIntervalSince1970),
                                 request.created.timeIntervalSince1970).rounded(.down))
        var signature: String?
        if decision != .pass {
            signature = signer.sign(id: request.id, digest: request.digest, decision: decision, answered: answered,
                                    for: request.agent)
            if signature == nil { return .failure(.cannotSign) }
        }
        let object: [String: Any] = ["version": 1, "id": request.id, "digest": request.digest,
                                     "decision": decision.rawValue, "answered": answered, "sig": signature ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              ApprovalFiles.write(data, to: folder.answer(request.id), exclusive: true)
        else { return .failure(.unwritable) }
        return .success(())
    }

    private func forget(_ id: String, at date: Date) {
        remembered[id] = date
        items.removeAll { $0.id == id }
        openedFor[id] = nil
        for (agent, kept) in held where kept == id { held[agent] = nil }
        onScreenSince[id] = nil
        lastSeen[id] = nil
        if maybeAnswered.contains(id) { maybeAnswered.remove(id) }
    }

    // MARK: Conditions

    private func conditionsChanged() {
        guard isRunning else { return }
        let read = readConditions()
        var next = ApprovalConditions()
        next.accepting = accepting
        next.chatGPTWait = waits.chatGPT
        next.terminalWait = waits.terminal
        next.locked = watchesConditions && (conditionWatch.locked || conditionWatch.asleep)
        next.presenting = read.presenting
        next.captured = read.captured
        next.visible = read.visible
        next.frontmost = watchesConditions ? conditionWatch.frontmost : ""
        conditions = next
        if isPrivate != (next.presenting || next.captured) { isPrivate = next.presenting || next.captured }
        presence.update(next, now: now())
        if !next.showsBlocking {
            passAllBlocking()
        } else {
            // The app that would ask has come forward: it asks there.
            for item in items where item.request.isBlocking && !item.request.hostApp.isEmpty
                && item.request.hostApp == next.frontmost {
                withdraw(item.id)
            }
        }
    }

    // MARK: Housekeeping

    /// Deletes requests whose hooks have gone or are long past their time, answers and
    /// half-written files a minute old, and ChatGPT sessions' Passed marks a day old,
    /// and forgets old answered ids.
    func sweep() {
        let date = now()
        lastSweep = date
        for name in ApprovalFiles.names(in: folder.requests) {
            let url = folder.requests.appendingPathComponent(name)
            if name.hasPrefix(".") {
                if let modified = ApprovalFiles.modified(url), date.timeIntervalSince(modified) > 60 {
                    ApprovalFiles.remove(url)
                }
                continue
            }
            let id = name.hasSuffix(".json") ? String(name.dropLast(5)) : ""
            guard ApprovalFolder.isID(id) else { continue }
            switch ApprovalRequestReader.read(url, now: date, startTime: startTime) {
            case .success(let request) where date.timeIntervalSince(request.deadline) <= 60: break
            case .failure(.unreadable), .failure(.malformed), .failure(.badPid), .failure(.badTimes),
                 .failure(.callMismatch):
                if let modified = ApprovalFiles.modified(url), date.timeIntervalSince(modified) > 600 {
                    ApprovalFiles.remove(url)
                }
            default:
                ApprovalFiles.remove(url)
            }
        }
        for name in ApprovalFiles.names(in: folder.answers) {
            let url = folder.answers.appendingPathComponent(name)
            if let modified = ApprovalFiles.modified(url), date.timeIntervalSince(modified) > 60 { ApprovalFiles.remove(url) }
        }
        // A session's marks go once it has left nothing to the app for a day.
        for name in ApprovalFiles.names(in: folder.passed) {
            let url = folder.passed.appendingPathComponent(name)
            if let modified = ApprovalFiles.modified(url), date.timeIntervalSince(modified) > Self.passedFor {
                ApprovalFiles.removeFolder(url)
            }
        }
        remembered = remembered.filter { date.timeIntervalSince($0.value) < Self.rememberFor }
        openingAsked = openingAsked.filter { id in remembered[id] != nil || items.contains { $0.id == id } }
    }
}
