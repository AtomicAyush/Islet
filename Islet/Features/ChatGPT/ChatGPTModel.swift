import Foundation
import Observation

/// The ChatGPT sessions worth showing, in the order they are shown. Knows nothing about
/// the island.
@MainActor
@Observable
final class ChatGPTModel {
    /// What the island shows beside the notch, for all the sessions together.
    enum Mark: Equatable {
        /// A session needs permission to go on.
        case needsPermission
        /// A session has asked a question.
        case waitingForInput
        /// A session is working on a reply.
        case working
        /// Only agents are at work, the replies done.
        case agents

        /// A session's own mark.
        init(_ state: ChatGPTSessionState) {
            switch state {
            case .working: self = .working
            case .needsPermission: self = .needsPermission
            case .waitingForInput: self = .waitingForInput
            case .idle: self = .agents
            }
        }
    }

    /// The real sessions, as the files and rollouts last said.
    private(set) var sessions: [ChatGPTSession] = []
    /// Made-up sessions a preview is showing, in place of the real ones.
    private(set) var samples: [ChatGPTSession] = []
    /// When the hook last wrote anything, for Settings; `nil` if it never has.
    private(set) var lastHeard: Date?

    /// Called after every change to what is shown.
    @ObservationIgnored var onChange: () -> Void = {}

    var shown: [ChatGPTSession] { samples.isEmpty ? sessions : samples }
    var isPreviewing: Bool { !samples.isEmpty }
    /// The session the compact island speaks for: the first one shown, so any session
    /// waiting on the person puts up the hand or the question.
    var displayed: ChatGPTSession? { shown.first }
    /// The agents at work in every session shown.
    var runningAgentCount: Int { shown.reduce(0) { $0 + $1.agentsAtWork.count } }
    /// How far the displayed session's plan has got; `nil` without one.
    var planFraction: Double? { displayed?.planFraction }

    var mark: Mark? { displayed.map { Mark($0.state) } }
    /// Whether a session is waiting on the person: it is then the one displayed.
    var needsYou: Bool { displayed?.state.needsYou ?? false }

    func update(_ sessions: [ChatGPTSession], lastHeard: Date?) {
        self.lastHeard = lastHeard
        guard sessions != self.sessions else { return }
        self.sessions = sessions
        if samples.isEmpty { onChange() }
    }

    func beginPreview(_ samples: [ChatGPTSession]) {
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
