import Foundation

/// Made-up conversations for the previews: invented projects, titles, tools and task
/// lists, never the person's.
enum GeminiSamples {
    private static func session(
        _ id: String, project: String, title: String, state: GeminiSessionState, run: TimeInterval,
        since: TimeInterval? = nil, model: String = "Gemini 3 Pro", step: GeminiStep? = nil, steps: Int = 0,
        history: [GeminiHistoryEntry] = [], tasks: [(String, GeminiTaskList.Item.Status)] = [],
        ended: GeminiEnding = .none, error: String = "", waiting: GeminiWaiting? = nil,
        agents: [GeminiAgent] = [], now: Date
    ) -> GeminiSession {
        let record = GeminiSessionRecord(
            id: "sample." + id, project: project, workspace: "", model: model, artifactDir: "",
            state: state, since: now.addingTimeInterval(-(since ?? run)), turnStarted: now.addingTimeInterval(-run),
            updated: now, ended: ended, error: error, step: step, lastStep: nil, steps: steps, history: history
        )
        let list = tasks.isEmpty ? nil : GeminiTaskList(items: tasks.map { GeminiTaskList.Item(text: $0.0, status: $0.1) })
        return GeminiSession(record: record, state: state, title: title, tasks: list, waiting: waiting, agents: agents)
    }

    private static func agent(_ id: String, name: String, parent: String, state: GeminiSessionState, run: TimeInterval,
                              now: Date) -> GeminiAgent {
        let record = GeminiSessionRecord(
            id: "sample." + id, state: state, since: now.addingTimeInterval(-run), turnStarted: now.addingTimeInterval(-run),
            updated: now, parent: "sample." + parent, agent: name
        )
        return GeminiAgent(record: record, state: state)
    }

    private static func used(_ entries: [(GeminiStep.Kind, String)]) -> [GeminiHistoryEntry] {
        entries.map { GeminiHistoryEntry(kind: $0.0, name: $0.1, count: $0.0 == .edit ? 1 : 0) }
    }

    static func working(now: Date) -> [GeminiSession] {
        [session("orchard", project: "Orchard", title: "Add a dark theme to the settings screen", state: .working,
                 run: 134, step: GeminiStep(kind: .shell, name: "npm", at: now.addingTimeInterval(-6)), steps: 11,
                 history: used([(.read, "Settings.tsx"), (.edit, "theme.ts"), (.edit, "Settings.tsx"), (.shell, "npm")]),
                 tasks: [("Find where colours are set", .completed), ("Add the dark palette", .completed),
                         ("Switch on the system setting", .inProgress), ("Check every screen", .pending)],
                 now: now)]
    }

    static func asking(now: Date) -> [GeminiSession] {
        [session("ledger", project: "Ledger", title: "Move the reports to the new database", state: .needsInput,
                 run: 300, since: 24, steps: 9, waiting: .question, now: now)]
    }

    static func quota(now: Date) -> [GeminiSession] {
        [session("ledger", project: "Ledger", title: "Move the reports to the new database", state: .error,
                 run: 420, since: 30, ended: .quota,
                 error: "Resource has been exhausted (e.g. check quota).", now: now)]
    }

    static func several(now: Date) -> [GeminiSession] {
        asking(now: now) + working(now: now) + [
            session("atlas", project: "Atlas", title: "Write tests for the map tiles", state: .working, run: 48,
                    model: "Gemini 3 Flash", steps: 3, history: used([(.search, ""), (.read, "Tiles.swift")]),
                    agents: [agent("atlas.browser", name: "browser_subagent", parent: "atlas", state: .working, run: 20,
                                   now: now)],
                    now: now),
        ]
    }
}
