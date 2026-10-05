import Foundation

/// The session files as last read, and what their rollouts say.
struct ChatGPTSessionSnapshot: Equatable, Sendable {
    var records: [ChatGPTSessionRecord] = []
    /// By session id, for sessions whose file says they are under way.
    var rollouts: [String: ChatGPTRolloutProbe] = [:]
    /// By session id, for sessions that could be shown and whose file names Codex's
    /// process: whether it is still running.
    var processes: [String: Bool] = [:]
    /// When any session's file was last written, idle ones and old ones included: when
    /// Islet last heard from the hook at all.
    var lastHeard: Date?
    /// By session id, for sessions with commands left running: those the rollout says
    /// have ended.
    var commandEnds: [String: Set<String>] = [:]
    /// The same: those whose call returned with them still running.
    var commandsRunning: [String: Set<String>] = [:]
    /// By session id: its thread's goal, and how many prompts wait in its queue, from
    /// Codex's own databases.
    var goals: [String: ChatGPTGoal] = [:]
    var queued: [String: Int] = [:]
}

/// What the monitor keeps between reads, so that what has not changed is not read again:
/// the last look at each rollout's end, how far each rollout's commands' ends were read,
/// and the last read of each folder of Codex's databases; each by its path.
struct ChatGPTMonitorCache: Sendable {
    var rollouts: [String: ChatGPTRolloutLook] = [:]
    var commands: [String: ChatGPTCommandEnds] = [:]
    var databases: [String: ChatGPTCodexData.Look] = [:]
}

/// The last look at a rollout's end, and its size then.
struct ChatGPTRolloutLook: Sendable {
    var probe: ChatGPTRolloutProbe
    var size: Int64
}

/// Follows the folder the hook writes a file per session into, reading it off the main
/// thread whenever a file is written, moved in or deleted (`FolderWatcher`); and between
/// times as `ChatGPTLiveness.watch` asks, for what only the rollouts, Codex's databases,
/// the processes and the clock say: every few seconds while a session is shown; once a
/// minute while a quiet session might yet carry on.
///
/// The folder is Islet's own, in Application Support, and is made if it is not there,
/// so it can be watched before the hook has ever run. Nothing else is written: without
/// the hook the folder stays empty, and nothing shows.
@MainActor
final class ChatGPTSessionMonitor {
    nonisolated static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Islet/ChatGPT/Sessions", isDirectory: true)
    }

    /// How often the files and rollouts are read again while a session shown is under
    /// way.
    nonisolated static let defaultPollInterval: TimeInterval = 5
    /// How often they are read while a session gone quiet is hidden.
    nonisolated static let defaultSlowPollInterval: TimeInterval = 60

    let directory: URL
    var onChange: (ChatGPTSessionSnapshot) -> Void = { _ in }

    private let now: () -> Date
    private let pollInterval: TimeInterval
    private let slowPollInterval: TimeInterval
    private var watcher: FolderWatcher?
    private var poll: DispatchWorkItem?
    private(set) var isRunning = false
    private(set) var snapshot = ChatGPTSessionSnapshot()
    /// What was read last, so what has not changed is not read again.
    private var cache = ChatGPTMonitorCache()
    private var generation = 0
    private var isReading = false
    private var readAgain = false

    /// Tests give a folder and a clock of their own, and poll faster.
    init(directory: URL = ChatGPTSessionMonitor.defaultDirectory,
         pollInterval: TimeInterval = ChatGPTSessionMonitor.defaultPollInterval,
         slowPollInterval: TimeInterval = ChatGPTSessionMonitor.defaultSlowPollInterval,
         now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.pollInterval = pollInterval
        self.slowPollInterval = slowPollInterval
        self.now = now
    }

    /// Whether the folder is being watched, for tests.
    var folderState: FolderWatcher.State? { watcher?.state }
    /// Whether the files are read again between changes to the folder, and how soon,
    /// for tests.
    var isPolling: Bool { poll != nil }
    private(set) var pollDelay: TimeInterval?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        let generation = generation
        let directory = directory
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.isRunning, self.generation == generation else { return }
                    let watcher = FolderWatcher(url: directory, debounce: 0.1) { [weak self] in self?.refresh() }
                    self.watcher = watcher
                    watcher.start()
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        watcher?.stop()
        watcher = nil
        poll?.cancel()
        poll = nil
        pollDelay = nil
        isReading = false
        readAgain = false
        cache = ChatGPTMonitorCache()
        snapshot = ChatGPTSessionSnapshot()
    }

    /// Reads the folder again, off the main thread. A read asked for while one is under
    /// way follows it, once.
    func refresh() {
        guard isRunning else { return }
        guard !isReading else {
            readAgain = true
            return
        }
        isReading = true
        let generation = generation
        let directory = directory
        let date = now()
        let known = cache
        DispatchQueue.global(qos: .utility).async {
            let (snapshot, cache) = Self.read(directory, now: date, known: known)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.isRunning, self.generation == generation else { return }
                    self.isReading = false
                    self.cache = cache
                    self.received(snapshot, at: date)
                    if self.readAgain {
                        self.readAgain = false
                        self.refresh()
                    }
                }
            }
        }
    }

    private func received(_ snapshot: ChatGPTSessionSnapshot, at date: Date) {
        self.snapshot = snapshot
        onChange(snapshot)
        poll?.cancel()
        poll = nil
        pollDelay = nil
        switch ChatGPTLiveness.watch(snapshot, now: date) {
        case .closely?: schedulePoll(after: pollInterval)
        case .loosely?: schedulePoll(after: slowPollInterval)
        case nil: break
        }
    }

    private func schedulePoll(after delay: TimeInterval) {
        pollDelay = delay
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.poll = nil
                self.pollDelay = nil
                self.refresh()
            }
        }
        poll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Every session file in `directory` that reads, less those a day old; their goals
    /// and queued prompts, from the databases in the folders the files name; whether
    /// Codex is still running for those that could be shown; and a look at the rollouts
    /// of those under way, and of those with commands left running. Hidden files (the
    /// hook's locks, marks and log) are passed over, but for the log's date, which counts
    /// as heard from: a chat's end deletes its file. Called off the main thread.
    nonisolated static func read(
        _ directory: URL, now: Date, known: ChatGPTMonitorCache
    ) -> (ChatGPTSessionSnapshot, ChatGPTMonitorCache) {
        var snapshot = ChatGPTSessionSnapshot()
        var next = ChatGPTMonitorCache()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified { snapshot.lastHeard = max(snapshot.lastHeard ?? modified, modified) }
            if let modified, now.timeIntervalSince(modified) > ChatGPTLiveness.forgottenAfter { continue }
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(ChatGPTSessionRecord.self, from: data),
                  !ChatGPTLiveness.isForgotten(record, now: now)
            else { continue }
            snapshot.records.append(record)
        }
        // The databases, a folder at a time, for every thread there; only a folder a
        // file names, never one assumed.
        let homes = Dictionary(grouping: snapshot.records.filter { !$0.codexHome.isEmpty }, by: \.codexHome)
        for (home, records) in homes {
            let look = ChatGPTCodexData.read(home: home, threads: Set(records.map(\.id)), known: known.databases[home])
            next.databases[home] = look
            snapshot.goals.merge(look.goals) { a, _ in a }
            snapshot.queued.merge(look.queued) { a, _ in a }
        }
        for record in snapshot.records {
            let path = record.transcriptPath
            // Followed for as long as the file lists commands, idle or not, so that one
            // seen to end is never taken as running again after a quiet spell.
            if !record.shells.isEmpty,
               let ends = ChatGPTRollout.commandEnds(path: path, known: known.commands[path],
                                                     calls: record.shells.map(\.id)) {
                next.commands[path] = ends
                snapshot.commandEnds[record.id] = Set(ends.ended)
                snapshot.commandsRunning[record.id] = Set(ends.running)
            }
            let goal = snapshot.goals[record.id]?.status == .active
            guard record.state != .idle || !record.runningAgents.isEmpty || goal else { continue }
            if let running = ChatGPTLiveness.isRunning(record) { snapshot.processes[record.id] = running }
            guard snapshot.processes[record.id] != false else { continue }
            let last = known.rollouts[path].map { (probe: $0.probe, size: $0.size) }
            guard record.state != .idle, let look = ChatGPTRollout.probe(path: path, known: last) else { continue }
            snapshot.rollouts[record.id] = look.probe
            next.rollouts[path] = ChatGPTRolloutLook(probe: look.probe, size: look.size)
        }
        let log = directory.appendingPathComponent(".hook-log.jsonl")
        if let logged = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            snapshot.lastHeard = max(snapshot.lastHeard ?? logged, logged)
        }
        snapshot.records.sort { $0.id < $1.id }
        return (snapshot, next)
    }
}
