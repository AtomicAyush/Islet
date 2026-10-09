import Foundation

/// What the monitor keeps between reads, so that what has not changed is not read again:
/// the last read of Antigravity's list of conversations, and of each task.md, by path.
struct GeminiMonitorCache: Sendable {
    var summaries: GeminiData.Look?
    var tasks: [String: (stamp: GeminiData.Stamp, list: GeminiTaskList?)] = [:]
}

/// Follows the folder the hook writes a file per conversation into, reading it off the
/// main thread whenever a file is written, moved in or deleted (`FolderWatcher`); and
/// between times as `GeminiLiveness.watch` asks, for what only Antigravity's own files
/// and the clock say: every few seconds while a conversation is shown, once a minute
/// while a quiet one might yet carry on.
///
/// The folder is Islet's own, in Application Support, and is made if it is not there,
/// so it can be watched before the hook has ever run. Nothing else is written: without
/// the hook the folder stays empty, and nothing shows.
@MainActor
final class GeminiSessionMonitor {
    nonisolated static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Islet/Gemini/Sessions", isDirectory: true)
    }

    nonisolated static let defaultPollInterval: TimeInterval = 5
    nonisolated static let defaultSlowPollInterval: TimeInterval = 60

    let directory: URL
    /// The home folder whose `.gemini` is read; tests give their own.
    let home: URL
    var onChange: (GeminiSessionSnapshot) -> Void = { _ in }

    private let now: () -> Date
    private let pollInterval: TimeInterval
    private let slowPollInterval: TimeInterval
    private var watcher: FolderWatcher?
    private var poll: DispatchWorkItem?
    private(set) var isRunning = false
    private(set) var snapshot = GeminiSessionSnapshot()
    private var cache = GeminiMonitorCache()
    private var generation = 0
    private var isReading = false
    private var readAgain = false

    init(directory: URL = GeminiSessionMonitor.defaultDirectory,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         pollInterval: TimeInterval = GeminiSessionMonitor.defaultPollInterval,
         slowPollInterval: TimeInterval = GeminiSessionMonitor.defaultSlowPollInterval,
         now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.home = home
        self.pollInterval = pollInterval
        self.slowPollInterval = slowPollInterval
        self.now = now
    }

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
        isReading = false
        readAgain = false
        cache = GeminiMonitorCache()
        snapshot = GeminiSessionSnapshot()
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
        let home = home
        let date = now()
        let known = cache
        DispatchQueue.global(qos: .utility).async {
            let (snapshot, cache) = Self.read(directory, home: home, now: date, known: known)
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

    private func received(_ snapshot: GeminiSessionSnapshot, at date: Date) {
        self.snapshot = snapshot
        onChange(snapshot)
        poll?.cancel()
        poll = nil
        switch GeminiLiveness.watch(snapshot, now: date) {
        case .closely?: schedulePoll(after: pollInterval)
        case .loosely?: schedulePoll(after: slowPollInterval)
        case nil: break
        }
    }

    private func schedulePoll(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.poll = nil
                self.refresh()
            }
        }
        poll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Every conversation file in `directory` that reads, less those a day old; what
    /// Antigravity's list says of each not idle, or with a subagent not idle, and the
    /// task list of each of those. Hidden files (the hook's locks and log) are passed
    /// over, but for the log's date, which counts as heard from. Called off the main thread.
    nonisolated static func read(
        _ directory: URL, home: URL, now: Date, known: GeminiMonitorCache
    ) -> (GeminiSessionSnapshot, GeminiMonitorCache) {
        var snapshot = GeminiSessionSnapshot()
        var next = GeminiMonitorCache()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension == "json" {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate
            if let modified { snapshot.lastHeard = max(snapshot.lastHeard ?? modified, modified) }
            if let modified, now.timeIntervalSince(modified) > GeminiLiveness.forgottenAfter { continue }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let data = try? handle.read(upToCount: 256 * 1024)
            try? handle.close()
            guard let data, let record = try? JSONDecoder().decode(GeminiSessionRecord.self, from: data),
                  file.deletingPathExtension().lastPathComponent == record.id,
                  !GeminiLiveness.isForgotten(record, now: now)
            else { continue }
            snapshot.records.append(record)
        }
        let log = directory.appendingPathComponent(".hook-log.jsonl")
        if let logged = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            snapshot.lastHeard = max(snapshot.lastHeard ?? logged, logged)
        }
        snapshot.records.sort { $0.id < $1.id }

        // The conversations under way, and those that sent off a subagent under way,
        // which are listed for it.
        var asked = Set<String>()
        for record in snapshot.records where record.state != .idle {
            asked.insert(record.id)
            if !record.parent.isEmpty { asked.insert(record.parent) }
        }
        let live = snapshot.records.filter { asked.contains($0.id) }
        let look = GeminiData.summaries(folder: GeminiData.antigravityFolder(home: home), ids: Set(live.map(\.id)),
                                        known: known.summaries)
        next.summaries = look
        snapshot.summaries = look.summaries
        for record in live {
            let file = GeminiData.taskFile(for: record, home: home)
            let stamp = GeminiData.stamp(file)
            let list: GeminiTaskList?
            if let cached = known.tasks[file.path], cached.stamp == stamp {
                list = cached.list
            } else {
                list = stamp.file.isEmpty ? nil : GeminiData.tasks(file)
            }
            next.tasks[file.path] = (stamp, list)
            if let list { snapshot.tasks[record.id] = list }
        }
        return (snapshot, next)
    }
}
