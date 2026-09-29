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
}

/// Follows the folder the hook writes a file per session into, reading it off the main
/// thread whenever a file is written, moved in or deleted (`FolderWatcher`); and between
/// times as `ChatGPTLiveness.watch` asks, for what only the rollouts, the processes and
/// the clock say: every few seconds while a session shown is under way, or has agents at
/// work; once a minute while a quiet session might yet carry on.
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
    /// The last look at each rollout, by path, so an unchanged one is not read again.
    private var rollouts: [String: (probe: ChatGPTRolloutProbe, size: Int64)] = [:]
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
        rollouts = [:]
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
        let known = rollouts
        DispatchQueue.global(qos: .utility).async {
            let (snapshot, rollouts) = Self.read(directory, now: date, known: known)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.isRunning, self.generation == generation else { return }
                    self.isReading = false
                    self.rollouts = rollouts
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

    /// Every session file in `directory` that reads, less those a day old; whether Codex
    /// is still running for those that could be shown; and a look at the rollouts of
    /// those under way. Hidden files (the hook's locks, marks and log) are passed over,
    /// but for the log's date, which counts as heard from: a chat's end deletes its file.
    /// Called off the main thread.
    nonisolated static func read(
        _ directory: URL, now: Date, known: [String: (probe: ChatGPTRolloutProbe, size: Int64)]
    ) -> (ChatGPTSessionSnapshot, [String: (probe: ChatGPTRolloutProbe, size: Int64)]) {
        var snapshot = ChatGPTSessionSnapshot()
        var looked: [String: (probe: ChatGPTRolloutProbe, size: Int64)] = [:]
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
            guard record.state != .idle || !record.runningAgents.isEmpty else { continue }
            if let running = ChatGPTLiveness.isRunning(record) { snapshot.processes[record.id] = running }
            guard snapshot.processes[record.id] != false, record.state != .idle,
                  let look = ChatGPTRollout.probe(path: record.transcriptPath, known: known[record.transcriptPath])
            else { continue }
            snapshot.rollouts[record.id] = look.probe
            looked[record.transcriptPath] = look
        }
        let log = directory.appendingPathComponent(".hook-log.jsonl")
        if let logged = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            snapshot.lastHeard = max(snapshot.lastHeard ?? logged, logged)
        }
        snapshot.records.sort { $0.id < $1.id }
        return (snapshot, looked)
    }
}
