import AppKit
import Observation

/// Notices when something new is copied. macOS posts nothing when the pasteboard
/// changes, so this looks at its change count — a number that goes up with every copy,
/// not what was copied — twice a second, on a timer the system may put off a little to
/// batch it with other work, and says when the count has moved.
@MainActor
final class ClipboardWatcher {
    let pasteboard: NSPasteboard
    /// Called with the new count when it moves, and when the count was last seen
    /// still (system uptime): the copy was made between the two.
    var onChange: (_ count: Int, _ since: TimeInterval) -> Void = { _, _ in }

    static let interval: TimeInterval = 0.5
    static let tolerance: TimeInterval = 0.25

    private(set) var changeCount: Int
    /// When the count was last looked at, in system uptime.
    private(set) var lastLook: TimeInterval
    private var timer: Timer?

    var isRunning: Bool { timer != nil }

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        changeCount = pasteboard.changeCount
        lastLook = ProcessInfo.processInfo.systemUptime
    }

    /// Starts from the count as it stands: what is on the clipboard already was copied
    /// before, and is not read.
    func start() {
        guard timer == nil else { return }
        changeCount = pasteboard.changeCount
        lastLook = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = Self.tolerance
        // Common modes, so a copy made from a menu is noticed while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        let count = pasteboard.changeCount
        let since = lastLook
        lastLook = now
        guard count != changeCount else { return }
        changeCount = count
        onChange(count, since)
    }

    /// Islet wrote to the pasteboard itself (putting an item back): its own write is
    /// not news.
    func acknowledge(_ count: Int) {
        changeCount = count
        lastLook = ProcessInfo.processInfo.systemUptime
    }
}

/// The clipboard history as the island shows it: what was copied, read off the
/// pasteboard as it changes and kept by the rules in `ClipboardReader`, and put back
/// when an item is clicked. Previews show a made-up history in the real one's place.
@MainActor
@Observable
final class ClipboardModel {
    let history: ClipboardHistory
    /// A made-up history a preview shows in the real one's place. Clicking its items
    /// says "Copied" and copies nothing.
    private(set) var sample: ClipboardHistory?
    /// The item just put back on the clipboard, whose row says so for a moment.
    private(set) var justCopied: UUID?
    /// Whether macOS lets copies be read. Anything short of `.allowed` leaves them
    /// unread: the count is still watched, but nothing on the pasteboard is touched.
    private(set) var access: ClipboardAccess = .allowed
    /// Something was copied that the history would have kept, but could not be read
    /// for want of permission, which is when the home tile asks for it. A copy of
    /// nothing, one marked as not for keeping, or one a password manager made misses
    /// nothing.
    private(set) var missedCopy = false
    /// macOS's alert is up, from a click on Allow.
    private(set) var isAsking = false
    /// The type Allow reads for macOS's alert: the latest copy's, where it is one the
    /// history would keep. macOS asks only as something is read, so with none (nothing
    /// copied since Islet started, or the latest copy a password) Allow waits for a copy.
    private(set) var askType: NSPasteboard.PasteboardType?
    /// Allow read the copy, and macOS neither asked nor gave anything back.
    private(set) var askFailed = false

    /// Whether Allow can put up macOS's alert now.
    var canAsk: Bool { askType != nil }

    /// The history on screen: a preview's, or the real one.
    var shown: ClipboardHistory { sample ?? history }

    /// Whether the home tile asks for permission: a copy went unread, and a click can
    /// still do something about it. Turned down, it is left to the page and Settings
    /// to say so, rather than asked again at every copy.
    var wantsAccess: Bool {
        sample == nil && missedCopy && (access == .notAsked || access == .asks)
    }

    /// Called after every change to the history shown, to whether a sample is up, or
    /// to whether copies can be read.
    @ObservationIgnored var onChange: () -> Void = {}
    /// Called after an item is handed to another app (a link opened, files shown in
    /// Finder), so the island can get out of the way.
    @ObservationIgnored var onHandOff: () -> Void = {}

    @ObservationIgnored let watcher: ClipboardWatcher
    @ObservationIgnored private let archive: ClipboardArchive?
    /// Where pictures dragged out as files are written (`ClipboardDrag`).
    @ObservationIgnored let dragFiles: ClipboardDragFiles
    /// The app in front, taken as the source of a copy that names none. Only a test
    /// replaces it.
    @ObservationIgnored var frontmost: () -> ClipboardSource? = {
        ClipboardSource(NSWorkspace.shared.frontmostApplication)
    }
    /// Looks up whether copies may be read, never itself asking. Only a test replaces
    /// it.
    @ObservationIgnored var checkAccess: () -> ClipboardAccess = { .allowed }
    /// Apps brought to the front, oldest first, with when (system uptime): the one in
    /// front when the pasteboard was last looked at, and any since. A copy was made by
    /// one of them, and the one in front by the time the copy is noticed may already
    /// be the app it is to be pasted into. A copy made within a look of leaving a
    /// password manager is taken for the password manager's, which errs the safe way.
    @ObservationIgnored private var activations: [(bundleIdentifier: String?, at: TimeInterval)] = []
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// Pictures being made into kept copies, off the main thread.
    @ObservationIgnored private let pictures = DispatchQueue(label: "com.ayush.Islet.clipboard.pictures", qos: .utility)
    @ObservationIgnored private var copiedTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    /// The saved history is still to be read: at first, and after the feature stops.
    @ObservationIgnored private var needsLoad = true
    /// Which read of the saved history is under way, if one is; a stop drops it.
    @ObservationIgnored private var loading: Int?
    @ObservationIgnored private var loads = 0
    /// A write was put off until the saved history had been read.
    @ObservationIgnored private var saveWaitingForLoad = false
    /// What was last written, so a copy that changes nothing on disk (with only pinned
    /// items kept, most of them) writes nothing. `nil` until the first write.
    @ObservationIgnored private var lastSaved: [ClipboardArchive.Record]?
    /// The change count `askType` was judged at.
    @ObservationIgnored private var askCount = 0
    /// Allow's read came back with the copy, and macOS still reports its default: it
    /// let the read through without asking, so reads go through here, whatever the
    /// default is elsewhere. Dropped as soon as macOS reports anything else.
    @ObservationIgnored private var readsLetThrough = false

    /// `pasteboard` is the general one; tests pass a private one of their own, and
    /// folders of their own as `archive`'s and `dragFiles`'.
    init(
        pasteboard: NSPasteboard = .general, archive: ClipboardArchive? = .standard,
        dragFiles: ClipboardDragFiles = .shared, limit: Int = ClipboardPrefs.currentLimit
    ) {
        history = ClipboardHistory(limit: limit)
        watcher = ClipboardWatcher(pasteboard: pasteboard)
        self.archive = archive
        self.dragFiles = dragFiles
        checkAccess = { ClipboardAccess.of(pasteboard) }
        history.onChange = { [weak self] in
            self?.scheduleSave()
            self?.onChange()
        }
        watcher.onChange = { [weak self] _, since in self?.pasteboardChanged(since: since) }
    }

    // MARK: Running

    func start() {
        // Pictures left behind by a drag when Islet last quit.
        dragFiles.removeAll()
        watcher.start()
        // What is on the clipboard already is not asked with either: who copied it is
        // not known, so it may be a password.
        askType = nil
        askCount = watcher.changeCount
        refreshAccess()
        activations = [(frontmost()?.bundleIdentifier, watcher.lastLook)]
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let id = app?.bundleIdentifier
                MainActor.assumeIsolated { self?.noteActivation(id) }
            }
        }
        loadIfNeeded()
    }

    /// Stops watching, writes any change still waiting, and forgets what was kept
    /// only in memory: switched off, the feature keeps nothing Settings does not ask
    /// it to keep on disk. Switched on again, it reads that back.
    func stop() {
        watcher.stop()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        activations = []
        missedCopy = false
        askType = nil
        askFailed = false
        flush()
        loading = nil
        needsLoad = true
        saveWaitingForLoad = false
        history.forget()
        dragFiles.removeAll()
        justCopied = nil
        endSample()
    }

    // MARK: Copies

    private func pasteboardChanged(since: TimeInterval) {
        let front = frontmost()
        let inFront = appsInFront(since: since)
        // Only the app in front now is still needed, for the next copy.
        activations = [(front?.bundleIdentifier, watcher.lastLook)]
        refreshAccess()
        guard access == .allowed else {
            noteUnread(suspects: [front?.bundleIdentifier] + inFront)
            return
        }
        let generation = history.generation
        switch ClipboardReader.read(watcher.pasteboard, frontmost: front, alsoInFront: inFront) {
        case .content(let content, let source):
            history.record(content, source: source)
        case .picture(let data, let type, let source):
            let copiedAt = Date()
            pictures.async { [weak self] in
                let image = ClipboardImage.make(data: data, type: type)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.pictureMade(image, source: source, copiedAt: copiedAt, generation: generation)
                    }
                }
            }
        case .skipped:
            break
        }
    }

    private func pictureMade(_ image: ClipboardImage?, source: ClipboardSource?, copiedAt: Date, generation: Int) {
        guard let image, image.data.count <= ClipboardLimits.pictureBytes,
              generation == history.generation, watcher.isRunning
        else { return }
        history.record(.image(image), source: source, at: copiedAt)
    }

    /// An app came to the front. Those in front before the pasteboard was last looked
    /// at are forgotten, but for the latest of them, which was still in front then.
    func noteActivation(_ bundleIdentifier: String?) {
        guard watcher.isRunning else { return }
        let lastLook = watcher.lastLook
        if let latest = activations.lastIndex(where: { $0.at <= lastLook }), latest > 0 {
            activations.removeFirst(latest)
        }
        activations.append((bundleIdentifier, ProcessInfo.processInfo.systemUptime))
    }

    /// Every app in front at some moment since `since`: the one in front then, and any
    /// brought to the front after.
    private func appsInFront(since: TimeInterval) -> [String?] {
        let first = activations.lastIndex(where: { $0.at <= since }) ?? 0
        return activations[first...].map(\.bundleIdentifier)
    }

    // MARK: Permission

    /// A copy went unread for want of permission. Only its types are looked at, which
    /// macOS allows without asking, and the apps in front as it was made: from them,
    /// whether the history would have kept it, and so whether it was missed and is one
    /// Allow may read for macOS's alert.
    private func noteUnread(suspects: [String?]) {
        let fromPasswordManager = suspects.contains(where: ClipboardReader.isPasswordManager)
        let type = fromPasswordManager ? nil : ClipboardAccess.typeToAsk(watcher.pasteboard.types ?? [])
        askCount = watcher.changeCount
        let missed = missedCopy || type != nil
        let failed = askFailed && type == nil
        guard type != askType || missed != missedCopy || failed != askFailed else { return }
        askType = type
        missedCopy = missed
        askFailed = failed
        onChange()
    }

    /// Looks again at whether copies may be read: as the feature starts, at every copy,
    /// and as the page or Settings appear, since the answer changes in System Settings.
    func refreshAccess() {
        var now = checkAccess()
        if now != .notAsked {
            readsLetThrough = false
        } else if readsLetThrough {
            now = .allowed
        }
        guard now != access else { return }
        access = now
        if now == .allowed {
            missedCopy = false
            askFailed = false
        }
        onChange()
    }

    /// Allow, clicked. Never asked, it reads the latest copy for macOS's alert, off the
    /// main thread, since the read waits for the answer, and drops what comes back. It
    /// reads only a copy the history would have kept, and of it the least telling type
    /// (`ClipboardAccess.typeToAsk`); with no such copy, it waits for one. Asked before,
    /// or turned down, the answer is in System Settings, which it opens.
    func requestAccess() {
        refreshAccess()
        switch access {
        case .allowed:
            return
        case .asks, .denied:
            if let url = ClipboardAccess.settingsURL, NSWorkspace.shared.open(url) {
                onHandOff()
            }
        case .notAsked:
            guard !isAsking else { return }
            // A copy made since the last look is judged before anything is read.
            watcher.poll()
            let count = watcher.changeCount
            guard access == .notAsked, let type = askType, askCount == count else { return }
            isAsking = true
            nonisolated(unsafe) let pasteboard = watcher.pasteboard
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Only the copy judged fit to read: one made since is left for the
                // watcher to judge.
                let answer: AskAnswer
                if pasteboard.changeCount != count {
                    answer = .moved
                } else if let data = pasteboard.data(forType: type), !data.isEmpty {
                    answer = .read
                } else {
                    answer = .nothing
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.asked(answer, count: count) }
                }
            }
        }
    }

    private enum AskAnswer {
        /// The copy came back: macOS let it through, having asked or not.
        case read
        /// Nothing came back: turned down in the alert, or not let through at all.
        case nothing
        /// Something else was copied first, and nothing was read.
        case moved
    }

    /// Allow's read is over. macOS moves off its default the first time it asks, so
    /// still at the default, it did not ask: with the copy back, reads go through here;
    /// without, Allow says so and waits for another copy to try with.
    private func asked(_ answer: AskAnswer, count: Int) {
        isAsking = false
        refreshAccess()
        guard access == .notAsked else { return }
        switch answer {
        case .read:
            readsLetThrough = true
            refreshAccess()
        case .nothing:
            guard askCount == count else { return }
            askType = nil
            askFailed = true
            onChange()
        case .moved:
            break
        }
    }

    #if DEBUG
    /// Waits for pictures being made to arrive, for tests.
    func waitForPictures() {
        pictures.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    #endif

    // MARK: Actions

    /// Puts the item back on the clipboard, making it the latest thing copied, and
    /// says so on its row. A sample's item is only said to be copied. Of files, only
    /// those still there go back, and an item whose files have all gone is taken off
    /// the list instead; one with some gone stays as it was, since a disk that was
    /// ejected may come back.
    func copy(_ item: ClipboardItem) {
        if let sample {
            sample.touch(item.id)
            confirm(item.id)
            return
        }
        var content = item.content
        if case .files(let urls) = content {
            let present = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !present.isEmpty else {
                history.remove(item.id)
                return
            }
            content = .files(present)
        }
        // Anything copied since the last look goes in first, rather than be taken for
        // Islet's own write below.
        watcher.poll()
        guard ClipboardReader.write(content, to: watcher.pasteboard) else { return }
        watcher.acknowledge(watcher.pasteboard.changeCount)
        var id = item.id
        if history.item(id: id) != nil {
            history.touch(id)
        } else {
            // The copy just read in pushed it past the limit.
            id = history.record(item.content, source: item.source)
        }
        confirm(id)
    }

    func setPinned(_ item: ClipboardItem, _ pinned: Bool) {
        shown.setPinned(item.id, pinned)
    }

    func remove(_ item: ClipboardItem) {
        shown.remove(item.id)
    }

    /// Clears everything but pinned items, as the page's Clear button does.
    func clear() {
        shown.clear(keepingPinned: true)
    }

    /// Forgets everything, pinned items and what is on disk included.
    func forgetEverything() {
        history.clear(keepingPinned: false)
        pendingSave?.cancel()
        pendingSave = nil
        guard let archive else { return }
        lastSaved = []
        ClipboardArchive.queue.async { archive.delete() }
    }

    /// Opens a copied link. A sample's goes nowhere.
    func open(_ url: URL) {
        guard sample == nil, NSWorkspace.shared.open(url) else { return }
        onHandOff()
    }

    /// Shows copied files in Finder, those still there.
    func reveal(_ urls: [URL]) {
        guard sample == nil else { return }
        let present = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !present.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(present)
        onHandOff()
    }

    private func confirm(_ id: UUID) {
        justCopied = id
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.justCopied = nil
        }
    }

    // MARK: Samples

    /// Shows `items` in the real history's place until `endSample()`.
    func showSample(_ items: [ClipboardItem]) {
        let sample = ClipboardHistory(limit: ClipboardPrefs.limits.last ?? 50)
        sample.replace(with: items)
        sample.onChange = { [weak self] in self?.onChange() }
        self.sample = sample
        onChange()
    }

    func endSample() {
        guard sample != nil else { return }
        sample = nil
        if let id = justCopied, history.item(id: id) == nil { justCopied = nil }
        onChange()
    }

    // MARK: Saving

    /// Reads the saved history as the feature starts. Items copied before it has been
    /// read stay in front of the saved ones; after a clear meanwhile, it is not wanted.
    private func loadIfNeeded() {
        guard needsLoad, let archive else { return }
        needsLoad = false
        loads &+= 1
        let load = loads
        loading = load
        let generation = history.generation
        let keepingAll = ClipboardPrefs.keepsHistory
        ClipboardArchive.queue.async { [weak self] in
            let (items, droppedAny) = archive.read(keepingAll: keepingAll)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.loading == load else { return }
                    self.loading = nil
                    let isCurrent = generation == self.history.generation
                    if isCurrent { self.history.merge(saved: items) }
                    // Items gone or no longer to be kept, a clear, or a change made
                    // while reading: write the file again.
                    if droppedAny || !isCurrent || self.saveWaitingForLoad { self.scheduleSave() }
                    self.saveWaitingForLoad = false
                }
            }
        }
    }

    /// The Settings toggle changed: write what is now to be kept, which, turned off,
    /// leaves only the pinned items on disk. Stopped, nothing is written; the saved
    /// history is trimmed to the setting when it is next read.
    func keepingChanged() {
        save()
    }

    /// Several changes in a row (a burst of copies, removing items one by one) become
    /// one write.
    private func scheduleSave() {
        guard archive != nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func save(waiting: Bool = false) {
        pendingSave?.cancel()
        pendingSave = nil
        guard let archive else { return }
        // Stopped, the history in memory has been forgotten, and writing it out would
        // take the pinned items off disk with it.
        guard !needsLoad else { return }
        // Before the saved history is read, writing would lose it.
        guard loading == nil else {
            saveWaitingForLoad = true
            return
        }
        let entries = ClipboardArchive.entries(for: history.items, keepingAll: ClipboardPrefs.keepsHistory)
        let records = entries.map(\.record)
        guard records != lastSaved else { return }
        lastSaved = records
        if waiting {
            ClipboardArchive.queue.sync { archive.save(entries) }
        } else {
            ClipboardArchive.queue.async { archive.save(entries) }
        }
    }

    /// Writes any change still waiting, and waits for writes already under way, so
    /// nothing is lost when the feature stops or the app quits.
    func flush() {
        if pendingSave != nil {
            save(waiting: true)
        } else {
            ClipboardArchive.queue.sync {}
        }
    }
}
