import Foundation

/// Follows downloads into a set of folders: how each is going, and when one finishes.
/// Three signals, each the cheapest that answers its question:
///
/// - **Progress.** A browser publishes an `NSProgress` for the file it is downloading,
///   which is how Finder draws the bar under its icon, and any app may subscribe to a
///   folder's. Chrome and the other Chromium browsers publish one for the `.crdownload`,
///   with the speed and the time left; WebKit publishes one for each download it is
///   given a file for, and Safari's may be for the file inside its `.download` bundle,
///   which a subscription to the folder does not hear about (it hears only of items
///   directly in the folder), so each bundle gets a subscription of its own. Nothing is
///   polled to hear of a download starting, and a subscription made while one is under
///   way hears of it at once. A folder is subscribed to once it has been listed, which
///   is when macOS has let Islet see into it, so nothing in it is looked at before.
/// - **Partial files.** A download no progress is published for (Firefox's) is followed
///   by the size of its partial file. The folder is watched for entries coming and going
///   (`FolderWatcher`), which costs nothing while nothing changes.
/// - **Finished.** Browsers post `com.apple.DownloadFileFinished`, with the finished
///   file's path, for the Dock to bounce its Downloads stack. That says a download ended
///   well, and where the file is, even one too quick to have been seen under way.
///
/// Downloads under way are looked at twice a second, for the speed and the time left,
/// but only while one is moving. One that stops (paused in Chrome, waiting at the end
/// for "Keep" on a file Chrome warns about, a server gone quiet, or a partial file left
/// behind long ago) is set aside after a while: it leaves the island, nothing looks at
/// it, and it comes back the moment it moves again. A progress set aside is observed
/// for its count of bytes changing; a partial file is watched for the kernel's word
/// that it has been written to. Neither costs anything until it happens.
///
/// A download that ends any other way (cancelled, failed, given up) just goes.
@MainActor
final class DownloadMonitor {
    nonisolated static let finishedNotification = Notification.Name("com.apple.DownloadFileFinished")

    /// How often downloads under way are looked at; only while one is moving.
    var sampleInterval: TimeInterval = 0.5
    /// How long a new partial file waits for its browser's progress before it is shown
    /// by its size alone.
    var grace: TimeInterval = 1.5
    /// A partial file must grow within this long to count as a download under way: one
    /// that was there before Islet looked, or one that turned up since. A download
    /// starts writing the moment its first bytes arrive; a file that does not grow is
    /// one given up, or copied in. A progress that has not moved since it was heard of
    /// gets the longer time too.
    var leftoverTimeout: TimeInterval = 5
    var newFileTimeout: TimeInterval = 15
    /// A download that stops growing for this long has been paused, or given up. It is
    /// set aside, and comes back if it grows again.
    var stallTimeout: TimeInterval = 60
    /// How long a download that has ended waits for word that it finished, or for its
    /// file to turn up under its real name.
    var settleTimeout: TimeInterval = 2
    /// The span speed is measured over, where the browser does not say.
    var speedWindow: TimeInterval = 3

    /// The downloads under way, oldest first, whenever that changes.
    var onChange: ([DownloadItem]) -> Void = { _ in }
    /// A download finished, once per file.
    var onFinished: (FinishedDownload) -> Void = { _ in }

    private(set) var isRunning = false
    private(set) var folders: [URL] = []
    /// Whether downloads are being looked at on a timer, which is only while one is
    /// moving, has just stopped or has just ended: at rest, nothing runs.
    var isSampling: Bool { timer != nil }
    /// How many downloads are set aside for not moving, watched for moving again.
    var setAsideCount: Int { entries.filter(\.isParked).count + leftoverWatches.count }
    /// Leftover partial files watched for being written to at most, since each holds a
    /// file open; any more come back only when their folder next changes.
    static let maxLeftoverWatches = 32

    private let finishedNotification: Notification.Name
    private var finishedObserver: FinishedObserver?
    private var watchers: [String: FolderWatcher] = [:]
    /// Progress subscriptions, by the path of the folder or bundle they are for.
    private var subscriptions: [String: Any] = [:]
    /// Published progress, by the key its subscription gave it.
    private var progresses: [UUID: Progress] = [:]
    private var entries: [Entry] = []
    /// Partial files seen, by path.
    private var partials: [String: Partial] = [:]
    /// Partial files found not to be growing, by path, and the size they had.
    private var leftovers: [String: Int64] = [:]
    /// Leftover partial files watched for being written to, by path.
    private var leftoverWatches: [String: DispatchSourceFileSystemObject] = [:]
    /// Progress set aside for not moving, observed for moving again, by its key.
    private var stillObservations: [UUID: NSKeyValueObservation] = [:]
    /// Folders listed once already, so a partial file that turns up later is new.
    private var listedFolders: Set<String> = []
    private var endings: [Ending] = []
    private var recentFinishes: [(url: URL, at: Date)] = []
    private var announced: [String: Date] = [:]
    private var reported: [DownloadItem] = []
    private var timer: Timer?
    /// Bumped by `stop()`, so a folder listing still under way is not taken in after it.
    private var generation = 0

    /// `finishedNotification` is the name finished downloads are announced under; tests
    /// use one of their own, so nothing they post reaches the Dock.
    init(finishedNotification: Notification.Name = DownloadMonitor.finishedNotification) {
        self.finishedNotification = finishedNotification
    }

    // MARK: Starting and stopping

    func start(folders: [URL]) {
        if !isRunning {
            isRunning = true
            let observer = FinishedObserver { [weak self] path in self?.finished(path: path) }
            // AppKit holds distributed notifications back while an app is inactive, and an
            // agent app almost always is.
            DistributedNotificationCenter.default().addObserver(
                observer, selector: #selector(FinishedObserver.received(_:)), name: finishedNotification,
                object: nil, suspensionBehavior: .deliverImmediately
            )
            finishedObserver = observer
        }
        watch(folders)
    }

    /// Follows these folders from now on: new ones are subscribed to and listed, and ones
    /// no longer wanted are let go, with whatever was being followed in them.
    func watch(_ folders: [URL]) {
        guard isRunning else { return }
        let wanted = folders.map(\.standardizedFileURL)
        for folder in self.folders where !wanted.contains(where: { $0.path == folder.path }) {
            forget(folder)
        }
        for folder in wanted {
            if let watcher = watchers[folder.path] {
                // Settings asking again: a folder Islet was refused may be allowed now.
                watcher.retry()
            } else {
                follow(folder)
            }
        }
        self.folders = wanted
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        if let finishedObserver { DistributedNotificationCenter.default().removeObserver(finishedObserver) }
        finishedObserver = nil
        watchers.values.forEach { $0.stop() }
        watchers.removeAll()
        subscriptions.values.forEach(Progress.removeSubscriber)
        subscriptions.removeAll()
        progresses.removeAll()
        stillObservations.values.forEach { $0.invalidate() }
        stillObservations.removeAll()
        entries.removeAll()
        partials.removeAll()
        leftovers.removeAll()
        leftoverWatches.values.forEach { $0.cancel() }
        leftoverWatches.removeAll()
        listedFolders.removeAll()
        endings.removeAll()
        recentFinishes.removeAll()
        announced.removeAll()
        folders.removeAll()
        timer?.invalidate()
        timer = nil
        report()
    }

    /// Watches the folder, which lists it once it is open, and subscribes to it once
    /// listed (`listed`).
    private func follow(_ folder: URL) {
        let watcher = FolderWatcher(url: folder) { [weak self] in self?.list(folder) }
        watchers[folder.path] = watcher
        watcher.start()
    }

    private func forget(_ folder: URL) {
        watchers.removeValue(forKey: folder.path)?.stop()
        unsubscribe(from: folder.path)
        listedFolders.remove(folder.path)
        for (path, partial) in partials where partial.folder == folder.path {
            partials[path] = nil
            takeBack(path)
            if partial.isBundle { unsubscribe(from: path) }
        }
        entries.removeAll { $0.progressKey == nil && $0.location.deletingLastPathComponent().path == folder.path }
        report()
        stopTimerIfIdle()
    }

    // MARK: Progress

    private func subscribe(to url: URL) {
        guard subscriptions[url.path] == nil else { return }
        let owner = Owner(self)
        subscriptions[url.path] = Progress.addSubscriber(forFileURL: url) { progress in
            let key = UUID()
            Self.onMain { owner.monitor?.published(progress, key: key) }
            return { Self.onMain { owner.monitor?.unpublished(key: key) } }
        }
    }

    private func unsubscribe(from path: String) {
        guard let token = subscriptions.removeValue(forKey: path) else { return }
        Progress.removeSubscriber(token)
    }

    /// The file a published progress is downloading, or `nil` when it is some other
    /// file operation (Finder copying into the folder, Archive Utility unpacking).
    ///
    /// Read from the user info: across processes, the subscriber's copy has no
    /// `fileURL` or `fileOperationKind` of its own, only the entries behind them.
    nonisolated static func downloadURL(of progress: Progress) -> URL? {
        let info = progress.userInfo
        guard progress.kind == nil || progress.kind == .file,
              (info[.fileOperationKindKey] as? String) == Progress.FileOperationKind.downloading.rawValue,
              let url = info[.fileURLKey] as? URL, url.isFileURL
        else { return nil }
        return url.standardizedFileURL
    }

    private func published(_ progress: Progress, key: UUID) {
        guard isRunning, let url = Self.downloadURL(of: progress) else { return }
        progresses[key] = progress
        let location = DownloadNames.partialItem(containing: url) ?? url
        if let entry = entries.first(where: { DownloadNames.sameDownload($0.location, url) }) {
            // Followed already: by the partial file's size, which the progress now takes
            // over from, or by another progress (Safari's bundle's and the file's own),
            // in which case this one is let be.
            guard entry.progressKey == nil else { return }
            entry.progressKey = key
            entry.location = location
            entry.isShown = true
        } else {
            let now = Date()
            let entry = Entry(id: "progress." + key.uuidString, location: location, startedAt: now, isNew: true)
            entry.progressKey = key
            entry.isShown = true
            // Where it had got to when first heard of, which is not growth: a download
            // found paused is as still as one that has not started.
            entry.received = max(0, progress.completedUnitCount)
            entry.samples = [(now, entry.received)]
            entries.append(entry)
        }
        tick()
        ensureTimer()
    }

    private func unpublished(key: UUID) {
        stillObservations.removeValue(forKey: key)?.invalidate()
        guard let progress = progresses.removeValue(forKey: key),
              let entry = entries.first(where: { $0.progressKey == key })
        else { return }
        read(progress, into: entry, at: Date())
        conclude(entry, ranToTheEnd: Self.ranToTheEnd(progress, entry))
    }

    private static func ranToTheEnd(_ progress: Progress?, _ entry: Entry) -> Bool {
        if progress?.isFinished == true { return true }
        guard let total = entry.total, total > 0 else { return false }
        return entry.received >= total
    }

    private func read(_ progress: Progress, into entry: Entry, at now: Date) {
        if let url = Self.downloadURL(of: progress) {
            entry.location = DownloadNames.partialItem(containing: url) ?? url
        }
        let total = progress.totalUnitCount
        entry.total = total > 0 ? total : nil
        entry.reportedSpeed = progress.throughput.flatMap { $0 > 0 ? Double($0) : nil }
        entry.reportedTimeLeft = progress.estimatedTimeRemaining.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        record(max(0, progress.completedUnitCount), in: entry, at: now)
    }

    // MARK: Partial files

    private struct Partial {
        var folder: String
        var isBundle: Bool
    }

    private struct PartialFile {
        var url: URL
        var isBundle: Bool
        var size: Int64
    }

    private func list(_ folder: URL) {
        guard isRunning else { return }
        let generation = generation
        DispatchQueue.global(qos: .utility).async {
            let found = Self.partialFiles(in: folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.isRunning, self.generation == generation,
                          self.watchers[folder.path] != nil
                    else { return }
                    self.listed(folder, found)
                }
            }
        }
    }

    /// The partial files directly in `folder`, or `nil` when it cannot be read. Only
    /// names are listed; only partial files are looked at.
    nonisolated private static func partialFiles(in folder: URL) -> [PartialFile]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.compactMap { name in
            guard !name.hasPrefix("."),
                  DownloadNames.partialExtensions.contains((name as NSString).pathExtension.lowercased())
            else { return nil }
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
            return PartialFile(url: url, isBundle: isDirectory.boolValue, size: size(of: url) ?? 0)
        }
    }

    /// A partial file's size, or for Safari's bundle the size of the file in it; `nil`
    /// when it has gone.
    nonisolated static func size(of url: URL) -> Int64? {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else {
            return (try? files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        let names = (try? files.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0 != "Info.plist" && !$0.hasPrefix(".") }.reduce(Int64(0)) { sum, name in
            let size = (try? files.attributesOfItem(atPath: url.appendingPathComponent(name).path)[.size] as? NSNumber)
            return sum + (size?.int64Value ?? 0)
        }
    }

    private func listed(_ folder: URL, _ found: [PartialFile]?) {
        guard let found else { return }
        let isFirstLook = listedFolders.insert(folder.path).inserted
        let present = Set(found.map(\.url.path))

        for (path, partial) in partials where partial.folder == folder.path && !present.contains(path) {
            partials[path] = nil
            takeBack(path)
            if partial.isBundle { unsubscribeSoon(from: path) }
            // A download followed by its size has ended; one with a progress ends when
            // that is withdrawn (or, failing that, in `tick()`).
            if let entry = entries.first(where: { $0.progressKey == nil && $0.location.path == path }) {
                conclude(entry, ranToTheEnd: false)
            }
        }
        // A progress set aside whose file has gone is looked at again, to end the way
        // `tick()` ends one whose withdrawal has not come.
        for entry in entries where entry.isParked && entry.location.deletingLastPathComponent().path == folder.path
            && !FileManager.default.fileExists(atPath: entry.location.path) {
            wake(entry, show: false)
        }

        for file in found {
            let path = file.url.path
            if partials[path] == nil {
                partials[path] = Partial(folder: folder.path, isBundle: file.isBundle)
                if file.isBundle { subscribe(to: file.url) }
            } else if let size = leftovers[path], size == file.size {
                continue
            } else if leftovers[path] == nil {
                continue
            }
            guard !entries.contains(where: { DownloadNames.sameDownload($0.location, file.url) }) else { continue }
            // One that was set aside and has grown since is under way again.
            let revived = takeBack(path)
            followFile(file.url, size: file.size, isNew: !isFirstLook || revived)
        }
        // Listed, so macOS has let Islet see into the folder: its progress is heard from now.
        if isFirstLook { subscribe(to: folder) }
        ensureTimer()
        stopTimerIfIdle()
    }

    private func followFile(_ url: URL, size: Int64, isNew: Bool) {
        let now = Date()
        let entry = Entry(id: "file." + url.path, location: url, startedAt: now, isNew: isNew)
        entry.received = size
        entry.samples = [(now, size)]
        entries.append(entry)
    }

    /// A bundle's subscription outlives the bundle a moment, so the withdrawal of a
    /// progress it passed on still arrives.
    private func unsubscribeSoon(from path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + settleTimeout + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.partials[path] == nil else { return }
                self.unsubscribe(from: path)
            }
        }
    }

    // MARK: Setting aside

    /// Sets aside a download whose progress has stopped moving: off the island, and not
    /// looked at, until the progress says more has come.
    private func park(_ entry: Entry, _ progress: Progress, key: UUID) {
        entry.isParked = true
        entry.isShown = false
        let owner = Owner(self)
        stillObservations[key] = progress.observe(\.completedUnitCount) { _, _ in
            Self.onMain { owner.monitor?.progressMoved(key: key) }
        }
        // It may have moved between the look just taken and the observing.
        if progress.completedUnitCount != entry.received { wake(entry, show: true) }
    }

    private func progressMoved(key: UUID) {
        guard isRunning, let entry = entries.first(where: { $0.progressKey == key }), entry.isParked,
              // Either way: a download started again from nothing has moved too.
              let progress = progresses[key], progress.completedUnitCount != entry.received
        else { return }
        wake(entry, show: true)
        read(progress, into: entry, at: Date())
        report()
    }

    /// Looks at a download set aside again: shown, when it has moved, or not, when its
    /// file has gone and it is only to be seen out.
    private func wake(_ entry: Entry, show: Bool) {
        entry.isParked = false
        if let key = entry.progressKey { stillObservations.removeValue(forKey: key)?.invalidate() }
        let now = Date()
        // The speed is measured from now, not across the time it stood still.
        entry.samples = [(now, entry.received)]
        entry.lastGrowth = now
        if show { entry.isShown = true }
        ensureTimer()
    }

    /// Sets aside a partial file that has stopped growing, and watches it for being
    /// written to again. Safari's bundles are not watched: Safari publishes a progress
    /// for a download it resumes, which the bundle's subscription hears.
    private func setAside(_ url: URL, size: Int64) {
        let path = url.path
        leftovers[path] = size
        guard partials[path]?.isBundle == false, leftoverWatches[path] == nil,
              leftoverWatches.count < Self.maxLeftoverWatches
        else { return }
        let generation = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let descriptor = Darwin.open(path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.generation == generation,
                          self.leftovers[path] != nil, self.leftoverWatches[path] == nil
                    else {
                        close(descriptor)
                        return
                    }
                    self.watchLeftover(url, descriptor: descriptor)
                }
            }
        }
    }

    private func watchLeftover(_ url: URL, descriptor: Int32) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.extend, .write, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source, !source.isCancelled else { return }
            let events = source.data
            MainActor.assumeIsolated { self?.leftoverChanged(url, events) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        leftoverWatches[url.path] = source
        // Written to between being set aside and being watched.
        if let size = Self.size(of: url), size != leftovers[url.path] { leftoverChanged(url, .extend) }
    }

    /// A leftover partial file was written to: its download is under way again. One
    /// deleted or renamed is left to its folder's listing, which says which.
    private func leftoverChanged(_ url: URL, _ events: DispatchSource.FileSystemEvent) {
        let path = url.path
        guard isRunning, leftovers[path] != nil else { return }
        if events.contains(.delete) || events.contains(.rename) {
            leftoverWatches.removeValue(forKey: path)?.cancel()
            return
        }
        takeBack(path)
        guard !entries.contains(where: { DownloadNames.sameDownload($0.location, url) }),
              let size = Self.size(of: url)
        else { return }
        followFile(url, size: size, isNew: true)
        ensureTimer()
    }

    /// Stops setting a partial file aside. Returns whether it had been.
    @discardableResult
    private func takeBack(_ path: String) -> Bool {
        leftoverWatches.removeValue(forKey: path)?.cancel()
        return leftovers.removeValue(forKey: path) != nil
    }

    // MARK: Looking

    /// Whether anything is to be looked at: a download not set aside, or one just ended.
    private var needsLooking: Bool {
        !endings.isEmpty || entries.contains { !$0.isParked }
    }

    private func ensureTimer() {
        guard isRunning, timer == nil, needsLooking else { return }
        let timer = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = sampleInterval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimerIfIdle() {
        guard !needsLooking else { return }
        timer?.invalidate()
        timer = nil
    }

    /// One look at every download under way and every one that has just ended.
    private func tick() {
        guard isRunning else { return }
        let now = Date()
        for entry in entries where !entry.isParked {
            if let key = entry.progressKey, let progress = progresses[key] {
                read(progress, into: entry, at: now)
                // A progress whose file has gone for a while without it being withdrawn:
                // its browser has quit, or the withdrawal went astray.
                guard FileManager.default.fileExists(atPath: entry.location.path) else {
                    if let gone = entry.goneSince, now.timeIntervalSince(gone) >= settleTimeout {
                        progresses[key] = nil
                        conclude(entry, ranToTheEnd: Self.ranToTheEnd(progress, entry))
                    } else if entry.goneSince == nil {
                        entry.goneSince = now
                    }
                    continue
                }
                entry.goneSince = nil
                if now.timeIntervalSince(entry.lastGrowth) >= (entry.hasGrown ? stallTimeout : newFileTimeout) {
                    park(entry, progress, key: key)
                }
            } else if let size = Self.size(of: entry.location) {
                record(size, in: entry, at: now)
                if !entry.isShown, entry.hasGrown, now.timeIntervalSince(entry.startedAt) >= grace {
                    entry.isShown = true
                }
                let limit = entry.hasGrown ? stallTimeout : entry.isNew ? newFileTimeout : leftoverTimeout
                if now.timeIntervalSince(entry.lastGrowth) >= limit {
                    entries.removeAll { $0 === entry }
                    setAside(entry.location, size: size)
                }
            } else {
                // Gone between two looks at its folder.
                conclude(entry, ranToTheEnd: false)
            }
        }
        endings.removeAll { ending in
            if settle(ending) { return true }
            guard now >= ending.deadline else { return false }
            if ending.ranToTheEnd, !FileManager.default.fileExists(atPath: ending.partial.path),
               let file = Self.newestFile(besides: ending) {
                announce(file)
            }
            return true
        }
        report()
        stopTimerIfIdle()
    }

    private func record(_ bytes: Int64, in entry: Entry, at now: Date) {
        if bytes > entry.received || (entry.samples.last.map { bytes > $0.bytes } ?? false) {
            entry.hasGrown = true
            entry.lastGrowth = now
        }
        entry.received = bytes
        entry.samples.append((now, bytes))
        // Keep one sample from before the window, so the speed is measured across all of it.
        while entry.samples.count > 2, now.timeIntervalSince(entry.samples[1].date) >= speedWindow {
            entry.samples.removeFirst()
        }
    }

    private func report() {
        let items = entries.filter(\.isShown).sorted { $0.startedAt < $1.startedAt }.map(\.item)
        guard items != reported else { return }
        reported = items
        onChange(items)
    }

    // MARK: Endings

    private struct Ending {
        /// Where the file should be now.
        var expected: URL
        var partial: URL
        var startedAt: Date
        var total: Int64?
        var ranToTheEnd: Bool
        var deadline: Date
    }

    /// A download is no longer under way. It finished if word comes that it did, or its
    /// file turns up under its real name, within `settleTimeout`; otherwise it simply goes.
    private func conclude(_ entry: Entry, ranToTheEnd: Bool) {
        entries.removeAll { $0 === entry }
        if let key = entry.progressKey {
            progresses[key] = nil
            stillObservations.removeValue(forKey: key)?.invalidate()
        }
        let ending = Ending(
            expected: DownloadNames.finalURL(for: entry.location), partial: entry.location,
            startedAt: entry.startedAt, total: entry.total, ranToTheEnd: ranToTheEnd,
            deadline: Date().addingTimeInterval(settleTimeout)
        )
        report()
        if !settle(ending) {
            endings.append(ending)
            ensureTimer()
        }
        stopTimerIfIdle()
    }

    /// Whether the download has been seen to finish, announcing it if so.
    private func settle(_ ending: Ending) -> Bool {
        if let finish = recentFinishes.first(where: { Self.same($0.url, ending.expected) }), announce(finish.url) {
            return true
        }
        let files = FileManager.default
        if ending.partial.path == ending.expected.path {
            // Written under its real name all along: done if its progress ran to the end.
            guard ending.ranToTheEnd, files.fileExists(atPath: ending.expected.path) else { return false }
        } else {
            guard !files.fileExists(atPath: ending.partial.path),
                  Self.isFresh(ending.expected, since: ending.startedAt)
            else { return false }
        }
        return announce(ending.expected)
    }

    /// Word from a browser that a download has finished, and where the file is. One still
    /// followed ends here; one that ended moments ago is settled. Any other was too quick
    /// to be seen under way, or saved into a folder not followed, and is announced as it
    /// is, unless it is somewhere nobody keeps downloads (`isOutOfSight`).
    private func finished(path: String) {
        guard isRunning, path.hasPrefix("/") else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let now = Date()
        recentFinishes.removeAll { now.timeIntervalSince($0.at) > 10 }
        recentFinishes.append((url, now))
        if let entry = entries.first(where: { Self.same(DownloadNames.finalURL(for: $0.location), url) }) {
            conclude(entry, ranToTheEnd: true)
        } else if endings.contains(where: { Self.same($0.expected, url) }) {
            endings.removeAll { Self.same($0.expected, url) && settle($0) }
        } else if isInFollowedFolder(url) || !Self.isOutOfSight(url) {
            announce(url)
        }
        stopTimerIfIdle()
    }

    /// Whether `url` is a download: one under way to it, one that has just ended there,
    /// or one said to have finished there lately. A PDF saved from Print never is
    /// (`PrintedPDFWatcher`), so a downloaded one is not shown twice.
    func isDownload(_ url: URL) -> Bool {
        entries.contains { Self.same(DownloadNames.finalURL(for: $0.location), url) }
            || endings.contains { Self.same($0.expected, url) }
            || recentFinishes.contains { Self.same($0.url, url) }
            || announced[url.resolvingSymlinksInPath().path] != nil
    }

    private func isInFollowedFolder(_ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        return folders.contains { Self.same($0, folder) }
    }

    /// Somewhere nobody keeps a download: inside the Library folder (where Mail puts the
    /// attachments it opens, and apps their caches), a temporary folder, or a hidden
    /// one. Other apps than browsers post the Dock's signal for files there, and they
    /// are not downloads to hand over.
    nonisolated static func isOutOfSight(
        _ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let url = url.standardizedFileURL
        let paths = [url.path, url.resolvingSymlinksInPath().path]
        let places = [
            home.standardizedFileURL.appendingPathComponent("Library").path,
            "/private/var/folders", "/var/folders", "/private/tmp", "/tmp",
        ]
        if paths.contains(where: { path in places.contains { path.hasPrefix($0 + "/") } }) { return true }
        return url.pathComponents.dropFirst().contains { $0.hasPrefix(".") }
    }

    /// Says a download finished, once per file. Returns whether it has been said, now or
    /// before; `false` while the file is not there to be handed over.
    @discardableResult
    private func announce(_ url: URL) -> Bool {
        let now = Date()
        announced = announced.filter { now.timeIntervalSince($0.value) < 30 }
        let key = url.resolvingSymlinksInPath().path
        if announced[key] != nil { return true }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return false }
        announced[key] = now
        onFinished(FinishedDownload(url: url, size: values.fileSize.map(Int64.init)))
        return true
    }

    private nonisolated static func same(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    /// A file with something in it, made or written since the download started (less a
    /// little for clocks): not an older file under the same name.
    nonisolated static func isFresh(_ url: URL, since start: Date) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey, .creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        if values.isDirectory != true, (values.fileSize ?? 0) == 0 { return false }
        let since = start.addingTimeInterval(-5)
        return [values.creationDate, values.contentModificationDate, values.addedToDirectoryDate]
            .contains { ($0 ?? .distantPast) >= since }
    }

    /// The newest file beside a download that ran to the end and turned up under a name
    /// other than the one it was written under (Chrome's "Unconfirmed 123456.crdownload"),
    /// as big as it was to be.
    nonisolated private static func newestFile(besides ending: Ending) -> URL? {
        let folder = ending.partial.deletingLastPathComponent()
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        let since = ending.startedAt.addingTimeInterval(-5)
        return urls
            .filter { !DownloadNames.isPartial($0) }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= since
                else { return nil }
                if let total = ending.total, Int64(values.fileSize ?? -1) != total { return nil }
                return (url, modified)
            }
            .max { $0.1 < $1.1 }?.0
    }

    // MARK: Plumbing

    nonisolated private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    /// The monitor, weakly, for the progress handlers, which Foundation may call on any
    /// thread and keeps after the monitor has gone.
    private final class Owner: @unchecked Sendable {
        weak var monitor: DownloadMonitor?

        init(_ monitor: DownloadMonitor) {
            self.monitor = monitor
        }
    }

    private final class FinishedObserver: NSObject {
        private let handler: @MainActor (String) -> Void

        init(handler: @escaping @MainActor (String) -> Void) {
            self.handler = handler
        }

        @objc func received(_ notification: Notification) {
            guard let path = notification.object as? String else { return }
            let handler = handler
            DownloadMonitor.onMain { handler(path) }
        }
    }

    private final class Entry {
        let id: String
        var progressKey: UUID?
        /// The partial file, Safari's bundle, or the file itself.
        var location: URL
        let startedAt: Date
        /// Turned up while Islet was watching, rather than found there.
        let isNew: Bool
        /// Shown in the island. A partial file is shown only once it has had time to be
        /// claimed by a progress, and has grown.
        var isShown = false
        /// A progress set aside for not moving: hidden, and not looked at until it moves.
        var isParked = false
        var received: Int64 = 0
        var total: Int64?
        var reportedSpeed: Double?
        var reportedTimeLeft: TimeInterval?
        var samples: [(date: Date, bytes: Int64)] = []
        var lastGrowth: Date
        var hasGrown = false
        /// When a followed progress's file was first found missing.
        var goneSince: Date?

        init(id: String, location: URL, startedAt: Date, isNew: Bool) {
            self.id = id
            self.location = location
            self.startedAt = startedAt
            self.isNew = isNew
            lastGrowth = startedAt
        }

        var speed: Double? {
            if let reportedSpeed { return reportedSpeed }
            guard let first = samples.first, let last = samples.last else { return nil }
            let span = last.date.timeIntervalSince(first.date)
            guard span >= 1 else { return nil }
            let rate = Double(last.bytes - first.bytes) / span
            return rate > 0 ? rate : nil
        }

        var timeLeft: TimeInterval? {
            if let reportedTimeLeft { return reportedTimeLeft }
            guard let total, let speed, total > received else { return nil }
            return Double(total - received) / speed
        }

        var item: DownloadItem {
            DownloadItem(
                id: id, name: DownloadNames.displayName(for: location), location: location,
                received: received, total: total, bytesPerSecond: speed, secondsLeft: timeLeft,
                startedAt: startedAt
            )
        }
    }
}
