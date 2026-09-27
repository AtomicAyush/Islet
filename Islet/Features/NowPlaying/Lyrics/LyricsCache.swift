import CryptoKit
import Foundation

/// What was found for each song, so a song played again, or gone back to, shows its
/// lyrics at once and sends nothing. Kept in memory for the songs of the last while,
/// and on disk in Application Support/Islet/Lyrics, a small file per song, for next
/// time.
///
/// Lyrics found are kept until `capacity` songs have been looked up since (the
/// oldest looked at goes first). A song with none is only remembered for
/// `missLifetime`: someone may have added them since. Failures are never kept. Each
/// song's offset, set with the panel's −/+ buttons, is kept with its lyrics.
///
/// Reading and writing files happens on `queue`, away from the island's animations.
@MainActor
final class LyricsCache {
    struct Entry: Codable, Equatable, Sendable {
        var key: String
        var result: LyricsResult
        var fetched: Date
        /// Seconds the lines are shown late (positive) or early (negative).
        var offset: TimeInterval = 0
    }

    static let shared = LyricsCache(folder: LyricsCache.defaultFolder)

    /// `nil` keeps nothing on disk.
    let folder: URL?
    let capacity: Int
    let missLifetime: TimeInterval
    /// Only a test replaces it.
    var now: () -> Date = Date.init

    private var memory: [String: Entry] = [:]
    /// Keys in `memory`, least recently used first.
    private var order: [String] = []
    private let queue = DispatchQueue(label: "com.ayush.Islet.lyrics", qos: .utility)

    /// Plenty for an evening's listening and the favourites that come round again.
    static let memoryCapacity = 64

    init(folder: URL?, capacity: Int = 500, missLifetime: TimeInterval = 6 * 3600) {
        self.folder = folder
        self.capacity = capacity
        self.missLifetime = missLifetime
    }

    static var defaultFolder: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Islet", isDirectory: true)
            .appendingPathComponent("Lyrics", isDirectory: true)
    }

    // MARK: Reading

    /// The entry for `key` from memory, else from disk; `nil` when there is none, or
    /// only a miss that has expired.
    func entry(for key: String) async -> Entry? {
        if let entry = memory[key] {
            guard isFresh(entry) else {
                forget(key)
                return nil
            }
            touch(key)
            return entry
        }
        guard let file = file(for: key) else { return nil }
        let stored: Entry? = await withCheckedContinuation { continuation in
            queue.async {
                let entry = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
                // Looked at now, so it is not the next to go when the folder is full.
                if entry != nil {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                }
                continuation.resume(returning: entry)
            }
        }
        // Two keys that hash alike are not the same song.
        guard let stored, stored.key == key else { return nil }
        guard isFresh(stored) else {
            forget(key)
            return nil
        }
        // Something stored meanwhile is newer than what was read.
        if let newer = memory[key] { return newer }
        remember(stored)
        return stored
    }

    // MARK: Writing

    func store(_ result: LyricsResult, for key: String) {
        let entry = Entry(key: key, result: result, fetched: now(), offset: memory[key]?.offset ?? 0)
        remember(entry)
        write(entry)
    }

    /// Keeps a song's offset with its lyrics. A song not in the cache has nothing to
    /// keep it with.
    func setOffset(_ offset: TimeInterval, for key: String) {
        guard var entry = memory[key], entry.offset != offset else { return }
        entry.offset = offset
        remember(entry)
        write(entry)
    }

    /// Everything, from memory and disk.
    func removeAll() {
        memory = [:]
        order = []
        guard let folder else { return }
        queue.async { try? FileManager.default.removeItem(at: folder) }
    }

    /// Waits for the files written so far, for a test.
    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    // MARK: Memory

    private func isFresh(_ entry: Entry) -> Bool {
        entry.result != .notFound || now().timeIntervalSince(entry.fetched) < missLifetime
    }

    private func remember(_ entry: Entry) {
        memory[entry.key] = entry
        touch(entry.key)
        while order.count > Self.memoryCapacity {
            memory[order.removeFirst()] = nil
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func forget(_ key: String) {
        memory[key] = nil
        order.removeAll { $0 == key }
        guard let file = file(for: key) else { return }
        queue.async { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: Disk

    /// A name for the key's file that says nothing of the song.
    private func file(for key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(String(digest.prefix(32)) + ".json")
    }

    /// Writes the entry, then trims the folder to `capacity`, the least recently used
    /// first.
    private func write(_ entry: Entry) {
        guard let folder, let file = file(for: entry.key), let data = try? JSONEncoder().encode(entry) else { return }
        let capacity = capacity
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
                .filter({ $0.pathExtension == "json" }), files.count > capacity else { return }
            let dated = files.map { url in
                (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
            }
            for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - capacity) where url != file {
                try? manager.removeItem(at: url)
            }
        }
    }
}
