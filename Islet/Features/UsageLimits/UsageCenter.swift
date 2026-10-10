import AppKit
import SwiftUI
import Observation

/// The preference keys for an agent's usage limits, in its own pane of Settings. Unset
/// keys read as on, as the toggles declare.
enum UsagePrefs {
    /// Whether the agent's limits are read and shown at all.
    static func showKey(_ agent: UsageAgent) -> String { agent.activityID + ".showUsage" }
    /// Whether a banner warns at 80% and 95% of a window. The limit reached has its
    /// banner either way.
    static func warnKey(_ agent: UsageAgent) -> String { agent.activityID + ".warnUsage" }
    /// Whether the agent's mark in the compact island gets a ring from 80%. When the
    /// limit lifts shows beside the notch either way.
    static func ringKey(_ agent: UsageAgent) -> String { agent.activityID + ".usageRing" }

    /// Whether Claude's limits are refreshed where they have grown old
    /// (`ClaudeUsageRefresh`).
    static let refreshClaude = "claudeCode.refreshUsage"

    static func shows(_ agent: UsageAgent, in defaults: UserDefaults = .standard) -> Bool { flag(showKey(agent), defaults) }
    static func warns(_ agent: UsageAgent, in defaults: UserDefaults = .standard) -> Bool { flag(warnKey(agent), defaults) }
    static func ring(_ agent: UsageAgent, in defaults: UserDefaults = .standard) -> Bool { flag(ringKey(agent), defaults) }
    static func refreshesClaude(in defaults: UserDefaults = .standard) -> Bool { flag(refreshClaude, defaults) }

    private static func flag(_ key: String, _ defaults: UserDefaults) -> Bool { defaults.object(forKey: key) as? Bool ?? true }

    /// The banners already put up, each window's until it resets (`UsageAlerts`).
    static let said = "usageLimits.said"
    /// Gemini's last figures read from Antigravity, shown dimmed while it is closed
    /// (`GeminiUsage.Kept`).
    static let geminiKept = "gemini.usageKept"
    /// The last limits Quick Ask or a refresh said of Claude, restored at launch
    /// (`ClaudeUsage.Kept`).
    static let claudeKept = "claudeCode.usageKept"
    /// When Claude's limits were last refreshed, for the least time between two.
    static let claudeRefreshed = "claudeCode.usageRefreshed"
}

/// How Islet gets at Antigravity, which tests replace: which of its processes run, and
/// a read of its quota.
struct AntigravityAccess {
    /// The Antigravity app's processes running now: the one at `GeminiUsage.appPath`
    /// alone.
    var running: @MainActor () -> [Int32]
    /// Asks its server for the quota, off the main thread.
    var read: @Sendable (_ apps: [Int32], _ known: GeminiUsage.Known?) -> GeminiUsage.Outcome

    static let live = AntigravityAccess(
        running: {
            NSRunningApplication.runningApplications(withBundleIdentifier: GeminiHostApp.antigravity)
                .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL.path == GeminiUsage.appPath }
                .map(\.processIdentifier)
        },
        read: { apps, known in GeminiUsage.read(apps: apps, known: known, system: .live) }
    )
}

/// Claude's, ChatGPT's and Gemini's usage limits, for the island: read while the agent's
/// activity is on and Settings shows its limits. Claude's and ChatGPT's come from files on
/// this Mac (`ClaudeUsage`, `ChatGPTUsage`), and only when they change: the Claude app's
/// folder and Codex's are watched for entries changing (`FolderWatcher`), which the Claude
/// app writing its history and Codex updating a thread both do, and ChatGPT's hooks say
/// when a chat has moved on. Claude's runs of Quick Ask say Claude's exactly, which are
/// kept across relaunches, and where the newest are over 20 minutes old as the tile or
/// the Claude Code page is about to show, a tiny request of Islet's own asks for them
/// afresh, at most once every 15 minutes (`ClaudeUsageRefresh`). Gemini's are asked of Antigravity while it is open
/// (`GeminiUsage`): as the tile, the Gemini page or its usage line is about to show, as
/// an Antigravity hook event comes, as Antigravity opens, and once a limit's reset has
/// passed; at most once a minute, every five while the island saves energy, and never
/// while Antigravity is closed, when its last figures show dimmed. Nothing polls. One
/// timer is kept, for the next moment the clock alone changes what shows: a window's
/// reset, or a Claude reading growing old.
///
/// It puts up the AI Usage tile while there is a reading, warns of a window filling and
/// of the limit through Show in Islet's banners (`UsageAlerts`), and its readings are
/// what the activities' pages and compact islands show.
@MainActor
@Observable
final class UsageCenter {
    static let shared = UsageCenter()

    /// Posted on the main thread when what the activities draw from it may have changed,
    /// for them to re-publish.
    static let didChange = Notification.Name("UsageCenterDidChange")

    static let tileID = "aiUsage"
    /// Where the tile goes on the home page: after Quick Ask, before the shelf.
    static let tileOrder = 57
    static let tileInfo = HomeTileInfo(id: tileID, title: "AI Usage", symbol: "gauge.with.dots.needle.50percent",
                                       order: tileOrder)

    /// Each agent's reading, while its limits are shown.
    private(set) var readings: [UsageAgent: UsageReading] = [:]
    /// The time the readings were last looked at, which the views show them as of.
    private(set) var now: Date
    /// What the Claude app's history file last said, for Settings.
    private(set) var claudeHistory: ClaudeUsage.History?
    /// What Islet last made of asking Antigravity, for Settings.
    private(set) var geminiSource: GeminiSource = .notRead
    /// Whether Antigravity was open when Islet last looked.
    private(set) var antigravityOpen = false
    /// What Quick Ask or a refresh last said of Claude's limits, kept across relaunches.
    private(set) var claudeEvent: ClaudeUsage.LimitEvent?
    /// What came of refreshing Claude's limits, for Settings.
    private(set) var claudeRefreshNote: ClaudeUsageRefresh.Note?

    /// What came of asking Antigravity for Gemini's quota.
    enum GeminiSource: Equatable {
        case notRead
        /// Read at this time.
        case read(Date)
        /// Not read at this time: no answer, a refusal or an answer Islet can't read.
        case failed(Date)
    }

    /// The least time between two reads of Gemini's quota, and while the island saves
    /// energy.
    static let geminiInterval: TimeInterval = 60
    static let geminiSavingInterval: TimeInterval = 5 * 60

    /// Where the settings above and the warnings said are kept.
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let claudeFolder: URL
    @ObservationIgnored private let codexHome: String
    @ObservationIgnored private let present: @MainActor (CustomBanner) -> Void
    @ObservationIgnored private let publishesTile: Bool
    @ObservationIgnored private var running: Set<UsageAgent> = []
    @ObservationIgnored private var active: Set<UsageAgent> = []
    @ObservationIgnored private var claudeWatcher: FolderWatcher?
    @ObservationIgnored private var codexWatcher: FolderWatcher?
    @ObservationIgnored private var claudeStamp: FileStamp?
    @ObservationIgnored private var claudeLimitHit: Date?
    @ObservationIgnored private var chatGPTReading: UsageReading?
    @ObservationIgnored private var chatGPTCache = ChatGPTUsage.Cache()
    @ObservationIgnored private var chatGPTHomes: [String] = []
    @ObservationIgnored private var chatGPTTranscripts: [String] = []
    @ObservationIgnored private var chatGPTSignature: [String] = []
    @ObservationIgnored private var readingChatGPT = false
    @ObservationIgnored private var readChatGPTAgain = false
    @ObservationIgnored private let antigravity: AntigravityAccess
    @ObservationIgnored private let saving: @MainActor () -> Bool
    @ObservationIgnored private let claudeAccess: ClaudeUsageRefresh.System
    /// The refresh of Claude's limits under way.
    @ObservationIgnored private var claudeRefreshing: Task<Void, Never>?
    /// Gemini's reading, the last kept while Antigravity is closed.
    @ObservationIgnored private var geminiReading: UsageReading?
    /// The server and port that last answered.
    @ObservationIgnored private var geminiKnown: GeminiUsage.Known?
    /// When Antigravity was last asked, for the least time between reads.
    @ObservationIgnored private(set) var geminiAsked: Date?
    @ObservationIgnored private var readingGemini = false
    /// The last read gave no figures (no answer, or no server), so those shown are
    /// dimmed once as old as Claude's are (`UsageStatus.staleAfter`).
    @ObservationIgnored private var geminiFailing = false
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    /// Bumped as each agent's reading starts or stops, so a read finishing after either
    /// is let go.
    @ObservationIgnored private var generations: [UsageAgent: Int] = [:]
    @ObservationIgnored private var alerts: UsageAlerts
    @ObservationIgnored private var timer: DispatchWorkItem?
    @ObservationIgnored private(set) var timerDue: Date?
    @ObservationIgnored private var tileShown = false
    /// The tile's share of the row as last put up: wider with a third column.
    @ObservationIgnored private var tileWeight: CGFloat = 0
    /// What the activities were last told: whether each agent's line shows, and its
    /// compact island.
    @ObservationIgnored private var published = Dictionary(uniqueKeysWithValues: UsageAgent.allCases.map { ($0, CompactUsage()) })
    @ObservationIgnored private var publishedLines: Set<UsageAgent> = []
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    /// Tests give a clock, folders and defaults of their own, and a stand-in for the
    /// banners; the island's tile is left alone unless `publishesTile`.
    init(
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = Date.init,
        claudeFolder: URL = ClaudeUsage.folder,
        codexHome: String = ChatGPTUsage.defaultHome,
        antigravity: AntigravityAccess = .live,
        claude: ClaudeUsageRefresh.System? = nil,
        saving: @escaping @MainActor () -> Bool = { EnergySaver.shared.isSaving },
        publishesTile: Bool = true,
        present: @escaping @MainActor (CustomBanner) -> Void = { banner in
            _ = FeatureRegistry.shared.feature(BannerFeature.self)?.show(banner)
        }
    ) {
        self.defaults = defaults
        self.clock = clock
        self.claudeFolder = claudeFolder
        self.codexHome = codexHome
        self.antigravity = antigravity
        claudeAccess = claude ?? .live
        self.saving = saving
        self.publishesTile = publishesTile
        self.present = present
        now = clock()
        let saved = defaults.data(forKey: UsagePrefs.said)
        alerts = saved.flatMap { try? JSONDecoder().decode(UsageAlerts.self, from: $0) } ?? UsageAlerts()
    }

    // MARK: Running

    /// The agent's activity has started: its limits are read while Settings shows them.
    func start(_ agent: UsageAgent) {
        running.insert(agent)
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
        reconcile()
    }

    func stop(_ agent: UsageAgent) {
        running.remove(agent)
        if running.isEmpty, let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        reconcile()
    }

    /// Reads, or stops reading, each agent's limits as its activity and Settings say.
    private func reconcile() {
        let wanted = Set(running.filter { UsagePrefs.shows($0, in: defaults) })
        guard wanted != active else {
            update()
            return
        }
        let started = wanted.subtracting(active)
        let stopped = active.subtracting(wanted)
        active = wanted
        for agent in started.union(stopped) { generations[agent, default: 0] &+= 1 }
        for agent in stopped { end(agent) }
        for agent in started { begin(agent) }
        update()
    }

    private func begin(_ agent: UsageAgent) {
        switch agent {
        case .claude:
            claudeEvent = keptClaude()
            let watcher = FolderWatcher(url: claudeFolder, debounce: 1) { [weak self] in self?.readClaude() }
            claudeWatcher = watcher
            watcher.start()
        case .chatGPT:
            let watcher = FolderWatcher(url: URL(fileURLWithPath: codexHome, isDirectory: true), debounce: 2) { [weak self] in
                self?.readChatGPT()
            }
            codexWatcher = watcher
            watcher.start()
        case .gemini:
            // Figures read before Show usage limits was last turned off stay, so that
            // turning it on again doesn't wait a minute to show them as they were.
            if geminiReading == nil { geminiReading = keptGemini() }
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard app?.bundleIdentifier == GeminiHostApp.antigravity else { return }
                    let launched = note.name == NSWorkspace.didLaunchApplicationNotification
                    MainActor.assumeIsolated {
                        if launched { self?.antigravityOpened() } else { self?.antigravityClosed() }
                    }
                })
            }
            refreshGemini()
        }
    }

    private func end(_ agent: UsageAgent) {
        switch agent {
        case .claude:
            claudeWatcher?.stop()
            claudeWatcher = nil
            claudeStamp = nil
            claudeHistory = nil
            claudeEvent = nil
            claudeLimitHit = nil
            claudeRefreshing?.cancel()
            claudeRefreshing = nil
        case .chatGPT:
            codexWatcher?.stop()
            codexWatcher = nil
            chatGPTReading = nil
            chatGPTCache = ChatGPTUsage.Cache()
            chatGPTSignature = []
            readingChatGPT = false
            readChatGPTAgain = false
        case .gemini:
            // The reading, what came of it and when it was asked for stay in memory, so
            // starting again keeps to once a minute and shows them as they were; what
            // shows is only what `active` lets through (`update`).
            for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            workspaceObservers = []
            geminiKnown = nil
            readingGemini = false
        }
    }

    // MARK: Claude

    /// Reads the Claude app's history off the main thread, if the file has changed.
    private func readClaude() {
        guard active.contains(.claude) else { return }
        let url = claudeFolder.appendingPathComponent(ClaudeUsage.fileName)
        let generation = generations[.claude]
        let known = claudeStamp
        DispatchQueue.global(qos: .utility).async {
            // Read again only once the file has changed; a link is not followed.
            let stamp = FileStamp.read(url)
            let history: ClaudeUsage.History?
            if let stamp {
                history = stamp == known ? nil : ClaudeUsage.readHistory(url)
            } else {
                history = FileStamp.isThere(url) ? .unknownFormat : .missing
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.generations[.claude] == generation, self.active.contains(.claude) else { return }
                    self.claudeStamp = stamp
                    guard let history, history != self.claudeHistory else { return }
                    self.claudeHistory = history
                    self.update()
                }
            }
        }
    }

    /// Quick Ask's run of Claude, or a refresh, said what its limits are: kept, for the
    /// next launch to start from.
    func received(_ event: ClaudeUsage.LimitEvent) {
        guard active.contains(.claude) else { return }
        // A run of Claude needs the tool and a token, so what stopped a refresh is gone.
        if case .cannot? = claudeRefreshNote { claudeRefreshNote = nil }
        if let known = claudeEvent, known.at > event.at { return }
        claudeEvent = event
        if let data = try? JSONEncoder().encode(ClaudeUsage.Kept(event)) {
            defaults.set(data, forKey: UsagePrefs.claudeKept)
        }
        update()
    }

    /// What Quick Ask or a refresh last said, as kept.
    private func keptClaude() -> ClaudeUsage.LimitEvent? {
        guard let data = defaults.data(forKey: UsagePrefs.claudeKept) else { return nil }
        return (try? JSONDecoder().decode(ClaudeUsage.Kept.self, from: data))?.event
    }

    /// The tile or the Claude Code page is about to show Claude's limits: they are asked
    /// for afresh if they have grown old and a refresh is allowed.
    func claudeWillShow() {
        refreshClaude()
    }

    /// When the newest of Claude's figures was true, the app's sample or a run's.
    var claudeNewest: Date? {
        [claudeHistory?.reading?.measured, claudeEvent?.at].compactMap { $0 }.max()
    }

    /// When Claude's limits were last refreshed, as kept.
    var claudeRefreshed: Date? { defaults.object(forKey: UsagePrefs.claudeRefreshed) as? Date }

    /// Why Claude's limits would not be refreshed now; `nil` where a refresh is due. The
    /// cheap reasons first, the token's presence (but never the token) last.
    func claudeRefreshSkip() -> ClaudeUsageRefresh.Skip? {
        guard UsagePrefs.refreshesClaude(in: defaults) else { return .off }
        guard active.contains(.claude) else { return .notShown }
        guard claudeHistory != nil else { return .notReadYet }
        guard claudeRefreshing == nil else { return .underWay }
        let now = clock()
        if let newest = claudeNewest, now.timeIntervalSince(newest) <= ClaudeUsageRefresh.oldAfter { return .fresh }
        if let asked = claudeRefreshed, now >= asked, now.timeIntervalSince(asked) < ClaudeUsageRefresh.interval {
            return .tooSoon
        }
        if saving() { return .saving }
        if claudeAccess.lowPower() { return .lowPower }
        if claudeAccess.asking() { return .asking }
        guard claudeAccess.setup.binary() != nil else { return .notInstalled }
        guard claudeAccess.setup.tokens.hasToken else { return .noToken }
        return nil
    }

    /// Refreshes Claude's limits where they are due: checks the Mac is online off the
    /// main thread, notes the time, and makes the request, whose figures are taken as
    /// Quick Ask's are. A refresh that can't be made for want of the tool or a token is
    /// said in Settings, until the tool or the token is there; nothing else that holds one
    /// back is.
    private func refreshClaude() {
        if case .cannot(let cause)? = claudeRefreshNote, !claudeLacks(cause) { claudeRefreshNote = nil }
        if let skip = claudeRefreshSkip() {
            if skip == .notInstalled || skip == .noToken, claudeRefreshNote != .cannot(skip) {
                claudeRefreshNote = .cannot(skip)
            }
            return
        }
        let generation = generations[.claude]
        let access = claudeAccess
        claudeRefreshing = Task { [weak self] in
            let offline = access.offline
            let isOffline = await Task.detached(priority: .utility) { offline() }.value
            guard let self, self.generations[.claude] == generation else { return }
            guard !isOffline, !access.asking(), let binary = access.setup.binary(), let token = access.setup.tokens.token() else {
                self.claudeRefreshing = nil
                return
            }
            self.defaults.set(self.clock(), forKey: UsagePrefs.claudeRefreshed)
            let outcome = await ClaudeUsageRefresh.run(ClaudeUsageRefresh.launch(binary, token: token, system: access))
            guard self.generations[.claude] == generation else { return }
            self.claudeRefreshing = nil
            let now = self.clock()
            self.claudeRefreshNote = .done(now, outcome)
            if case .read(var event) = outcome {
                event.at = now
                self.received(event)
            }
        }
    }

    /// Whether the tool or the token, as `cause` says, is still missing: the token's
    /// presence alone is looked at, never the token.
    private func claudeLacks(_ cause: ClaudeUsageRefresh.Skip) -> Bool {
        switch cause {
        case .notInstalled: claudeAccess.setup.binary() == nil
        case .noToken: !claudeAccess.setup.tokens.hasToken
        default: false
        }
    }

    /// Claude Code's StopFailure hook said a turn was turned away at the limit.
    func claudeLimitReached() {
        guard active.contains(.claude) else { return }
        claudeLimitHit = clock()
        update()
    }

    // MARK: ChatGPT

    /// The ChatGPT hooks' sessions as last read: the rollouts they name are read again
    /// once any of them has moved on.
    func chatGPTSessions(_ records: [ChatGPTSessionRecord]) {
        let signature = records.map { "\($0.transcriptPath)|\($0.codexHome)|\($0.updated.timeIntervalSince1970)" }.sorted()
        guard signature != chatGPTSignature else { return }
        chatGPTSignature = signature
        chatGPTTranscripts = records.map(\.transcriptPath).filter { !$0.isEmpty }
        chatGPTHomes = records.map(\.codexHome).filter { !$0.isEmpty }
        readChatGPT()
    }

    /// Reads the rollouts off the main thread. A read asked for while one is under way
    /// follows it, once.
    private func readChatGPT() {
        guard active.contains(.chatGPT) else { return }
        guard !readingChatGPT else {
            readChatGPTAgain = true
            return
        }
        readingChatGPT = true
        let generation = generations[.chatGPT]
        let homes = [codexHome] + chatGPTHomes
        let transcripts = chatGPTTranscripts
        let cache = chatGPTCache
        DispatchQueue.global(qos: .utility).async {
            let (reading, cache) = ChatGPTUsage.read(homes: homes, transcripts: transcripts, cache: cache)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.generations[.chatGPT] == generation, self.active.contains(.chatGPT) else { return }
                    self.readingChatGPT = false
                    self.chatGPTCache = cache
                    if reading != self.chatGPTReading {
                        self.chatGPTReading = reading
                        self.update()
                    }
                    if self.readChatGPTAgain {
                        self.readChatGPTAgain = false
                        self.readChatGPT()
                    }
                }
            }
        }
    }

    // MARK: Gemini

    /// The tile, the Gemini page or its usage line is about to show: Gemini's quota is
    /// asked for again, if a read is due.
    func willShow() {
        refreshGemini()
    }

    /// Antigravity's hook told of an agent at work, which uses the quota.
    func geminiEvent() {
        refreshGemini()
    }

    func antigravityOpened() {
        antigravityOpen = true
        refreshGemini()
    }

    /// Antigravity has quit: its last figures stay, dimmed, and nothing is asked until it
    /// opens again.
    func antigravityClosed() {
        guard active.contains(.gemini) else { return }
        antigravityOpen = false
        keepGemini()
        update()
    }

    /// Antigravity isn't open: the last figures are kept, dimmed, until it is.
    private func keepGemini() {
        geminiKnown = nil
        if var reading = geminiReading, !reading.isKept {
            reading.isKept = true
            geminiReading = reading
        }
    }

    /// Asks Antigravity for Gemini's quota off the main thread, while its limits show,
    /// Antigravity is open and no read is under way, at most once a minute (every five
    /// while the island saves energy).
    private func refreshGemini() {
        guard active.contains(.gemini), !readingGemini else { return }
        let apps = antigravity.running()
        if antigravityOpen != !apps.isEmpty { antigravityOpen = !apps.isEmpty }
        guard !apps.isEmpty else {
            // Quit unseen, while the limits weren't shown.
            if geminiReading?.isKept == false {
                keepGemini()
                update()
            }
            return
        }
        let now = clock()
        let interval = saving() ? Self.geminiSavingInterval : Self.geminiInterval
        if let asked = geminiAsked, now.timeIntervalSince(asked) < interval, now >= asked { return }
        geminiAsked = now
        readingGemini = true
        let generation = generations[.gemini]
        let known = geminiKnown
        let read = antigravity.read
        DispatchQueue.global(qos: .utility).async {
            let outcome = read(apps, known)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.generations[.gemini] == generation, self.active.contains(.gemini) else { return }
                    self.readingGemini = false
                    self.received(outcome)
                }
            }
        }
    }

    /// What a read came to. Anything but a reading shows nothing new.
    private func received(_ outcome: GeminiUsage.Outcome) {
        switch outcome {
        case .read(var reading, let known):
            geminiSource = .read(reading.measured)
            geminiFailing = false
            if let data = try? JSONEncoder().encode(GeminiUsage.Kept(reading)) {
                defaults.set(data, forKey: UsagePrefs.geminiKept)
            }
            // Antigravity quit while it was asked: what it said shows as kept.
            if antigravity.running().isEmpty {
                antigravityOpen = false
                reading.isKept = true
            } else {
                geminiKnown = known
            }
            geminiReading = reading
        case .noServer:
            geminiKnown = nil
            geminiFailing = true
        case .failed:
            geminiKnown = nil
            geminiFailing = true
            geminiSource = .failed(clock())
        }
        update()
    }

    /// The figures last read, as kept, dimmed.
    private func keptGemini() -> UsageReading? {
        guard let data = defaults.data(forKey: UsagePrefs.geminiKept),
              var reading = (try? JSONDecoder().decode(GeminiUsage.Kept.self, from: data))?.reading
        else { return nil }
        reading.isKept = true
        return reading
    }

    /// When the reading was last true, kept or read, for Settings.
    var geminiMeasured: Date? { geminiReading?.measured }

    /// Asks again once a limit's reset has passed since the reading, the one thing the
    /// clock alone tells of Gemini's quota.
    private func refreshGeminiAfterReset() {
        guard let reading = geminiReading, !reading.isKept else { return }
        let now = clock()
        if reading.windows.contains(where: { $0.resets.map { $0 > reading.measured && $0 <= now } ?? false }) {
            refreshGemini()
        }
    }

    // MARK: What shows

    /// The agent's reading as of now, while its limits are shown; `nil` with none.
    func status(_ agent: UsageAgent) -> UsageStatus? {
        readings[agent]?.status(at: now)
    }

    /// What the agent's compact island shows of its limits.
    func compact(_ agent: UsageAgent) -> CompactUsage {
        guard let status = status(agent) else { return CompactUsage() }
        return CompactUsage(status: status, ring: UsagePrefs.ring(agent, in: defaults))
    }

    /// Works out the readings again as of now, warns of what has newly filled, and sets
    /// the tile and the timer to match.
    private func update() {
        now = clock()
        var next: [UsageAgent: UsageReading] = [:]
        if active.contains(.claude) {
            next[.claude] = ClaudeUsage.reading(history: claudeHistory?.reading, event: claudeEvent, limitHit: claudeLimitHit,
                                                now: now)
        }
        if active.contains(.chatGPT) { next[.chatGPT] = chatGPTReading }
        if active.contains(.gemini), var reading = geminiReading {
            // Reads failing since, figures as old as a Claude reading that is dimmed are
            // dimmed too, and warn or ring no more.
            if geminiFailing, now.timeIntervalSince(reading.measured) > UsageStatus.staleAfter { reading.isKept = true }
            next[.gemini] = reading
        }
        if next != readings { readings = next }
        warn()
        syncTile()
        schedule()
        announce()
    }

    /// Puts up what has newly filled, as one banner: Show in Islet keeps to a pace a
    /// person can read, and of several asked for at once, would show the newest alone.
    private func warn() {
        let before = alerts
        var due: [UsageAlerts.Alert] = []
        for agent in UsageAgent.allCases {
            guard let status = status(agent) else { continue }
            due += alerts.due(status, warns: UsagePrefs.warns(agent, in: defaults))
        }
        if let banner = banner(for: due) { present(banner) }
        if alerts != before, let data = try? JSONEncoder().encode(alerts) {
            defaults.set(data, forKey: UsagePrefs.said)
        }
    }

    /// The banner for `alerts`, `nil` for none: a card, so the whole of it fits. The
    /// limit comes first, then the fullest, whose title it takes; the rest follow its
    /// reset in the subtitle, its own agent's first, "Weekly limit at 80%". Warnings give
    /// way to a Focus asking for quiet, the limit does not. A click opens the first's
    /// agent's page, or the home page and its tile where the activity is not showing.
    func banner(for alerts: [UsageAlerts.Alert]) -> CustomBanner? {
        let ranked = alerts.sorted { $0.rank > $1.rank }
        guard let alert = ranked.first else { return nil }
        let isLimit = alert.kind == .limit
        let rest = ranked.dropFirst()
        let others = rest.filter { $0.agent == alert.agent } + rest.filter { $0.agent != alert.agent }
        let subtitle = ([alert.subtitle(now: now)] + others.map { $0.mention(beside: alert) })
            .compactMap { $0 }.joined(separator: " · ")
        var banner = CustomBanner(
            title: alert.title, subtitle: subtitle.isEmpty ? nil : subtitle,
            symbol: isLimit ? "gauge.with.dots.needle.100percent" : "gauge.with.dots.needle.67percent",
            tint: .named(isLimit ? .red : .orange), duration: CustomBanner.defaultDuration(for: .card),
            style: .card, sound: nil, interruption: isLimit ? .active : .passive,
            activityID: alert.agent.activityID
        )
        banner.page = alert.agent.activityID
        return banner
    }

    /// The tile's share of the row: three columns, Gemini's beside Claude's and
    /// ChatGPT's, need two-thirds as much again for their names and figures to read whole
    /// where the row is narrowest.
    static func tileWeight(columns: Int) -> CGFloat { columns >= 3 ? 2.5 : 1.5 }

    private func syncTile() {
        guard publishesTile else { return }
        let wanted = !readings.isEmpty
        let weight = Self.tileWeight(columns: readings.count)
        if wanted, !tileShown || weight != tileWeight {
            ActivityCenter.shared.setHomeWidget(HomeWidget(
                id: Self.tileID, order: Self.tileOrder, weight: weight, view: AnyView(UsageHomeTile(center: self))
            ))
        } else if !wanted, tileShown {
            ActivityCenter.shared.removeHomeWidget(id: Self.tileID)
        }
        tileShown = wanted
        tileWeight = wanted ? weight : 0
    }

    /// Tells the activities when what their compact islands show has changed, or a
    /// reading has come or gone, which their pages' heights follow.
    private func announce() {
        var current: [UsageAgent: CompactUsage] = [:]
        for agent in UsageAgent.allCases { current[agent] = compact(agent) }
        let lines = Set(readings.keys)
        guard current != published || lines != publishedLines else { return }
        published = current
        publishedLines = lines
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: The clock

    /// The next moment the clock alone changes what shows: a window reaching its reset,
    /// or its whole length where none is known, a limit with no reset lapsing, a reading
    /// or one of its figures growing old enough to say so.
    func nextChange() -> Date? {
        var moments: [Date] = []
        for reading in readings.values {
            for window in reading.status(at: now).windows {
                moments += [window.lapses, window.measured.addingTimeInterval(UsageStatus.staleAfter)]
            }
            moments.append(reading.measured.addingTimeInterval(UsageStatus.ageShownAfter))
            if let since = reading.limitSince { moments.append(since.addingTimeInterval(UsageStatus.limitHold)) }
        }
        return moments.filter { $0 > now }.min()
    }

    /// One timer, for the next change, on the wall clock so that it comes on time after
    /// the Mac has slept.
    private func schedule() {
        let due = nextChange()
        guard due != timerDue else { return }
        timer?.cancel()
        timer = nil
        timerDue = due
        guard let due else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.timerDue = nil
                self.update()
                self.refreshGeminiAfterReset()
            }
        }
        timer = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(1, due.timeIntervalSince(now) + 1), execute: work)
    }

    #if DEBUG
    /// For the harness: Claude's reading as the centre makes it from the app's history
    /// and a run's figures, and what Settings says of refreshing.
    func showClaude(history: ClaudeUsage.History?, event: ClaudeUsage.LimitEvent?, note: ClaudeUsageRefresh.Note? = nil) {
        now = clock()
        claudeHistory = history
        claudeEvent = event
        claudeRefreshNote = note
        var next = readings
        next[.claude] = ClaudeUsage.reading(history: history?.reading, event: event, limitHit: nil, now: now)
        readings = next
        publishedLines = []
        announce()
    }

    /// For the harness: a reading in place of the files', and for Claude, the history
    /// Settings says it came from.
    func show(_ reading: UsageReading?, for agent: UsageAgent) {
        now = clock()
        var next = readings
        next[agent] = reading
        readings = next
        publishedLines = []
        if agent == .claude {
            claudeHistory = reading.map { .read(ClaudeUsage.HistoryReading(measured: $0.measured, organisation: nil, windows: $0.windows, samples: 1)) }
        }
        if agent == .gemini {
            geminiReading = reading
            geminiSource = reading.map { .read($0.measured) } ?? .notRead
            antigravityOpen = !(reading?.isKept ?? false)
        }
        announce()
    }
    #endif
}

/// What an agent's compact island shows of its limits: a ring round its mark from 80%,
/// and at the limit, when it lifts in place of the turn's time, whether or not the ring
/// shows. A dimmed figure fills no ring; a limit shows as the page does.
struct CompactUsage: Equatable {
    /// How full the fullest window is, 0 to 1, while the ring shows.
    var ring: Double?
    /// At the limit.
    var atLimit = false
    var resets: Date?

    /// The level the ring starts at.
    static let ringFrom: Double = 80

    init() {}

    init(status: UsageStatus, ring showsRing: Bool) {
        atLimit = status.showsLimit
        resets = atLimit ? status.limitResets?.date : nil
        if showsRing, atLimit || status.level >= Self.ringFrom {
            ring = atLimit ? 1 : status.level / 100
        }
    }
}
