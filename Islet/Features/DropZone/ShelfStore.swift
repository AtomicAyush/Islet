import Foundation
import Observation

/// A file kept on the shelf. The shelf holds only where the file is; the file itself
/// stays put until it is dragged somewhere else.
struct ShelfItem: Identifiable, Equatable {
    let id: UUID
    var url: URL

    var name: String { url.lastPathComponent }
}

/// Files dropped on the island to be picked up later, newest first.
///
/// Each file is also remembered by a minimal bookmark, so an item follows its file
/// when it is moved or renamed. Files that have gone are dropped the next time the
/// shelf is shown.
///
/// A picture dropped from a web page has no file of its own, and one dragged out of
/// Firefox has only a file in the temporary folder, so the shelf keeps one: a copy in
/// `storageFolder`, which it deletes when the picture leaves the shelf. A copy moved
/// out of that folder is the user's, and is left alone.
@MainActor
@Observable
final class ShelfStore {
    private(set) var items: [ShelfItem] = []
    /// Pictures dropped on the shelf that are still being fetched.
    private(set) var arriving = 0

    /// Called after every change to `items` or `arriving`.
    @ObservationIgnored var onChange: () -> Void = {}

    /// Where the shelf keeps its own copies of pictures; `nil` if Application
    /// Support is out of reach.
    let storageFolder: URL?
    /// Copies older than this that are on no shelf item are left over from an
    /// earlier run, and are deleted when the saved shelf is read in.
    @ObservationIgnored private let startedAt = Date()

    @ObservationIgnored private var bookmarks: [UUID: Data] = [:]
    @ObservationIgnored private var hasLoaded = false
    /// Bumped by `clear()`, so a saved shelf still being read in is not restored
    /// after it.
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var pendingSave: DispatchWorkItem?

    init(storageFolder: URL? = ShelfArchive.picturesFolder) {
        self.storageFolder = storageFolder
    }

    // MARK: Changes

    /// Adds the files not already on the shelf, and returns how many that was.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var known = Set(items.map { Self.identity(of: $0.url) })
        let fresh = urls
            .filter { $0.isFileURL && known.insert(Self.identity(of: $0)).inserted }
            .map { ShelfItem(id: UUID(), url: $0) }
        guard !fresh.isEmpty else { return 0 }
        items.insert(contentsOf: fresh, at: 0)
        didChange()
        return fresh.count
    }

    func remove(_ item: ShelfItem) {
        remove(ids: [item.id])
    }

    func remove(urls: [URL]) {
        let gone = Set(urls.map(Self.identity(of:)))
        remove(ids: Set(items.filter { gone.contains(Self.identity(of: $0.url)) }.map(\.id)))
    }

    /// Empties the shelf and its saved copy, including one not yet read in.
    func clear() {
        hasLoaded = true
        loadGeneration &+= 1
        let hadItems = !items.isEmpty
        let copies = items.map(\.url).filter(isOwnCopy)
        items.removeAll()
        bookmarks.removeAll()
        if hadItems { onChange() }
        scheduleSave()
        discard(copies)
    }

    private func remove(ids: Set<UUID>) {
        guard items.contains(where: { ids.contains($0.id) }) else { return }
        let copies = items.filter { ids.contains($0.id) }.map(\.url).filter(isOwnCopy)
        items.removeAll { ids.contains($0.id) }
        for id in ids { bookmarks[id] = nil }
        didChange()
        discard(copies)
    }

    /// `count` pictures dropped on the shelf are being fetched, or (`count` below
    /// zero) are no longer.
    func picturesArriving(_ count: Int) {
        let next = max(0, arriving + count)
        guard next != arriving else { return }
        arriving = next
        onChange()
    }

    // MARK: Own copies

    /// Whether the file is one of the shelf's own copies, in its storage folder.
    func isOwnCopy(_ url: URL) -> Bool {
        guard let storageFolder else { return false }
        let folder = Self.identity(of: storageFolder)
        return Self.identity(of: url).hasPrefix(folder + "/")
    }

    /// Deletes copies that have left the shelf, off the main thread.
    private func discard(_ copies: [URL]) {
        guard !copies.isEmpty, let storageFolder else { return }
        ShelfArchive.queue.async { ShelfArchive.discard(copies, in: storageFolder) }
    }

    private func didChange() {
        onChange()
        scheduleSave()
    }

    /// Two URLs for the same file compare equal: `/var` and `/private/var`, a
    /// trailing slash, `..` segments.
    private static func identity(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Checking files

    /// Finds each item's file again, following moves and dropping the ones that are
    /// gone. Runs off the main thread; cheap enough to call whenever the shelf is shown.
    func refresh() {
        guard !items.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        let records = self.records()
        ShelfArchive.queue.async { [weak self] in
            let found = records.map { ($0.id, ShelfArchive.locate($0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(found) }
            }
        }
    }

    private func apply(_ found: [(UUID, ShelfArchive.Location?)]) {
        isRefreshing = false
        var next = items
        var itemsChanged = false
        var bookmarksChanged = false
        for (id, location) in found {
            // Removed while the check was running.
            guard let index = next.firstIndex(where: { $0.id == id }) else { continue }
            if let location {
                if next[index].url.path != location.url.path {
                    next[index].url = location.url
                    itemsChanged = true
                }
                if bookmarks[id] != location.bookmark {
                    bookmarks[id] = location.bookmark
                    bookmarksChanged = true
                }
            } else {
                next.remove(at: index)
                bookmarks[id] = nil
                itemsChanged = true
            }
        }
        if itemsChanged {
            items = next
            onChange()
        }
        if itemsChanged || bookmarksChanged { scheduleSave() }
    }

    // MARK: Persistence

    /// Reads the saved shelf the first time the feature starts. Items added before
    /// it finishes loading stay in front of the saved ones.
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let storageFolder = self.storageFolder
        let startedAt = self.startedAt
        guard ShelfArchive.keepsBetweenLaunches else {
            ShelfArchive.queue.async {
                ShelfArchive.delete()
                if let storageFolder { ShelfArchive.prune(storageFolder, keeping: [], madeBefore: startedAt) }
            }
            return
        }
        let generation = loadGeneration
        ShelfArchive.queue.async { [weak self] in
            let saved = ShelfArchive.read()
            let found = saved.compactMap { record in
                ShelfArchive.locate(record).map { (record.id, $0) }
            }
            if let storageFolder {
                ShelfArchive.prune(storageFolder, keeping: found.map { $0.1.url }, madeBefore: startedAt)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.restore(found, savedCount: saved.count, generation: generation)
                }
            }
        }
    }

    private func restore(_ found: [(UUID, ShelfArchive.Location)], savedCount: Int, generation: Int) {
        guard generation == loadGeneration else { return }
        // Files dropped while this was loading may already have been saved without
        // the ones read back here.
        let addedWhileLoading = !items.isEmpty
        var known = Set(items.map { Self.identity(of: $0.url) })
        var restored: [ShelfItem] = []
        for (id, location) in found where known.insert(Self.identity(of: location.url)).inserted {
            restored.append(ShelfItem(id: id, url: location.url))
            bookmarks[id] = location.bookmark
        }
        guard !restored.isEmpty || savedCount > 0 else { return }
        items.append(contentsOf: restored)
        onChange()
        // Rewrite if files had gone or moved since the last launch.
        if addedWhileLoading || restored.count != savedCount || found.contains(where: { $0.1.wasMoved }) {
            scheduleSave()
        }
    }

    /// The Settings toggle changed: write the shelf now, or forget the saved copy.
    func keepingChanged(_ keeps: Bool) {
        if keeps {
            save()
        } else {
            pendingSave?.cancel()
            pendingSave = nil
            ShelfArchive.queue.async { ShelfArchive.delete() }
        }
    }

    /// Writes any change still waiting, and waits for writes already under way, so
    /// nothing is lost when the feature stops or the app quits.
    func flush() {
        if pendingSave != nil {
            save(waiting: true)
        } else {
            ShelfArchive.queue.sync {}
        }
    }

    /// Several changes in a row (removing items one by one) become one write.
    private func scheduleSave() {
        pendingSave?.cancel()
        guard ShelfArchive.keepsBetweenLaunches else {
            pendingSave = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func save(waiting: Bool = false) {
        pendingSave?.cancel()
        pendingSave = nil
        guard ShelfArchive.keepsBetweenLaunches else { return }
        let records = self.records()
        if waiting {
            adopt(ShelfArchive.queue.sync { ShelfArchive.save(records) })
        } else {
            ShelfArchive.queue.async { [weak self] in
                let made = ShelfArchive.save(records)
                guard !made.isEmpty else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.adopt(made) }
                }
            }
        }
    }

    /// Keeps the bookmarks made while saving, for the items still on the shelf.
    private func adopt(_ made: [UUID: Data]) {
        for (id, data) in made where items.contains(where: { $0.id == id }) {
            bookmarks[id] = data
        }
    }

    private func records() -> [ShelfArchive.Record] {
        items.map { ShelfArchive.Record(id: $0.id, path: $0.url.path, bookmark: bookmarks[$0.id]) }
    }
}

/// The shelf on disk: Application Support/Islet/shelf.json. Reading, bookmarking and
/// writing happen on `queue`, away from the island's animations.
enum ShelfArchive {
    /// The Settings toggle. On by default.
    static let keepKey = "dropZone.keepShelf"

    static var keepsBetweenLaunches: Bool {
        UserDefaults.standard.object(forKey: keepKey) as? Bool ?? true
    }

    /// Serial, so writes land in the order they were made.
    static let queue = DispatchQueue(label: "com.ayush.Islet.shelf", qos: .utility)

    struct Record: Codable {
        var id: UUID
        var path: String
        var bookmark: Data?
    }

    struct Location {
        var url: URL
        var bookmark: Data?
        /// The file is no longer at the saved path.
        var wasMoved = false
    }

    private static var fileURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return support.appendingPathComponent("Islet", isDirectory: true)
            .appendingPathComponent("shelf.json")
    }

    static func read() -> [Record] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private static func write(_ records: [Record]) {
        guard let url = fileURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(records).write(to: url, options: .atomic)
    }

    static func delete() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Own copies

    /// Application Support/Islet/Shelf: the shelf's copies of pictures dropped from
    /// web pages, each in a folder of its own.
    static var picturesFolder: URL? {
        fileURL?.deletingLastPathComponent().appendingPathComponent("Shelf", isDirectory: true)
    }

    /// Deletes copies that have left the shelf: each picture's own folder, or the
    /// file alone if it sits in `folder` itself.
    static func discard(_ copies: [URL], in folder: URL) {
        let storage = folder.standardizedFileURL.resolvingSymlinksInPath().path
        for copy in copies {
            let parent = copy.deletingLastPathComponent()
            let isOwnFolder = parent.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path == storage
            try? FileManager.default.removeItem(at: isOwnFolder ? parent : copy)
        }
    }

    /// Deletes copies no shelf item holds: left by a shelf that was not kept between
    /// launches, or by a quit before a removal was written. Only those made before
    /// `date`, so a picture dropped while the saved shelf is being read is safe.
    static func prune(_ folder: URL, keeping kept: [URL], madeBefore date: Date) {
        let files = FileManager.default
        let identity = { (url: URL) in url.standardizedFileURL.resolvingSymlinksInPath().path }
        let keptPaths = Set(kept.flatMap { [identity($0), identity($0.deletingLastPathComponent())] })
        let entries = (try? files.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: []
        )) ?? []
        for entry in entries where !keptPaths.contains(identity(entry)) {
            guard let made = try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate, made < date
            else { continue }
            try? files.removeItem(at: entry)
        }
    }

    /// Bookmarks the records that have no bookmark yet (new items are bookmarked
    /// here rather than as they are dropped, to keep the file system off the main
    /// thread), writes the file, and returns the new bookmarks.
    static func save(_ records: [Record]) -> [UUID: Data] {
        var made: [UUID: Data] = [:]
        let complete = records.map { record -> Record in
            guard record.bookmark == nil,
                  let data = bookmark(for: URL(fileURLWithPath: record.path))
            else { return record }
            made[record.id] = data
            var copy = record
            copy.bookmark = data
            return copy
        }
        write(complete)
        return made
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where a saved file is now: through its bookmark if it was moved, else at its
    /// path. `nil` when it is gone, including into the Trash, which a bookmark
    /// would otherwise follow it to.
    static func locate(_ record: Record) -> Location? {
        let files = FileManager.default
        if let data = record.bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), files.fileExists(atPath: url.path) {
                let saved = URL(fileURLWithPath: record.path)
                let moved = url.resolvingSymlinksInPath().path != saved.resolvingSymlinksInPath().path
                if moved, isInTrash(url) { return nil }
                return Location(
                    url: moved ? url : saved,
                    bookmark: isStale ? bookmark(for: url) ?? data : data,
                    wasMoved: moved
                )
            }
        }
        guard files.fileExists(atPath: record.path) else { return nil }
        let url = URL(fileURLWithPath: record.path)
        return Location(url: url, bookmark: record.bookmark ?? bookmark(for: url))
    }

    /// The home folder's `.Trash`, or a volume's `.Trashes`.
    private static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }
}
