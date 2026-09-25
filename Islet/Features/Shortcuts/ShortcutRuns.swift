import Darwin
import Foundation
import Observation

/// One run of a shortcut, as the island shows it.
struct ShortcutRun: Identifiable, Equatable {
    enum Origin: Equatable {
        /// Started by Islet, from the home tile or a URL: Islet can stop it, and shows
        /// what it gives back.
        case islet
        /// Started anywhere else, with the database's word for where.
        case elsewhere(source: String?)
        /// A preview's stand-in: nothing runs.
        case sample
    }

    enum Phase: Equatable {
        case running
        case succeeded
        /// `nil` when all that is known is that it did not succeed (a run started
        /// elsewhere, whose record does not tell failing from being cancelled).
        case failed(ShortcutRunFailure?)
        /// Stopped from Islet.
        case stopped
        /// Its end was never recorded: the runner went away without saying. It folds
        /// away without a verdict.
        case vanished
    }

    let id: String
    var shortcut: ShortcutInfo
    let startedAt: Date
    let origin: Origin
    var phase = Phase.running

    /// Only a run Islet started can be stopped: stopping the tool it started stops the
    /// shortcut, and there is no supported way to stop anyone else's.
    var canStop: Bool {
        guard phase == .running else { return false }
        if case .elsewhere = origin { return false }
        return true
    }
}

/// The runs the island is showing: those still going, and the last one to end, for a
/// moment, so its tick or cross can be seen before the activity folds away.
///
/// The island shows one run, the latest; the others are counted. A run that ends while
/// a newer one is still going ends quietly, since the island is not showing it.
@MainActor
@Observable
final class ShortcutRuns {
    /// Oldest first.
    private(set) var running: [ShortcutRun] = []
    /// The run that ended last, while its outcome shows.
    private(set) var settled: ShortcutRun?

    /// How long an outcome shows before the activity folds away.
    static let settleDuration: TimeInterval = 1.2

    /// Called after anything above changes.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    /// The run the island shows: the latest to start, unless a run that started later
    /// still has just ended.
    var displayed: ShortcutRun? {
        if let settled, settled.startedAt >= (running.last?.startedAt ?? .distantPast) { return settled }
        return running.last ?? settled
    }

    var count: Int { running.count }
    var isActive: Bool { !running.isEmpty || settled != nil }
    var hasSamples: Bool { (running + [settled].compactMap { $0 }).contains { $0.origin == .sample } }

    func run(id: String) -> ShortcutRun? {
        running.first { $0.id == id } ?? (settled?.id == id ? settled : nil)
    }

    /// Where a run of `shortcut` is up to: running, or just ended.
    func phase(of shortcut: ShortcutInfo) -> ShortcutRun.Phase? {
        if running.contains(where: { $0.shortcut.id == shortcut.id }) { return .running }
        return settled?.shortcut.id == shortcut.id ? settled?.phase : nil
    }

    func begin(_ run: ShortcutRun) {
        guard !running.contains(where: { $0.id == run.id }) else { return }
        var run = run
        run.phase = .running
        running.append(run)
        running.sort { $0.startedAt < $1.startedAt }
        onChange()
    }

    /// Ends a run. Its outcome shows for `settleDuration` if the island is showing it,
    /// unless it `vanished`. Returns whether the run was still going.
    @discardableResult
    func finish(id: String, phase: ShortcutRun.Phase) -> Bool {
        guard let index = running.firstIndex(where: { $0.id == id }) else { return false }
        var run = running.remove(at: index)
        run.phase = phase
        let isShown = run.startedAt >= (running.last?.startedAt ?? .distantPast)
        if phase != .vanished, isShown {
            settled = run
            settleTask?.cancel()
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.settleDuration))
                guard let self, !Task.isCancelled else { return }
                settled = nil
                onChange()
            }
        }
        onChange()
        return true
    }

    /// Drops runs without showing how they ended: a setting turned off, or the feature.
    func removeAll(where shouldRemove: (ShortcutRun) -> Bool) {
        let before = (running.count, settled)
        running.removeAll(where: shouldRemove)
        if let settled, shouldRemove(settled) {
            settleTask?.cancel()
            self.settled = nil
        }
        if before.0 != running.count || before.1 != settled { onChange() }
    }
}

/// Notices runs started outside Islet — from the Shortcuts app, the menu bar,
/// Spotlight, Siri, an automation, the command line — from their records in the
/// Shortcuts database.
///
/// Every run of a shortcut writes a record as it starts and gives it an outcome as it
/// ends. The daemon announces each save, naming the records it touched, which brings a
/// start here within a few tens of milliseconds; the database's files changing brings
/// the same records a moment later, and would still if the announcement ever stopped.
/// Records are handled once each, whichever way they arrive. Islet's own runs are told
/// apart by `ShortcutLaunches`, and left alone.
///
/// A run whose runner is killed never gets an outcome, so while any run is open the
/// monitor checks every few seconds that a shortcut runner is still alive, and gives up
/// on runs once none has been for two checks, or after ten minutes whatever happens.
@MainActor
final class ShortcutRunMonitor {
    /// A run has started: its record, still without an outcome.
    var onStart: (ShortcutRunEvent) -> Void = { _ in }
    /// A run has ended; `nil` when its end was never recorded.
    var onEnd: (_ identifier: String, _ state: ShortcutRunEvent.State?) -> Void = { _, _ in }

    /// A record left open this long belongs to a run long dead.
    static let longest: TimeInterval = 10 * 60
    /// A record first seen already ended is still shown, briefly, if it is this recent:
    /// a quick run the announcement missed.
    static let freshness: TimeInterval = 10
    static let runnerCheckInterval: TimeInterval = 5

    private enum Known {
        case ignored
        case open(ShortcutRunEvent)
        case closed
    }

    private let directory: URL
    private let isRunnerAlive: @Sendable () -> Bool
    private let isIsletRun: (ShortcutRunEvent) -> Bool
    private let queue = DispatchQueue(label: "Islet.Shortcuts.Runs", qos: .utility)

    private var known: [String: (state: Known, seen: Date)] = [:]
    /// The newest record seen; `nil` until the first look, so nothing written before
    /// the monitor started is taken for a new run.
    private var latestKey: Int64?
    private var generation = 0
    private(set) var isRunning = false
    private var runnerTimer: Timer?
    private var runnerMissing = 0

    init(
        directory: URL = ShortcutsDatabase.defaultDirectory,
        isRunnerAlive: @escaping @Sendable () -> Bool = { ShortcutRunMonitor.isRunnerAlive() },
        isIsletRun: @escaping (ShortcutRunEvent) -> Bool = { ShortcutRunMonitor.isIsletRun($0) }
    ) {
        self.directory = directory
        self.isRunnerAlive = isRunnerAlive
        self.isIsletRun = isIsletRun
    }

    var openRuns: [ShortcutRunEvent] {
        known.values.compactMap { entry in
            if case .open(let event) = entry.state { return event }
            return nil
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        latestKey = nil
        known.removeAll()
        let generation = generation
        let directory = directory
        queue.async { [weak self] in
            let reading = ShortcutsDatabase.runEvents(after: nil, directory: directory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, case .value(let found) = reading else { return }
                    self.latestKey = max(self.latestKey ?? 0, found.latest)
                }
            }
        }
    }

    /// Stops watching, and forgets every run it knew of, saying nothing of them.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        known.removeAll()
        latestKey = nil
        runnerTimer?.invalidate()
        runnerTimer = nil
        runnerMissing = 0
    }

    /// The daemon announced a save touching these records.
    func saved(runEvents identifiers: [String]) {
        guard isRunning, !identifiers.isEmpty else { return }
        read { directory in
            ShortcutsDatabase.runEvents(identifiers: identifiers, directory: directory)
        } then: { [weak self] events in
            self?.ingest(events)
        }
    }

    /// The database's files changed: looks for records written since the last look,
    /// and for the end of the runs still open.
    func filesChanged() {
        guard isRunning, let key = latestKey else { return }
        let open = openRuns.map(\.identifier)
        read { directory -> ShortcutsDatabase.Reading<(events: [ShortcutRunEvent], latest: Int64)> in
            let fresh = ShortcutsDatabase.runEvents(after: key, directory: directory)
            guard case .value(var found) = fresh, !open.isEmpty else { return fresh }
            if case .value(let reread) = ShortcutsDatabase.runEvents(identifiers: open, directory: directory) {
                found.events += reread
            }
            return .value(found)
        } then: { [weak self] found in
            guard let self else { return }
            latestKey = max(latestKey ?? 0, found.latest)
            ingest(found.events)
        }
    }

    /// Takes in records, however they arrived: each new one starts a run, unless it is
    /// Islet's own, names no shortcut, or is too old to be running; each open one that
    /// now has an outcome ends one.
    func ingest(_ events: [ShortcutRunEvent], now: Date = Date()) {
        guard isRunning else { return }
        for event in events.sorted(by: { $0.key < $1.key }) {
            if let latest = latestKey, event.key > latest { latestKey = event.key }
            switch known[event.identifier]?.state {
            case .ignored?, .closed?:
                continue
            case .open?:
                guard event.state != .running else { continue }
                known[event.identifier] = (.closed, now)
                onEnd(event.identifier, event.state)
            case nil:
                let age = event.date.map { now.timeIntervalSince($0) } ?? 0
                if event.shortcut == nil || isIsletRun(event) {
                    known[event.identifier] = (.ignored, now)
                } else if event.state == .running {
                    guard age < Self.longest else {
                        known[event.identifier] = (.ignored, now)
                        continue
                    }
                    known[event.identifier] = (.open(event), now)
                    onStart(event)
                } else {
                    known[event.identifier] = (.closed, now)
                    if age < Self.freshness {
                        onStart(event)
                        onEnd(event.identifier, event.state)
                    }
                }
            }
        }
        forgetOld(now: now)
        scheduleRunnerChecks()
    }

    /// Gives up on open runs whose runner has gone, or that have gone on too long.
    /// Called every few seconds while any is open; `alive` is whether a shortcut runner
    /// was running just now.
    func checkRunner(alive: Bool, now: Date = Date()) {
        for event in openRuns where event.date.map({ now.timeIntervalSince($0) >= Self.longest }) ?? false {
            close(event.identifier, now: now)
        }
        runnerMissing = alive ? 0 : runnerMissing + 1
        // Twice, so a runner starting up or handing over between two runs is not
        // taken for none.
        guard runnerMissing >= 2 else { return }
        runnerMissing = 0
        let open = openRuns.map(\.identifier)
        guard !open.isEmpty else { return }
        // The outcome may have been written and the word of it missed: look once more.
        read { directory in
            ShortcutsDatabase.runEvents(identifiers: open, directory: directory)
        } then: { [weak self] events in
            guard let self else { return }
            ingest(events, now: now)
            for identifier in open { close(identifier, now: now) }
        } otherwise: { [weak self] in
            for identifier in open { self?.close(identifier, now: now) }
        }
    }

    private func close(_ identifier: String, now: Date) {
        guard case .open? = known[identifier]?.state else { return }
        known[identifier] = (.closed, now)
        onEnd(identifier, nil)
    }

    /// Records are remembered for a while after they close, so one that arrives again
    /// (by the other route) is not taken for a new run; open ones are kept.
    private func forgetOld(now: Date) {
        known = known.filter { _, entry in
            if case .open = entry.state { return true }
            return now.timeIntervalSince(entry.seen) < Self.longest
        }
    }

    private func scheduleRunnerChecks() {
        let hasOpen = !openRuns.isEmpty
        if hasOpen, runnerTimer == nil {
            runnerMissing = 0
            let isRunnerAlive = isRunnerAlive
            let timer = Timer.scheduledTimer(withTimeInterval: Self.runnerCheckInterval, repeats: true) { [weak self] _ in
                DispatchQueue.global(qos: .utility).async {
                    let alive = isRunnerAlive()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.isRunning else { return }
                            self.checkRunner(alive: alive)
                            self.scheduleRunnerChecks()
                        }
                    }
                }
            }
            timer.tolerance = 1
            runnerTimer = timer
        } else if !hasOpen, let timer = runnerTimer {
            timer.invalidate()
            runnerTimer = nil
        }
    }

    /// Reads on the monitor's queue and hands a value back on the main actor, unless
    /// the monitor was stopped or restarted meanwhile.
    private func read<Value: Sendable>(
        _ body: @escaping @Sendable (URL) -> ShortcutsDatabase.Reading<Value>,
        then use: @escaping @MainActor (Value) -> Void,
        otherwise fail: @escaping @MainActor () -> Void = {}
    ) {
        let generation = generation
        let directory = directory
        queue.async { [weak self] in
            let reading = body(directory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    if case .value(let value) = reading { use(value) } else { fail() }
                }
            }
        }
    }

    // MARK: Defaults

    /// Whether the run a record describes is one Islet started.
    nonisolated static func isIsletRun(_ event: ShortcutRunEvent) -> Bool {
        ShortcutLaunches.shared.claim(
            identifier: event.shortcut?.identifier, name: event.shortcut?.name, source: event.source, date: event.date
        )
    }

    /// Whether any of the person's shortcut runners is running: every run of a shortcut
    /// happens in one, started for it. Reading the process list takes a fraction of a
    /// millisecond.
    nonisolated static func isRunnerAlive() -> Bool {
        runningProcessNames().contains("BackgroundShortcutRunner")
    }

    nonisolated static func runningProcessNames() -> Set<String> {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        var names = Set<String>()
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(Int(max(0, count))) where pid > 0 {
            // Fails for other users' processes, which are not the person's runners.
            if proc_name(pid, &name, UInt32(name.count)) > 0 { names.insert(String(cString: name)) }
        }
        return names
    }
}
