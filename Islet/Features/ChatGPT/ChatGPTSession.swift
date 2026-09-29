import Foundation

/// What a ChatGPT session (a chat in the ChatGPT app, or a thread in Codex) is doing, as
/// its hook last said.
enum ChatGPTSessionState: String, Equatable, Sendable {
    /// A prompt has been sent and the reply is not finished.
    case working
    /// ChatGPT, or one of its agents, is waiting for permission to use a tool.
    case needsPermission
    /// ChatGPT, or one of its agents, has asked a question and is waiting for the answer.
    case waitingForInput
    /// The reply is finished, or the session has not been asked anything yet.
    case idle

    /// Waiting on the person rather than on ChatGPT.
    var needsYou: Bool { self == .needsPermission || self == .waitingForInput }
}

/// A tool ChatGPT, or one of its agents, has under way: what sort of tool, and a short
/// name for it. The hook keeps nothing it was given but the name.
struct ChatGPTStep: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// A command; the name is the program it runs.
        case shell
        /// A patch; the name is the first file it changes, and `count` how many.
        case patch
        /// The turn's plan being written.
        case plan
        /// A question put to the person.
        case ask
        /// An MCP server's tool; the name is the server.
        case mcp
        /// An agent being sent off.
        case spawn
        /// Waiting for agents.
        case wait
        /// A picture being looked at.
        case image
        /// The thread's goal being set or read.
        case goal
        /// Anything else; the name is the tool's.
        case other
    }

    var id: String
    var kind: Kind
    var name: String
    var count: Int = 0
    var started: Date
}

/// A step of the turn's plan, as ChatGPT's latest update_plan left it.
struct ChatGPTPlanStep: Equatable, Sendable {
    enum Status: String, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    var step: String
    var status: Status
}

/// An agent a session has sent off: named by the task it was given where the hook could
/// pair the two, with what it is doing and how many tools it has used.
struct ChatGPTAgent: Equatable, Identifiable, Sendable {
    var id: String
    /// Codex's word for the sort of agent: "default", "explorer", "worker".
    var type: String = ""
    /// The task name it was sent off with ("fix_tests"), or "".
    var name: String = ""
    var isRunning = true
    var firstSeen: Date
    var ended: Date?
    var step: ChatGPTStep?
    var steps = 0

    /// When it last did anything the hook saw.
    var lastSign: Date { [firstSeen, ended, step?.started].compactMap { $0 }.max() ?? firstSeen }
}

/// One session's file, as `Scripts/chatgpt-hook.sh` writes it. Its header lists the
/// fields. Anything missing reads as empty, so a file from a later version of the hook
/// with more in it, or less, still reads.
struct ChatGPTSessionRecord: Equatable, Identifiable, Sendable {
    var id: String
    /// The git repository's folder name, or "" for a plain chat.
    var project: String = ""
    var cwd: String = ""
    var transcriptPath: String = ""
    /// The bundle id of the app Codex runs in, or "".
    var hostApp: String = ""
    /// Codex's own process, and when it started; `nil` when the hook could not find it.
    var pid: Int32?
    var pidStarted: Date?
    var state: ChatGPTSessionState = .idle
    /// When the session entered `state`, or last asked.
    var since: Date
    /// The latest prompt's turn, which the rollout names too.
    var turnId: String = ""
    /// When the latest prompt was sent; `nil` before the first.
    var turnStarted: Date?
    /// The latest hook event.
    var updated: Date
    /// The latest prompt's first line, plain.
    var prompt: String = ""
    /// The start of the last reply, while idle.
    var reply: String = ""
    /// The tool under way, `nil` when none is.
    var step: ChatGPTStep?
    /// How many tools the turn has used.
    var steps = 0
    var plan: [ChatGPTPlanStep] = []
    var agents: [ChatGPTAgent] = []

    /// When the turn on show began: the prompt's time, or failing that the state's.
    var turnStart: Date { turnStarted ?? since }
    var runningAgents: [ChatGPTAgent] { agents.filter(\.isRunning) }
    /// A plain chat has no project; it is named by its prompt.
    var isPlainChat: Bool { project.isEmpty }
    var planDone: Int { plan.filter { $0.status == .completed }.count }
}

extension ChatGPTSessionRecord: Decodable {
    private enum Keys: String, CodingKey {
        case sessionId, project, cwd, transcriptPath, hostApp, pid, pidStarted, state, since, turnId, turnStarted
        case updated, prompt, reply, step, steps, plan, agents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .sessionId)
        project = (try? c.decodeIfPresent(String.self, forKey: .project)) ?? ""
        cwd = (try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? ""
        transcriptPath = (try? c.decodeIfPresent(String.self, forKey: .transcriptPath)) ?? ""
        hostApp = (try? c.decodeIfPresent(String.self, forKey: .hostApp)) ?? ""
        pid = (try? c.decodeIfPresent(Int32.self, forKey: .pid)).flatMap { $0 }.flatMap { $0 > 1 ? $0 : nil }
        pidStarted = (try? c.decodeIfPresent(Double.self, forKey: .pidStarted)).flatMap { $0 }
            .map(Date.init(timeIntervalSince1970:))
        // A state this version does not know is taken as idle: nothing to show for it.
        let state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? ""
        self.state = ChatGPTSessionState(rawValue: state) ?? .idle
        let updated = (try? c.decodeIfPresent(Double.self, forKey: .updated)).flatMap { $0 }
        let since = (try? c.decodeIfPresent(Double.self, forKey: .since)).flatMap { $0 } ?? updated
        guard let since else {
            throw DecodingError.dataCorruptedError(forKey: .updated, in: c, debugDescription: "No times")
        }
        self.updated = Date(timeIntervalSince1970: updated ?? since)
        self.since = Date(timeIntervalSince1970: since)
        turnId = (try? c.decodeIfPresent(String.self, forKey: .turnId)) ?? ""
        turnStarted = (try? c.decodeIfPresent(Double.self, forKey: .turnStarted)).flatMap { $0 }
            .map(Date.init(timeIntervalSince1970:))
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        reply = (try? c.decodeIfPresent(String.self, forKey: .reply)) ?? ""
        step = (try? c.decodeIfPresent(Lenient<ChatGPTStep>.self, forKey: .step))?.value
        steps = max(0, (try? c.decodeIfPresent(Int.self, forKey: .steps)) ?? 0)
        plan = ((try? c.decodeIfPresent([Lenient<ChatGPTPlanStep>].self, forKey: .plan)) ?? []).compactMap(\.value)
        agents = ((try? c.decodeIfPresent([Lenient<ChatGPTAgent>].self, forKey: .agents)) ?? []).compactMap(\.value)
    }
}

extension ChatGPTStep: Decodable {
    private enum Keys: String, CodingKey {
        case id, kind, name, count, started
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        kind = Kind(rawValue: (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "") ?? .other
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        count = max(0, (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0)
        started = ((try? c.decodeIfPresent(Double.self, forKey: .started)).flatMap { $0 })
            .map(Date.init(timeIntervalSince1970:)) ?? .distantPast
    }
}

extension ChatGPTPlanStep: Decodable {
    private enum Keys: String, CodingKey {
        case step, status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        step = try c.decode(String.self, forKey: .step)
        status = Status(rawValue: (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "") ?? .pending
    }
}

extension ChatGPTAgent: Decodable {
    private enum Keys: String, CodingKey {
        case id, type, name, status, firstSeen, ended, step, steps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        isRunning = ((try? c.decodeIfPresent(String.self, forKey: .status)) ?? "running") == "running"
        firstSeen = ((try? c.decodeIfPresent(Double.self, forKey: .firstSeen)).flatMap { $0 })
            .map(Date.init(timeIntervalSince1970:)) ?? .distantPast
        ended = (try? c.decodeIfPresent(Double.self, forKey: .ended)).flatMap { $0 }
            .map(Date.init(timeIntervalSince1970:))
        step = (try? c.decodeIfPresent(Lenient<ChatGPTStep>.self, forKey: .step))?.value
        steps = max(0, (try? c.decodeIfPresent(Int.self, forKey: .steps)) ?? 0)
    }
}

/// An element of a list that is skipped, rather than failing the list, when it does
/// not decode.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - Rollouts

/// What a thread's rollout file says about its latest turn, beyond what the hooks do.
/// Codex writes the rollout as it goes, and ends each turn in it with a line saying so,
/// even a turn that failed, which fires no hook.
struct ChatGPTRolloutProbe: Equatable, Sendable {
    /// When the rollout was last written to.
    var modified: Date?
    /// The latest turn the rollout says has ended, completed or aborted.
    var endedTurn: String?
    /// Whether that turn ended in an error.
    var failed = false
}

enum ChatGPTRollout {
    /// How much of the end of a rollout is read for the latest turn's end: a line holding
    /// a long tool output can run to hundreds of kilobytes, so more is read where the
    /// first piece holds no end of a turn.
    static let tailLengths = [64 * 1024, 1024 * 1024]
    private static let endings: Set<String> = ["task_complete", "turn_aborted"]

    /// Looks at the rollout at `path`. Called off the main thread. `known` is the last
    /// look at it, reused while the file has not changed since.
    static func probe(path: String, known: (probe: ChatGPTRolloutProbe, size: Int64)?) -> (probe: ChatGPTRolloutProbe, size: Int64)? {
        guard !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if let known, known.probe.modified == modified, known.size == size { return known }
        var probe = ChatGPTRolloutProbe(modified: modified)
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            for length in tailLengths {
                let offset = max(0, size - Int64(length))
                try? handle.seek(toOffset: UInt64(offset))
                guard let data = try? handle.readToEnd() else { break }
                if let ended = lastEnded(in: data, isWhole: offset == 0) {
                    probe.endedTurn = ended.turn
                    probe.failed = ended.failed
                    break
                }
                if offset == 0 { break }
            }
        }
        return (probe, size)
    }

    /// The last turn `data`, the end of a rollout, says has ended, and whether in an
    /// error. Only an event's type, its turn and whether it holds an error are read. The
    /// first line is skipped unless `data` is the whole file, since it is likely a piece
    /// of a longer one; so is a last line still being written.
    static func lastEnded(in data: Data, isWhole: Bool) -> (turn: String, failed: Bool)? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !isWhole, !lines.isEmpty { lines.removeFirst() }
        let complete = Data(#""task_complete""#.utf8)
        let aborted = Data(#""turn_aborted""#.utf8)
        for line in lines.reversed() {
            guard line.range(of: complete) != nil || line.range(of: aborted) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String, endings.contains(type),
                  let turn = payload["turn_id"] as? String
            else { continue }
            let error = payload["error"]
            return (turn, error != nil && !(error is NSNull))
        }
        return nil
    }
}

// MARK: - What is shown

/// A session as the island shows it: its file, and what it is doing now, which is not
/// always what the file last said.
struct ChatGPTSession: Equatable, Identifiable, Sendable {
    var record: ChatGPTSessionRecord
    var state: ChatGPTSessionState
    /// Its agents still at work: running, as the hook says, and not gone quiet.
    var agentsAtWork: [ChatGPTAgent] = []
    var id: String { record.id }

    /// The agents listed under it: while the turn goes on, those at work and those
    /// finished in it, with a tick; once it is done, those still at work.
    var agentsShown: [ChatGPTAgent] {
        let atWork = Set(agentsAtWork.map(\.id))
        return record.agents.filter { atWork.contains($0.id) || (state != .idle && !$0.isRunning) }
    }

    /// The plan, while the turn it belongs to goes on.
    var plan: [ChatGPTPlanStep] { state == .idle ? [] : record.plan }
    /// How far the plan has got; `nil` without one.
    var planFraction: Double? {
        plan.isEmpty ? nil : Double(record.planDone) / Double(plan.count)
    }
}

/// Which sessions are live, from their files, their rollouts and their processes.
///
/// The hooks say when a turn starts, what it is doing, when ChatGPT needs the person and
/// when a reply is finished, but not everything: a turn that fails sends no Stop, and
/// nothing is sent when the person answers a permission by declining it. The rest comes
/// from elsewhere. A session whose Codex has gone is over. A turn the rollout says has
/// ended is over. A turn whose hooks and rollout have been quiet for ten minutes is
/// over; an hour, while a tool is under way and Codex is still there (a long build,
/// say). An agent that has gone as quiet is taken to have stopped.
enum ChatGPTLiveness {
    /// A turn silent this long, in its hooks and its rollout, is taken to be over.
    static let staleAfter: TimeInterval = 10 * 60
    /// The same while a tool is under way and Codex is still running.
    static let longStepStaleAfter: TimeInterval = 60 * 60
    /// A session's file this old is ignored: its session ended without saying so.
    static let forgottenAfter: TimeInterval = 24 * 3600

    static func isForgotten(_ record: ChatGPTSessionRecord, now: Date) -> Bool {
        now.timeIntervalSince(record.updated) > forgottenAfter
    }

    /// Whether the session's Codex is still running: `nil` when its file names no
    /// process. Called off the main thread.
    static func isRunning(_ record: ChatGPTSessionRecord) -> Bool? {
        guard let pid = record.pid else { return nil }
        guard let started = ClaudeProcess.startTime(of: pid) else { return false }
        guard let recorded = record.pidStarted else { return true }
        return abs(started.timeIntervalSince(recorded)) <= ClaudeProcess.startSlack
    }

    /// What `record`'s session is doing now. `process` is whether its Codex is still
    /// running, `nil` when not known.
    static func state(
        of record: ChatGPTSessionRecord, rollout: ChatGPTRolloutProbe?, process: Bool? = nil, now: Date
    ) -> ChatGPTSessionState {
        if process == false { return .idle }
        guard record.state != .idle else { return .idle }
        if let ended = rollout?.endedTurn, !record.turnId.isEmpty, ended == record.turnId { return .idle }
        // Waiting on the person is never stale: the question is there until answered.
        guard record.state == .working else { return record.state }
        let lastSign = [record.since, record.updated, rollout?.modified].compactMap { $0 }.max() ?? record.updated
        let limit = record.step != nil && process == true ? longStepStaleAfter : staleAfter
        return now.timeIntervalSince(lastSign) > limit ? .idle : .working
    }

    /// The session's agents still at work: running, as the hook says, and heard from in
    /// the last ten minutes (an hour while one has a tool under way and Codex is still
    /// there). A session whose Codex has gone has none.
    static func agentsAtWork(_ record: ChatGPTSessionRecord, process: Bool?, now: Date) -> [ChatGPTAgent] {
        guard process != false else { return [] }
        return record.runningAgents.filter { agent in
            let lastSign = max(agent.lastSign, record.updated)
            let limit = agent.step != nil && process == true ? longStepStaleAfter : staleAfter
            return now.timeIntervalSince(lastSign) <= limit
        }
    }

    /// The sessions to show, in the order they are shown: those waiting for permission
    /// first, then those waiting for an answer, the longest waiting first; then those
    /// working, the longest going first; then those with only agents at work, the oldest
    /// first. The first is the one the compact island speaks for.
    static func sessions(
        _ records: [ChatGPTSessionRecord], rollouts: [String: ChatGPTRolloutProbe] = [:],
        processes: [String: Bool] = [:], now: Date
    ) -> [ChatGPTSession] {
        let shown = records.compactMap { record -> ChatGPTSession? in
            guard !isForgotten(record, now: now), processes[record.id] != false else { return nil }
            let process = processes[record.id]
            let state = state(of: record, rollout: rollouts[record.id], process: process, now: now)
            let agents = agentsAtWork(record, process: process, now: now)
            guard state != .idle || !agents.isEmpty else { return nil }
            return ChatGPTSession(record: record, state: state, agentsAtWork: agents)
        }
        return shown.sorted { a, b in
            let (ra, rb) = (rank(a.state), rank(b.state))
            if ra != rb { return ra < rb }
            let (ta, tb) = (orderTime(a), orderTime(b))
            if ta != tb { return ta < tb }
            return a.id < b.id
        }
    }

    static func sessions(_ snapshot: ChatGPTSessionSnapshot, now: Date) -> [ChatGPTSession] {
        sessions(snapshot.records, rollouts: snapshot.rollouts, processes: snapshot.processes, now: now)
    }

    private static func rank(_ state: ChatGPTSessionState) -> Int {
        switch state {
        case .needsPermission: 0
        case .waitingForInput: 1
        case .working: 2
        case .idle: 3
        }
    }

    private static func orderTime(_ session: ChatGPTSession) -> Date {
        switch session.state {
        case .needsPermission, .waitingForInput: session.record.since
        case .working: session.record.turnStart
        case .idle: session.agentsAtWork.map(\.firstSeen).min() ?? session.record.since
        }
    }

    /// How often the files and rollouts are read again, beyond whenever the folder
    /// changes.
    enum Watch: Equatable {
        /// Every few seconds: a session shown is working or waiting on the person, or has
        /// agents at work, so a turn that fails or goes quiet is seen to end.
        case closely
        /// Every minute: a session's file says it is under way, or has agents running,
        /// while it is not shown, and it comes back if it carries on; or a session that
        /// ended without saying so is let go once a day old.
        case loosely
    }

    /// How `snapshot` needs watching; `nil` when not at all.
    static func watch(_ snapshot: ChatGPTSessionSnapshot, now: Date) -> Watch? {
        if !sessions(snapshot, now: now).isEmpty { return .closely }
        let hidden = snapshot.records.contains {
            ($0.state != .idle || !$0.runningAgents.isEmpty) && !isForgotten($0, now: now)
                && snapshot.processes[$0.id] != false
        }
        return hidden ? .loosely : nil
    }
}

// MARK: - Words

/// What a step is doing, in a few words, from its kind and the short name the hook kept:
/// "Running swift", "Editing Store.swift and 2 more". Worked out here rather than in the
/// hook, so the words can change without the hook changing, which would have the
/// person trust it again.
enum ChatGPTToolWords {
    static func doing(_ step: ChatGPTStep) -> String {
        let name = step.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch step.kind {
        case .shell: return name.isEmpty ? "Running a command" : "Running \(name)"
        case .patch:
            guard !name.isEmpty else { return "Editing files" }
            return step.count > 1 ? "Editing \(name) and \(step.count - 1) more" : "Editing \(name)"
        case .plan: return "Planning"
        case .ask: return "Asking you"
        case .mcp: return name == "cua_repl" ? "Using the computer" : name.isEmpty ? "Using a tool" : "Using \(name)"
        case .spawn: return "Starting an agent"
        case .wait: return "Waiting for agents"
        case .image: return "Looking at an image"
        case .goal: return "Setting a goal"
        case .other:
            let readable = readable(name)
            return readable.isEmpty ? "Working" : "Using \(readable)"
        }
    }

    /// A tool's or a task's name as words: "write_stdin" as "write stdin".
    static func readable(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
