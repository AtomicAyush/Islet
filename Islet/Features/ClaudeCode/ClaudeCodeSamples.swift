import Foundation

/// Made-up sessions for the previews: invented projects, prompts, workflows and agents,
/// never the person's.
enum ClaudeCodeSamples {
    private static func session(
        _ id: String, project: String, branch: String = "", state: ClaudeSessionState, turn: TimeInterval,
        since: TimeInterval? = nil, prompt: String, reply: String = "", workflows: [ClaudeWorkflow] = [],
        tasks: [ClaudeBackgroundTask] = [], progress: [String: ClaudeTaskProgress] = [:], now: Date
    ) -> ClaudeSession {
        let record = ClaudeSessionRecord(
            id: "sample." + id, project: project, branch: branch, cwd: "", transcriptPath: "", hostApp: "com.apple.Terminal",
            state: state, since: now.addingTimeInterval(-(since ?? turn)),
            turnStarted: now.addingTimeInterval(-turn), updated: now,
            prompt: prompt, reply: reply, workflows: workflows, tasks: tasks
        )
        return ClaudeSession(record: record, state: state, progress: progress)
    }

    private static func workflow(_ id: String, _ name: String, _ summary: String, minutes: Double, now: Date) -> ClaudeWorkflow {
        ClaudeWorkflow(id: id, name: name, summary: summary, status: "running",
                       firstSeen: now.addingTimeInterval(-minutes * 60))
    }

    private static func task(
        _ id: String, _ kind: ClaudeBackgroundTask.Kind, _ summary: String, minutes: Double, now: Date
    ) -> ClaudeBackgroundTask {
        ClaudeBackgroundTask(id: id, kind: kind, summary: summary, status: "running",
                             firstSeen: now.addingTimeInterval(-minutes * 60))
    }

    /// A workflow's progress: `phase` of `phases` under way, `done` of `started` agents in
    /// it finished, those before it all done, `running` at work.
    private static func progress(
        _ phases: [String], phase: Int, done: Int, started: Int, before: Int = 0, running: [String],
        failed: Int = 0, retrying: Int = 0
    ) -> ClaudeTaskProgress {
        .workflow(ClaudeWorkflowProgress(
            phases: phases, phase: phases[phase], phaseIndex: phase, phaseStarted: started, phaseDone: done,
            started: before + started, done: before + done, failed: failed, retrying: retrying, running: running
        ))
    }

    private static func agent(
        _ doing: String, steps: Int, finished: Bool = false, quietMinutes: Double = 0, now: Date
    ) -> ClaudeTaskProgress {
        .agent(ClaudeAgentProgress(doing: doing, steps: steps, finished: finished,
                                   modified: now.addingTimeInterval(-quietMinutes * 60)))
    }

    static func working(now: Date) -> [ClaudeSession] {
        [session("harbour", project: "Harbour", branch: "tide-tables", state: .working, turn: 134,
                 prompt: "Add offline caching to the timetable screen", now: now)]
    }

    static func needsPermission(now: Date) -> [ClaudeSession] {
        [session("lighthouse", project: "Lighthouse", branch: "main", state: .needsPermission, turn: 95, since: 12,
                 prompt: "Rename the settings keys and move the old values over", now: now)]
    }

    static func several(now: Date) -> [ClaudeSession] {
        [
            session("lighthouse", project: "Lighthouse", branch: "main", state: .needsPermission, turn: 95, since: 12,
                    prompt: "Rename the settings keys and move the old values over", now: now),
            session("harbour", project: "Harbour", branch: "tide-tables", state: .working, turn: 134,
                    prompt: "Add offline caching to the timetable screen", now: now),
            session("study", project: "", state: .idle, turn: 1500, since: 1260,
                    prompt: "Compare three ways to keep the shelf's pictures",
                    reply: "Both studies are under way; I'll write up what they find.",
                    workflows: [
                        workflow("w1", "shelf-storage-study", "Benchmarks three stores for the shelf and writes up the trade-offs",
                                 minutes: 21, now: now),
                        workflow("w2", "picture-import-tests", "Adds tests for pictures dragged in from a browser",
                                 minutes: 4.5, now: now),
                    ],
                    tasks: [task("a1", .agent, "Tidy the shelf's colour names", minutes: 7, now: now)],
                    progress: [
                        "w1": progress(["Survey", "Benchmark", "Write up"], phase: 1, done: 1, started: 3, before: 3,
                                       running: ["bench:sqlite", "bench:plain-files"]),
                        "w2": progress(["Implement", "Review", "Fix"], phase: 0, done: 0, started: 1, running: ["implement"]),
                        "a1": agent("Editing ShelfColours.swift", steps: 23, now: now),
                    ], now: now),
        ]
    }

    /// Background work at several stages, for the harness: workflows early and late, one
    /// that gave up on an agent, one trying an agent again, one just ended, background
    /// agents at work, gone quiet and done, and commands left running, one described by
    /// Claude Code and one by its program alone.
    static func background(now: Date) -> [ClaudeSession] {
        [
            session("harbour", project: "Harbour", branch: "tide-tables", state: .working, turn: 250,
                    prompt: "Split the timetable cache into its own module", workflows: [
                        workflow("w1", "timetable-cache-split", "Moves the cache out, then reviews and fixes",
                                 minutes: 38, now: now),
                        workflow("w4", "timetable-docs", "Writes up the new module", minutes: 20, now: now),
                    ],
                    tasks: [
                        task("a1", .agent, "Check the old cache keys still read", minutes: 16, now: now),
                        task("b1", .shell, "Dev server on port 8080", minutes: 52, now: now),
                    ],
                    progress: [
                        "w1": progress(["Implement", "Review", "Fix"], phase: 1, done: 3, started: 8, before: 2,
                                       running: ["review:storage", "review:network", "review:ui", "review:tests", "review:docs"],
                                       retrying: 1),
                        "w4": .workflow(ClaudeWorkflowProgress(started: 3, done: 3, outcome: .completed)),
                        "a1": agent("Running xcodebuild", steps: 41, quietMinutes: 12, now: now),
                    ], now: now),
            session("study", project: "", state: .idle, turn: 3000, since: 2400,
                    prompt: "Work through the shelf's open bugs", reply: "The three fixes are running.",
                    workflows: [
                        workflow("w2", "shelf-bug-sweep", "Fixes the three open shelf bugs", minutes: 64, now: now),
                        workflow("w3", "shelf-docs", "Writes the shelf's help page", minutes: 1, now: now),
                    ],
                    tasks: [
                        task("a2", .agent, "Draft the release notes", minutes: 12, now: now),
                        ClaudeBackgroundTask(id: "b2", kind: .shell, summary: "", status: "running",
                                             firstSeen: now.addingTimeInterval(-300), program: "npm"),
                    ],
                    progress: [
                        "w2": progress(["Implement", "Review", "Fix"], phase: 2, done: 1, started: 2, before: 6,
                                       running: ["fix:drag-drop"], failed: 1),
                        "w3": .workflow(ClaudeWorkflowProgress()),
                        "a2": agent("Writing RELEASE-NOTES.md", steps: 17, finished: true, now: now),
                    ], now: now),
        ]
    }
}
