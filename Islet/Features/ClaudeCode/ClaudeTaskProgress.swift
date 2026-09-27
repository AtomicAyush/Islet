import Foundation

// MARK: - What is shown

/// How far a background workflow has got, from the files Claude Code keeps for its run:
/// the script it was started with, whose `meta` plans its phases by title, and its
/// journal, a line for each agent the script starts, finishes or gives up on. A run tried
/// again counts only what this try has started, and the agents done before it.
struct ClaudeWorkflowProgress: Equatable, Sendable {
    /// How a run ended, as the record Claude Code writes of it then says.
    enum Outcome: Equatable, Sendable {
        case completed
        case failed
        /// Stopped before it was done, or ended some other way.
        case stopped

        init(_ status: String) {
            switch status {
            case "completed": self = .completed
            case "failed": self = .failed
            default: self = .stopped
            }
        }
    }

    /// The phases the script plans, by title, in order; empty when it could not be read.
    var phases: [String] = []
    /// The phase under way: the furthest one, of those planned, that an agent has been
    /// started in; or where none were planned, the latest one named.
    var phase: String?
    /// Its place among `phases`, from 0; `nil` when it is not one of them.
    var phaseIndex: Int?
    /// The agents started in that phase, and how many of them are done.
    var phaseStarted = 0
    var phaseDone = 0
    /// Every agent the run has started, each counted once however often it was tried,
    /// and how many of them are done.
    var started = 0
    var done = 0
    /// Agents the run gave up on.
    var failed = 0
    /// Agents started again after a try stalled or broke, and still going.
    var retrying = 0
    /// The agents at work now, by their labels, the earliest started first.
    var running: [String] = []
    /// When this try of the run began, as near as its files say.
    var began: Date?
    /// How the run ended, once its record says so for this task; `nil` while it goes on.
    var outcome: Outcome?

    var isEnded: Bool { outcome != nil }

    /// How far along, from 0 to 1: through the planned phases, the one under way counting
    /// for the share of its agents that are done; or, where no phases are known, the share
    /// of the agents started that are done. `nil` before any agent has started.
    var fraction: Double? {
        if let phaseIndex, !phases.isEmpty {
            let within = phaseStarted > 0 ? Double(phaseDone) / Double(phaseStarted) : 0
            return min(1, (Double(phaseIndex) + within) / Double(phases.count))
        }
        guard started > 0 else { return nil }
        return Double(done) / Double(started)
    }
}

/// What an agent sent off in the background is doing, from its own transcript.
struct ClaudeAgentProgress: Equatable, Sendable {
    /// What it was sent to do, from the file Claude Code keeps beside its transcript.
    var summary = ""
    /// Its latest tool call, in a few words: "Editing IslandTheme.swift".
    var doing: String?
    /// How many tools it has called.
    var steps = 0
    /// Whether `steps` is only of the end of a transcript too long to read whole.
    var stepsAtLeast = false
    /// Whether its latest message ended its turn: it is done, and Claude Code has not yet
    /// said so to the hook.
    var finished = false
    /// When it started, as near as its files say.
    var began: Date?
    /// When its transcript was last written.
    var modified: Date?

    /// How long it has gone without writing, at `now`, once that is as long as a turn
    /// may go quiet before it is taken to be over; `nil` before then, or once it has
    /// finished. It may be waiting on a long command, or stuck.
    func quiet(at now: Date) -> TimeInterval? {
        guard !finished, let modified else { return nil }
        let quiet = now.timeIntervalSince(modified)
        return quiet >= ClaudeLiveness.staleAfter ? quiet : nil
    }
}

/// A background task's progress, as its files say.
enum ClaudeTaskProgress: Equatable, Sendable {
    case workflow(ClaudeWorkflowProgress)
    case agent(ClaudeAgentProgress)

    /// Whether its files say it is still at work: a workflow whose run has not ended, an
    /// agent that has not finished.
    var isAtWork: Bool {
        switch self {
        case .workflow(let progress): !progress.isEnded
        case .agent(let progress): !progress.finished
        }
    }

    var workflow: ClaudeWorkflowProgress? {
        if case .workflow(let progress) = self { return progress }
        return nil
    }

    var agent: ClaudeAgentProgress? {
        if case .agent(let progress) = self { return progress }
        return nil
    }
}

// MARK: - Following files

/// A file read a piece at a time as it grows: where the next read starts, and enough
/// about it to tell when it has been written afresh rather than added to.
struct ClaudeFollowedFile: Equatable, Sendable {
    /// Just past the last whole line read.
    var offset: Int64 = 0
    var size: Int64 = 0
    var modified: Date?
    /// Its first bytes, as last read.
    var head = Data()

    static let headLength = 64

    /// The whole lines added to the file at `path` since `known`, and how it now stands;
    /// `nil` when there is no such file. A file not followed before is read from
    /// `lookBack` bytes before its end (from its start when `nil`); one that has shrunk,
    /// or whose first bytes have changed, is read afresh the same way, and `fresh` says
    /// so, so what was gathered from it before is dropped. At most `limit` bytes are read,
    /// the latest; a line cut at the start of what is read is skipped, and so is a last
    /// line still being written, which is read whole next time.
    static func read(
        _ path: String, known: ClaudeFollowedFile?, lookBack: Int64? = nil, limit: Int64
    ) -> (lines: [Data], file: ClaudeFollowedFile, fresh: Bool, cut: Bool)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes[.modificationDate] as? Date
        if let known, known.size == size, known.modified == modified { return ([], known, false, false) }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headLength)) ?? Data()

        var fresh = known == nil
        var start: Int64
        // A file added to starts as it did; one written afresh most likely does not.
        if let known, size >= known.offset, head.starts(with: known.head) {
            start = known.offset
        } else {
            fresh = true
            start = lookBack.map { max(0, size - $0) } ?? 0
        }
        var cut = start > 0 && fresh
        if size - start > limit {
            start = size - limit
            cut = true
        }
        // One byte before the start shows whether the line there is whole.
        let from = max(0, start - 1)
        try? handle.seek(toOffset: UInt64(from))
        let data = (try? handle.read(upToCount: Int(size - from))) ?? Data()
        var file = ClaudeFollowedFile(offset: start, size: size, modified: modified, head: head)
        guard !data.isEmpty else { return ([], file, fresh, cut) }

        let newline = UInt8(ascii: "\n")
        var begin = data.startIndex
        if start > 0 {
            if data[begin] == newline {
                begin = data.index(after: begin)
            } else {
                guard let first = data[begin...].firstIndex(of: newline) else {
                    // No whole line yet: try again from the same place.
                    file.offset = start
                    return ([], file, fresh, cut)
                }
                begin = data.index(after: first)
            }
        }
        guard let last = data[begin...].lastIndex(of: newline) else {
            file.offset = from + Int64(begin - data.startIndex)
            return ([], file, fresh, cut)
        }
        file.offset = from + Int64(last - data.startIndex) + 1
        let lines = data[begin..<last].split(separator: newline, omittingEmptySubsequences: true)
        return (lines.map { Data($0) }, file, fresh, cut)
    }
}

// MARK: - Reading

/// Where a workflow's run keeps its files, from the result Claude Code writes into the
/// session's transcript when it starts one in the background.
struct ClaudeWorkflowLaunch: Equatable, Sendable {
    /// The run's id, which names its folder and its record.
    var runId = ""
    /// The run's folder, holding its journal and its agents' transcripts; `""` when not
    /// said. As launched, it may be in the folder the session was in then, since moved.
    var runFolder: String
    /// The script it runs, `""` when not said.
    var scriptPath: String
    /// When it was launched: for a run tried again, when this try began.
    var date: Date?
    /// For a run found by name that has been tried again since it last ended, when it
    /// ended, the new try beginning after.
    var endedBefore: Date?
}

/// What the last reads of the files behind a session's background tasks found, so each
/// file is read again only from where the last read stopped.
struct ClaudeProgressCache: Sendable {
    /// By session transcript: the workflows started from it, by task id.
    var launches: [String: LaunchIndex] = [:]
    /// By journal.
    var journals: [String: Journal] = [:]
    /// By agent transcript.
    var agents: [String: AgentLog] = [:]
    /// By script: the phases its `meta` plans.
    var plans: [String: Plan] = [:]
    /// By run record: the task it is of, and how the run ended.
    var records: [String: RunRecord] = [:]

    struct LaunchIndex: Sendable {
        var file = ClaudeFollowedFile()
        var launches: [String: ClaudeWorkflowLaunch] = [:]
    }

    struct Plan: Sendable {
        var modified: Date?
        var phases: [String]
    }

    struct RunRecord: Equatable, Sendable {
        var modified: Date?
        var taskId: String
        var status: String
    }

    /// A run's journal, as read so far: each agent it has started, by the key the script
    /// gives it, which stays the same when the agent is tried again.
    struct Journal: Sendable {
        var file = ClaudeFollowedFile()
        var steps: [String: Step] = [:]
        var order: [String] = []
        /// Every start, in order.
        var starts: [Start] = []
        var created: Date?
        /// For a run tried again, how many of `starts` came before the try that began at
        /// `since`, once worked out.
        var earlier: (since: Date, count: Int)?
    }

    struct Start: Equatable, Sendable {
        var key: String
        var agent: String
    }

    struct Step: Equatable, Sendable {
        var label = ""
        var phase: String?
        var tries = 0
        var done = false
        var failed = false
        /// Which start this key's latest was, counting every start in the journal from 1.
        var lastStart = 0
    }

    struct AgentLog: Sendable {
        var file = ClaudeFollowedFile()
        var steps = 0
        var stepsAtLeast = false
        var doing: String?
        var finished = false
        var summary = ""
        var created: Date?
    }
}

/// Reads how far a session's background tasks have got, from the files Claude Code keeps
/// beside the session's transcript, `<session>.jsonl`, in the folder `<session>/`:
///
/// - When Claude starts a workflow in the background, the result it gets back, written
///   into the transcript, gives the task's id, the run's id, folder and script
///   (`"toolUseResult": {"status": "async_launched", "taskId", "runId", "transcriptDir",
///   "scriptPath", …}`). The transcript is not read whole for it: only its last few
///   megabytes, and after that only what is added. The folder and script it names are
///   where the session was then; a session moved to another project since has its runs
///   in its own folder, `subagents/workflows/<run id>/` and `workflows/scripts/`, which
///   are looked in first.
/// - Failing that, a workflow's script is `workflows/scripts/<name>-<run id>.js`, and a
///   run that is still going has its folder, `subagents/workflows/<run id>/`, but not yet
///   its record, `workflows/<run id>.json`, which is written as it ends and names its
///   task (`"taskId"`) and how it ended (`"status"`).
/// - A run's folder has `journal.jsonl`: `{"type":"started","key","agentId","label",
///   "phase"}` as each agent starts (again, with the same key, when it is retried after
///   stalling), `{"type":"result","key",…}` when it is done, `{"type":"failed","key",…}`
///   when the run gives up on it; and each agent's transcript, `agent-<agent id>.jsonl`.
/// - A run can be tried again: it keeps its id, its folder and its journal, and gets a new
///   task and launch. Nothing in the journal marks where the new try began, so the agents'
///   transcripts, each made as its agent started, tell the starts before the launch from
///   those after; and the record of an earlier try, whose task is not this one, does not
///   end it.
/// - The script opens with `export const meta = {…, phases: [{title: '…', …}, …]}`.
/// - An agent sent off in the background has the task's id as its own, and its
///   transcript is `subagents/agent-<id>.jsonl`, with what it was sent to do in
///   `subagents/agent-<id>.meta.json`.
///
/// Anything missing, or not as described, is left out: the task then shows as it did
/// before, by what the hook says of it alone. Called off the main thread.
enum ClaudeTaskProgressReader {
    /// How far back from its end a session's transcript is first looked through for the
    /// workflows it started.
    static let launchLookBack: Int64 = 4 << 20
    /// The most read of any file at once: a longer journal or agent transcript is read
    /// from this far before its end.
    static let readLimit: Int64 = 16 << 20
    /// How much of the start of a script is read for its `meta`.
    static let planLength = 16 * 1024
    /// The largest run record read.
    static let recordLimit = 4 << 20
    /// A journal made this long before its run's launch is an earlier try's; an agent's
    /// transcript made this long before it, an earlier try's agent.
    static let launchSlack: TimeInterval = 60

    /// What the files say of `record`'s running workflows and background agents, by task
    /// id. `cache` is the last read's; what this one used is put in `next`.
    static func read(
        _ record: ClaudeSessionRecord, cache: ClaudeProgressCache, into next: inout ClaudeProgressCache
    ) -> [String: ClaudeTaskProgress] {
        guard record.transcriptPath.hasSuffix(".jsonl"), record.transcriptPath.hasPrefix("/") else { return [:] }
        let folder = String(record.transcriptPath.dropLast(".jsonl".count))
        var progress: [String: ClaudeTaskProgress] = [:]

        let workflows = record.runningWorkflows.filter { isSafe($0.id) }
        if !workflows.isEmpty {
            let launches = self.launches(of: record.transcriptPath, for: workflows.map(\.id), cache: cache, into: &next)
            var found: [(task: String, launch: ClaudeWorkflowLaunch)] = []
            var byName: [ClaudeWorkflow] = []
            for workflow in workflows {
                if let launch = launches[workflow.id].flatMap({ locate($0, in: folder) }) {
                    found.append((workflow.id, launch))
                } else {
                    byName.append(workflow)
                }
            }
            found += runs(for: byName, in: folder, taken: Set(found.map(\.launch.runFolder)), cache: cache, into: &next)
            for (task, launch) in found {
                guard let run = self.workflow(launch, task: task, cache: cache, into: &next) else { continue }
                progress[task] = .workflow(run)
            }
        }
        for task in record.runningAgents where isSafe(task.id) {
            guard let found = agent(task.id, in: folder, cache: cache, into: &next) else { continue }
            progress[task.id] = .agent(found)
        }
        return progress
    }

    /// Task and run ids name files, so only plain ones are used.
    static func isSafe(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && !id.hasPrefix(".")
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
    }

    // MARK: Workflows

    /// The runs of the workflows `wanted` from the session's transcript. It is read only
    /// while one of them has not been found in it, and then only as far as it is new.
    static func launches(
        of transcript: String, for wanted: [String], cache: ClaudeProgressCache, into next: inout ClaudeProgressCache
    ) -> [String: ClaudeWorkflowLaunch] {
        var index = cache.launches[transcript] ?? ClaudeProgressCache.LaunchIndex()
        if cache.launches[transcript] == nil || wanted.contains(where: { index.launches[$0] == nil }),
           let read = ClaudeFollowedFile.read(
            transcript, known: cache.launches[transcript]?.file, lookBack: launchLookBack, limit: launchLookBack
           ) {
            if read.fresh { index.launches = [:] }
            index.file = read.file
            for line in read.lines {
                if let (id, launch) = launch(in: line) { index.launches[id] = launch }
            }
        }
        next.launches[transcript] = index
        return index.launches
    }

    private static let launchMark = Data(#""async_launched""#.utf8)

    /// A transcript line holding the result of starting a workflow in the background: the
    /// task's id and where its run is.
    static func launch(in line: Data) -> (String, ClaudeWorkflowLaunch)? {
        guard line.range(of: launchMark) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let result = object["toolUseResult"] as? [String: Any],
              result["status"] as? String == "async_launched",
              let id = result["taskId"] as? String, isSafe(id)
        else { return nil }
        let folder = (result["transcriptDir"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } ?? ""
        let run = (result["runId"] as? String).flatMap { isSafe($0) ? $0 : nil }
            ?? (folder as NSString).lastPathComponent
        guard isSafe(run) else { return nil }
        let script = (result["scriptPath"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } ?? ""
        let date = (object["timestamp"] as? String).flatMap(parseDate)
        return (id, ClaudeWorkflowLaunch(runId: run, runFolder: folder, scriptPath: script, date: date))
    }

    /// Where `launch`'s run is now: in the session's own folder, `folder`, where a session
    /// moved since keeps it, or else where the launch said; `nil` when it has no journal
    /// in either. Its script likewise, `""` when in neither.
    static func locate(_ launch: ClaudeWorkflowLaunch, in folder: String) -> ClaudeWorkflowLaunch? {
        var found = launch
        let own = folder + "/subagents/workflows/" + launch.runId
        if isFile(own + "/journal.jsonl") {
            found.runFolder = own
        } else if launch.runFolder.isEmpty || !isFile(launch.runFolder + "/journal.jsonl") {
            return nil
        }
        let name = (launch.scriptPath as NSString).lastPathComponent
        let scripts = [
            name.hasSuffix(".js") && !name.hasPrefix(".") ? folder + "/workflows/scripts/" + name : nil,
            launch.scriptPath.isEmpty ? nil : launch.scriptPath,
        ]
        found.scriptPath = scripts.compactMap { $0 }.first(where: isFile) ?? ""
        return found
    }

    private static func isFile(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular
    }

    /// Runs for `workflows`, whose launches the transcript does not give, by their
    /// scripts' names: for each, the run whose record says it ended as that task; or
    /// else, the latest first, one still going (no record yet), or one tried again since
    /// its record was written (its journal written later). A run is given to one task
    /// only, and not at all when in `taken`.
    static func runs(
        for workflows: [ClaudeWorkflow], in folder: String, taken: Set<String>,
        cache: ClaudeProgressCache, into next: inout ClaudeProgressCache
    ) -> [(task: String, launch: ClaudeWorkflowLaunch)] {
        var found: [(task: String, launch: ClaudeWorkflowLaunch)] = []
        var taken = taken
        var names: [String] = []
        for workflow in workflows where !names.contains(workflow.name) { names.append(workflow.name) }
        for name in names {
            let group = workflows.filter { $0.name == name }.sorted { $0.firstSeen > $1.firstSeen }
            let tasks = Set(group.map(\.id))
            let runs = self.runs(named: name, in: folder, cache: cache, into: &next)
            for workflow in group {
                let free = runs.filter { !taken.contains($0.launch.runFolder) }
                let own = free.first { $0.record?.taskId == workflow.id }
                let open = free.first { run in
                    guard let record = run.record else { return true }
                    guard !tasks.contains(record.taskId), let ended = record.modified else { return false }
                    return run.written > ended
                }
                guard var run = own ?? open else { continue }
                if own == nil, let record = run.record { run.launch.endedBefore = record.modified }
                taken.insert(run.launch.runFolder)
                found.append((workflow.id, run.launch))
            }
        }
        return found
    }

    /// A run of a workflow found by its script's name.
    struct NamedRun {
        var launch: ClaudeWorkflowLaunch
        /// When its journal was last written.
        var written: Date
        var record: ClaudeProgressCache.RunRecord?
    }

    /// The runs in the session's folder of the workflow called `name`, with a journal,
    /// the one whose journal was written last first.
    static func runs(
        named name: String, in folder: String, cache: ClaudeProgressCache, into next: inout ClaudeProgressCache
    ) -> [NamedRun] {
        guard !name.isEmpty, !name.contains("/") else { return [] }
        let scripts = folder + "/workflows/scripts"
        let prefix = name + "-wf_"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: scripts) else { return [] }
        var runs: [NamedRun] = []
        for file in files where file.hasPrefix(prefix) && file.hasSuffix(".js") {
            let run = String(file.dropFirst(name.count + 1).dropLast(3))
            guard isSafe(run) else { continue }
            let runFolder = folder + "/subagents/workflows/" + run
            guard let written = (try? FileManager.default.attributesOfItem(atPath: runFolder + "/journal.jsonl"))?[
                .modificationDate] as? Date
            else { continue }
            let record = self.record(folder + "/workflows/" + run + ".json", cache: cache, into: &next)
            let launch = ClaudeWorkflowLaunch(runId: run, runFolder: runFolder, scriptPath: scripts + "/" + file)
            runs.append(NamedRun(launch: launch, written: written, record: record))
        }
        return runs.sorted { $0.written > $1.written }
    }

    /// How far the run `launch` points to has got, for the task `task`: ended, where the
    /// run's record says so of this task and not of an earlier try.
    static func workflow(
        _ launch: ClaudeWorkflowLaunch, task: String, cache: ClaudeProgressCache, into next: inout ClaudeProgressCache
    ) -> ClaudeWorkflowProgress? {
        let path = launch.runFolder + "/journal.jsonl"
        guard var journal = self.journal(path, cache: cache, into: &next) else { return nil }
        let phases = launch.scriptPath.isEmpty ? [] : plan(launch.scriptPath, cache: cache, into: &next)
        let earlier = startsBefore(launch, in: &journal)
        next.journals[path] = journal
        var progress = progress(of: journal, phases: phases, after: earlier)
        progress.began = launch.date ?? (launch.endedBefore == nil ? journal.created : nil)
        if let recordPath = recordPath(of: launch),
           let record = record(recordPath, cache: cache, into: &next), record.taskId == task {
            progress.outcome = .init(record.status)
        }
        return progress
    }

    /// How many of the journal's starts came before the try `launch` began, for a run
    /// tried again: 0 for one launched afresh, its journal made as it was. Worked out once
    /// for each try, from the latest start back, by when each start's agent transcript
    /// was made; a start whose transcript is not there yet counts as this try's.
    static func startsBefore(_ launch: ClaudeWorkflowLaunch, in journal: inout ClaudeProgressCache.Journal) -> Int {
        guard let since = launch.date ?? launch.endedBefore, let created = journal.created,
              created < since.addingTimeInterval(-launchSlack)
        else { return 0 }
        if let known = journal.earlier, known.since == since { return known.count }
        var count = 0
        let limit = since.addingTimeInterval(-launchSlack)
        for index in journal.starts.indices.reversed() {
            let agent = journal.starts[index].agent
            guard isSafe(agent),
                  let made = (try? FileManager.default.attributesOfItem(
                    atPath: launch.runFolder + "/agent-" + agent + ".jsonl"))?[.creationDate] as? Date
            else { continue }
            if made < limit {
                count = index + 1
                break
            }
        }
        journal.earlier = (since, count)
        return count
    }

    /// Where the run's record is written as it ends: `workflows/<run id>.json` in the
    /// folder of the session whose `subagents/workflows/` holds the run.
    static func recordPath(of launch: ClaudeWorkflowLaunch) -> String? {
        let tail = "/subagents/workflows/" + launch.runId
        guard !launch.runId.isEmpty, launch.runFolder.hasSuffix(tail) else { return nil }
        return String(launch.runFolder.dropLast(tail.count)) + "/workflows/" + launch.runId + ".json"
    }

    /// A run's record: the task it was of (`""` when not said), and how it ended. Read
    /// again only when it has been written since.
    static func record(
        _ path: String, cache: ClaudeProgressCache, into next: inout ClaudeProgressCache
    ) -> ClaudeProgressCache.RunRecord? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        let modified = attributes[.modificationDate] as? Date
        if let known = next.records[path] ?? cache.records[path], known.modified == modified {
            next.records[path] = known
            return known
        }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= recordLimit,
              let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let record = ClaudeProgressCache.RunRecord(
            modified: modified, taskId: object["taskId"] as? String ?? "", status: object["status"] as? String ?? "")
        next.records[path] = record
        return record
    }

    static func journal(
        _ path: String, cache: ClaudeProgressCache, into next: inout ClaudeProgressCache
    ) -> ClaudeProgressCache.Journal? {
        let known = cache.journals[path]
        guard let read = ClaudeFollowedFile.read(path, known: known?.file, limit: readLimit) else { return nil }
        var journal = read.fresh ? ClaudeProgressCache.Journal() : (known ?? ClaudeProgressCache.Journal())
        journal.file = read.file
        if journal.created == nil {
            journal.created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
        }
        for line in read.lines { add(line, to: &journal) }
        next.journals[path] = journal
        return journal
    }

    /// One journal line. Kinds of line not known here (a run restored after a restart
    /// brackets its old lines with two of them, as Claude Code's own code writes them) are
    /// passed over.
    static func add(_ line: Data, to journal: inout ClaudeProgressCache.Journal) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return }
        let agent = object["agentId"] as? String ?? ""
        let key = (object["key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? agent
        guard !key.isEmpty else { return }
        switch type {
        case "started":
            journal.starts.append(.init(key: key, agent: agent))
            var step = journal.steps[key] ?? ClaudeProgressCache.Step()
            if journal.steps[key] == nil { journal.order.append(key) }
            step.tries += 1
            step.done = false
            step.failed = false
            step.lastStart = journal.starts.count
            if let label = object["label"] as? String, !label.isEmpty { step.label = label }
            if let phase = object["phase"] as? String, !phase.isEmpty { step.phase = phase }
            journal.steps[key] = step
        case "result", "failed":
            var step = journal.steps[key] ?? ClaudeProgressCache.Step()
            if journal.steps[key] == nil { journal.order.append(key) }
            if type == "result" { step.done = true } else { step.failed = true }
            journal.steps[key] = step
        default:
            break
        }
    }

    /// How far a run has got, from its journal and the phases its script plans. For a run
    /// tried again, whose first `earlier` starts were an earlier try's, only this try's
    /// agents count, and those done before it: an earlier agent given up on, left
    /// running, or in a later phase than this try has reached, is not this try's. Until
    /// this try has started an agent, it is only starting.
    static func progress(
        of journal: ClaudeProgressCache.Journal, phases: [String], after earlier: Int = 0
    ) -> ClaudeWorkflowProgress {
        var progress = ClaudeWorkflowProgress(phases: phases)
        let keyed = journal.order.compactMap { key in journal.steps[key].map { (key: key, step: $0) } }
        let current = keyed.filter { earlier == 0 || $0.step.lastStart > earlier }
        guard earlier == 0 || !current.isEmpty else { return progress }
        let doneBefore = earlier == 0 ? 0 : keyed.filter { $0.step.lastStart <= earlier && $0.step.done }.count
        // Tries of this try's alone.
        var tries: [String: Int] = [:]
        for start in journal.starts.dropFirst(earlier) where earlier > 0 { tries[start.key, default: 0] += 1 }

        let steps = current.map(\.step)
        progress.started = steps.count + doneBefore
        progress.done = steps.filter(\.done).count + doneBefore
        progress.failed = steps.filter { $0.failed && !$0.done }.count
        let going = current.filter { !$0.step.done && !$0.step.failed }
        progress.retrying = going.filter { (earlier == 0 ? $0.step.tries : tries[$0.key] ?? 0) > 1 }.count
        progress.running = going.map { $0.step.label.isEmpty ? "agent" : $0.step.label }

        let planned = steps.compactMap { step in step.phase.flatMap { phases.firstIndex(of: $0) } }
        if let furthest = planned.max() {
            progress.phaseIndex = furthest
            progress.phase = phases[furthest]
        } else {
            progress.phase = steps.filter { $0.phase != nil }.max { $0.lastStart < $1.lastStart }?.phase
        }
        if let phase = progress.phase {
            let inPhase = steps.filter { $0.phase == phase }
            progress.phaseStarted = inPhase.count
            progress.phaseDone = inPhase.filter(\.done).count
        }
        return progress
    }

    /// The phases the script at `path` plans, by title.
    static func plan(_ path: String, cache: ClaudeProgressCache, into next: inout ClaudeProgressCache) -> [String] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let known = cache.plans[path], known.modified == modified {
            next.plans[path] = known
            return known.phases
        }
        guard modified != nil, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: planLength)) ?? Data()
        let phases = self.phases(inScript: String(decoding: data, as: UTF8.self))
        next.plans[path] = ClaudeProgressCache.Plan(modified: modified, phases: phases)
        return phases
    }

    /// The phase titles in a script's `meta`: the `title` of each object in its `phases`
    /// list, each a string in any of JavaScript's quotes.
    static func phases(inScript script: String) -> [String] {
        let text = Substring(script)
        let metaStart = text.range(of: "meta")?.upperBound ?? text.startIndex
        guard let key = text[metaStart...].range(of: #"phases["']?\s*:\s*\["#, options: .regularExpression) else {
            return []
        }
        // The list, to its closing bracket, skipping over strings.
        var depth = 1
        var quote: Character?
        var escaped = false
        var end = key.upperBound
        var index = key.upperBound
        while index < text.endIndex {
            let c = text[index]
            if let open = quote {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == open { quote = nil }
            } else if c == "'" || c == "\"" || c == "`" {
                quote = c
            } else if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
            index = text.index(after: index)
        }
        guard depth == 0 else { return [] }
        let list = String(text[key.upperBound..<end])
        let pattern = #"["']?title["']?\s*:\s*(?:'((?:\\.|[^'\\])*)'|"((?:\\.|[^"\\])*)"|`((?:\\.|[^`\\])*)`)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(list.startIndex..., in: list)
        return regex.matches(in: list, range: range).compactMap { match in
            for group in 1...3 {
                if let r = Range(match.range(at: group), in: list) {
                    return unescape(String(list[r]))
                }
            }
            return nil
        }
    }

    private static func unescape(_ string: String) -> String {
        var out = ""
        var escaped = false
        for c in string {
            if escaped {
                out.append(c == "n" ? " " : c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    // MARK: Agents

    private static let toolUseMark = Data(#""tool_use""#.utf8)
    private static let userMark = Data(#""type":"user""#.utf8)
    private static let assistantMark = Data(#""type":"assistant""#.utf8)

    static func agent(
        _ id: String, in folder: String, cache: ClaudeProgressCache, into next: inout ClaudeProgressCache
    ) -> ClaudeAgentProgress? {
        let base = folder + "/subagents/agent-" + id
        let path = base + ".jsonl"
        let known = cache.agents[path]
        guard let read = ClaudeFollowedFile.read(path, known: known?.file, limit: readLimit) else { return nil }
        var log = known ?? ClaudeProgressCache.AgentLog()
        if read.fresh {
            log.steps = 0
            log.stepsAtLeast = false
            log.doing = nil
            log.finished = false
        }
        log.file = read.file
        if read.cut { log.stepsAtLeast = true }
        if known == nil {
            log.created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
            log.summary = summary(ofAgentMeta: base + ".meta.json")
        }
        add(read.lines, to: &log)
        next.agents[path] = log
        return ClaudeAgentProgress(summary: log.summary, doing: log.doing, steps: log.steps,
                                   stepsAtLeast: log.stepsAtLeast, finished: log.finished, began: log.created,
                                   modified: log.file.modified)
    }

    /// What an agent's lines add: its tool calls, and whether the last of its messages
    /// ended its turn. Only lines naming a tool call, and the last message, are parsed.
    static func add(_ lines: [Data], to log: inout ClaudeProgressCache.AgentLog) {
        for line in lines where line.range(of: toolUseMark) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant"
            else { continue }
            let calls = blocks(of: object).filter { $0["type"] as? String == "tool_use" }
            guard let last = calls.last else { continue }
            log.steps += calls.count
            log.doing = ClaudeToolWords.describe(last["name"] as? String ?? "", input: last["input"] as? [String: Any] ?? [:])
        }
        for line in lines.reversed() where line.range(of: userMark) != nil || line.range(of: assistantMark) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant"
            else { continue }
            let message = object["message"] as? [String: Any]
            log.finished = type == "assistant" && message?["stop_reason"] as? String == "end_turn"
            break
        }
    }

    static func summary(ofAgentMeta path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path), data.count < 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        return object["description"] as? String ?? ""
    }

    private static func blocks(of object: [String: Any]) -> [[String: Any]] {
        (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    private static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - Tool calls in words

/// A tool call in a few words, for the line under a background agent: "Editing
/// IslandTheme.swift", "Running xcodebuild".
enum ClaudeToolWords {
    static let limit = 40

    static func describe(_ name: String, input: [String: Any]) -> String {
        func file(_ key: String) -> String? {
            guard let path = input[key] as? String, !path.isEmpty else { return nil }
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? nil : clip(name)
        }
        switch name {
        case "Read": return file("file_path").map { "Reading \($0)" } ?? "Reading a file"
        case "Edit", "MultiEdit": return file("file_path").map { "Editing \($0)" } ?? "Editing a file"
        case "Write": return file("file_path").map { "Writing \($0)" } ?? "Writing a file"
        case "NotebookEdit": return file("notebook_path").map { "Editing \($0)" } ?? "Editing a notebook"
        case "Bash": return program(input["command"] as? String ?? "").map { "Running \($0)" } ?? "Running a command"
        case "Grep":
            if let pattern = input["pattern"] as? String, pattern.count <= 24,
               pattern.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._- ".unicodeScalars.contains($0) }) {
                return "Searching for “\(pattern)”"
            }
            return "Searching the code"
        case "Glob": return "Looking for files"
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host }
            return host.map { "Reading \(clip($0))" } ?? "Reading a web page"
        case "WebSearch": return "Searching the web"
        case "Agent", "Task": return "Sending off an agent"
        case "Workflow": return "Starting a workflow"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet": return "Updating its to-do list"
        case "Skill": return "Using a skill"
        case "ToolSearch": return "Looking up tools"
        case "BashOutput", "TaskOutput": return "Checking on a command"
        case "KillShell", "KillBash", "TaskStop": return "Stopping a command"
        default:
            if name.hasPrefix("mcp__"), let tool = name.components(separatedBy: "__").last, !tool.isEmpty {
                return "Using " + clip(tool.replacingOccurrences(of: "_", with: " "))
            }
            return name.isEmpty ? "Using a tool" : "Using \(clip(name))"
        }
    }

    /// Words that start a command without being what it runs.
    private static let setup: Set<String> = [
        "cd", "export", "set", "unset", "source", ".", "true", "false", ":", "pushd", "popd", "local", "shopt",
        "trap", "umask", "ulimit", "echo", "printf", "sleep", "mkdir", "wait", "read", "declare", "alias",
    ]
    /// Words that run what follows them.
    private static let wrappers: Set<String> = [
        "sudo", "env", "time", "nohup", "exec", "command", "caffeinate", "xcrun", "timeout", "nice",
        "if", "while", "until", "then", "else", "do", "!", "{", "(",
    ]
    /// Words that begin or end a compound command, with nothing run in them.
    private static let keywords: Set<String> = ["for", "case", "select", "done", "fi", "esac", "}", ")", "in"]
    /// Programs that run a script named after them.
    private static let interpreters: Set<String> = [
        "bash", "sh", "zsh", "python", "python3", "node", "ruby", "perl", "swift", "osascript",
    ]

    /// The program a command line mostly runs: past any `cd … &&`, variables set, and
    /// wrappers like `sudo` or `env`; for an interpreter, its script. `nil` for a blank
    /// line.
    static func program(_ command: String) -> String? {
        var segments: [[String]] = []
        var current = ""
        let text = command.replacingOccurrences(of: "&&", with: "\n").replacingOccurrences(of: "||", with: "\n")
        for c in text {
            if c == "\n" || c == ";" || c == "|" {
                segments.append(current.split(whereSeparator: \.isWhitespace).map(String.init))
                current = ""
            } else {
                current.append(c)
            }
        }
        segments.append(current.split(whereSeparator: \.isWhitespace).map(String.init))

        var first: String?
        for words in segments {
            var index = 0
            var afterWrapper = false
            while index < words.count {
                var word = words[index].trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                while let c = word.first, "({!".contains(c), word.count > 1 { word.removeFirst() }
                if word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
                    || wrappers.contains(word)
                    || (afterWrapper && (word.hasPrefix("-") || word.allSatisfy { $0.isNumber || $0 == "." || $0 == "s" || $0 == "m" })) {
                    afterWrapper = afterWrapper || wrappers.contains(word)
                    index += 1
                    continue
                }
                break
            }
            guard index < words.count else { continue }
            let word = words[index].trimmingCharacters(in: CharacterSet(charactersIn: "\"'`(){}"))
            if keywords.contains(word) || word.isEmpty { continue }
            var name = (word as NSString).lastPathComponent
            if interpreters.contains(name),
               let script = words[(index + 1)...].first(where: { !$0.hasPrefix("-") }),
               script.contains(".") || script.contains("/") {
                let base = (script.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) as NSString).lastPathComponent
                if !base.isEmpty { name = base }
            }
            guard !name.isEmpty else { continue }
            if first == nil { first = name }
            if !setup.contains(name) { return clip(name) }
        }
        return first.map(clip)
    }

    private static func clip(_ text: String) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
