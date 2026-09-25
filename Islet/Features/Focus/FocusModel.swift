import AppKit
import Observation

/// Whether Islet can see Focus at all.
enum FocusAccess: Equatable {
    /// Not looked yet.
    case unknown
    case granted
    /// The database is there but macOS will not open it to Islet.
    case needsFullDiskAccess
    /// There is no database where Islet knows to look.
    case unavailable
}

/// Which Focus is on, kept current by watching the Focus database. It knows nothing
/// of the island: it reads, and says when the Focus changed.
///
/// The files are watched while the model runs, and read again on wake, and every half
/// minute: a schedule or a timed Focus can end by the clock alone, and a grant of Full
/// Disk Access comes with no notification. Reads happen off the main thread; only a
/// change in what they resolve to is published, so the daemon rewriting its metrics
/// beside them goes unnoticed.
@MainActor
@Observable
final class FocusModel {
    /// A change of Focus, from one resolved state to another.
    struct Change: Equatable {
        var from: FocusState
        var to: FocusState
    }

    private(set) var access = FocusAccess.unknown
    /// The Focus as the database has it; off while it cannot be read.
    private(set) var state = FocusState.off
    /// A sample standing in for the real state, while a preview runs.
    private(set) var preview: FocusState?

    /// What to show: a preview, or the real state once there is one to show.
    var shown: FocusState? {
        preview ?? (access == .granted ? state : nil)
    }

    /// Called after anything above changes. `change` is set when a different Focus
    /// (or none) took over — but not for the first reading, which only says how things
    /// already were, and never for a preview.
    @ObservationIgnored var onChange: (_ change: Change?) -> Void = { _ in }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let queue = DispatchQueue(label: "Islet.Focus", qos: .utility)
    @ObservationIgnored private var watcher: FocusDatabaseWatcher?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// Bumped on every start and stop, so a reading already on its way from an
    /// earlier run is recognised and dropped.
    @ObservationIgnored private var generation = 0
    /// Whether `state` has been read since access was last granted.
    @ObservationIgnored private var hasBaseline = false

    static let recheckInterval: TimeInterval = 30

    init(directory: URL = FocusDatabase.defaultDirectory) {
        self.directory = directory
    }

    var isRunning: Bool { watcher != nil }

    func start(debounce: TimeInterval = 0.25) {
        guard watcher == nil else { return }
        generation &+= 1
        hasBaseline = false
        let generation = generation
        let watcher = FocusDatabaseWatcher(directory: directory, queue: queue, debounce: debounce) { [weak self, directory] in
            // Already on the reading queue.
            let reading = FocusDatabase.read(directory: directory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(reading, generation: generation) }
            }
        }
        self.watcher = watcher
        watcher.start()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.recheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 5
        self.timer = timer
        refresh()
    }

    /// Stops watching and forgets what was read, and any preview — which may be running
    /// while the model is not.
    func stop() {
        previewTask?.cancel()
        previewTask = nil
        let hadPreview = preview != nil
        preview = nil
        guard let watcher else {
            if hadPreview { onChange(nil) }
            return
        }
        generation &+= 1
        watcher.stop()
        self.watcher = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        hasBaseline = false
        access = .unknown
        state = .off
        onChange(nil)
    }

    /// Reads the database again now. Also re-opens the watch if it was lost (the folder
    /// replaced) or never opened (no Full Disk Access at the time).
    func refresh() {
        guard let watcher else { return }
        let generation = generation
        let directory = directory
        queue.async { [weak self] in
            watcher.armIfNeeded()
            let reading = FocusDatabase.read(directory: directory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(reading, generation: generation) }
            }
        }
    }

    /// Shows `sample` in place of the real state for eight seconds, reading and
    /// changing nothing.
    func showPreview(_ sample: FocusState) {
        previewTask?.cancel()
        preview = sample
        onChange(nil)
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            preview = nil
            onChange(nil)
        }
    }

    private func apply(_ reading: FocusDatabase.Reading, generation: Int) {
        guard generation == self.generation else { return }
        let before = (access, state)
        var change: Change?

        switch reading {
        case .unavailable, .needsFullDiskAccess:
            access = reading == .unavailable ? .unavailable : .needsFullDiskAccess
            state = .off
            hasBaseline = false
        case .unreadable:
            // Keep what was read last; the next write will be whole.
            grantAccess()
        case .state(let new):
            grantAccess()
            // Only a different Focus (or none) is news: a timed Focus's end moving, or
            // the daemon rewriting what it already had, is not.
            if hasBaseline, new.mode?.identifier != state.mode?.identifier {
                change = Change(from: state, to: new)
            }
            state = new
            hasBaseline = true
        }

        if before.0 != access || before.1 != state { onChange(change) }
    }

    /// The database could be opened. After a spell without access (or without the
    /// folder), the watch may be on nothing, or on a folder since replaced: open it
    /// afresh.
    private func grantAccess() {
        guard access != .granted else { return }
        if access != .unknown { watcher?.rearm() }
        access = .granted
    }
}

/// Watches the Focus database's folder, and the two files in it, and says when any of
/// them may have changed, once they have been still for a moment.
///
/// The daemon replaces its files whole, which changes the folder; the files are
/// watched too in case it ever writes one in place. Events arrive in bursts (the
/// assertions and the metrics beside them are written together), so the callback
/// waits until none has come for `debounce` seconds. If the folder itself goes away
/// or is replaced, the watch is re-opened a moment later.
///
/// Everything happens on `queue`, the one the database is read on.
final class FocusDatabaseWatcher: @unchecked Sendable {
    private let directory: URL
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onChange: () -> Void

    // Only touched on `queue`.
    private var isOn = false
    private var folderSource: DispatchSourceFileSystemObject?
    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    /// `onChange` is called on `queue`.
    init(directory: URL, queue: DispatchQueue, debounce: TimeInterval, onChange: @escaping () -> Void) {
        self.directory = directory
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        queue.async {
            self.isOn = true
            self.armIfNeeded()
        }
    }

    func stop() {
        queue.async {
            self.isOn = false
            self.disarm()
            self.pending?.cancel()
            self.pending = nil
        }
    }

    /// Opens the watch afresh: after access was granted, when the folder may be a
    /// different one than the watch was opened on.
    func rearm() {
        queue.async {
            self.disarm()
            self.armIfNeeded()
        }
    }

    /// Opens the watch if it is not open. Call on `queue`.
    func armIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isOn, folderSource == nil else { return }
        folderSource = watch(directory.path, events: [.write, .delete, .rename, .revoke]) { [weak self] events in
            self?.folderChanged(events)
        }
        if folderSource != nil { watchFiles() }
    }

    private func disarm() {
        folderSource?.cancel()
        folderSource = nil
        fileSources.forEach { $0.cancel() }
        fileSources.removeAll()
    }

    /// The files are opened again whenever the folder changes: a file replaced whole is
    /// a new file, and the old watch would be on the one that was replaced.
    private func watchFiles() {
        fileSources.forEach { $0.cancel() }
        fileSources = [FocusDatabase.assertionsFile, FocusDatabase.configurationsFile].compactMap { name in
            watch(directory.appendingPathComponent(name).path, events: [.write, .extend, .delete, .rename]) { [weak self] events in
                guard let self else { return }
                if !events.isDisjoint(with: [.delete, .rename]) { watchFiles() }
                changed()
            }
        }
    }

    private func folderChanged(_ events: DispatchSource.FileSystemEvent) {
        if events.isDisjoint(with: [.delete, .rename, .revoke]) {
            watchFiles()
        } else {
            // The folder went, or moved: watch whatever is at its path shortly, and
            // read it once watched. If nothing is there yet, the model's periodic
            // re-read tries again.
            disarm()
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                armIfNeeded()
                if folderSource != nil { changed() }
            }
        }
        changed()
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, isOn else { return }
            pending = nil
            onChange()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func watch(
        _ path: String,
        events: DispatchSource.FileSystemEvent,
        handler: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: queue)
        source.setEventHandler { [weak source] in
            guard let source, !source.isCancelled else { return }
            handler(source.data)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
