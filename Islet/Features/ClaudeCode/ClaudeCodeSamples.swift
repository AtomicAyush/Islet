import Foundation

/// Made-up sessions for the previews: invented projects, prompts and workflows, never
/// the person's.
enum ClaudeCodeSamples {
    private static func session(
        _ id: String, project: String, state: ClaudeSessionState, turn: TimeInterval, since: TimeInterval? = nil,
        prompt: String, reply: String = "", workflows: [ClaudeWorkflow] = [], now: Date
    ) -> ClaudeSession {
        let record = ClaudeSessionRecord(
            id: "sample." + id, project: project, cwd: "", transcriptPath: "", hostApp: "com.apple.Terminal",
            state: state, since: now.addingTimeInterval(-(since ?? turn)),
            turnStarted: now.addingTimeInterval(-turn), updated: now,
            prompt: prompt, reply: reply, workflows: workflows
        )
        return ClaudeSession(record: record, state: state)
    }

    private static func workflow(_ id: String, _ name: String, _ summary: String, minutes: Double, now: Date) -> ClaudeWorkflow {
        ClaudeWorkflow(id: id, name: name, summary: summary, status: "running",
                       firstSeen: now.addingTimeInterval(-minutes * 60))
    }

    static func working(now: Date) -> [ClaudeSession] {
        [session("harbour", project: "Harbour", state: .working, turn: 134,
                 prompt: "Add offline caching to the timetable screen", now: now)]
    }

    static func needsPermission(now: Date) -> [ClaudeSession] {
        [session("lighthouse", project: "Lighthouse", state: .needsPermission, turn: 95, since: 12,
                 prompt: "Rename the settings keys and move the old values over", now: now)]
    }

    static func several(now: Date) -> [ClaudeSession] {
        [
            session("lighthouse", project: "Lighthouse", state: .needsPermission, turn: 95, since: 12,
                    prompt: "Rename the settings keys and move the old values over", now: now),
            session("harbour", project: "Harbour", state: .working, turn: 134,
                    prompt: "Add offline caching to the timetable screen", now: now),
            session("study", project: "", state: .idle, turn: 1500, since: 1260,
                    prompt: "Compare three ways to keep the shelf's pictures",
                    reply: "Both studies are under way; I'll write up what they find.",
                    workflows: [
                        workflow("w1", "shelf-storage-study", "Benchmarks three stores for the shelf and writes up the trade-offs",
                                 minutes: 21, now: now),
                        workflow("w2", "picture-import-tests", "Adds tests for pictures dragged in from a browser",
                                 minutes: 4.5, now: now),
                    ], now: now),
        ]
    }
}
