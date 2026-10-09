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

    static func shows(_ agent: UsageAgent, in defaults: UserDefaults = .standard) -> Bool { flag(showKey(agent), defaults) }
    static func warns(_ agent: UsageAgent, in defaults: UserDefaults = .standard) -> Bool { flag(warnKey(agent), defaults) }
    static func ring(_ agent: UsageAgent, in defaults: UserDefaults = .standard) -> Bool { flag(ringKey(agent), defaults) }

    private static func flag(_ key: String, _ defaults: UserDefaults) -> Bool { defaults.object(forKey: key) as? Bool ?? true }

    /// The banners already put up, each window's until it resets (`UsageAlerts`).
    static let said = "usageLimits.said"
}

/// Claude's and ChatGPT's usage limits, for the island: read while the agent's activity
/// is on and Settings shows its limits, from files on this Mac alone (`ClaudeUsage`,
/// `ChatGPTUsage`), and only when they change. Nothing polls: the Claude app's folder
/// and Codex's are watched for entries changing (`FolderWatcher`), which the Claude app
/// writing its history and Codex updating a thread both do, and ChatGPT's hooks say when
/// a chat has moved on. One timer is kept, for the next moment the clock alone changes
/// what shows: a window's reset, or a Claude reading growing old.
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
    @ObservationIgnored private var claudeEvent: ClaudeUsage.LimitEvent?
    @ObservationIgnored private var claudeLimitHit: Date?
    @ObservationIgnored private var chatGPTReading: UsageReading?
    @ObservationIgnored private var chatGPTCache = ChatGPTUsage.Cache()
    @ObservationIgnored private var chatGPTHomes: [String] = []
    @ObservationIgnored private var chatGPTTranscripts: [String] = []
    @ObservationIgnored private var chatGPTSignature: [String] = []
    @ObservationIgnored private var readingChatGPT = false
    @ObservationIgnored private var readChatGPTAgain = false
    /// Bumped as each agent's reading starts or stops, so a read finishing after either
    /// is let go.
    @ObservationIgnored private var generations: [UsageAgent: Int] = [:]
    @ObservationIgnored private var alerts: UsageAlerts
    @ObservationIgnored private var timer: DispatchWorkItem?
    @ObservationIgnored private(set) var timerDue: Date?
    @ObservationIgnored private var tileShown = false
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
        publishesTile: Bool = true,
        present: @escaping @MainActor (CustomBanner) -> Void = { banner in
            _ = FeatureRegistry.shared.feature(BannerFeature.self)?.show(banner)
        }
    ) {
        self.defaults = defaults
        self.clock = clock
        self.claudeFolder = claudeFolder
        self.codexHome = codexHome
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
            let watcher = FolderWatcher(url: claudeFolder, debounce: 1) { [weak self] in self?.readClaude() }
            claudeWatcher = watcher
            watcher.start()
        case .chatGPT:
            let watcher = FolderWatcher(url: URL(fileURLWithPath: codexHome, isDirectory: true), debounce: 2) { [weak self] in
                self?.readChatGPT()
            }
            codexWatcher = watcher
            watcher.start()
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
        case .chatGPT:
            codexWatcher?.stop()
            codexWatcher = nil
            chatGPTReading = nil
            chatGPTCache = ChatGPTUsage.Cache()
            chatGPTSignature = []
            readingChatGPT = false
            readChatGPTAgain = false
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

    /// Quick Ask's run of Claude said what its limits are.
    func received(_ event: ClaudeUsage.LimitEvent) {
        guard active.contains(.claude) else { return }
        if let known = claudeEvent, known.at > event.at { return }
        claudeEvent = event
        update()
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

    private func syncTile() {
        guard publishesTile else { return }
        let wanted = !readings.isEmpty
        if wanted, !tileShown {
            ActivityCenter.shared.setHomeWidget(HomeWidget(
                id: Self.tileID, order: Self.tileOrder, weight: 1.5, view: AnyView(UsageHomeTile(center: self))
            ))
        } else if !wanted, tileShown {
            ActivityCenter.shared.removeHomeWidget(id: Self.tileID)
        }
        tileShown = wanted
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
            }
        }
        timer = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(1, due.timeIntervalSince(now) + 1), execute: work)
    }

    #if DEBUG
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
