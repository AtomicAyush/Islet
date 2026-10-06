import AppKit

/// How macOS is set to save screenshots, from the Screenshot app's Options (⇧⌘5),
/// which it keeps in the `com.apple.screencapture` domain. They are read whenever they
/// are needed; the floating thumbnail's is the only one ever written, and only while
/// Show screenshots here at once is on (`FloatingThumbnail`).
struct ScreenshotPreferences: Equatable {
    /// Where screenshots are saved: the Desktop unless another folder is chosen.
    var folder: URL
    /// Whether they are saved as files at all, rather than put on the clipboard or
    /// handed straight to Mail, Messages or Preview.
    var savesFiles: Bool
    /// Whether macOS shows its floating thumbnail first, which holds the file back
    /// until the thumbnail goes, about five seconds later.
    var showsThumbnail: Bool

    static var desktop: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    static func read() -> ScreenshotPreferences {
        read(from: .system)
    }

    static func read(from store: ScreenshotSettingsStore) -> ScreenshotPreferences {
        store.synchronize()
        return make(location: store.value("location") as? String, target: store.value("target") as? String,
                    showThumbnail: store.value(ScreenshotSettingsStore.thumbnailKey))
    }

    /// The settings from their stored values; missing ones read as macOS's defaults.
    static func make(location: String?, target: String?, showThumbnail: Any?) -> ScreenshotPreferences {
        var folder = desktop
        if let location, !location.isEmpty {
            let path = (location as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            // macOS saves to the Desktop when the chosen folder is not there.
            if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                folder = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        let savesFiles = target.map { $0.isEmpty || $0 == "file" } ?? true
        let showsThumbnail = ScreenshotSettingsStore.flag(showThumbnail) ?? true
        return ScreenshotPreferences(folder: folder.standardizedFileURL, savesFiles: savesFiles, showsThumbnail: showsThumbnail)
    }
}

/// Notices screenshots as macOS saves them into its screenshot folder, from the moment
/// it starts: never one that was there before.
///
/// Spotlight says first: a live query for files tagged `kMDItemIsScreenCapture` made
/// since the watcher started, across the home folder, so a screenshot saved after the
/// folder has been changed in the Screenshot app's Options is still heard of, and the
/// folder is looked up again. Only screenshots in the screenshot folder count; a copy of
/// one elsewhere, or dragged out of the island, does not. Where Spotlight is off or slow
/// to index, the folder itself is watched (`FolderWatcher`): a new picture in it is
/// checked for the tag macOS writes on every screenshot, and again a moment later if it
/// does not have it yet. Whichever hears first shows it; the other is ignored.
///
/// The Screenshot app's settings are read, and its folder opened, off the main thread:
/// the folder may be one macOS asks the person about before Islet may look inside
/// (the Desktop, or one in Documents), and the asking holds up whoever looked.
///
/// A screenshot copied to the clipboard (⌃ held down) makes no file, and is not seen.
@MainActor
final class ScreenshotWatcher {
    var onScreenshot: (Screenshot) -> Void = { _ in }

    private(set) var isRunning = false
    private(set) var preferences: ScreenshotPreferences?

    /// Where the Spotlight query looks.
    enum Spotlight {
        /// Not at all: the folder is only watched.
        case off
        /// Across the home folder, and the screenshot folder where it is outside it.
        case home
        /// In the screenshot folder alone.
        case folder
    }

    /// Called off the main thread.
    private let readPreferences: () -> ScreenshotPreferences
    private let spotlight: Spotlight
    /// How long after a new picture turns up the tag is looked for again.
    private let recheckDelays: [TimeInterval]
    private var startedAt = Date()
    private var query: NSMetadataQuery?
    private var queryObservers: [NSObjectProtocol] = []
    private var folderWatcher: FolderWatcher?
    /// Names in the folder when it was last listed, so what is new can be told; `nil`
    /// until it has first been listed.
    private var knownNames: Set<String>?
    /// Screenshots shown or being read, by path, and by `ScreenshotFiles.identity`.
    private var seenPaths: Set<String> = []
    private var seenIdentities: Set<String> = []
    private var generation = 0

    /// Tests give their own preferences, and keep Spotlight to their own folder.
    init(
        preferences: @escaping () -> ScreenshotPreferences = ScreenshotPreferences.read,
        spotlight: Spotlight = .home,
        recheckDelays: [TimeInterval] = [0.5, 1.5, 3]
    ) {
        readPreferences = preferences
        self.spotlight = spotlight
        self.recheckDelays = recheckDelays
    }

    /// How the folder watch is going, for Settings and tests.
    var folderState: FolderWatcher.State? { folderWatcher?.state }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startedAt = Date()
        generation &+= 1
        read { [weak self] preferences in
            guard let self else { return }
            self.preferences = preferences
            self.watch(preferences.folder)
            if self.spotlight != .off { self.startQuery() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        stopQuery()
        folderWatcher?.stop()
        folderWatcher = nil
        knownNames = nil
        seenPaths.removeAll()
        seenIdentities.removeAll()
    }

    /// Reads the settings again, off the main thread, and follows the folder if it has
    /// changed; `then` says whether it had.
    func refresh(then done: (@MainActor (Bool) -> Void)? = nil) {
        guard isRunning else { return }
        read { [weak self] fresh in
            guard let self else { return }
            let moved = self.follow(fresh)
            done?(moved)
        }
    }

    /// Takes settings read elsewhere (by Settings, off the main thread), and follows the
    /// folder if it has changed. Returns whether it had. The same folder is tried again
    /// if it could not be opened: access may just have been given.
    @discardableResult
    func follow(_ fresh: ScreenshotPreferences) -> Bool {
        guard isRunning, preferences != nil else { return false }
        let moved = fresh.folder.resolvingSymlinksInPath().path != preferences?.folder.resolvingSymlinksInPath().path
        preferences = fresh
        guard moved else {
            folderWatcher?.retry()
            return false
        }
        watch(fresh.folder)
        // A folder outside the home folder is a scope of the query's own.
        if spotlight != .off {
            stopQuery()
            startQuery()
        }
        return true
    }

    private func read(then use: @escaping @MainActor (ScreenshotPreferences) -> Void) {
        let generation = generation
        let readPreferences = readPreferences
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let preferences = readPreferences()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.generation == generation else { return }
                    use(preferences)
                }
            }
        }
    }

    // MARK: The folder

    /// Watches the folder, which lists it once it is open: the first listing is what
    /// was there already, and each after it says what is new.
    private func watch(_ folder: URL) {
        folderWatcher?.stop()
        knownNames = nil
        let watcher = FolderWatcher(url: folder, debounce: 0.1) { [weak self] in self?.folderChanged() }
        folderWatcher = watcher
        watcher.start()
    }

    private func list(_ folder: URL, then handle: @escaping @MainActor (Set<String>) -> Void) {
        let generation = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.isRunning, self.generation == generation,
                          self.folderWatcher?.url.path == folder.path
                    else { return }
                    handle(names)
                }
            }
        }
    }

    private func folderChanged() {
        guard let folder = folderWatcher?.url else { return }
        list(folder) { [weak self] names in
            guard let self else { return }
            guard let knownNames else {
                self.knownNames = names
                return
            }
            let added = names.subtracting(knownNames)
            self.knownNames = names
            for name in added where !name.hasPrefix(".") {
                let url = folder.appendingPathComponent(name)
                guard ScreenshotFiles.isPicture(url), isNew(url) else { continue }
                check(url)
            }
        }
    }

    /// Made since the watcher started (less a second for the clock), so an old
    /// screenshot moved into the folder is not taken for a new one.
    private func isNew(_ url: URL) -> Bool {
        guard let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return false }
        return created >= startedAt.addingTimeInterval(-1)
    }

    /// Takes the picture if it has the screenshot tag; otherwise looks again at each of
    /// `recheckDelays` after it turned up, since macOS tags a screenshot a moment after
    /// saving it.
    private func check(_ url: URL, attempt: Int = 0) {
        guard isRunning, !seenPaths.contains(url.path), FileManager.default.fileExists(atPath: url.path) else { return }
        if ScreenshotFiles.isScreenCapture(url) {
            consider(url)
            return
        }
        guard recheckDelays.indices.contains(attempt) else { return }
        let wait = recheckDelays[attempt] - (attempt > 0 ? recheckDelays[attempt - 1] : 0)
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, wait)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.check(url, attempt: attempt + 1)
            }
        }
    }

    // MARK: Spotlight

    private func startQuery() {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "%K == 1 AND %K >= %@",
            "kMDItemIsScreenCapture", "kMDItemContentCreationDate", startedAt.addingTimeInterval(-1) as NSDate
        )
        var scopes: [Any] = spotlight == .home ? [NSMetadataQueryUserHomeScope] : []
        if let folder = preferences?.folder,
           spotlight == .folder || !folder.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/") {
            scopes.append(folder)
        }
        query.searchScopes = scopes
        query.notificationBatchingInterval = 0.1
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            queryObservers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.received(note) }
            })
        }
        self.query = query
        if !query.start() {
            self.query = nil
            queryObservers.forEach(center.removeObserver)
            queryObservers.removeAll()
        }
    }

    private func stopQuery() {
        query?.stop()
        query = nil
        queryObservers.forEach(NotificationCenter.default.removeObserver)
        queryObservers.removeAll()
    }

    /// The paths of the items a query notification is about: every result once it has
    /// gathered, the ones added or changed after.
    private func received(_ note: Notification) {
        guard let query, note.object as? NSMetadataQuery === query else { return }
        var items: [NSMetadataItem] = []
        if note.name == .NSMetadataQueryDidFinishGathering {
            query.disableUpdates()
            items = (0..<query.resultCount).compactMap { query.result(at: $0) as? NSMetadataItem }
            query.enableUpdates()
        } else {
            for key in [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey] {
                items += (note.userInfo?[key] as? [NSMetadataItem]) ?? []
            }
        }
        found(items.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String })
    }

    private func found(_ paths: [String]) {
        guard isRunning else { return }
        var elsewhere: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard !seenPaths.contains(url.standardizedFileURL.path) else { continue }
            if isInFolder(url) {
                consider(url)
            } else {
                elsewhere.append(url)
            }
        }
        // Elsewhere: the screenshot folder may have been changed since it was read.
        guard !elsewhere.isEmpty else { return }
        refresh { [weak self] moved in
            guard let self, moved else { return }
            for url in elsewhere where self.isInFolder(url) { self.consider(url) }
        }
    }

    /// Whether the file is directly in the screenshot folder, however either path is
    /// spelled (through a symbolic link, or `/private`).
    private func isInFolder(_ url: URL) -> Bool {
        guard let folder = preferences?.folder else { return false }
        return url.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path
    }

    // MARK: Showing

    private func consider(_ url: URL) {
        let url = url.standardizedFileURL
        guard isRunning, !url.lastPathComponent.hasPrefix("."), seenPaths.insert(url.path).inserted else { return }
        if let identity = ScreenshotFiles.identity(of: url) {
            guard seenIdentities.insert(identity).inserted else { return }
        }
        let generation = generation
        let place = FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
        Task { [weak self] in
            guard let shot = await ScreenshotFiles.load(url, place: place) else { return }
            guard let self, self.isRunning, self.generation == generation else { return }
            self.onScreenshot(shot)
        }
    }
}
