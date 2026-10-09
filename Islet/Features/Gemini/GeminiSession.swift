import Foundation

/// What a Gemini conversation in Google Antigravity is doing, as its hook last said.
enum GeminiSessionState: String, Equatable, Sendable {
    /// The agent is at work on the conversation.
    case working
    /// The agent stopped to ask the person something, and waits for the answer.
    case needsInput
    /// The agent stopped on an error, its quota among them.
    case error
    /// The agent has finished, or has not been asked anything yet.
    case idle

    /// Waiting on the person rather than on Gemini.
    var needsYou: Bool { self == .needsInput }
}

/// How the agent's latest run ended, as the hook's Stop said.
enum GeminiEnding: String, Equatable, Sendable {
    /// Still under way.
    case none = ""
    case done
    case needsInput
    /// Stopped with background tasks still going, which carry on without it.
    case background
    /// Stopped at Antigravity's limit on steps.
    case maxSteps
    /// Stopped by the person.
    case cancelled
    case error
    /// Stopped by its quota running out: the error said so.
    case quota
}

/// A tool the agent used or has under way: what sort of tool, and a short name for it.
/// The hook keeps nothing it was given but the name.
struct GeminiStep: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// A command; the name is the program it runs.
        case shell
        /// A file written or changed; the name is the file's.
        case edit
        /// A file or a folder looked at; the name is its own.
        case read
        /// The workspace searched.
        case search
        /// The browser Antigravity drives.
        case browser
        /// The web searched or a page read.
        case web
        /// A question put to the person.
        case ask
        /// A message to the person.
        case notify
        /// The agent's task updated.
        case task
        /// An MCP server's tool; the name is the server.
        case mcp
        /// A picture being made.
        case image
        /// Anything else; the name is the tool's.
        case other
    }

    var kind: Kind
    var name: String
    var count: Int = 0
    /// When it started, or for one finished, when it finished.
    var at: Date
}

/// One of the run's tools so far, as the hook keeps them: a run of the same one, counted
/// once.
struct GeminiHistoryEntry: Equatable, Sendable {
    var kind: GeminiStep.Kind
    var name: String
    var count = 0
    /// How many times in a row.
    var n = 1
}

/// One conversation's file, as `Scripts/antigravity-hook.sh` writes it. Its header lists
/// the fields. Anything missing reads as empty, so a file from a later version of the
/// hook with more in it, or less, still reads.
struct GeminiSessionRecord: Equatable, Identifiable, Sendable {
    var id: String
    /// The git repository's folder name, or the workspace's; "" without one.
    var project: String = ""
    var workspace: String = ""
    var model: String = ""
    var artifactDir: String = ""
    var state: GeminiSessionState = .idle
    /// When the conversation entered `state`.
    var since: Date
    /// When the agent's latest run began; `nil` before the first.
    var turnStarted: Date?
    /// The latest hook event.
    var updated: Date
    var ended: GeminiEnding = .none
    /// The start of the error that stopped it.
    var error: String = ""
    /// The tool under way, where the hook was told of it.
    var step: GeminiStep?
    /// The latest tool to finish.
    var lastStep: GeminiStep?
    /// How many tools the run has used.
    var steps = 0
    var history: [GeminiHistoryEntry] = []
    /// For a subagent's conversation, the conversation that sent it off; "" otherwise.
    var parent: String = ""
    /// A subagent's name, as Antigravity gives it; "" otherwise.
    var agent: String = ""

    /// When the run on show began: its start, or failing that the state's.
    var turnStart: Date { turnStarted ?? since }
    /// Whether it stopped for its quota.
    var isQuota: Bool { ended == .quota }
}

extension GeminiSessionRecord: Decodable {
    private enum Keys: String, CodingKey {
        case sessionId, project, workspace, model, artifactDir, state, since, turnStarted, updated, ended, error
        case step, lastStep, steps, history, parent, agent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .sessionId)
        guard GeminiSessionRecord.isValidID(id) else {
            throw DecodingError.dataCorruptedError(forKey: .sessionId, in: c, debugDescription: "Bad id")
        }
        project = (try? c.decodeIfPresent(String.self, forKey: .project)) ?? ""
        let workspace = (try? c.decodeIfPresent(String.self, forKey: .workspace)) ?? ""
        self.workspace = workspace.hasPrefix("/") ? workspace : ""
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
        let artifactDir = (try? c.decodeIfPresent(String.self, forKey: .artifactDir)) ?? ""
        self.artifactDir = artifactDir.hasPrefix("/") ? artifactDir : ""
        // A state this version does not know is taken as idle: nothing to show for it.
        let state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? ""
        self.state = GeminiSessionState(rawValue: state) ?? .idle
        let updated = (try? c.decodeIfPresent(Double.self, forKey: .updated)).flatMap { $0 }
        let since = (try? c.decodeIfPresent(Double.self, forKey: .since)).flatMap { $0 } ?? updated
        guard let since else {
            throw DecodingError.dataCorruptedError(forKey: .updated, in: c, debugDescription: "No times")
        }
        self.updated = Date(timeIntervalSince1970: updated ?? since)
        self.since = Date(timeIntervalSince1970: since)
        turnStarted = (try? c.decodeIfPresent(Double.self, forKey: .turnStarted)).flatMap { $0 }
            .map(Date.init(timeIntervalSince1970:))
        ended = GeminiEnding(rawValue: (try? c.decodeIfPresent(String.self, forKey: .ended)) ?? "") ?? .none
        error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? ""
        step = (try? c.decodeIfPresent(GeminiLenient<GeminiStep>.self, forKey: .step))?.value
        lastStep = (try? c.decodeIfPresent(GeminiLenient<GeminiStep>.self, forKey: .lastStep))?.value
        steps = max(0, (try? c.decodeIfPresent(Int.self, forKey: .steps)) ?? 0)
        history = ((try? c.decodeIfPresent([GeminiLenient<GeminiHistoryEntry>].self, forKey: .history)) ?? [])
            .compactMap(\.value)
        let parent = (try? c.decodeIfPresent(String.self, forKey: .parent)) ?? ""
        self.parent = parent != id && GeminiSessionRecord.isValidID(parent) ? parent : ""
        agent = self.parent.isEmpty ? "" : (try? c.decodeIfPresent(String.self, forKey: .agent)) ?? ""
    }

    /// An id as Antigravity gives one, and as the hook names a file by: letters, digits,
    /// dots, dashes and underscores, up to 128, never starting with a dot.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }
}

extension GeminiStep: Decodable {
    private enum Keys: String, CodingKey {
        case kind, name, count, started, at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = Kind(rawValue: (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "") ?? .other
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        count = max(0, (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0)
        let at = (try? c.decodeIfPresent(Double.self, forKey: .at)).flatMap { $0 }
            ?? (try? c.decodeIfPresent(Double.self, forKey: .started)).flatMap { $0 }
        self.at = at.map(Date.init(timeIntervalSince1970:)) ?? .distantPast
    }
}

extension GeminiHistoryEntry: Decodable {
    private enum Keys: String, CodingKey {
        case kind, name, count, n
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = GeminiStep.Kind(rawValue: (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "") ?? .other
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        count = max(0, (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0)
        n = max(1, (try? c.decodeIfPresent(Int.self, forKey: .n)) ?? 1)
    }
}

/// An element of a list that is skipped, rather than failing the list, when it does
/// not decode.
private struct GeminiLenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - What is shown

/// A subagent a conversation has sent off, as the island lists it under that
/// conversation: its name and what it is doing now.
struct GeminiAgent: Equatable, Identifiable, Sendable {
    var record: GeminiSessionRecord
    var state: GeminiSessionState
    /// What it waits on the person for, as Antigravity's list says; `nil` otherwise.
    var waiting: GeminiWaiting?
    var id: String { record.id }
}

/// A conversation as the island shows it: its file, what it is doing now, which is not
/// always what the file last said, and what Antigravity's own files say of it.
struct GeminiSession: Equatable, Identifiable, Sendable {
    var record: GeminiSessionRecord
    var state: GeminiSessionState
    /// Antigravity's title for the conversation, from its list of conversations; "" when
    /// it has none yet.
    var title: String = ""
    /// The start of the conversation, as that list previews it; "" without one.
    var preview: String = ""
    /// The agent's task list, from its task.md; `nil` without one.
    var tasks: GeminiTaskList?
    /// What a step of the run, or of one of its subagents', waits on the person for, as
    /// Antigravity's list says, while the hook has nothing to say of it; `nil` otherwise.
    var waiting: GeminiWaiting?
    /// The subagents it has sent off that are still at work, waiting on the person or
    /// stopped by an error.
    var agents: [GeminiAgent] = []
    /// What the conversation itself is doing, its subagents apart.
    var ownState: GeminiSessionState
    var id: String { record.id }

    init(record: GeminiSessionRecord, state: GeminiSessionState, title: String = "", preview: String = "",
         tasks: GeminiTaskList? = nil, waiting: GeminiWaiting? = nil, agents: [GeminiAgent] = [],
         ownState: GeminiSessionState? = nil) {
        self.record = record
        self.state = state
        self.title = title
        self.preview = preview
        self.tasks = tasks
        self.waiting = waiting
        self.agents = agents
        self.ownState = ownState ?? state
    }

    /// Whether only its subagents are at work, or stopped, the conversation itself
    /// having finished.
    var onlyAgents: Bool { ownState == .idle && !agents.isEmpty }
    /// The subagent that stopped on an error, where the conversation itself did not.
    var failedAgent: GeminiAgent? {
        ownState == .error ? nil : agents.first { $0.state == .error }
    }
    /// Whether it, or the subagent that stopped it, ran out of quota.
    var isQuota: Bool { failedAgent?.record.isQuota ?? record.isQuota }
    /// The start of the error that stopped it, or the subagent that did.
    var error: String { failedAgent?.record.error ?? record.error }
    /// Since when it has waited on the person: since its last event, for a wait only
    /// Antigravity's list tells of; else since the hook said so.
    var waitingSince: Date {
        guard waiting != nil else { return record.since }
        if let agent = agents.first(where: { $0.state == .needsInput }) {
            return agent.waiting != nil ? agent.record.updated : agent.record.since
        }
        return record.updated
    }

    /// The run's tools so far, while it goes on.
    var history: [GeminiHistoryEntry] { state == .working ? record.history : [] }
    /// How far the task list has got; `nil` without one.
    var progress: Double? { tasks.flatMap { $0.items.isEmpty ? nil : $0.fraction } }
}

/// The agent's task list, as its task.md holds it: a checklist in Markdown, each item
/// to do, under way or done.
struct GeminiTaskList: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case pending
            case inProgress
            case completed
        }

        var text: String
        var status: Status
    }

    var items: [Item]

    var done: Int { items.filter { $0.status == .completed }.count }
    var fraction: Double { items.isEmpty ? 0 : min(1, Double(done) / Double(items.count)) }

    /// How many items are listed under a conversation, at most.
    static let shownLimit = 5
    /// How many of a task.md's items are read, at most.
    static let itemLimit = 200
    /// How much of an item's words are kept.
    static let textLimit = 80

    /// The items to list: from the one before the first not done, so the list shows
    /// where the agent has got to, `shownLimit` of them at most.
    var shown: [Item] {
        guard items.count > Self.shownLimit else { return items }
        let first = items.firstIndex { $0.status != .completed } ?? items.count - 1
        let start = max(0, min(first - 1, items.count - Self.shownLimit))
        return Array(items[start..<(start + Self.shownLimit)])
    }

    /// The checklist in `markdown`: every line that is a list item with a box,
    /// `- [ ]`, `- [/]` (under way) or `- [x]`, nested ones too. `nil` when it has none.
    static func parse(_ markdown: String) -> GeminiTaskList? {
        var items: [Item] = []
        for line in markdown.prefix(256 * 1024).split(whereSeparator: \.isNewline) {
            guard items.count < itemLimit,
                  let match = line.firstMatch(of: #/^\s*(?:[-*+]|\d+[.)])\s+\[([ xX\/~-])\]\s+(.*)$/#)
            else { continue }
            let mark = match.output.1
            let status: Item.Status = mark == "x" || mark == "X" ? .completed
                : mark == " " ? .pending : .inProgress
            let text = plain(String(match.output.2))
            guard !text.isEmpty else { continue }
            items.append(Item(text: text, status: status))
        }
        return items.isEmpty ? nil : GeminiTaskList(items: items)
    }

    /// An item's words, plain: no emphasis, code marks or links' addresses, nor an
    /// anchor comment Antigravity may leave at the end, cut at a word.
    static func plain(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
        text = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return GeminiText.firstWords(text, limit: textLimit) ?? ""
    }
}

/// Which conversations are live, from their files and Antigravity's list of
/// conversations.
///
/// The hooks say when the agent is called, each tool it finishes and when it stops, but
/// not everything: a run the person stops, or one cut short, may send no Stop. So a
/// conversation the list says is idle is over a moment after its last event, and one
/// silent for ten minutes is over (an hour while a tool is under way, or the list says
/// it runs). One waiting on the person is shown for two hours at most, since Antigravity
/// never says a conversation was closed; one stopped by an error, for five minutes, long
/// enough to open the island and see why.
///
/// A question the agent puts, or a tool waiting for leave, sends no hook event until it
/// is answered; Antigravity's list says it waits (`GeminiWaiting`), and a run the hook
/// last said was working is then waiting on the person. A subagent's conversation is
/// listed under the one that sent it off rather than on its own, where that one is
/// known.
enum GeminiLiveness {
    /// A run silent this long is taken to be over.
    static let staleAfter: TimeInterval = 10 * 60
    /// The same while a tool is under way, or Antigravity's list says the agent runs.
    static let longStaleAfter: TimeInterval = 60 * 60
    /// How long a question waits on show.
    static let askShownFor: TimeInterval = 2 * 3600
    /// How long a run stopped by an error stays on show.
    static let errorShownFor: TimeInterval = 5 * 60
    /// How long after its last event a run the list says is idle is let go.
    static let idleGrace: TimeInterval = 30
    /// A file this old is ignored: Antigravity never says a conversation was closed.
    static let forgottenAfter: TimeInterval = 24 * 3600

    static func isForgotten(_ record: GeminiSessionRecord, now: Date) -> Bool {
        now.timeIntervalSince(record.updated) > forgottenAfter
    }

    /// What `record`'s conversation is doing now. `run` is what Antigravity's list says
    /// of it, `nil` when it says nothing.
    static func state(of record: GeminiSessionRecord, run: GeminiRunStatus? = nil, waiting: GeminiWaiting? = nil,
                      now: Date) -> GeminiSessionState {
        switch record.state {
        case .idle:
            return .idle
        case .needsInput:
            return now.timeIntervalSince(record.since) > askShownFor ? .idle : .needsInput
        case .error:
            return now.timeIntervalSince(record.since) > errorShownFor ? .idle : .error
        case .working:
            if waiting != nil, run == .running {
                return now.timeIntervalSince(record.updated) > askShownFor ? .idle : .needsInput
            }
            // A run stopped with background tasks going is idle in the list but for
            // them, which the list may not say at once.
            if run == .idle, record.ended != .background, now.timeIntervalSince(record.updated) > idleGrace {
                return .idle
            }
            let limit = record.step != nil || run == .running ? longStaleAfter : staleAfter
            return now.timeIntervalSince(record.updated) > limit ? .idle : .working
        }
    }

    /// The conversation a record is listed under: the one at the top of the chain of
    /// conversations that sent it off, of those with files, eight up at most; itself, if
    /// none has, or the chain comes back round to one already in it.
    static func root(of record: GeminiSessionRecord, in records: [String: GeminiSessionRecord]) -> String {
        var seen: Set<String> = [record.id]
        var id = record.id
        var parent = record.parent
        while !parent.isEmpty, seen.count <= 8, let up = records[parent] {
            guard !seen.contains(up.id) else { return record.id }
            seen.insert(up.id)
            id = up.id
            parent = up.parent
        }
        return id
    }

    /// The conversations to show, in the order they are shown: those waiting on the
    /// person first, then those stopped by an error, then those working, the longest
    /// going first. The first is the one the compact island speaks for.
    static func sessions(_ snapshot: GeminiSessionSnapshot, now: Date) -> [GeminiSession] {
        let records = snapshot.records.filter { !isForgotten($0, now: now) }
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var agents: [String: [GeminiAgent]] = [:]
        var top: [GeminiSessionRecord] = []
        for record in records {
            let root = root(of: record, in: byID)
            guard root != record.id else {
                top.append(record)
                continue
            }
            let summary = snapshot.summaries[record.id]
            let state = state(of: record, run: summary?.run, waiting: summary?.waiting, now: now)
            guard state != .idle else { continue }
            let waiting = state == .needsInput && record.state == .working ? summary?.waiting : nil
            agents[root, default: []].append(GeminiAgent(record: record, state: state, waiting: waiting))
        }
        let shown = top.compactMap { record -> GeminiSession? in
            let summary = snapshot.summaries[record.id]
            let own = state(of: record, run: summary?.run, waiting: summary?.waiting, now: now)
            let atWork = (agents[record.id] ?? []).sorted { $0.record.turnStart < $1.record.turnStart }
            var state = own
            var waiting = own == .needsInput && record.state == .working ? summary?.waiting : nil
            // A subagent waiting on the person holds up the conversation that sent it off;
            // one at work, or stopped by an error, keeps it shown, as working or stopped.
            if own != .needsInput, let asking = atWork.first(where: { $0.state == .needsInput }) {
                state = .needsInput
                waiting = asking.waiting ?? .input
            } else if own == .idle, !atWork.isEmpty {
                state = atWork.contains { $0.state == .working } ? .working : .error
            }
            guard state != .idle else { return nil }
            return GeminiSession(record: record, state: state, title: summary?.title ?? "",
                                 preview: summary?.preview ?? "", tasks: snapshot.tasks[record.id],
                                 waiting: waiting, agents: atWork, ownState: own)
        }
        return shown.sorted { a, b in
            let (ra, rb) = (rank(a.state), rank(b.state))
            if ra != rb { return ra < rb }
            let (ta, tb) = (orderTime(a), orderTime(b))
            if ta != tb { return ta < tb }
            return a.id < b.id
        }
    }

    private static func rank(_ state: GeminiSessionState) -> Int {
        switch state {
        case .needsInput: 0
        case .error: 1
        case .working: 2
        case .idle: 3
        }
    }

    private static func orderTime(_ session: GeminiSession) -> Date {
        switch session.state {
        case .working: session.record.turnStart
        case .needsInput: session.waitingSince
        case .error, .idle: session.record.since
        }
    }

    /// How often the files are read again, beyond whenever the folder changes.
    enum Watch: Equatable {
        /// Every few seconds: a conversation is shown, so one gone quiet is seen to end.
        case closely
        /// Every minute: a file says a run is under way while it is not shown.
        case loosely
    }

    static func watch(_ snapshot: GeminiSessionSnapshot, now: Date) -> Watch? {
        if !sessions(snapshot, now: now).isEmpty { return .closely }
        let hidden = snapshot.records.contains { $0.state != .idle && !isForgotten($0, now: now) }
        return hidden ? .loosely : nil
    }
}

// MARK: - Words

/// What a tool is doing, in a few words, from its kind and the short name the hook
/// kept: "Running swift", "Editing Store.swift". Worked out here rather than in the hook,
/// so the words can change without the script being copied again.
enum GeminiToolWords {
    static func doing(_ step: GeminiStep) -> String {
        let name = step.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch step.kind {
        case .shell: return name.isEmpty ? "Running a command" : "Running \(name)"
        case .edit: return name.isEmpty ? "Editing files" : "Editing \(name)"
        case .read: return name.isEmpty ? "Reading files" : "Reading \(name)"
        case .search: return "Searching the workspace"
        case .browser: return "Using the browser"
        case .web: return "Searching the web"
        case .ask: return "Asking you"
        case .notify: return "Messaging you"
        case .task: return "Updating its task"
        case .mcp: return name.isEmpty ? "Using a tool" : "Using \(name)"
        case .image: return "Making an image"
        case .other:
            let readable = readable(name)
            return readable.isEmpty ? "Working" : "Using \(readable)"
        }
    }

    /// The same, for a tool that has finished: "Ran swift", "Edited Store.swift".
    static func done(_ step: GeminiStep) -> String {
        let name = step.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch step.kind {
        case .shell: return name.isEmpty ? "Ran a command" : "Ran \(name)"
        case .edit: return name.isEmpty ? "Edited files" : "Edited \(name)"
        case .read: return name.isEmpty ? "Read files" : "Read \(name)"
        case .search: return "Searched the workspace"
        case .browser: return "Used the browser"
        case .web: return "Searched the web"
        case .ask: return "Asked you"
        case .notify: return "Messaged you"
        case .task: return "Updated its task"
        case .mcp: return name.isEmpty ? "Used a tool" : "Used \(name)"
        case .image: return "Made an image"
        case .other:
            let readable = readable(name)
            return readable.isEmpty ? "Working" : "Used \(readable)"
        }
    }

    /// A tool's name as words: "view_file_outline" as "view file outline".
    static func readable(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
