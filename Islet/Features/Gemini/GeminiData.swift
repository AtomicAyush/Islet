import Foundation

/// What Antigravity's list of conversations says of the agent's run.
enum GeminiRunStatus: Equatable, Sendable {
    case running
    case idle

    /// From the list's status, `CASCADE_RUN_STATUS_RUNNING` and the like; `nil` for one
    /// it does not say plainly. An idle run whose background tasks are not done
    /// (`notFullyIdle`) still runs, as Antigravity's own list counts it.
    init?(status: String, killed: Bool, notFullyIdle: Bool = false) {
        let status = status.uppercased()
        if killed || status.contains("CANCEL") {
            self = .idle
        } else if status.hasSuffix("IDLE") {
            self = notFullyIdle ? .running : .idle
        } else if status.hasSuffix("RUNNING") || status.hasSuffix("BUSY") {
            self = .running
        } else {
            return nil
        }
    }
}

/// What a run is waiting on the person for, as Antigravity's list of conversations
/// has it: a step of the run held until they answer.
enum GeminiWaiting: Equatable, Sendable {
    /// The agent asked a question (`ask_question`).
    case question
    /// A tool waits for the person to allow it.
    case approval
    /// Something else waits on them.
    case input

    /// The steps waiting, from the conversation's summary as the list keeps it
    /// (`raw_summary`, Antigravity's `CascadeTrajectorySummary` in protobuf's wire
    /// format): its `waiting_steps`, field 8, each a step and its index, the step in field
    /// 1. A step is a question where it holds `ask_question` (field 154), and asks for
    /// leave where it holds a `requested_interaction` (field 56). `nil` when none waits,
    /// or the bytes don't read as a summary; nothing else of it is looked at, or kept.
    static func parse(_ summary: Data) -> GeminiWaiting? {
        var found: GeminiWaiting?
        let ok = GeminiProtobuf.fields(summary) { field, payload in
            guard field == 8, let payload else { return }
            var step: Data?
            guard GeminiProtobuf.fields(payload, { field, payload in
                if field == 1, let payload { step = payload }
            }), let step else { return }
            var kind = GeminiWaiting.input
            guard GeminiProtobuf.fields(step, { field, _ in
                if field == 154 { kind = .question } else if field == 56, kind == .input { kind = .approval }
            }) else { return }
            // A question first, then a tool waiting for leave: what the person is asked.
            if found.map({ kind.rank < $0.rank }) ?? true { found = kind }
        }
        return ok ? found : nil
    }

    private var rank: Int {
        switch self {
        case .question: 0
        case .approval: 1
        case .input: 2
        }
    }
}

/// Just enough of protobuf's wire format to walk a message's fields, never past its
/// end: a varint, 64 or 32 bits, or bytes of a length given.
enum GeminiProtobuf {
    /// Calls `body` with each field's number, and its bytes where it is of a length
    /// given. Whether the whole of `data` read as fields.
    @discardableResult
    static func fields(_ data: Data, _ body: (_ field: UInt64, _ payload: Data?) -> Void) -> Bool {
        let bytes = [UInt8](data)
        var index = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard index < bytes.count else { return nil }
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7f) << UInt64(shift)
                if byte < 0x80 { return value }
            }
            return nil
        }
        while index < bytes.count {
            guard let key = varint() else { return false }
            let field = key >> 3
            guard field > 0 else { return false }
            switch key & 7 {
            case 0:
                guard varint() != nil else { return false }
                body(field, nil)
            case 1, 5:
                let size = key & 7 == 1 ? 8 : 4
                guard bytes.count - index >= size else { return false }
                index += size
                body(field, nil)
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return false }
                let end = index + Int(length)
                body(field, Data(bytes[index..<end]))
                index = end
            default:
                return false
            }
        }
        return true
    }
}

/// A conversation as Antigravity's list of conversations has it: its title, the start
/// of it, how its run stands, and what it waits on the person for.
struct GeminiSummary: Equatable, Sendable {
    var title: String = ""
    var preview: String = ""
    var run: GeminiRunStatus?
    /// A step of the run waiting on the person; `nil` when none is, or the list doesn't
    /// say.
    var waiting: GeminiWaiting?
}

/// The session files as last read, and what Antigravity's own files say of them.
struct GeminiSessionSnapshot: Equatable, Sendable {
    var records: [GeminiSessionRecord] = []
    /// By conversation id, from Antigravity's list of conversations.
    var summaries: [String: GeminiSummary] = [:]
    /// By conversation id, from its task.md.
    var tasks: [String: GeminiTaskList] = [:]
    /// When any file was last written: when Islet last heard from the hook at all.
    var lastHeard: Date?
}

/// What Antigravity keeps of its conversations that Islet reads, read-only: its list of
/// conversations, `conversation_summaries.db`, for each one's title, the start of it and
/// whether its agent runs; and each one's task list, the `task.md` among its own files
/// (`brain/<conversation id>/`). Both are in `~/.gemini/antigravity`, and only there:
/// a folder a hook's event names is followed only where it lies inside `~/.gemini`.
/// Nothing in either is written, and nothing else of them is read. The list is read as
/// any SQLite reader reads a database Antigravity has open: SQLite marks where the
/// reader has got to in the database's shared-memory index, its `-shm` file, which
/// changes nothing in the database itself or in Antigravity's settings.
enum GeminiData {
    static let summariesFile = "conversation_summaries.db"
    static let taskFile = "task.md"
    /// The most of a task.md read.
    static let taskReadLimit = 256 * 1024
    /// How much of a title, and of the preview, is kept.
    static let titleLimit = 80

    /// Antigravity's folder, `~/.gemini/antigravity`.
    static func antigravityFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
    }

    /// A database or a file as last seen, as its size and date, and its write-ahead
    /// log's.
    struct Stamp: Equatable, Sendable {
        var file: [Double] = []
        var log: [Double] = []
    }

    /// The last read of the list of conversations, for the conversations asked about.
    struct Look: Equatable, Sendable {
        var ids: Set<String> = []
        var stamp = Stamp()
        var summaries: [String: GeminiSummary] = [:]
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
        return Stamp(file: look(file.path), log: look(file.path + "-wal"))
    }

    /// The conversations `ids` as the list in `folder` has them, reusing `known` while
    /// the database has not changed. A database missing, locked or of another shape
    /// reads as saying nothing; one that could not be read is read again next time.
    /// Called off the main thread.
    static func summaries(folder: URL, ids: Set<String>, known: Look?) -> Look {
        var look = Look(ids: ids)
        let file = folder.appendingPathComponent(summariesFile)
        look.stamp = stamp(file)
        guard !ids.isEmpty, !look.stamp.file.isEmpty else { return look }
        if let known, known.ids == ids, known.stamp == look.stamp { return known }
        if let summaries = read(file, ids: ids) { look.summaries = summaries } else { look.stamp = Stamp() }
        return look
    }

    /// The most of a conversation's summary read for what it waits on.
    static let summaryReadLimit = 1024 * 1024

    /// The columns asked of the list, each where the database has it, `NULL` in its
    /// place where it does not, so a version of Antigravity without one still reads.
    static let columns = ["conversation_id", "title", "preview", "status", "killed", "not_fully_idle", "raw_summary"]

    /// Each conversation's title, preview, run and what it waits on, by its id; `nil`
    /// when the database could not be read.
    static func read(_ file: URL, ids: Set<String>) -> [String: GeminiSummary]? {
        guard let connection = ShortcutsDatabase.Connection(file) else { return nil }
        var present: Set<String> = []
        guard connection.rows("PRAGMA table_info(conversation_summaries)", [], { row in
            if let name = row.text(1) { present.insert(name) }
        }), present.contains("conversation_id") else { return nil }
        let picked = columns.map { column -> String in
            guard present.contains(column) else { return "NULL" }
            return column == "raw_summary"
                ? "CASE WHEN length(raw_summary) <= \(summaryReadLimit) THEN raw_summary END" : column
        }
        let list = Array(ids)
        let sql = "SELECT \(picked.joined(separator: ", ")) FROM conversation_summaries "
            + "WHERE conversation_id IN (\(Array(repeating: "?", count: list.count).joined(separator: ", ")))"
        var summaries: [String: GeminiSummary] = [:]
        let finished = connection.rows(sql, list.map { .text($0) }) { row in
            guard let id = row.text(0) else { return }
            func flag(_ column: Int32) -> Bool {
                (row.integer(column) ?? 0) != 0 || ["true", "1"].contains(row.text(column)?.lowercased() ?? "")
            }
            let run = GeminiRunStatus(status: row.text(3) ?? "", killed: flag(4), notFullyIdle: flag(5))
            // Only their first words, at once: nothing more of them is kept. Of the
            // summary, only whether a step waits, and on what.
            summaries[id] = GeminiSummary(
                title: GeminiText.firstWords(row.text(1) ?? "", limit: titleLimit) ?? "",
                preview: GeminiText.firstWords(row.text(2) ?? "", limit: titleLimit) ?? "",
                run: run,
                waiting: row.data(6).flatMap(GeminiWaiting.parse))
        }
        return finished ? summaries : nil
    }

    /// The titles in the list as Antigravity has them, by conversation id, for telling
    /// which conversation its window shows: whole, never cut, of those at most
    /// `titleCompareLimit` long. `nil` when the database could not be read.
    static func titles(_ file: URL) -> [String: String]? {
        guard let connection = ShortcutsDatabase.Connection(file) else { return nil }
        var titles: [String: String] = [:]
        let sql = "SELECT conversation_id, title FROM conversation_summaries "
            + "WHERE length(title) BETWEEN 1 AND \(titleCompareLimit) LIMIT 5000"
        let finished = connection.rows(sql) { row in
            if let id = row.text(0), let title = row.text(1) { titles[id] = title }
        }
        return finished ? titles : nil
    }

    /// The longest title compared with a window's.
    static let titleCompareLimit = 1000

    /// Where a conversation's task.md is: in the folder its hook's event named for its
    /// own files, where that lies inside `~/.gemini`, a link or a step up in it never
    /// followed out; else in `brain/<id>` in Antigravity's folder.
    static func taskFile(for record: GeminiSessionRecord, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        if !record.artifactDir.isEmpty, !record.artifactDir.split(separator: "/").contains("..") {
            let folder = URL(fileURLWithPath: record.artifactDir, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            if folder.path.hasPrefix(gemini + "/") {
                return folder.appendingPathComponent(taskFile)
            }
        }
        return antigravityFolder(home: home).appendingPathComponent("brain", isDirectory: true)
            .appendingPathComponent(record.id, isDirectory: true).appendingPathComponent(taskFile)
    }

    /// The task list in `file`, if it is an ordinary file (not a link) holding one;
    /// only its first `taskReadLimit` bytes are read. Called off the main thread.
    static func tasks(_ file: URL) -> GeminiTaskList? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: file.path)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: taskReadLimit), !data.isEmpty else { return nil }
        return GeminiTaskList.parse(String(decoding: data, as: UTF8.self))
    }
}
