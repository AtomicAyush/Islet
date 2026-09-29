import Foundation

/// The session files as last read, and what their transcripts say.
struct ClaudeSessionSnapshot: Equatable, Sendable {
    var records: [ClaudeSessionRecord] = []
    /// By session id, for sessions whose file says they are under way.
    var transcripts: [String: ClaudeTranscriptProbe] = [:]
    /// By session id, for sessions that could be shown and whose file names Claude
    /// Code's process: whether it is still running.
    var processes: [String: Bool] = [:]
    /// When any session's file was last written, idle ones and old ones included: when
    /// Islet last heard from the hook at all.
    var lastHeard: Date?
    /// By session id, then task id, for sessions that could be shown with workflows or
    /// agents at work: how far those have got, as their files say.
    var progress: [String: [String: ClaudeTaskProgress]] = [:]
    /// The sessions needing permission whose every request has been seen given, its
    /// command running (`ClaudeBashCommand`).
    var answered: Set<String> = []
}

/// What the monitor's last read found, so what has not changed is not read again.
struct ClaudeMonitorCache: Sendable {
    /// The last look at each transcript, by path.
    var transcripts: [String: (probe: ClaudeTranscriptProbe, size: Int64)] = [:]
    /// Where each file behind the background tasks' progress was read to.
    var progress = ClaudeProgressCache()
    /// The permissions asked whose commands have been seen running, by session id, agent,
    /// time asked and fingerprint: one seen once is answered, though its command has since
    /// finished and its PostToolUse is on its way.
    var answered: Set<String> = []
}

/// Follows the folder the hook writes a file per session into, reading it off the main
/// thread whenever a file is written, moved in or deleted (`FolderWatcher`); and between
/// times as `ClaudeLiveness.watch` asks, for what only the transcripts, Claude Code's
/// processes and the clock say: every few seconds while a session shown is working or
/// waiting on the person, or has workflows or agents at work whose progress is followed;
/// once a minute while only workflows show that cannot be followed, or a quiet session
/// might yet carry on.
///
/// The folder is Islet's own, in Application Support, and is made if it is not there,
/// so it can be watched before the hook has ever run. Nothing else is written: without
/// the hook the folder stays empty, and nothing shows.
@MainActor
final class ClaudeSessionMonitor {
    nonisolated static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Islet/Claude Code/Sessions", isDirectory: true)
    }

    /// How often the files and transcripts are read again while a session shown is
    /// under way.
    nonisolated static let defaultPollInterval: TimeInterval = 5
    /// How often they are read while only workflows show, or a session gone quiet is
    /// hidden.
    nonisolated static let defaultSlowPollInterval: TimeInterval = 60

    let directory: URL
    var onChange: (ClaudeSessionSnapshot) -> Void = { _ in }

    private let now: () -> Date
    private let pollInterval: TimeInterval
    private let slowPollInterval: TimeInterval
    private var watcher: FolderWatcher?
    private var poll: DispatchWorkItem?
    private(set) var isRunning = false
    private(set) var snapshot = ClaudeSessionSnapshot()
    /// The last look at each transcript, and at the files behind the background tasks'
    /// progress, so an unchanged one is not read again.
    private var cache = ClaudeMonitorCache()
    private var generation = 0
    private var isReading = false
    private var readAgain = false

    /// Tests give a folder and a clock of their own, and poll faster.
    init(directory: URL = ClaudeSessionMonitor.defaultDirectory,
         pollInterval: TimeInterval = ClaudeSessionMonitor.defaultPollInterval,
         slowPollInterval: TimeInterval = ClaudeSessionMonitor.defaultSlowPollInterval,
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
        cache = ClaudeMonitorCache()
        snapshot = ClaudeSessionSnapshot()
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
        let cache = cache
        DispatchQueue.global(qos: .utility).async {
            let (snapshot, cache) = Self.read(directory, now: date, cache: cache)
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

    private func received(_ snapshot: ClaudeSessionSnapshot, at date: Date) {
        self.snapshot = snapshot
        onChange(snapshot)
        poll?.cancel()
        poll = nil
        pollDelay = nil
        switch ClaudeLiveness.watch(snapshot, now: date) {
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

    /// Every session file in `directory` that reads, less those a day old; a look at the
    /// transcripts of those under way, and their agents'; whether Claude Code is still
    /// running for those that could be shown; how far the workflows and agents at work
    /// in those have got; and for those needing permission to run commands, whether
    /// Claude Code is running them. Called off the main thread.
    nonisolated static func read(
        _ directory: URL, now: Date, cache: ClaudeMonitorCache
    ) -> (ClaudeSessionSnapshot, ClaudeMonitorCache) {
        var snapshot = ClaudeSessionSnapshot()
        var nextCache = ClaudeMonitorCache()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified { snapshot.lastHeard = max(snapshot.lastHeard ?? modified, modified) }
            if let modified, now.timeIntervalSince(modified) > ClaudeLiveness.forgottenAfter { continue }
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(ClaudeSessionRecord.self, from: data),
                  !ClaudeLiveness.isForgotten(record, now: now)
            else { continue }
            snapshot.records.append(record)
            guard record.state != .idle || record.hasBackgroundWork else { continue }
            if let running = ClaudeProcess.isRunning(record) { snapshot.processes[record.id] = running }
            guard snapshot.processes[record.id] != false else { continue }
            if record.state == .needsPermission, record.pending.contains(where: { $0.tool == "Bash" }),
               snapshot.processes[record.id] == true, let pid = record.pid {
                let keys = record.pending.map { request in
                    "\(record.id) \(request.agentId) \(request.at.timeIntervalSince1970) \(request.command)"
                }
                let running = ClaudeBashCommand.running(record.pending, children: ClaudeProcess.children(of: pid))
                let seen = zip(keys, running).filter { key, running in running || cache.answered.contains(key) }.map(\.0)
                nextCache.answered.formUnion(seen)
                if seen.count == keys.count { snapshot.answered.insert(record.id) }
            }
            if record.hasBackgroundWork {
                let progress = ClaudeTaskProgressReader.read(record, cache: cache.progress, into: &nextCache.progress)
                if !progress.isEmpty { snapshot.progress[record.id] = progress }
            }
            guard record.state != .idle, !record.transcriptPath.isEmpty,
                  let look = ClaudeTranscript.probe(path: record.transcriptPath, known: cache.transcripts[record.transcriptPath])
            else { continue }
            var probe = look.probe
            probe.agentsModified = ClaudeTranscript.agentsModified(
                transcriptPath: record.transcriptPath, background: Set(record.runningAgents.map(\.id)))
            snapshot.transcripts[record.id] = probe
            nextCache.transcripts[record.transcriptPath] = look
        }
        snapshot.records.sort { $0.id < $1.id }
        return (snapshot, nextCache)
    }
}
