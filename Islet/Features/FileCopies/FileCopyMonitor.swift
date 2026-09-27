import Foundation

/// Follows copies as Finder makes them: how each is going, and whether it ran to the end.
///
/// Finder publishes an `NSProgress` for each copy, of the kind browsers publish for a
/// download (`DownloadMonitor`), and any app may subscribe to a folder's. Finder's copy
/// engine makes one for the whole operation, however many items were chosen, and names
/// in it the folder they are going into (as a reference to the folder rather than its
/// path), how many items there are, the one item's name when there is one, and its bytes
/// copied and to copy. A move to another disk is a copy too, as far as it says, and a
/// Duplicate is a copy into the same folder. A subscription to a folder hears of
/// progress for the folder itself and for what is directly in it, never deeper, so
/// copies are listened for at a set of places (`FileCopyPlaces`) and, deeper, wherever
/// files are being written (`WrittenFolders`, passed on to `noticeWrites(in:)`). Several
/// subscriptions can hear of the same copy; it is followed once.
///
/// A copy is shown once it has been going a second, if it is at least `sizeThreshold` or
/// will take `slowDelay` in all, or once it has been going `slowDelay` where how long it
/// will take is not known yet: one that is over in a moment never shows. Copies under
/// way are looked at twice a second, for the speed and the time left, but only while
/// one is moving. One that stops (waiting on a question Finder has asked, or a disk gone
/// quiet) is set aside after a while: it leaves the island and nothing looks at it until
/// its progress moves again. Working out how much there is to copy, which for a big
/// folder on a share can take minutes, is not stopping.
///
/// Stopping a copy cancels its progress, which Foundation passes on to the app copying
/// as a request to stop; only a copy that says it may be cancelled is offered it, and
/// only on the person's click.
@MainActor
final class FileCopyMonitor {
    /// How often copies under way are looked at; only while one is moving.
    var sampleInterval: TimeInterval = 0.5
    /// No copy is shown before it has been going this long; one at least
    /// `sizeThreshold` big is shown then.
    var showDelay: TimeInterval = 1
    /// A smaller copy is shown once it is seen to take this long in all, or, where how
    /// long it will take is not known yet, once it has been going this long.
    var slowDelay: TimeInterval = 5
    /// A copy with less than this left is about to end; it is not brought up only to go.
    var nearlyDone: TimeInterval = 1
    /// The size in bytes at which a copy is shown after `showDelay` rather than `slowDelay`.
    var sizeThreshold: Int64 = FileCopiesPrefs.defaultThreshold {
        didSet { if isRunning, oldValue != sizeThreshold { tick() } }
    }
    /// A copy that stops moving for this long is set aside, and comes back if it moves;
    /// counted from when its size is known.
    var stallTimeout: TimeInterval = 60
    /// Stop was clicked but the copy carried on: after this long it is offered again.
    var stopTimeout: TimeInterval = 5
    /// The span speed is measured over, where the copy does not say.
    var speedWindow: TimeInterval = 3
    /// How long a folder found being written in stays listened to after the last write
    /// there, when no copy has been heard of in it.
    var writtenLinger: TimeInterval = 30
    /// Folders found being written in, listened to at most; the least recent goes first.
    var maxWritten = 32
    /// Folders found being written in taken on from one batch at most.
    var maxWrittenAtOnce = 8
    /// Where a copy is not the person's (`FileCopyPlaces.isOutOfSight`); tests put their
    /// copies in a temporary folder, and give their own.
    var ignores: (URL) -> Bool = { FileCopyPlaces.isOutOfSight($0) }

    /// The copies worth showing, oldest first, whenever that changes.
    var onChange: ([FileCopyItem]) -> Void = { _ in }
    /// A copy that was shown ran to the end, reported before `onChange` drops it.
    var onFinished: (FileCopyItem) -> Void = { _ in }

    private(set) var isRunning = false
    /// Whether copies are being looked at on a timer, which is only while one is moving.
    var isSampling: Bool { timer != nil }
    /// Copies set aside for not moving.
    var setAsideCount: Int { entries.filter(\.isParked).count }
    /// Copies followed, shown or not.
    var followedCount: Int { entries.count }
    /// The folders subscribed to, standing and found being written in.
    var subscribedPaths: Set<String> { Set(subscriptions.keys) }
    /// The folders found being written in that are listened to for now.
    var writtenPaths: Set<String> { Set(subscriptions.filter { !$0.value.isPlace }.keys) }

    private final class Subscription {
        let token: Any
        var isPlace: Bool
        var lastWrite: Date

        init(token: Any, isPlace: Bool, lastWrite: Date) {
            self.token = token
            self.isPlace = isPlace
            self.lastWrite = lastWrite
        }
    }

    /// Subscriptions by the path of the folder they are for.
    private var subscriptions: [String: Subscription] = [:]
    /// Every copy's progress heard, by the key its subscription gave it, and the folder
    /// of the subscription that heard it.
    private var heard: [UUID: (progress: Progress, folder: String)] = [:]
    private var entries: [Entry] = []
    /// Progress set aside for not moving, observed for moving again, by its entry's id.
    private var stillObservations: [String: [NSKeyValueObservation]] = [:]
    private var reported: [FileCopyItem] = []
    private var timer: Timer?
    private var lingerTimer: Timer?

    init() {}

    // MARK: Starting and stopping

    func start(places: [URL]) {
        isRunning = true
        watch(places)
    }

    /// Listens at these places from now on: new ones are subscribed to, and ones no
    /// longer wanted are let go, unless a copy heard through one is still under way.
    func watch(_ places: [URL]) {
        guard isRunning else { return }
        let wanted = Set(places.map(\.standardizedFileURL.path))
        for (path, subscription) in subscriptions where subscription.isPlace && !wanted.contains(path) {
            subscription.isPlace = false
            subscription.lastWrite = Date()
        }
        for path in wanted {
            if let subscription = subscriptions[path] {
                subscription.isPlace = true
            } else {
                subscribe(to: path, isPlace: true)
            }
        }
        let now = Date()
        letGoOfQuietFolders(now: now)
        ensureLingerTimer()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        subscriptions.values.forEach { Progress.removeSubscriber($0.token) }
        subscriptions.removeAll()
        heard.removeAll()
        stillObservations.values.joined().forEach { $0.invalidate() }
        stillObservations.removeAll()
        entries.removeAll()
        timer?.invalidate()
        timer = nil
        lingerTimer?.invalidate()
        lingerTimer = nil
        report()
    }

    // MARK: Folders written in

    /// Files are being written in these folders: each is listened to for a while, unless
    /// it, or the folder it is in, is already (which hears of copies into it). Of the
    /// rest, only those at the top of what was written are (`FileCopyPlaces.topmost`), at
    /// most `maxWrittenAtOnce`.
    func noticeWrites(in folders: [URL]) {
        guard isRunning else { return }
        let now = Date()
        var fresh: [URL] = []
        for folder in folders.map(\.standardizedFileURL) {
            let path = folder.path
            if let subscription = subscriptions[path] {
                subscription.lastWrite = now
                continue
            }
            let parent = folder.deletingLastPathComponent().path
            if path == "/" || subscriptions[parent] != nil || ignores(folder) { continue }
            fresh.append(folder)
        }
        for folder in FileCopyPlaces.topmost(fresh, limit: maxWrittenAtOnce) {
            subscribe(to: folder.path, isPlace: false)
        }
        // Too many: the least recently written in go, unless a copy is heard through one.
        let written = subscriptions.filter { !$0.value.isPlace && !isCarrying($0.key) }
            .sorted { $0.value.lastWrite < $1.value.lastWrite }
        for (path, _) in written.prefix(max(0, subscriptions.values.filter { !$0.isPlace }.count - maxWritten)) {
            unsubscribe(from: path)
        }
        ensureLingerTimer()
    }

    /// Whether a copy heard through the subscription for `path` is still published.
    private func isCarrying(_ path: String) -> Bool {
        heard.values.contains { $0.folder == path }
    }

    private func ensureLingerTimer() {
        let hasWritten = subscriptions.values.contains { !$0.isPlace }
        guard isRunning, hasWritten else {
            lingerTimer?.invalidate()
            lingerTimer = nil
            return
        }
        guard lingerTimer == nil else { return }
        let interval = max(1, writtenLinger / 3)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.letGoOfQuietFolders(now: Date())
                self.ensureLingerTimer()
            }
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        lingerTimer = timer
    }

    /// Lets go of folders found being written in that have been quiet for `writtenLinger`,
    /// with no copy heard through them under way.
    private func letGoOfQuietFolders(now: Date) {
        for (path, subscription) in subscriptions where !subscription.isPlace
            && now.timeIntervalSince(subscription.lastWrite) >= writtenLinger && !isCarrying(path) {
            unsubscribe(from: path)
        }
    }

    // MARK: Progress

    private func subscribe(to path: String, isPlace: Bool) {
        let owner = Owner(self)
        let token = Progress.addSubscriber(forFileURL: URL(fileURLWithPath: path, isDirectory: true)) { progress in
            let key = UUID()
            Self.onMain { owner.monitor?.published(progress, key: key, folder: path) }
            return { Self.onMain { owner.monitor?.unpublished(key: key) } }
        }
        subscriptions[path] = Subscription(token: token, isPlace: isPlace, lastWrite: Date())
    }

    private func unsubscribe(from path: String) {
        guard let subscription = subscriptions.removeValue(forKey: path) else { return }
        Progress.removeSubscriber(subscription.token)
    }

    /// What a published progress says of a copy, or `nil` when it is not one: a download
    /// (`DownloadMonitor`'s), an archive being made or opened, a file coming by AirDrop.
    struct Reading: Equatable {
        var kind: FileCopyItem.Kind
        /// The URL the progress is for, as it was published: a path, or Finder's
        /// reference to a folder. Kept as it came, since bridging it to `URL` looks a
        /// reference up then and there, and one that cannot be is no longer a file URL.
        var url: NSURL
        /// The one item's name, where the copy gives it.
        var displayName: String?
        var itemCount: Int?
        /// The progress is for the folder the items are going into, as Finder's is,
        /// rather than for the item being written.
        var isForFolder: Bool
        var completed: Int64
        var total: Int64?
        var fraction: Double?
        var bytesPerSecond: Double?
        var secondsLeft: TimeInterval?
        var isCancellable: Bool

        /// What two subscriptions' copies of one progress share: what it is for, and how,
        /// which are set before it is published. Two copies at once into one folder, of
        /// as many items and by the same name, share it too, which is why one progress is
        /// taken for another already heard only when it comes through another
        /// subscription (`published`).
        var signature: String {
            [url.absoluteString ?? "", "\(kind)", itemCount.map(String.init) ?? "", displayName ?? ""]
                .joined(separator: "\u{1F}")
        }
    }

    /// Finder's own keys for the bytes of a copy, beside its unit counts, and for the
    /// name of the one item, and its word that the progress describes items.
    nonisolated static let byteTotalKey = ProgressUserInfoKey("NSProgressByteTotalCountKey")
    nonisolated static let byteCompletedKey = ProgressUserInfoKey("NSProgressByteCompletedCountKey")
    nonisolated static let displayNameKey = ProgressUserInfoKey("NSProgressFileDisplayNameKey")
    nonisolated static let itemDescriptionKey = ProgressUserInfoKey("NSProgressUseItemDescriptionKey")

    /// Read from the user info: across processes, the subscriber's copy has no `fileURL`
    /// or `fileOperationKind` of its own, only the entries behind them.
    nonisolated static func reading(of progress: Progress) -> Reading? {
        let info = progress.userInfo
        guard progress.kind == nil || progress.kind == .file,
              let url = info[.fileURLKey] as? NSURL, url.isFileURL
        else { return nil }
        let kind: FileCopyItem.Kind
        switch info[.fileOperationKindKey] as? String {
        case Progress.FileOperationKind.copying.rawValue?: kind = .copying
        case Progress.FileOperationKind.duplicating.rawValue?: kind = .duplicating
        default: return nil
        }
        let displayName = (info[displayNameKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let itemCount = (info[.fileTotalCountKey] as? NSNumber).flatMap { $0.intValue > 0 ? $0.intValue : nil }
        let isForFolder = (info[itemDescriptionKey] as? Bool) == true || displayName != nil

        let unitTotal = progress.totalUnitCount
        let byteTotal = (info[byteTotalKey] as? NSNumber)?.int64Value
        let byteDone = (info[byteCompletedKey] as? NSNumber)?.int64Value
        var fraction: Double?
        if unitTotal > 0 {
            fraction = min(1, max(0, progress.fractionCompleted))
        } else if let byteTotal, byteTotal > 0 {
            fraction = min(1, max(0, Double(max(0, byteDone ?? 0)) / Double(byteTotal)))
        }
        let total: Int64?
        var completed: Int64
        if let byteTotal, byteTotal > 0 {
            // Finder's bytes, and never less than its own fraction of them: the fraction
            // is what it draws, should the bytes lag behind.
            total = byteTotal
            completed = max(0, byteDone ?? 0)
            if let fraction { completed = max(completed, Int64(fraction * Double(byteTotal))) }
            completed = min(completed, byteTotal)
        } else if unitTotal > 0 {
            total = unitTotal
            completed = min(unitTotal, max(0, progress.completedUnitCount))
        } else {
            total = nil
            completed = max(0, byteDone ?? progress.completedUnitCount)
        }
        return Reading(
            kind: kind, url: url, displayName: displayName, itemCount: itemCount, isForFolder: isForFolder,
            completed: completed, total: total, fraction: fraction,
            bytesPerSecond: progress.throughput.flatMap { $0 > 0 ? Double($0) : nil },
            secondsLeft: progress.estimatedTimeRemaining.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            isCancellable: progress.isCancellable
        )
    }

    /// Where a copy is going, found from the URL its progress is for: the folder itself
    /// for Finder's, the folder the item is in otherwise. A reference to a folder is
    /// looked up, which asks the disk, so this is called off the main thread; `nil` where
    /// macOS will not say.
    nonisolated static func destination(of reading: Reading) -> URL? {
        guard let path = reading.url.filePathURL?.standardizedFileURL else { return nil }
        return reading.isForFolder ? path : path.deletingLastPathComponent()
    }

    /// What a copy is called in the island: the item's name, or "12 items". An app's copy
    /// of one file published by reference is named once it has been looked up (`item`).
    nonisolated static func name(of reading: Reading, item: URL? = nil) -> String {
        if let count = reading.itemCount, count > 1 { return FileCopyItem.itemsName(count) }
        if let name = reading.displayName { return name }
        if reading.isForFolder { return FileCopyItem.itemsName(reading.itemCount ?? 1) }
        if let item { return item.lastPathComponent }
        return reading.url.isFileReferenceURL() ? "Item" : reading.url.lastPathComponent ?? "Item"
    }

    /// Where a copy is going, looked up off the main thread. Finder's reference to the
    /// folder is turned into its path, and the folder is named from that path alone
    /// (`FileCopyPlaces.name(of:)`): nothing of the folder itself is asked of the disk,
    /// which for one in Documents, on another disk or on a share is somewhere macOS may
    /// ask the person about before letting Islet look.
    private struct Place: @unchecked Sendable {
        var destination: URL?
        var name: String?
        var item: URL?

        init(_ url: NSURL, isForFolder: Bool) {
            let path = url.filePathURL?.standardizedFileURL
            destination = isForFolder ? path : path?.deletingLastPathComponent()
            name = destination.map { FileCopyPlaces.name(of: $0) }
            item = isForFolder ? nil : path
        }
    }

    private func published(_ progress: Progress, key: UUID, folder: String) {
        guard isRunning, let reading = Self.reading(of: progress) else { return }
        // Heard again through another subscription: the same copy. A subscription hears
        // one progress once, so one like it through the same subscription is another copy.
        let same = entries.first { entry in
            entry.signature == reading.signature && !entry.keys.contains { heard[$0]?.folder == folder }
        }
        heard[key] = (progress, folder)
        if let same {
            same.keys.append(key)
            return
        }
        let now = Date()
        let entry = Entry(id: "copy." + key.uuidString, signature: reading.signature, startedAt: now)
        entry.keys = [key]
        entry.kind = reading.kind
        entry.itemCount = reading.itemCount
        entry.isForFolder = reading.isForFolder
        entry.name = Self.name(of: reading)
        // Where it had got to when first heard of, which is not growth: a copy found
        // waiting is as still as one that has not started.
        entry.copied = reading.completed
        entry.samples = [(now, reading.completed)]
        entries.append(entry)
        locate(entry, reading)
        tick()
        ensureTimer()
    }

    /// Looks up where a copy is going, off the main thread: a reference is looked up on
    /// its disk, which for a network share can take a moment. A copy somewhere out of
    /// sight is let go once that is known, before it would be shown.
    private func locate(_ entry: Entry, _ reading: Reading) {
        let owner = Owner(self)
        let id = entry.id
        let url = reading.url
        let isForFolder = reading.isForFolder
        DispatchQueue.global(qos: .utility).async {
            let place = Place(url, isForFolder: isForFolder)
            Self.onMain { owner.monitor?.located(id: id, place, reading: reading) }
        }
    }

    private func located(id: String, _ place: Place, reading: Reading) {
        guard isRunning, let entry = entries.first(where: { $0.id == id }) else { return }
        if let destination = place.destination, ignores(destination) {
            forget(entry)
            return
        }
        entry.destination = place.destination
        entry.destinationName = place.name
        entry.name = Self.name(of: reading, item: place.item)
        // An item's own progress inside a folder a whole copy is going into is part of that
        // copy, should the copy publish one for each item too: followed once, as the whole.
        if let destination = place.destination {
            let parts = entries.filter { !$0.isForFolder && $0.destination?.path == destination.path }
            if entry.isForFolder {
                parts.forEach(forget)
            } else if entries.contains(where: { $0.isForFolder && $0.destination?.path == destination.path }) {
                forget(entry)
                return
            }
        }
        report()
    }

    /// Lets a copy go without a word: not one to show after all.
    private func forget(_ entry: Entry) {
        stillObservations.removeValue(forKey: entry.id)?.forEach { $0.invalidate() }
        for key in entry.keys { heard[key] = nil }
        entries.removeAll { $0 === entry }
        report()
        stopTimerIfIdle()
    }

    private func unpublished(key: UUID) {
        guard let (progress, _) = heard.removeValue(forKey: key),
              let entry = entries.first(where: { $0.keys.contains(key) })
        else { return }
        entry.keys.removeAll { $0 == key }
        guard entry.keys.isEmpty else {
            // Still heard through another subscription.
            if stillObservations[entry.id] != nil, let other = primary(of: entry) { observe(entry, other) }
            return
        }
        if let reading = Self.reading(of: progress) { read(reading, into: entry, at: Date()) }
        let ranToTheEnd = !progress.isCancelled && !entry.isStopping
            && (progress.isFinished || (entry.total.map { $0 > 0 && entry.copied >= $0 } ?? false))
        conclude(entry, ranToTheEnd: ranToTheEnd)
    }

    private func primary(of entry: Entry) -> Progress? {
        entry.keys.lazy.compactMap { self.heard[$0]?.progress }.first
    }

    private func read(_ reading: Reading, into entry: Entry, at now: Date) {
        // The wait for a stall starts once the size is known, and again should it change.
        if let total = reading.total, total != entry.total { entry.lastGrowth = now }
        entry.total = reading.total
        entry.fraction = reading.fraction
        entry.canStop = reading.isCancellable
        entry.reportedSpeed = reading.bytesPerSecond
        entry.reportedTimeLeft = reading.secondsLeft
        record(reading.completed, in: entry, at: now)
    }

    // MARK: Stopping a copy

    /// Stops a copy, by cancelling its progress, which asks the app copying to stop.
    /// Only a copy that says it may be cancelled; returns whether it was asked to stop.
    /// The one progress the island reads is cancelled, which is enough for the copy it
    /// stands for, and never reaches another copy taken for this one.
    @discardableResult
    func stop(id: String) -> Bool {
        guard isRunning, let entry = entries.first(where: { $0.id == id }), entry.canStop, !entry.isStopping,
              let progress = primary(of: entry)
        else { return false }
        entry.isStopping = true
        entry.stoppingSince = Date()
        progress.cancel()
        report()
        ensureTimer()
        return true
    }

    // MARK: Setting aside

    /// Sets aside a copy that has stopped moving: off the island, and not looked at,
    /// until the progress says it has moved.
    private func park(_ entry: Entry, _ progress: Progress) {
        entry.isParked = true
        entry.isShown = false
        observe(entry, progress)
        // It may have moved between the look just taken and the observing.
        if let reading = Self.reading(of: progress), reading.completed != entry.copied { wake(entry) }
    }

    /// Watches for the copy moving: its count, or its fraction, which Finder may move by
    /// the bytes of an item part-way through while the count waits for the item to end.
    private func observe(_ entry: Entry, _ progress: Progress) {
        let owner = Owner(self)
        let id = entry.id
        stillObservations[id]?.forEach { $0.invalidate() }
        let moved: @Sendable () -> Void = { Self.onMain { owner.monitor?.progressMoved(id: id) } }
        stillObservations[id] = [
            progress.observe(\.completedUnitCount) { _, _ in moved() },
            progress.observe(\.fractionCompleted) { _, _ in moved() },
        ]
    }

    private func progressMoved(id: String) {
        guard isRunning, let entry = entries.first(where: { $0.id == id }), entry.isParked,
              let progress = primary(of: entry), let reading = Self.reading(of: progress),
              reading.completed != entry.copied
        else { return }
        wake(entry)
        read(reading, into: entry, at: Date())
        tick()
    }

    /// Looks at a copy set aside again; it is shown again as any copy is.
    private func wake(_ entry: Entry) {
        entry.isParked = false
        stillObservations.removeValue(forKey: entry.id)?.forEach { $0.invalidate() }
        let now = Date()
        // The speed is measured from now, not across the time it stood still.
        entry.samples = [(now, entry.copied)]
        entry.lastGrowth = now
        ensureTimer()
    }

    // MARK: Looking

    private func ensureTimer() {
        guard isRunning, timer == nil, entries.contains(where: { !$0.isParked }) else { return }
        let timer = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = sampleInterval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimerIfIdle() {
        guard !entries.contains(where: { !$0.isParked }) else { return }
        timer?.invalidate()
        timer = nil
    }

    /// One look at every copy under way.
    private func tick() {
        guard isRunning else { return }
        let now = Date()
        for entry in entries where !entry.isParked {
            guard let progress = primary(of: entry) else { continue }
            if let reading = Self.reading(of: progress) { read(reading, into: entry, at: now) }
            if entry.isStopping, let since = entry.stoppingSince, now.timeIntervalSince(since) >= stopTimeout {
                // Asked to stop, and did not: it may be asked again.
                entry.isStopping = false
                entry.stoppingSince = nil
            }
            if !entry.isShown, Self.isWorthShowing(
                total: entry.total, elapsed: now.timeIntervalSince(entry.startedAt), secondsLeft: entry.timeLeft,
                threshold: sizeThreshold, showDelay: showDelay, slowDelay: slowDelay, nearlyDone: nearlyDone
            ) {
                entry.isShown = true
            }
            // Still working out how much there is: waiting, not stuck.
            if entry.total != nil, now.timeIntervalSince(entry.lastGrowth) >= stallTimeout {
                park(entry, progress)
            }
        }
        report()
        stopTimerIfIdle()
    }

    /// Whether a copy is worth bringing up: going for `showDelay`, not about to end, and
    /// either at least `threshold` big or taking `slowDelay` in all, as far as its time
    /// left says; where that is not known yet, once it has been going `slowDelay`.
    ///
    /// Big copies come up if they last a couple of seconds, smaller ones only if they
    /// last a few more, so the size chosen in Settings decides which of the copies over
    /// in a few seconds show.
    nonisolated static func isWorthShowing(
        total: Int64?, elapsed: TimeInterval, secondsLeft: TimeInterval?, threshold: Int64,
        showDelay: TimeInterval, slowDelay: TimeInterval, nearlyDone: TimeInterval
    ) -> Bool {
        guard elapsed >= showDelay else { return false }
        if let secondsLeft, secondsLeft < nearlyDone { return false }
        if let total, total >= threshold { return true }
        if let secondsLeft { return elapsed + secondsLeft >= slowDelay }
        return elapsed >= slowDelay
    }

    private func record(_ bytes: Int64, in entry: Entry, at now: Date) {
        if bytes > entry.copied || (entry.samples.last.map { bytes > $0.bytes } ?? false) {
            entry.lastGrowth = now
        }
        entry.copied = bytes
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

    /// A copy is no longer under way. One that was shown and ran to the end says so,
    /// before it goes from the list.
    private func conclude(_ entry: Entry, ranToTheEnd: Bool) {
        stillObservations.removeValue(forKey: entry.id)?.forEach { $0.invalidate() }
        if ranToTheEnd, entry.isShown { onFinished(entry.item) }
        entries.removeAll { $0 === entry }
        report()
        stopTimerIfIdle()
        // A folder found being written in whose copy has ended lingers from now.
        for key in entry.keys { heard[key] = nil }
        ensureLingerTimer()
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
        weak var monitor: FileCopyMonitor?

        init(_ monitor: FileCopyMonitor) {
            self.monitor = monitor
        }
    }

    private final class Entry {
        let id: String
        let signature: String
        /// The keys of the progress it is heard through, one per subscription that heard it.
        var keys: [UUID] = []
        var kind: FileCopyItem.Kind = .copying
        /// Published for the folder the items are going into, as Finder's is.
        var isForFolder = false
        var name = ""
        var itemCount: Int?
        var destination: URL?
        var destinationName: String?
        let startedAt: Date
        /// Shown in the island: once it is worth it (`isWorthShowing`).
        var isShown = false
        /// Set aside for not moving: hidden, and not looked at until it moves.
        var isParked = false
        var isStopping = false
        var stoppingSince: Date?
        var canStop = false
        var copied: Int64 = 0
        var total: Int64?
        var fraction: Double?
        var reportedSpeed: Double?
        var reportedTimeLeft: TimeInterval?
        var samples: [(date: Date, bytes: Int64)] = []
        var lastGrowth: Date

        init(id: String, signature: String, startedAt: Date) {
            self.id = id
            self.signature = signature
            self.startedAt = startedAt
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
            guard let total, let speed, total > copied else { return nil }
            return Double(total - copied) / speed
        }

        var item: FileCopyItem {
            FileCopyItem(
                id: id, kind: kind, name: name, itemCount: itemCount, destination: destination,
                destinationName: destinationName, copied: copied, total: total, fraction: fraction,
                bytesPerSecond: speed, secondsLeft: timeLeft, canStop: canStop, isStopping: isStopping,
                startedAt: startedAt
            )
        }
    }
}
