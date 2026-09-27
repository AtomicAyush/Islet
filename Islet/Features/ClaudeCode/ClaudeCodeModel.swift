import Foundation
import Observation

/// The Claude Code sessions worth showing, in the order they are shown. Knows nothing
/// about the island.
@MainActor
@Observable
final class ClaudeCodeModel {
    /// What the island shows beside the notch, for all the sessions together.
    enum Mark: Equatable {
        /// A session needs permission to go on.
        case needsPermission
        /// A session has asked a question.
        case waitingForInput
        /// A session is working on a reply.
        case working
        /// Only workflows, or agents sent off in the background, are running.
        case workflows

        /// A session's own mark.
        init(_ state: ClaudeSessionState) {
            switch state {
            case .working: self = .working
            case .needsPermission: self = .needsPermission
            case .waitingForInput: self = .waitingForInput
            case .idle: self = .workflows
            }
        }
    }

    /// The real sessions, as the files and transcripts last said.
    private(set) var sessions: [ClaudeSession] = []
    /// Made-up sessions a preview is showing, in place of the real ones.
    private(set) var samples: [ClaudeSession] = []
    /// When the hook last wrote anything, for Settings; `nil` if it never has.
    private(set) var lastHeard: Date?

    /// Called after every change to what is shown.
    @ObservationIgnored var onChange: () -> Void = {}

    var shown: [ClaudeSession] { samples.isEmpty ? sessions : samples }
    var isPreviewing: Bool { !samples.isEmpty }
    /// The session the compact island speaks for: the first one shown.
    var displayed: ClaudeSession? { shown.first }
    /// The workflows and background agents at work: running, and not ended or finished
    /// as their files say since.
    var runningWorkflowCount: Int { shown.reduce(0) { $0 + $1.workflowsAtWork.count } }
    var runningAgentCount: Int { shown.reduce(0) { $0 + $1.agentsAtWork.count } }
    /// The workflows and background agents at work, which the compact island counts.
    var backgroundCount: Int { runningWorkflowCount + runningAgentCount }
    /// How far the workflows at work have got, together: the mean of those whose files
    /// say; `nil` when none do.
    var workflowFraction: Double? {
        let fractions = shown.flatMap { session in
            session.workflowsAtWork.compactMap { session.progress(of: $0)?.fraction }
        }
        guard !fractions.isEmpty else { return nil }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    /// The displayed session's: sessions waiting for permission come first, then those
    /// waiting for an answer, then those working, so the mark and the time beside it
    /// are the same session's.
    var mark: Mark? { displayed.map { Mark($0.state) } }
    /// Whether a session is waiting on the person: it is then the one displayed.
    var needsYou: Bool { displayed?.state.needsYou ?? false }

    func update(_ sessions: [ClaudeSession], lastHeard: Date?) {
        self.lastHeard = lastHeard
        guard sessions != self.sessions else { return }
        self.sessions = sessions
        if samples.isEmpty { onChange() }
    }

    func beginPreview(_ samples: [ClaudeSession]) {
        guard samples != self.samples else { return }
        self.samples = samples
        onChange()
    }

    func endPreview() {
        guard !samples.isEmpty else { return }
        samples = []
        onChange()
    }
}
