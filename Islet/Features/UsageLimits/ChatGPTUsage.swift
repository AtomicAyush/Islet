import Foundation

/// ChatGPT's limits, as Codex writes them into its rollout files after each reply: on
/// every `token_count` event, `rate_limits` says the plan, each window's use, length and
/// exact reset, the credits left, and whether the limit was reached. Only those lines
/// are read, from the end of each file, and only these fields of them; never a line of
/// the conversation.
///
/// The files are the chats the ChatGPT hooks name, and the threads Codex last updated,
/// from its own `state_5.sqlite`, read-only and by their paths and times alone. A file
/// is touched by more than its replies (settings applied to a thread change it too), so
/// the newest reading is the one whose event is newest, never the newest file: an old
/// reading from before an upgrade can sit in a file changed since. Codex keeps more than
/// one bucket of limits; its own, `codex` (or none, as older Codex wrote it), is the one
/// shown, and another only where there is none. The reading shown is kept until a newer
/// one comes, so the chats the hooks named ending, or older chats opened since, never
/// take it away.
///
/// Codex writes a reading only as a reply comes, so one taken before a window's reset
/// shows that window as reset once the time has passed.
enum ChatGPTUsage {
    /// One bucket's limits, as one `token_count` line has them.
    struct Snapshot: Equatable, Sendable {
        var at: Date
        var limitID: String?
        /// Shortest first.
        var windows: [UsageWindow]
        var plan: String?
        var credits: UsageCredits?
        var reached: Bool
    }

    /// A rollout's newest snapshot of each bucket, and the file as it was when read.
    struct FileLook: Equatable, Sendable {
        var modified: Date
        var size: Int64
        var snapshots: [Snapshot]
    }

    /// What was read last, so what has not changed is not read again: each rollout's
    /// look, by path, and each Codex folder's threads with its database as it was.
    struct Cache: Equatable, Sendable {
        var files: [String: FileLook] = [:]
        var threads: [String: Threads] = [:]
        /// The snapshot last shown.
        var kept: Snapshot?
    }

    /// The threads Codex last updated in one folder, with its database as it was then.
    struct Threads: Equatable, Sendable {
        var stamp: ChatGPTCodexData.Stamp
        var paths: [String]
    }

    static let stateFile = "state_5.sqlite"
    /// How many of the threads Codex last updated are looked at, newest file first, as
    /// far as one could hold a reading newer than the one in hand.
    static let threadCount = 32
    /// How much of a rollout's end is read: a line holding a long tool output can run to
    /// hundreds of kilobytes, so more where the first piece holds no reading.
    static let tailLengths = [64 * 1024, 1024 * 1024]
    /// Codex's own bucket.
    static let codexBucket = "codex"

    /// Codex's folder where nothing names another: `~/.codex`.
    static var defaultHome: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true).path
    }

    /// The newest reading among the rollouts of the threads last updated in each of
    /// `homes`, and those at `transcripts`. Called off the main thread.
    static func read(homes: [String], transcripts: [String], cache: Cache) -> (reading: UsageReading?, cache: Cache) {
        var next = Cache()
        var paths: [String] = []
        for home in Set(homes) where home.hasPrefix("/") {
            let database = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(stateFile)
            let stamp = ChatGPTCodexData.stamp(database)
            if let known = cache.threads[home], known.stamp == stamp {
                next.threads[home] = known
                paths += known.paths
            } else if !stamp.database.isEmpty, let threads = recentRollouts(database) {
                // One that could not be read is tried again next time, changed or not.
                next.threads[home] = Threads(stamp: stamp, paths: threads)
                paths += threads
            }
        }
        paths += transcripts
        // Newest file first: one last changed before the reading in hand was taken cannot
        // hold a newer one, and is not read.
        let files = Set(paths).filter(isRollout).compactMap { path in modified(path).map { (path: path, modified: $0) } }
            .sorted { $0.modified > $1.modified }
        var snapshots = cache.kept.map { [$0] } ?? []
        for file in files {
            if let best = choose(snapshots), isOwn(best), best.at >= file.modified { break }
            guard let look = look(path: file.path, known: cache.files[file.path]) else { continue }
            next.files[file.path] = look
            snapshots += look.snapshots
        }
        next.kept = choose(snapshots)
        return (next.kept.map(reading), next)
    }

    /// When the plain file at `path` last changed; `nil` for anything else.
    private static func modified(_ path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// A full path to a `.jsonl` file: what a rollout's path is.
    static func isRollout(_ path: String) -> Bool {
        path.hasPrefix("/") && path.hasSuffix(".jsonl") && !path.contains("/../")
    }

    /// The rollouts of the threads Codex last updated, newest first; `nil` where the
    /// database cannot be read. Only the paths are read.
    ///
    /// The database is in write-ahead mode. While Codex has it open, its log beside it
    /// holds what is not yet in the file, and is read with it. Once Codex closes it, the
    /// log is folded in and gone, and a read-only connection, which may not make the
    /// shared memory the mode needs, cannot read it as it is; then it is read as a file
    /// nothing changes, which creates nothing beside it either.
    static func recentRollouts(_ database: URL) -> [String]? {
        let hasLog = FileManager.default.fileExists(atPath: database.path + "-wal")
        for immutable in hasLog ? [false, true] : [true] {
            guard let connection = ShortcutsDatabase.Connection(database, immutable: immutable) else { continue }
            var paths: [String] = []
            let finished = connection.rows("SELECT rollout_path FROM threads ORDER BY updated_at_ms DESC LIMIT ?",
                                           [.integer(Int64(threadCount))]) { row in
                if let path = row.text(0) { paths.append(path) }
            }
            if finished { return paths }
        }
        return nil
    }

    /// The newest snapshot of each bucket at the end of the rollout at `path`. `known` is
    /// the last look at it, kept while the file has not changed. `nil` for a file that is
    /// not there, or is not a plain file.
    static func look(path: String, known: FileLook?) -> FileLook? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if let known, known.modified == modified, known.size == size { return known }
        var look = FileLook(modified: modified, size: size, snapshots: [])
        guard let handle = FileHandle(forReadingAtPath: path) else { return look }
        defer { try? handle.close() }
        for length in tailLengths {
            let offset = max(0, size - Int64(length))
            try? handle.seek(toOffset: UInt64(offset))
            guard let data = try? handle.readToEnd() else { break }
            look.snapshots = newest(in: data, isWhole: offset == 0)
            // Another bucket's reading at the end may sit after Codex's own.
            if look.snapshots.contains(where: { isOwn($0) && !$0.windows.isEmpty }) || offset == 0 { break }
        }
        return look
    }

    /// The newest snapshot of each bucket in `data`, the end of a rollout. The first line
    /// is skipped unless `data` is the whole file, as likely a piece of a longer one, and
    /// a line that does not read (one still being written) is passed over.
    static func newest(in data: Data, isWhole: Bool) -> [Snapshot] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !isWhole, !lines.isEmpty { lines.removeFirst() }
        let event = Data(#""token_count""#.utf8)
        let limits = Data(#""rate_limits""#.utf8)
        var byBucket: [String: Snapshot] = [:]
        for line in lines where line.range(of: event) != nil && line.range(of: limits) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let found = snapshot(object)
            else { continue }
            let bucket = found.limitID ?? ""
            if byBucket[bucket].map({ $0.at <= found.at }) ?? true { byBucket[bucket] = found }
        }
        return byBucket.values.sorted { $0.at < $1.at }
    }

    /// The snapshot on a `token_count` event, `nil` for anything else. Only the event's
    /// time and its `rate_limits` are read.
    static func snapshot(_ object: [String: Any]) -> Snapshot? {
        guard object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              let stamp = object["timestamp"] as? String, let at = date(stamp)
        else { return nil }
        let windows = ["primary", "secondary"].compactMap { window(limits[$0] as? [String: Any], at: at) }
            .sorted { $0.minutes < $1.minutes }
        var credits: UsageCredits?
        if let given = limits["credits"] as? [String: Any] {
            credits = UsageCredits(hasCredits: given["has_credits"] as? Bool ?? false,
                                   unlimited: given["unlimited"] as? Bool ?? false,
                                   balance: given["balance"] as? String ?? (given["balance"] as? Double).map { String($0) })
        }
        let reached = limits["rate_limit_reached_type"].map { !($0 is NSNull) } ?? false
        return Snapshot(at: at, limitID: limits["limit_id"] as? String, windows: windows,
                        plan: limits["plan_type"] as? String, credits: credits, reached: reached)
    }

    /// A window: its use, its length and its reset, in seconds since 1970, or as older
    /// Codex wrote it, in seconds from the event.
    static func window(_ fields: [String: Any]?, at: Date) -> UsageWindow? {
        guard let fields, let percent = fields["used_percent"] as? Double, percent.isFinite,
              let minutes = fields["window_minutes"] as? Int, minutes > 0
        else { return nil }
        var resets: Date?
        if let seconds = fields["resets_at"] as? Double, seconds.isFinite {
            resets = Date(timeIntervalSince1970: seconds)
        } else if let seconds = fields["resets_in_seconds"] as? Double, seconds.isFinite {
            resets = at.addingTimeInterval(seconds)
        }
        return UsageWindow(minutes: minutes, percent: min(100, max(0, percent)), resets: resets)
    }

    /// The newest of Codex's own bucket with windows to show, or where there is none, the
    /// newest other.
    static func choose(_ snapshots: [Snapshot]) -> Snapshot? {
        let shown = snapshots.filter { !$0.windows.isEmpty }
        let own = shown.filter(isOwn)
        return (own.isEmpty ? shown : own).max { $0.at < $1.at }
    }

    /// Whether `snapshot` is of Codex's own bucket.
    static func isOwn(_ snapshot: Snapshot) -> Bool {
        snapshot.limitID == nil || snapshot.limitID == codexBucket
    }

    static func reading(_ snapshot: Snapshot) -> UsageReading {
        UsageReading(agent: .chatGPT, measured: snapshot.at, windows: snapshot.windows, plan: snapshot.plan,
                     credits: snapshot.credits, limitSince: snapshot.reached ? snapshot.at : nil)
    }

    /// "2026-10-07T18:57:33.429Z", with or without the fraction.
    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }
}
