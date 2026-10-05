import Foundation

/// What only Codex's own databases say about a thread: its goal, which Codex updates as
/// it works and which no hook reports while it does (nor when it is set from the ChatGPT
/// app), and how many prompts wait in its queue, which no hook reports at all.
///
/// Both are read read-only, from the folder the hook says Codex keeps its files in, and
/// only again once a database has changed. Of a goal, its objective's first words, its
/// state and what it has used are read; of the queue, how many prompts wait for each
/// thread, never their words. A session whose file names no folder has neither.
enum ChatGPTCodexData {
    static let goalsFile = "goals_1.sqlite"
    static let queueFile = "queue_1.sqlite"
    /// How much of a goal's objective is kept, as its title.
    static let titleLimit = 60

    /// A database as last seen: its file and its write-ahead log, as sizes and dates.
    struct Stamp: Equatable, Sendable {
        var database: [Double] = []
        var log: [Double] = []
    }

    /// The last read of one folder's databases, for the threads asked about.
    struct Look: Equatable, Sendable {
        var threads: Set<String> = []
        var goalsStamp = Stamp()
        var queueStamp = Stamp()
        var goals: [String: ChatGPTGoal] = [:]
        var queued: [String: Int] = [:]
    }

    /// The goals and queued prompts of `threads`, from the databases in `home`. Called
    /// off the main thread. `known` is the last read of the same folder, reused for a
    /// database that has not changed since, when asked about the same threads. A
    /// database missing, locked or of another shape reads as having nothing; one that
    /// could not be read is read again next time, changed or not.
    static func read(home: String, threads: Set<String>, known: Look?) -> Look {
        var look = Look(threads: threads)
        guard home.hasPrefix("/"), !threads.isEmpty else { return look }
        let folder = URL(fileURLWithPath: home, isDirectory: true)
        let same = known?.threads == threads

        let goalsURL = folder.appendingPathComponent(goalsFile)
        look.goalsStamp = stamp(goalsURL)
        if same, let known, known.goalsStamp == look.goalsStamp {
            look.goals = known.goals
        } else if !look.goalsStamp.database.isEmpty {
            if let goals = goals(goalsURL, threads: threads) { look.goals = goals } else { look.goalsStamp = Stamp() }
        }

        let queueURL = folder.appendingPathComponent(queueFile)
        look.queueStamp = stamp(queueURL)
        if same, let known, known.queueStamp == look.queueStamp {
            look.queued = known.queued
        } else if !look.queueStamp.database.isEmpty {
            if let queued = queued(queueURL, threads: threads) { look.queued = queued } else { look.queueStamp = Stamp() }
        }
        return look
    }

    static func stamp(_ file: URL) -> Stamp {
        func look(_ path: String) -> [Double] {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular
            else { return [] }
            let size = (attributes[.size] as? NSNumber)?.doubleValue ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return [size, modified]
        }
        return Stamp(database: look(file.path), log: look(file.path + "-wal"))
    }

    /// Each thread's goal, by its id; `nil` when the database could not be read.
    static func goals(_ file: URL, threads: Set<String>) -> [String: ChatGPTGoal]? {
        guard let connection = ShortcutsDatabase.Connection(file) else { return nil }
        let ids = Array(threads)
        let sql = "SELECT thread_id, objective, status, token_budget, tokens_used, time_used_seconds, updated_at_ms "
            + "FROM thread_goals WHERE thread_id IN (\(placeholders(ids.count)))"
        var goals: [String: ChatGPTGoal] = [:]
        let finished = connection.rows(sql, ids.map { .text($0) }) { row in
            guard let thread = row.text(0) else { return }
            // Its first words, at once: nothing more of it is kept.
            let title = title(row.text(1) ?? "")
            // A state this version does not know is taken as paused: not at work.
            let status = ChatGPTGoal.Status(rawValue: row.text(2) ?? "") ?? .paused
            let budget = row.integer(3).map { Int(clamping: $0) }
            goals[thread] = ChatGPTGoal(
                title: title, status: status, budget: budget.flatMap { $0 > 0 ? $0 : nil },
                used: max(0, Int(clamping: row.integer(4) ?? 0)), seconds: max(0, Int(clamping: row.integer(5) ?? 0)),
                updated: Date(timeIntervalSince1970: Double(row.integer(6) ?? 0) / 1000))
        }
        return finished ? goals : nil
    }

    /// How many prompts wait in each thread's queue, by its id, only those with any;
    /// `nil` when the database could not be read.
    static func queued(_ file: URL, threads: Set<String>) -> [String: Int]? {
        guard let connection = ShortcutsDatabase.Connection(file) else { return nil }
        let ids = Array(threads)
        let sql = "SELECT thread_id, COUNT(*) FROM queued_items WHERE thread_id IN (\(placeholders(ids.count))) "
            + "GROUP BY thread_id"
        var queued: [String: Int] = [:]
        let finished = connection.rows(sql, ids.map { .text($0) }) { row in
            guard let thread = row.text(0), let count = row.integer(1), count > 0 else { return }
            queued[thread] = Int(clamping: count)
        }
        return finished ? queued : nil
    }

    /// An objective as a title: its first line with words, plain, cut at a word.
    static func title(_ objective: String) -> String {
        let line = objective.prefix(4000).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let plain = line.replacingOccurrences(of: #"^([-*•]|[0-9]+\.|#+)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
        return ChatGPTText.firstWords(plain, limit: titleLimit) ?? ""
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
