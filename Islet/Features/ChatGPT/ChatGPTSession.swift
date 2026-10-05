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
        /// The thread's goal being set, read or marked done.
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
    /// The task name it was sent off with ("fix_tests"), or the nickname Codex gave it
    /// ("Fermat"), or "".
    var name: String = ""
    var isRunning = true
    var firstSeen: Date
    var ended: Date?
    var step: ChatGPTStep?
    var steps = 0
    /// How many steps of its own plan are done, and how many it has; `nil` until it has
    /// written one. The hook keeps no more of its plan than that.
    var planDone: Int?
    var planTotal: Int?
    /// When the hook last heard from it: its start, or one of its tools starting or
    /// ending. Between its tools it has no step, so this is all that says it is busy.
    var seen: Date?

    /// When it last did anything the hook saw.
    var lastSign: Date { [firstSeen, ended, step?.started, seen].compactMap { $0 }.max() ?? firstSeen }

    /// How far its own plan has got; `nil` without one.
    var planFraction: Double? {
        guard let planTotal, planTotal > 0 else { return nil }
        return min(1, Double(planDone ?? 0) / Double(planTotal))
    }

    /// How long it has gone without a sign, at `now`, once that is ten minutes or more;
    /// `nil` before then, or once it has finished. It may be waiting on a long command,
    /// or stuck.
    func quiet(at now: Date) -> TimeInterval? {
        guard isRunning else { return nil }
        let quiet = now.timeIntervalSince(lastSign)
        return quiet >= ChatGPTLiveness.quietAfter ? quiet : nil
    }
}

/// One of the turn's steps so far, as the hook keeps them: a run of the same step,
/// counted once.
struct ChatGPTHistoryEntry: Equatable, Sendable {
    var kind: ChatGPTStep.Kind
    var name: String
    var count = 0
    /// How many times in a row.
    var n = 1
}

/// A command the chat left running: one still under way once another tool started, or
/// the turn stopped. The hook keeps only the program it runs.
struct ChatGPTShell: Equatable, Identifiable, Sendable {
    /// The call's id, as the rollout names it once it ends.
    var id: String
    var name: String
    var started: Date
    /// When it was seen to be left running.
    var since: Date
    /// Whether it had been asked permission for. One declined looks the same to the hook
    /// as one let run, so it is listed only once the rollout shows it running.
    var asked = false
}

/// A thread's goal, as Codex keeps it in its own database: what it is, how it stands,
/// and how much it has used.
struct ChatGPTGoal: Equatable, Sendable {
    enum Status: String, Sendable {
        case active
        case paused
        case blocked
        case usageLimited = "usage_limited"
        case budgetLimited = "budget_limited"
        case complete
    }

    /// Its objective's first words, plain: the person's own, or ChatGPT's.
    var title: String
    var status: Status
    /// The tokens it may use, where it was given a budget.
    var budget: Int?
    var used = 0
    var seconds = 0
    var updated: Date

    /// How much of its budget it has used; `nil` without one.
    var fraction: Double? {
        guard let budget, budget > 0 else { return nil }
        return min(1, Double(used) / Double(budget))
    }
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
    /// Where Codex keeps its own files, as a full path; "" when the hook did not say.
    var codexHome: String = ""
    /// The turn's steps so far, oldest first.
    var history: [ChatGPTHistoryEntry] = []
    /// The chat's commands left running, as far as the hook knows.
    var shells: [ChatGPTShell] = []

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
        case updated, prompt, reply, step, steps, plan, agents, codexHome, history, shells
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
        let home = (try? c.decodeIfPresent(String.self, forKey: .codexHome)) ?? ""
        codexHome = home.hasPrefix("/") ? home : ""
        history = ((try? c.decodeIfPresent([Lenient<ChatGPTHistoryEntry>].self, forKey: .history)) ?? [])
            .compactMap(\.value)
        shells = ((try? c.decodeIfPresent([Lenient<ChatGPTShell>].self, forKey: .shells)) ?? []).compactMap(\.value)
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
        case id, type, name, status, firstSeen, ended, step, steps, planDone, planTotal, seen
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
        planDone = (try? c.decodeIfPresent(Int.self, forKey: .planDone)).flatMap { $0 }.map { max(0, $0) }
        planTotal = (try? c.decodeIfPresent(Int.self, forKey: .planTotal)).flatMap { $0 }.map { max(0, $0) }
        seen = (try? c.decodeIfPresent(Double.self, forKey: .seen)).flatMap { $0 }
            .map(Date.init(timeIntervalSince1970:))
    }
}

extension ChatGPTHistoryEntry: Decodable {
    private enum Keys: String, CodingKey {
        case kind, name, count, n
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = ChatGPTStep.Kind(rawValue: (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "") ?? .other
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        count = max(0, (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0)
        n = max(1, (try? c.decodeIfPresent(Int.self, forKey: .n)) ?? 1)
    }
}

extension ChatGPTShell: Decodable {
    private enum Keys: String, CodingKey {
        case id, name, started, since, asked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "No id")
        }
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        let started = (try? c.decodeIfPresent(Double.self, forKey: .started)).flatMap { $0 }
        let since = (try? c.decodeIfPresent(Double.self, forKey: .since)).flatMap { $0 } ?? started
        guard let since else {
            throw DecodingError.dataCorruptedError(forKey: .since, in: c, debugDescription: "No times")
        }
        self.started = Date(timeIntervalSince1970: started ?? since)
        self.since = Date(timeIntervalSince1970: since)
        asked = (try? c.decodeIfPresent(Bool.self, forKey: .asked)) ?? false
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

    // MARK: Commands' ends

    /// How far back a rollout not read before is read for commands' ends, and the most
    /// read at once: a command's end holds all it printed.
    static let commandLookBack: Int64 = 4 * 1024 * 1024
    static let commandReadLimit: Int64 = 8 * 1024 * 1024
    /// How much further back a rollout not read before is searched, a piece at a time,
    /// for the calls of the commands listed: an end lies somewhere after its call, and a
    /// turn or two of long output can push it past the first look.
    static let commandSearchLimit: Int64 = 64 * 1024 * 1024
    /// How many of the latest ends, and of the latest seen running, are kept.
    static let commandEndsKept = 256
    private static let runningMark = Data("Process running with session ID".utf8)

    /// What a rollout says of commands, read as it grows: those that have ended (left to
    /// exit on their own with no hook to say so, stopped by Codex at an interrupt or when
    /// the app cleans up its background terminals, or never started, a call declined) and
    /// those still running once their call returned. Called off the main thread. `known`
    /// is the last read, carried on from; `calls` the commands listed, which a rollout not
    /// read before is searched back for.
    static func commandEnds(path: String, known: ChatGPTCommandEnds?, calls: [String] = []) -> ChatGPTCommandEnds? {
        guard !path.isEmpty,
              let read = ClaudeFollowedFile.read(path, known: known?.file, lookBack: commandLookBack,
                                                 limit: commandReadLimit)
        else { return nil }
        var ends = read.fresh ? ChatGPTCommandEnds() : (known ?? ChatGPTCommandEnds())
        ends.file = read.file
        let lines = read.fresh && read.cut ? earlierLines(path: path, before: read.file.offset, calls: calls) : read.lines
        for line in lines {
            guard let sign = commandSign(in: line) else { continue }
            ends.ended.removeAll { $0 == sign.id }
            ends.running.removeAll { $0 == sign.id }
            if sign.running { ends.running.append(sign.id) } else { ends.ended.append(sign.id) }
        }
        let listed = Set(calls)
        ends.ended = trimmed(ends.ended, keeping: listed)
        ends.running = trimmed(ends.running, keeping: listed)
        return ends
    }

    /// The latest `commandEndsKept` of `ids`, those listed kept before any other.
    private static func trimmed(_ ids: [String], keeping listed: Set<String>) -> [String] {
        guard ids.count > commandEndsKept else { return ids }
        var excess = ids.count - commandEndsKept
        return ids.filter { id in
            guard excess > 0, !listed.contains(id) else { return true }
            excess -= 1
            return false
        }.suffix(commandEndsKept).map { $0 }
    }

    /// The whole lines of a rollout up to `end`, read from far enough back to hold every
    /// one of `calls` (or their ends, or the file's start), and at least `commandLookBack`;
    /// at most `commandSearchLimit`. Read back a piece at a time, only lines that could
    /// say a command ended or kept running are kept.
    static func earlierLines(path: String, before end: Int64, calls: [String]) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        var unseen = Set(calls.map { Data("\"\($0)\"".utf8) })
        let newline = UInt8(ascii: "\n")
        let piece: Int64 = 4 * 1024 * 1024
        var pieces: [[Data]] = []
        var upTo = end
        // A piece's first line, cut by its start, is read whole with the piece before.
        var carry = Data()
        while upTo > 0 {
            let from = max(0, upTo - piece)
            try? handle.seek(toOffset: UInt64(from))
            guard var data = try? handle.read(upToCount: Int(upTo - from)) else { break }
            data.append(carry)
            var parts = data.split(separator: newline, omittingEmptySubsequences: false)
            carry = from > 0 && !parts.isEmpty ? Data(parts.removeFirst()) : Data()
            // A line longer than a search is let go.
            if carry.count > Int(commandReadLimit) { carry = Data() }
            var kept: [Data] = []
            for part in parts where !part.isEmpty {
                let line = Data(part)
                for call in unseen where line.range(of: call) != nil { unseen.remove(call) }
                if line.range(of: Data(#""CommandExecution""#.utf8)) != nil
                    || line.range(of: Data(#""function_call_output""#.utf8)) != nil {
                    kept.append(line)
                }
            }
            pieces.append(kept)
            upTo = from
            if unseen.isEmpty, end - upTo >= commandLookBack { break }
            if end - upTo >= commandSearchLimit { break }
        }
        return pieces.reversed().flatMap { $0 }
    }

    /// The command `line` says something of, and whether it is running: an end recorded
    /// as a CommandExecution item, or the output its call returned, which begins by
    /// saying whether the process is still running. Of such a line only the id is taken,
    /// and of an output only whether its first lines say so: never the command, nor what
    /// it printed.
    static func commandSign(in line: Data) -> (id: String, running: Bool)? {
        if line.range(of: Data(#""CommandExecution""#.utf8)) != nil,
           let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           object["type"] as? String == "event_msg",
           let payload = object["payload"] as? [String: Any],
           payload["type"] as? String == "item_completed",
           let item = payload["item"] as? [String: Any],
           item["type"] as? String == "CommandExecution",
           let id = item["id"] as? String, !id.isEmpty {
            return (id, false)
        }
        guard line.range(of: Data(#""function_call_output""#.utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "function_call_output",
              let id = payload["call_id"] as? String, !id.isEmpty
        else { return nil }
        let output = payload["output"] as? String
            ?? (payload["output"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.first ?? ""
        // The process's state is said before what it printed.
        let head = Data(output.prefix(200).components(separatedBy: "\nOutput:").first?.utf8 ?? "".utf8)
        return (id, head.range(of: runningMark) != nil)
    }
}

/// What a rollout says of commands, by their calls' ids, the latest last: those ended,
/// and those whose call returned with them still running; and where reading it got to.
struct ChatGPTCommandEnds: Equatable, Sendable {
    var file = ClaudeFollowedFile()
    var ended: [String] = []
    var running: [String] = []
}

// MARK: - What is shown

/// A session as the island shows it: its file, and what it is doing now, which is not
/// always what the file last said.
struct ChatGPTSession: Equatable, Identifiable, Sendable {
    var record: ChatGPTSessionRecord
    var state: ChatGPTSessionState
    /// Its agents still at work: running, as the hook says, and not gone quiet.
    var agentsAtWork: [ChatGPTAgent] = []
    /// Its commands left running, the oldest first: those the hook listed that the
    /// rollout has not seen end, once left a moment.
    var terminals: [ChatGPTShell] = []
    /// The thread's goal, as Codex's database last said; `nil` without one.
    var goal: ChatGPTGoal?
    /// How many prompts wait in its queue.
    var queuedCount = 0
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

    /// The turn's steps so far, while it goes on.
    var history: [ChatGPTHistoryEntry] { state == .idle ? [] : record.history }
    /// The prompts waiting their turn, while one goes on.
    var queued: Int { state == .idle ? 0 : queuedCount }
    /// How far the session has got, by the best measure there is: its plan; else, while
    /// any is at work, how many of the turn's agents are done, of two or more. `nil`
    /// without either. A goal's use of its token budget is no such measure: a goal may
    /// be met with most of it left, or run out of it unmet.
    var progress: ChatGPTProgress? {
        if !plan.isEmpty { return ChatGPTProgress(done: record.planDone, total: plan.count, source: .plan) }
        let atWork = Set(agentsAtWork.map(\.id))
        let counted = record.agents.filter { atWork.contains($0.id) || !$0.isRunning }
        if !atWork.isEmpty, counted.count >= 2 {
            return ChatGPTProgress(done: counted.filter { !$0.isRunning }.count, total: counted.count, source: .agents)
        }
        return nil
    }
}

/// How far a session has got: so many of so many, of its plan's steps or its agents.
struct ChatGPTProgress: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case plan
        case agents
    }

    var done: Int
    var total: Int
    var source: Source

    var fraction: Double { total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0 }
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
///
/// A session is shown while it is under way, while its agents are at work, and while a
/// goal keeps Codex at it between the turns it starts itself. Its commands left running
/// are listed under it, but never keep it shown by themselves: a server may run for
/// days. One ends when its hook or the rollout says so, or its Codex goes.
enum ChatGPTLiveness {
    /// A turn silent this long, in its hooks and its rollout, is taken to be over.
    static let staleAfter: TimeInterval = 10 * 60
    /// The same while a tool is under way and Codex is still running.
    static let longStepStaleAfter: TimeInterval = 60 * 60
    /// A session's file this old is ignored: its session ended without saying so.
    static let forgottenAfter: TimeInterval = 24 * 3600
    /// An agent silent this long is marked as quiet, as long as a turn is given. Less
    /// would mark an agent simply running a test or a build.
    static let quietAfter: TimeInterval = staleAfter
    /// A command is listed as left running only after this: its end, which the hook
    /// hears in the background, may land a moment after the next tool's start.
    static let terminalSettle: TimeInterval = 2
    /// An active goal updated this recently keeps its session shown between turns.
    static let goalFreshFor: TimeInterval = 2 * 60

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

    /// The session's commands left running: those its file lists, less those `ended`
    /// (by the rollout), once left for `terminalSettle`; one that was asked permission
    /// for only once the rollout has it `running`, since one declined never ran. A
    /// session whose Codex has gone has none.
    static func terminals(
        _ record: ChatGPTSessionRecord, ended: Set<String>, running: Set<String> = [], process: Bool?, now: Date
    ) -> [ChatGPTShell] {
        guard process != false else { return [] }
        return record.shells
            .filter { !ended.contains($0.id) && (!$0.asked || running.contains($0.id))
                && now.timeIntervalSince($0.since) >= terminalSettle }
            .sorted { $0.started < $1.started }
    }

    /// Whether `goal` keeps its session shown: active, updated in the last two minutes,
    /// and its Codex not gone.
    static func goalKeepsShown(_ goal: ChatGPTGoal?, process: Bool?, now: Date) -> Bool {
        guard let goal, goal.status == .active, process != false else { return false }
        return now.timeIntervalSince(goal.updated) <= goalFreshFor
    }

    /// The sessions to show, in the order they are shown: those waiting for permission
    /// first, then those waiting for an answer, the longest waiting first; then those
    /// working, the longest going first; then those with only agents or a goal at work,
    /// the oldest first. The first is the one the compact island speaks for.
    static func sessions(
        _ records: [ChatGPTSessionRecord], rollouts: [String: ChatGPTRolloutProbe] = [:],
        processes: [String: Bool] = [:], commandEnds: [String: Set<String>] = [:],
        commandsRunning: [String: Set<String>] = [:], goals: [String: ChatGPTGoal] = [:], queued: [String: Int] = [:], now: Date
    ) -> [ChatGPTSession] {
        let shown = records.compactMap { record -> ChatGPTSession? in
            guard !isForgotten(record, now: now), processes[record.id] != false else { return nil }
            let process = processes[record.id]
            let state = state(of: record, rollout: rollouts[record.id], process: process, now: now)
            let agents = agentsAtWork(record, process: process, now: now)
            let goal = goals[record.id]
            guard state != .idle || !agents.isEmpty || goalKeepsShown(goal, process: process, now: now)
            else { return nil }
            return ChatGPTSession(
                record: record, state: state, agentsAtWork: agents,
                terminals: terminals(record, ended: commandEnds[record.id] ?? [],
                                     running: commandsRunning[record.id] ?? [], process: process, now: now),
                goal: goal, queuedCount: queued[record.id] ?? 0)
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
        sessions(snapshot.records, rollouts: snapshot.rollouts, processes: snapshot.processes,
                 commandEnds: snapshot.commandEnds, commandsRunning: snapshot.commandsRunning, goals: snapshot.goals, queued: snapshot.queued, now: now)
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
        /// or its thread has an active goal, while it is not shown, and it comes back if
        /// it carries on; or a session that ended without saying so is let go once a day
        /// old.
        case loosely
    }

    /// How `snapshot` needs watching; `nil` when not at all.
    static func watch(_ snapshot: ChatGPTSessionSnapshot, now: Date) -> Watch? {
        if !sessions(snapshot, now: now).isEmpty { return .closely }
        let hidden = snapshot.records.contains {
            ($0.state != .idle || !$0.runningAgents.isEmpty || snapshot.goals[$0.id]?.status == .active)
                && !isForgotten($0, now: now) && snapshot.processes[$0.id] != false
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
        case .goal: return "Working on the goal"
        case .other:
            if let words = agentTools[bare(name)] { return words }
            let readable = readable(name)
            return readable.isEmpty ? "Working" : "Using \(readable)"
        }
    }

    /// The tools for agents that are neither a spawn nor a wait, by name.
    private static let agentTools = [
        "list_agents": "Checking on agents",
        "send_message": "Messaging an agent",
        "send_input": "Messaging an agent",
        "followup_task": "Giving an agent more to do",
        "interrupt_agent": "Stopping an agent",
        "close_agent": "Closing an agent",
        "resume_agent": "Resuming an agent",
    ]

    /// A tool's name without the namespace Codex glues to the front of the tools for
    /// agents: "collaborationlist_agents" as "list_agents".
    static func bare(_ name: String) -> String {
        for prefix in ["collaboration", "multi_agent_v1"] where name.hasPrefix(prefix) && name.count > prefix.count {
            return String(name.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }
        return name
    }

    /// A tool's or a task's name as words: "write_stdin" as "write stdin".
    static func readable(_ name: String) -> String {
        bare(name).replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
