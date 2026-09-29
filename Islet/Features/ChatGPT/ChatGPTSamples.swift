import Foundation

/// Made-up sessions for the previews: invented projects, prompts, plans and agents,
/// never the person's.
enum ChatGPTSamples {
    private static func session(
        _ id: String, project: String, state: ChatGPTSessionState, turn: TimeInterval, since: TimeInterval? = nil,
        prompt: String, reply: String = "", step: ChatGPTStep? = nil, steps: Int = 0, plan: [ChatGPTPlanStep] = [],
        agents: [ChatGPTAgent] = [], now: Date
    ) -> ChatGPTSession {
        let record = ChatGPTSessionRecord(
            id: "sample." + id, project: project, cwd: "", transcriptPath: "", hostApp: "",
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
        now: Date
    ) -> ChatGPTAgent {
        ChatGPTAgent(id: id, type: "default", name: name, isRunning: running,
                     firstSeen: now.addingTimeInterval(-minutes * 60),
                     ended: running ? nil : now.addingTimeInterval(-20), step: doing, steps: steps)
    }

    static func working(now: Date) -> [ChatGPTSession] {
        [session("harbour", project: "Harbour", state: .working, turn: 102,
                 prompt: "Add offline caching to the timetable screen",
                 step: step(.shell, "swift", seconds: 9, now: now), steps: 14,
                 plan: plan([("Read the timetable code", .completed), ("Add a cache to the store", .completed),
                             ("Build and run the tests", .inProgress), ("Write up the change", .pending)]),
                 now: now)]
    }

    static func needsPermission(now: Date) -> [ChatGPTSession] {
        [session("lighthouse", project: "Lighthouse", state: .needsPermission, turn: 80, since: 11,
                 prompt: "Move the settings keys over and delete the old ones",
                 step: step(.shell, "rm", seconds: 11, now: now), steps: 6, now: now)]
    }

    static func several(now: Date) -> [ChatGPTSession] {
        [
            session("lighthouse", project: "Lighthouse", state: .needsPermission, turn: 80, since: 11,
                    prompt: "Move the settings keys over and delete the old ones",
                    step: step(.shell, "rm", seconds: 11, now: now), steps: 6, now: now),
            session("harbour", project: "Harbour", state: .working, turn: 245,
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

    /// A question, a plain chat and a long plan, for the harness.
    static func asking(now: Date) -> [ChatGPTSession] {
        [
            session("question", project: "Harbour", state: .waitingForInput, turn: 60, since: 7,
                    prompt: "Pick a cache size and add it", step: step(.ask, "", seconds: 7, now: now), steps: 3,
                    now: now),
            session("plain", project: "", state: .working, turn: 4,
                    prompt: "What's a good name for a timetable app that works offline?", now: now),
        ]
    }
}
