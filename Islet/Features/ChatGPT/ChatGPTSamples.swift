import Foundation

/// Made-up sessions for the previews: invented projects, prompts, plans, agents, goals
/// and commands, never the person's.
enum ChatGPTSamples {
    private static func session(
        _ id: String, project: String, branch: String = "", state: ChatGPTSessionState, turn: TimeInterval,
        since: TimeInterval? = nil, prompt: String, reply: String = "", step: ChatGPTStep? = nil, steps: Int = 0,
        plan: [ChatGPTPlanStep] = [], agents: [ChatGPTAgent] = [], now: Date
    ) -> ChatGPTSession {
        let record = ChatGPTSessionRecord(
            id: "sample." + id, project: project, branch: branch, cwd: "", transcriptPath: "", hostApp: "",
            state: state, since: now.addingTimeInterval(-(since ?? turn)), turnId: "sample-turn",
            turnStarted: now.addingTimeInterval(-turn), updated: now,
            prompt: prompt, reply: reply, step: step, steps: steps, plan: plan, agents: agents
        )
        return ChatGPTSession(record: record, state: state, agentsAtWork: agents.filter(\.isRunning))
    }

    private static func step(_ kind: ChatGPTStep.Kind, _ name: String, count: Int = 0, seconds: TimeInterval, now: Date) -> ChatGPTStep {
        ChatGPTStep(id: "sample-\(kind.rawValue)", kind: kind, name: name, count: count,
                    started: now.addingTimeInterval(-seconds))
    }

    private static func plan(_ steps: [(String, ChatGPTPlanStep.Status)]) -> [ChatGPTPlanStep] {
        steps.map { ChatGPTPlanStep(step: $0.0, status: $0.1) }
    }

    private static func agent(
        _ id: String, _ name: String, running: Bool = true, minutes: Double, doing: ChatGPTStep? = nil, steps: Int,
        plan: (done: Int, total: Int)? = nil, now: Date
    ) -> ChatGPTAgent {
        ChatGPTAgent(id: id, type: "default", name: name, isRunning: running,
                     firstSeen: now.addingTimeInterval(-minutes * 60),
                     ended: running ? nil : now.addingTimeInterval(-20), step: doing, steps: steps,
                     planDone: plan?.done, planTotal: plan?.total)
    }

    static func working(now: Date) -> [ChatGPTSession] {
        [session("harbour", project: "Harbour", branch: "tide-tables", state: .working, turn: 102,
                 prompt: "Add offline caching to the timetable screen",
                 step: step(.shell, "swift", seconds: 9, now: now), steps: 14,
                 plan: plan([("Read the timetable code", .completed), ("Add a cache to the store", .completed),
                             ("Build and run the tests", .inProgress), ("Write up the change", .pending)]),
                 now: now)]
    }

    static func needsPermission(now: Date) -> [ChatGPTSession] {
        [session("lighthouse", project: "Lighthouse", branch: "main", state: .needsPermission, turn: 80, since: 11,
                 prompt: "Move the settings keys over and delete the old ones",
                 step: step(.shell, "rm", seconds: 11, now: now), steps: 6, now: now)]
    }

    static func several(now: Date) -> [ChatGPTSession] {
        [
            session("lighthouse", project: "Lighthouse", branch: "main", state: .needsPermission, turn: 80, since: 11,
                    prompt: "Move the settings keys over and delete the old ones",
                    step: step(.shell, "rm", seconds: 11, now: now), steps: 6, now: now),
            session("harbour", project: "Harbour", branch: "tide-tables", state: .working, turn: 245,
                    prompt: "Split the timetable cache into its own module",
                    step: step(.wait, "", seconds: 40, now: now), steps: 22,
                    agents: [
                        agent("a1", "fix_tests", minutes: 3.5,
                              doing: step(.patch, "CacheTests.swift", count: 2, seconds: 5, now: now), steps: 17, now: now),
                        agent("a2", "write_docs", running: false, minutes: 3, steps: 9, now: now),
                    ], now: now),
            session("chat", project: "", state: .idle, turn: 900, since: 600,
                    prompt: "Compare three ways to store the shelf's pictures",
                    reply: "Two agents are still measuring; I'll sum up once they're back.",
                    agents: [agent("a3", "measure_sqlite", minutes: 9,
                                   doing: step(.shell, "python3", seconds: 30, now: now), steps: 31, now: now)],
                    now: now),
        ]
    }

    /// A chat with everything it can have at work: a plan, agents (one with a plan of its
    /// own, one gone quiet, one done), a goal with a budget, two commands left running,
    /// its steps so far and two prompts queued.
    static func progress(now: Date) -> [ChatGPTSession] {
        var chat = session(
            "harbour", project: "Harbour", branch: "tide-tables", state: .working, turn: 1250,
            prompt: "Ship offline mode for the timetable",
            step: step(.wait, "", seconds: 30, now: now), steps: 38,
            plan: plan([("Cache the timetable", .completed), ("Sync when back online", .completed),
                        ("Build and run the tests", .inProgress), ("Write up the change", .pending)]),
            agents: [
                agent("a1", "fix_tests", minutes: 6, doing: step(.shell, "swift", seconds: 12, now: now), steps: 21,
                      plan: (2, 5), now: now),
                agent("a2", "measure_sync", minutes: 14, doing: step(.shell, "python3", seconds: 720, now: now),
                      steps: 8, now: now),
                agent("a3", "write_docs", running: false, minutes: 7, steps: 12, now: now),
            ], now: now)
        chat.record.history = [
            ChatGPTHistoryEntry(kind: .patch, name: "TimetableCache.swift", count: 2),
            ChatGPTHistoryEntry(kind: .mcp, name: "cua_repl", n: 3),
            ChatGPTHistoryEntry(kind: .shell, name: "npm", n: 2),
            ChatGPTHistoryEntry(kind: .shell, name: "swift", n: 4),
            ChatGPTHistoryEntry(kind: .spawn, name: "", n: 3),
            ChatGPTHistoryEntry(kind: .patch, name: "SyncQueue.swift"),
            ChatGPTHistoryEntry(kind: .wait, name: ""),
        ]
        chat.terminals = [
            ChatGPTShell(id: "sample-t1", name: "npm", started: now.addingTimeInterval(-840),
                         since: now.addingTimeInterval(-830)),
            ChatGPTShell(id: "sample-t2", name: "tail", started: now.addingTimeInterval(-95),
                         since: now.addingTimeInterval(-90)),
        ]
        chat.record.shells = chat.terminals
        chat.goal = ChatGPTGoal(title: "Timetable works offline, tests pass", status: .active, budget: 50_000,
                                used: 18_400, seconds: 1250, updated: now)
        chat.queuedCount = 2
        return [chat]
    }

    /// A plain chat with no plan, agents or goal, as most are: its steps so far and a
    /// command left running.
    static func plain(now: Date) -> [ChatGPTSession] {
        var chat = session("plain", project: "", state: .working, turn: 312,
                           prompt: "Tidy the sync code and check it still builds",
                           step: step(.patch, "SyncQueue.swift", seconds: 3, now: now), steps: 14, now: now)
        chat.record.history = [
            ChatGPTHistoryEntry(kind: .shell, name: "rg", n: 3),
            ChatGPTHistoryEntry(kind: .patch, name: "Store.swift"),
            ChatGPTHistoryEntry(kind: .mcp, name: "cua_repl", n: 2),
            ChatGPTHistoryEntry(kind: .shell, name: "swift", n: 4),
            ChatGPTHistoryEntry(kind: .shell, name: "git", n: 2),
            ChatGPTHistoryEntry(kind: .patch, name: "SyncQueue.swift", count: 2),
        ]
        chat.terminals = [ChatGPTShell(id: "sample-t3", name: "swift", started: now.addingTimeInterval(-64),
                                       since: now.addingTimeInterval(-60))]
        chat.record.shells = chat.terminals
        return [chat]
    }

    /// A question, a plain chat and a long plan, for the harness.
    static func asking(now: Date) -> [ChatGPTSession] {
        [
            session("question", project: "Harbour", branch: "tide-tables", state: .waitingForInput, turn: 60, since: 7,
                    prompt: "Pick a cache size and add it", step: step(.ask, "", seconds: 7, now: now), steps: 3,
                    now: now),
            session("plain", project: "", state: .working, turn: 4,
                    prompt: "What's a good name for a timetable app that works offline?", now: now),
        ]
    }
}
