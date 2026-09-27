import Foundation

/// What a Claude Code session is doing, as its hook last said.
enum ClaudeSessionState: String, Equatable, Sendable {
    /// A prompt has been sent and the reply is not finished.
    case working
    /// Claude is waiting for permission to use a tool.
    case needsPermission
    /// Claude, or one of its agents, has asked a question and is waiting for the answer.
    case waitingForInput
    /// The reply is finished, or the session has not been asked anything yet.
    case idle

    /// Waiting on the person rather than on Claude.
    var needsYou: Bool { self == .needsPermission || self == .waitingForInput }
}

/// A background workflow a session has running, as Claude Code lists it with every
/// hook event.
struct ClaudeWorkflow: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// What it was started to do, in a sentence or two.
    var summary: String
    var status: String
    /// When the hook first saw it listed: near enough when it started, since it is
    /// listed with the next event after that, and agents stop often.
    var firstSeen: Date

    var isRunning: Bool { status == "running" }
}

/// Anything else a session has running in the background, as Claude Code lists it with
/// its Stop and SubagentStop hooks: an agent sent off to work on its own, a command left
/// running, a monitor. The hook keeps workflows apart, in `ClaudeWorkflow`, as it always
/// has.
struct ClaudeBackgroundTask: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// An agent sent off in the background: the task's id is the agent's.
        case agent
        /// A shell command left running.
        case shell
        /// Anything else, by Claude Code's word for it: "monitor", "MCP task".
        case other(String)

        init(_ label: String) {
            switch label {
            case "subagent": self = .agent
            case "shell": self = .shell
            default: self = .other(label)
            }
        }
    }

    var id: String
    var kind: Kind
    /// What it was started to do; `""` when Claude Code gave only the command itself,
    /// which the hook does not keep.
    var summary: String
    var status: String
    /// When the hook first saw it listed.
    var firstSeen: Date
    /// For a command with nothing said of it but itself, the program it runs, which the
    /// hook keeps in place of the command: "npm", "xcodebuild".
    var program = ""

    /// Claude Code lists only what is in flight: running, or about to be.
    var isRunning: Bool { status == "running" || status == "pending" }
}

/// One session's file, as `Scripts/claude-code-hook.sh` writes it. Its header lists the
/// fields. Anything missing reads as empty, so a file from a later version of the hook
/// with more in it, or less, still reads.
struct ClaudeSessionRecord: Equatable, Identifiable, Sendable {
    var id: String
    /// The git repository's folder name, or "" for Claude's scratch folders.
    var project: String = ""
    var cwd: String = ""
    var transcriptPath: String = ""
    /// The bundle id of the app Claude Code runs in, or "".
    var hostApp: String = ""
    /// Claude Code's own process, and when it started; `nil` when the hook could not
    /// find it (or an earlier hook did not look).
    var pid: Int32?
    var pidStarted: Date?
    var state: ClaudeSessionState = .idle
    /// When the session entered `state`.
    var since: Date
    /// When the latest prompt was sent; `nil` before the first.
    var turnStarted: Date?
    /// The latest hook event.
    var updated: Date
    /// The latest prompt's first line, plain.
    var prompt: String = ""
    /// The start of the last reply, while idle.
    var reply: String = ""
    var workflows: [ClaudeWorkflow] = []
    /// Its other background tasks, as the latest event listed them.
    var tasks: [ClaudeBackgroundTask] = []

    /// When the turn on show began: the prompt's time, or failing that the state's.
    var turnStart: Date { turnStarted ?? since }
    var runningWorkflows: [ClaudeWorkflow] { workflows.filter(\.isRunning) }
    var runningAgents: [ClaudeBackgroundTask] { tasks.filter { $0.isRunning && $0.kind == .agent } }
    /// Commands, monitors and the like: shown under a session shown anyway, but not
    /// enough to show it, since a server left running can run for days.
    var runningOthers: [ClaudeBackgroundTask] { tasks.filter { $0.isRunning && $0.kind != .agent } }
    /// Workflows or agents at work in the background: enough to show the session.
    var hasBackgroundWork: Bool { !runningWorkflows.isEmpty || !runningAgents.isEmpty }
    /// Claude's scratch folders have no project; they are named by their prompt.
    var isScratch: Bool { project.isEmpty }
}

extension ClaudeSessionRecord: Decodable {
    private enum Keys: String, CodingKey {
        case sessionId, project, cwd, transcriptPath, hostApp, pid, pidStarted, state, since, turnStarted, updated
        case prompt, reply, workflows, tasks
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
        self.state = ClaudeSessionState(rawValue: state) ?? .idle
        let updated = (try? c.decodeIfPresent(Double.self, forKey: .updated)).flatMap { $0 }
        let since = (try? c.decodeIfPresent(Double.self, forKey: .since)).flatMap { $0 } ?? updated
        guard let updated, let since else {
            throw DecodingError.dataCorruptedError(forKey: .updated, in: c, debugDescription: "No times")
        }
        self.updated = Date(timeIntervalSince1970: updated)
        self.since = Date(timeIntervalSince1970: since)
        turnStarted = (try? c.decodeIfPresent(Double.self, forKey: .turnStarted)).flatMap { $0 }
            .map(Date.init(timeIntervalSince1970:))
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        reply = (try? c.decodeIfPresent(String.self, forKey: .reply)) ?? ""
        workflows = ((try? c.decodeIfPresent([Lenient<ClaudeWorkflow>].self, forKey: .workflows)) ?? [])
            .compactMap(\.value)
        tasks = ((try? c.decodeIfPresent([Lenient<ClaudeBackgroundTask>].self, forKey: .tasks)) ?? [])
            .compactMap(\.value)
    }
}

extension ClaudeBackgroundTask: Decodable {
    private enum Keys: String, CodingKey {
        case id, type, description, status, firstSeen, program
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = Kind((try? c.decodeIfPresent(String.self, forKey: .type)) ?? "")
        summary = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        firstSeen = ((try? c.decodeIfPresent(Double.self, forKey: .firstSeen)).flatMap { $0 })
            .map(Date.init(timeIntervalSince1970:)) ?? .distantPast
        program = (try? c.decodeIfPresent(String.self, forKey: .program)) ?? ""
    }
}

extension ClaudeWorkflow: Decodable {
    private enum Keys: String, CodingKey {
        case id, name, description, status, firstSeen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        summary = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        firstSeen = ((try? c.decodeIfPresent(Double.self, forKey: .firstSeen)).flatMap { $0 })
            .map(Date.init(timeIntervalSince1970:)) ?? .distantPast
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

// MARK: - Transcripts

/// What a session's transcripts say about it, beyond what its hooks do. Claude Code
/// writes the transcript as it goes: each message, the person's and Claude's, as it is
/// sent, with bookkeeping of its own in between. An agent Claude sends off keeps a
/// transcript of its own, in a folder beside the session's, and the session's says
/// nothing more until the agent is done; nor while a command runs.
struct ClaudeTranscriptProbe: Equatable, Sendable {
    /// When the transcript was last written to, by anything.
    var modified: Date?
    /// When the last message in it was written: a prompt, a reply, a tool's result.
    var lastMessage: Date?
    /// Whether that message is the note Claude Code leaves when a turn is interrupted
    /// (Esc), which ends the turn without the Stop hook firing.
    var interrupted = false
    /// The tools Claude's latest calls went to that have not answered yet: a command
    /// running, an agent at work, or a call waiting for permission. Empty once the
    /// turn has moved past them.
    var pendingTools: [String] = []
    /// When one of the session's agents last wrote to its transcript. Its background
    /// workflows' agents, and the agents it has sent off in the background, are left out:
    /// they run beside the turn, not in it.
    var agentsModified: Date?

    /// Claude is waiting on a tool.
    var awaitsTool: Bool { !pendingTools.isEmpty }
    /// Claude is waiting on one agent and nothing else, so whatever an agent writes is
    /// that one going on.
    var awaitsOneAgent: Bool {
        pendingTools.count == 1 && ClaudeTranscript.agentTools.contains(pendingTools[0])
    }
}

enum ClaudeTranscript {
    /// How much of the end of a transcript is read for its last message: a line holding
    /// a long tool result can run to hundreds of kilobytes, so more is read where the
    /// first piece holds no whole message.
    static let tailLengths = [64 * 1024, 1024 * 1024]
    /// The tool that sends an agent off, by its name and its earlier one.
    static let agentTools: Set<String> = ["Agent", "Task"]
    private static let interruptionNote = "[Request interrupted by user"
    /// How many messages before the last are looked through for the calls it answers or
    /// makes: Claude writes each part of a reply (its thinking, its words, each call)
    /// as a line of its own, and each result comes back as one.
    private static let lookBack = 40
    /// Past this many agents, a session's folder is not looked through further.
    private static let agentFileLimit = 2000

    /// Looks at the transcript at `path`. Called off the main thread. `known` is the
    /// last look at it, reused while the file has not changed since.
    static func probe(path: String, known: (probe: ClaudeTranscriptProbe, size: Int64)?) -> (probe: ClaudeTranscriptProbe, size: Int64)? {
        guard !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if let known, known.probe.modified == modified, known.size == size { return known }
        var probe = ClaudeTranscriptProbe(modified: modified)
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            for length in tailLengths {
                let offset = max(0, size - Int64(length))
                try? handle.seek(toOffset: UInt64(offset))
                guard let data = try? handle.readToEnd() else { break }
                if let last = lastMessage(in: data, isWhole: offset == 0) {
                    probe.lastMessage = last.date
                    probe.interrupted = last.interrupted
                    probe.pendingTools = last.pendingTools
                    break
                }
                if offset == 0 { break }
            }
        }
        return (probe, size)
    }

    /// The end of a transcript, as `lastMessage(in:isWhole:)` reads it.
    struct Last: Equatable {
        var date: Date
        var interrupted: Bool
        var pendingTools: [String]
    }

    /// The last message in `data`, the end of a transcript: its time, whether it is the
    /// note an interruption leaves, and the tools Claude's latest calls went to that
    /// have not answered in the results after them. The first line is skipped unless
    /// `data` is the whole file, since it is likely a piece of a longer one; so is a
    /// last line still being written. Agents' messages, where an older Claude Code
    /// kept them in the session's own transcript, are passed over.
    static func lastMessage(in data: Data, isWhole: Bool) -> Last? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !isWhole, !lines.isEmpty { lines.removeFirst() }
        let user = Data(#""type":"user""#.utf8)
        let assistant = Data(#""type":"assistant""#.utf8)
        var last: Last?
        var answered: Set<String> = []
        var calls: [(id: String, name: String)] = []
        var looked = 0
        for line in lines.reversed() {
            // Only a message's own type is spelt this way: inside the JSON strings of
            // its content, the quotes are escaped.
            guard line.range(of: user) != nil || line.range(of: assistant) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  object["isSidechain"] as? Bool != true
            else { continue }
            if last == nil {
                guard let stamp = object["timestamp"] as? String, let date = parseDate(stamp) else { continue }
                let interrupted = type == "user" && text(of: object).hasPrefix(interruptionNote)
                last = Last(date: date, interrupted: interrupted, pendingTools: [])
                if type == "user" {
                    // A prompt, or the note: nothing is pending. Results: see what for.
                    let results = resultIDs(in: object)
                    if results.isEmpty { break }
                    answered.formUnion(results)
                } else {
                    calls += toolCalls(in: object)
                }
                continue
            }
            looked += 1
            guard looked <= lookBack else { break }
            if type == "user" {
                // Results before any of Claude's calls answer them; once past the
                // calls, a message of the person's (or an earlier result) is the start.
                let results = resultIDs(in: object)
                guard calls.isEmpty, !results.isEmpty else { break }
                answered.formUnion(results)
            } else {
                calls += toolCalls(in: object)
            }
        }
        guard var found = last else { return nil }
        found.pendingTools = calls.reversed().filter { !answered.contains($0.id) }.map { $0.name }
        return found
    }

    /// When the session's agents last wrote: their transcripts are the `agent-*.jsonl`
    /// files in a `subagents` folder named after the session's own transcript, beside it.
    /// Background workflows' agents are further in, and not looked at; nor are those of
    /// the agents the hook lists as sent off in the background, by their ids, `background`.
    /// Called off the main thread.
    static func agentsModified(transcriptPath: String, background: Set<String> = []) -> Date? {
        guard transcriptPath.hasSuffix(".jsonl") else { return nil }
        let folder = URL(fileURLWithPath: String(transcriptPath.dropLast(".jsonl".count)), isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        return files.lazy
            .filter { file in
                let name = file.lastPathComponent
                guard name.hasPrefix("agent-"), file.pathExtension == "jsonl" else { return false }
                return background.isEmpty || !background.contains(String(name.dropFirst(6).dropLast(6)))
            }
            .prefix(agentFileLimit)
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    /// A message's text: its content as a string, or its first text block's.
    private static func text(of message: [String: Any]) -> String {
        let content = (message["message"] as? [String: Any])?["content"]
        if let string = content as? String { return string }
        return blocks(of: message).lazy.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first ?? ""
    }

    private static func blocks(of message: [String: Any]) -> [[String: Any]] {
        (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    /// Claude's tool calls in a message, by their ids and the tools' names.
    private static func toolCalls(in message: [String: Any]) -> [(id: String, name: String)] {
        blocks(of: message).compactMap { block in
            guard block["type"] as? String == "tool_use", let id = block["id"] as? String else { return nil }
            return (id, block["name"] as? String ?? "")
        }
    }

    /// The calls a message of results answers.
    private static func resultIDs(in message: [String: Any]) -> Set<String> {
        Set(blocks(of: message).compactMap { block in
            block["type"] as? String == "tool_result" ? block["tool_use_id"] as? String : nil
        })
    }

    private static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - Processes

/// Claude Code's own process, as the hook found it: a session whose process has gone
/// is over, whatever its file last said, since nothing is left to say otherwise.
enum ClaudeProcess {
    /// How far the start the hook worked out, from `ps`'s whole seconds, may be from the
    /// process's own. A number given to a new process is never given within seconds of
    /// the last one with it starting.
    static let startSlack: TimeInterval = 5

    /// Whether the session's Claude Code is still running: `nil` when its file names no
    /// process. Called off the main thread.
    static func isRunning(_ record: ClaudeSessionRecord) -> Bool? {
        guard let pid = record.pid else { return nil }
        guard let started = startTime(of: pid) else { return false }
        guard let recorded = record.pidStarted else { return true }
        return abs(started.timeIntervalSince(recorded)) <= startSlack
    }

    /// When the process `pid` started, or `nil` if there is none (or only its remains,
    /// waiting to be collected).
    static func startTime(of pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0,
              Int32(info.kp_proc.p_stat) != SZOMB
        else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}

// MARK: - What is shown

/// A session as the island shows it: its file, and what it is doing now, which is not
/// always what the file last said.
struct ClaudeSession: Equatable, Identifiable, Sendable {
    var record: ClaudeSessionRecord
    var state: ClaudeSessionState
    /// How far its running workflows and background agents have got, by task id, where
    /// their files say (`ClaudeTaskProgressReader`).
    var progress: [String: ClaudeTaskProgress] = [:]
    var id: String { record.id }
    var runningWorkflows: [ClaudeWorkflow] { record.runningWorkflows }
    var runningAgents: [ClaudeBackgroundTask] { record.runningAgents }
    var runningOthers: [ClaudeBackgroundTask] { record.runningOthers }

    func progress(of workflow: ClaudeWorkflow) -> ClaudeWorkflowProgress? { progress[workflow.id]?.workflow }
    func progress(of task: ClaudeBackgroundTask) -> ClaudeAgentProgress? { progress[task.id]?.agent }

    /// Whether the running workflow or agent `id` is still at work: the hook lists it as
    /// running, and its files do not say it has since ended or finished.
    func isAtWork(_ id: String) -> Bool { progress[id]?.isAtWork ?? true }
    /// The running workflows and background agents still at work, which the compact
    /// island counts and which keep a session done with its reply shown.
    var workflowsAtWork: [ClaudeWorkflow] { runningWorkflows.filter { isAtWork($0.id) } }
    var agentsAtWork: [ClaudeBackgroundTask] { runningAgents.filter { isAtWork($0.id) } }
    var hasWorkAtWork: Bool { !workflowsAtWork.isEmpty || !agentsAtWork.isEmpty }
    /// Whether any of its background work at work is followed in its files, and so worth
    /// reading again every few seconds.
    var isFollowed: Bool { progress.values.contains(where: \.isAtWork) }
}

/// Which sessions are live, from their files, their transcripts and their processes.
///
/// The hooks say when a turn starts, when Claude needs the person and when a reply is
/// finished, but not everything: an interrupted turn (Esc) sends no Stop, nor does a
/// session whose terminal was closed under it, and nothing is sent when a permission
/// has been given and Claude carries on. The rest comes from elsewhere. A session whose
/// Claude Code has gone is over. A turn whose last message is the note an interruption
/// leaves is over; so is one whose transcript, and its agents', have been quiet for ten
/// minutes, unless Claude Code is still there and waiting on a tool (a long build, say).
/// A session waiting for the person is under way again once its transcript has a
/// message after the asking, which is when the approved tool has finished, or once the
/// one agent it is waiting on writes again.
enum ClaudeLiveness {
    /// A turn silent this long, in its transcripts and its hooks, is taken to be over.
    static let staleAfter: TimeInterval = 10 * 60
    /// A session's file this old is ignored: its session ended without saying so.
    static let forgottenAfter: TimeInterval = 24 * 3600
    /// The hook's Notification comes a few seconds after the message that asked, and
    /// the two clocks are the same one; a message later than this is a new one.
    static let movedOnMargin: TimeInterval = 2

    static func isForgotten(_ record: ClaudeSessionRecord, now: Date) -> Bool {
        now.timeIntervalSince(record.updated) > forgottenAfter
    }

    /// What `record`'s session is doing now. `process` is whether its Claude Code is
    /// still running, `nil` when not known.
    static func state(
        of record: ClaudeSessionRecord, transcript: ClaudeTranscriptProbe?, process: Bool? = nil, now: Date
    ) -> ClaudeSessionState {
        if process == false { return .idle }
        var state = record.state
        if state.needsYou, let transcript {
            let asked = record.since.addingTimeInterval(movedOnMargin)
            if let last = transcript.lastMessage, last > asked {
                state = transcript.interrupted ? .idle : .working
            } else if transcript.awaitsOneAgent, let agents = transcript.agentsModified, agents > asked {
                state = .working
            }
        }
        guard state == .working else { return state }
        if let transcript, transcript.interrupted, let last = transcript.lastMessage, last > record.turnStart {
            return .idle
        }
        if process == true, transcript?.awaitsTool == true { return .working }
        let lastSign = [record.since, record.updated, transcript?.modified, transcript?.agentsModified]
            .compactMap { $0 }.max() ?? record.updated
        return now.timeIntervalSince(lastSign) > staleAfter ? .idle : .working
    }

    /// The sessions to show, in the order they are shown: those waiting for permission
    /// first, then those waiting for an answer, the longest waiting first; then those
    /// working, the longest going first; then those with only workflows or background
    /// agents at work, the oldest first: running, as the hook says, and not ended as their
    /// files say since. The first is the one the compact island speaks for, so any session
    /// waiting for permission puts up the hand. A session whose Claude Code has gone is not
    /// shown, workflows and all.
    static func sessions(
        _ records: [ClaudeSessionRecord], transcripts: [String: ClaudeTranscriptProbe],
        processes: [String: Bool] = [:], progress: [String: [String: ClaudeTaskProgress]] = [:], now: Date
    ) -> [ClaudeSession] {
        let shown = records.compactMap { record -> ClaudeSession? in
            guard !isForgotten(record, now: now), processes[record.id] != false else { return nil }
            let state = state(of: record, transcript: transcripts[record.id], process: processes[record.id], now: now)
            let session = ClaudeSession(record: record, state: state, progress: progress[record.id] ?? [:])
            guard state != .idle || session.hasWorkAtWork else { return nil }
            return session
        }
        return shown.sorted { a, b in
            let (ra, rb) = (rank(a.state), rank(b.state))
            if ra != rb { return ra < rb }
            let (ta, tb) = (orderTime(a), orderTime(b))
            if ta != tb { return ta < tb }
            return a.id < b.id
        }
    }

    static func sessions(_ snapshot: ClaudeSessionSnapshot, now: Date) -> [ClaudeSession] {
        sessions(snapshot.records, transcripts: snapshot.transcripts, processes: snapshot.processes,
                 progress: snapshot.progress, now: now)
    }

    private static func rank(_ state: ClaudeSessionState) -> Int {
        switch state {
        case .needsPermission: 0
        case .waitingForInput: 1
        case .working: 2
        case .idle: 3
        }
    }

    private static func orderTime(_ session: ClaudeSession) -> Date {
        switch session.state {
        case .needsPermission, .waitingForInput: session.record.since
        case .working: session.record.turnStart
        case .idle:
            (session.workflowsAtWork.map(\.firstSeen) + session.agentsAtWork.map(\.firstSeen)).min()
                ?? session.record.since
        }
    }

    /// How often the files and transcripts are read again, beyond whenever the folder
    /// changes (a new prompt, or anything else from the hook).
    enum Watch: Equatable {
        /// Every few seconds: a session shown is working or waiting on the person, so a
        /// turn that goes quiet is seen to end, and one given its permission to go on;
        /// or its workflows or agents are at work, and how far they have got is followed
        /// in their files.
        case closely
        /// Every minute: only workflows or agents show whose files say nothing, and a
        /// session that ended without saying so is let go once a day old; or a session's
        /// file says it is under way, or has background work running, while it is not
        /// shown, having gone quiet or its work having ended as its files say, and it
        /// comes back if it carries on.
        case loosely
    }

    /// How `snapshot` needs watching; `nil` when not at all.
    static func watch(_ snapshot: ClaudeSessionSnapshot, now: Date) -> Watch? {
        let shown = sessions(snapshot, now: now)
        if shown.contains(where: { $0.state != .idle || $0.isFollowed }) { return .closely }
        if !shown.isEmpty { return .loosely }
        let hidden = snapshot.records.contains {
            ($0.state != .idle || $0.hasBackgroundWork) && !isForgotten($0, now: now)
                && snapshot.processes[$0.id] != false
        }
        return hidden ? .loosely : nil
    }
}
