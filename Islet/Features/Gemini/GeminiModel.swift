import Foundation
import Observation

/// The Gemini conversations worth showing, in the order they are shown. Knows nothing
/// about the island.
@MainActor
@Observable
final class GeminiModel {
    /// What the island shows beside the notch, for all the conversations together.
    enum Mark: Equatable {
        /// A conversation has asked the person something.
        case needsInput
        /// A conversation stopped on an error.
        case error
        /// One ran out of quota.
        case quota
        /// A conversation is at work.
        case working

        /// A conversation's own mark.
        init(_ session: GeminiSession) {
            switch session.state {
            case .needsInput: self = .needsInput
            case .error: self = session.isQuota ? .quota : .error
            case .working, .idle: self = .working
            }
        }
    }

    /// The real conversations, as the files last said.
    private(set) var sessions: [GeminiSession] = []
    /// Made-up conversations a preview is showing, in place of the real ones.
    private(set) var samples: [GeminiSession] = []
    /// When Antigravity's hook last wrote anything, for Settings; `nil` if it never has.
    private(set) var lastHeard: Date?
    /// The same, for Gemini CLI's.
    private(set) var lastHeardCLI: Date?

    /// Called after every change to what is shown.
    @ObservationIgnored var onChange: () -> Void = {}

    var shown: [GeminiSession] { samples.isEmpty ? sessions : samples }
    var isPreviewing: Bool { !samples.isEmpty }
    /// The conversation the compact island speaks for: the first one shown, so one
    /// waiting on the person puts up the question.
    var displayed: GeminiSession? { shown.first }
    var mark: Mark? { displayed.map(Mark.init) }
    /// Whether a conversation is waiting on the person: it is then the one displayed.
    var needsYou: Bool { displayed?.state.needsYou ?? false }
    /// How far the conversations shown have got, on average, of those with a task list;
    /// `nil` when none has one.
    var fraction: Double? {
        let fractions = shown.filter { $0.state == .working }.compactMap(\.progress)
        return fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
    }

    func update(_ sessions: [GeminiSession], lastHeard: Date?, lastHeardCLI: Date?) {
        self.lastHeard = lastHeard
        self.lastHeardCLI = lastHeardCLI
        guard sessions != self.sessions else { return }
        self.sessions = sessions
        if samples.isEmpty { onChange() }
    }

    func beginPreview(_ samples: [GeminiSession]) {
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
