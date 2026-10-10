import Foundation

/// Who answers a quick question.
enum AskProvider: String, CaseIterable, Identifiable {
    /// Apple's on-device model: nothing leaves the Mac.
    case onDevice = "apple"
    /// ChatGPT, through the ChatGPT app's own command line tool.
    case chatGPT = "chatgpt"
    /// Claude, through the Claude app's own command line tool.
    case claude
    /// Gemini, through Gemini CLI, signed in as it is. Offered only once it can answer.
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: "On this Mac"
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }

    /// The name in "Ask …" and "Still waiting for …".
    var name: String {
        switch self {
        case .onDevice: "Apple's model"
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }

    var symbol: String {
        switch self {
        case .onDevice: "laptopcomputer"
        case .chatGPT: "bubble.left.fill"
        case .claude: "sparkle"
        case .gemini: "wand.and.stars"
        }
    }

    /// Where a picture of the screen goes, beside it before it is sent.
    var pictureGoes: String {
        switch self {
        case .onDevice: "Stays on this Mac"
        case .chatGPT: "Sent to ChatGPT with your question"
        case .claude: "Sent to Claude with your question"
        case .gemini: "Sent to Gemini with your question"
        }
    }

    /// Whether it is offered in the menu of who answers: Gemini only once it can answer,
    /// being installed and signed in; the others always, saying why where they can't.
    static func isOffered(_ provider: AskProvider, _ status: (AskProvider) -> AskStatus) -> Bool {
        provider != .gemini || status(provider) == .ready
    }

    /// The first ready of On this Mac, ChatGPT, Claude and Gemini, or On this Mac when none is.
    static func firstReady(_ status: (AskProvider) -> AskStatus) -> AskProvider {
        allCases.first { status($0) == .ready } ?? .onDevice
    }
}

/// Whether a provider can answer now, and if not, why, as its row in the menu says it.
enum AskStatus: Equatable {
    case ready
    case notInstalled
    case signInNeeded
    /// ChatGPT's list of models, which Islet builds its tool-free model from, is missing
    /// or not as expected (`CodexCatalog`).
    case notReady
    case appleIntelligenceOff
    case modelDownloading
    case notEligible
    case needsNewerMacOS

    func text(for provider: AskProvider) -> String {
        switch self {
        case .ready: "Ready"
        case .notInstalled:
            provider == .gemini ? "Install Gemini CLI to ask Gemini" : "Install the \(provider.title) app to ask \(provider.title)"
        case .signInNeeded:
            switch provider {
            case .claude: "Connect Claude in Settings"
            case .gemini: "Sign in to Gemini CLI: run gemini in Terminal once"
            default: "Sign in to the \(provider.title) app"
            }
        case .notReady: "ChatGPT isn't ready — open the ChatGPT app once"
        case .appleIntelligenceOff: "Turn on Apple Intelligence in System Settings"
        case .modelDownloading: "Apple's model is still downloading"
        case .notEligible: "This Mac can't run Apple's model"
        case .needsNewerMacOS: "Needs macOS 26"
        }
    }
}

/// An exchange already had in the box, resent to a command line tool with a follow-up.
struct AskTurn: Equatable {
    var question: String
    var answer: String
    /// It came with a picture of the screen, which isn't sent again: a follow-up says so.
    var hadPicture = false
}

/// Why a question went unanswered, in Islet's words.
enum AskFailure: Error, Equatable {
    case notInstalled
    case notSignedIn
    case notReady
    /// The provider's usage limit, and when it resets as it said, if it did.
    case usageLimit(resets: String?)
    case offline
    case busy
    /// Apple's model won't answer that.
    case refused
    /// More than Apple's model can hold.
    case tooLong
    case unavailable(AskStatus)
    /// No whole answer within the time allowed.
    case timedOut
    /// A command line tool said nothing at all for too long.
    case noResponse
    /// The tool stopped with this exit status and no answer.
    case exited(Int32)
    /// The provider's own one-line message.
    case provider(String)
    /// A picture went with the question, and this provider can't take one.
    case cantSee

    /// What went wrong, and what can be done about it: `other` is the provider offered
    /// instead, if any, and `afresh` whether the question can be asked again alone.
    func text(for provider: AskProvider, instead other: AskProvider? = nil, afresh: Bool = false) -> String {
        let instead = other.map { " — ask \($0.name) instead?" } ?? ""
        switch self {
        case .notInstalled: return AskStatus.notInstalled.text(for: provider)
        case .notSignedIn: return AskStatus.signInNeeded.text(for: provider)
        case .notReady: return AskStatus.notReady.text(for: provider)
        case .usageLimit(let resets):
            let reached = provider == .gemini ? "Gemini's quota is used up for now" : "\(provider.title)'s usage limit is reached"
            let limit = reached + (resets.map { " — it resets \($0)" } ?? "")
            return limit + (other.map { ". Ask \($0.name) instead?" } ?? "")
        case .offline: return "You're offline" + instead
        case .busy: return "\(provider.title) is busy — try again" + (other.map { " or ask \($0.name)" } ?? "")
        case .refused: return "Apple's model won't answer that" + instead
        case .tooLong:
            let choices = [afresh ? "start afresh" : nil, other.map { "ask \($0.name) instead" }].compactMap { $0 }
            return "That's more than Apple's model can hold" + (choices.isEmpty ? "" : " — \(choices.joined(separator: " or "))?")
        case .unavailable(let status): return status.text(for: provider)
        case .timedOut: return "No answer after \(Int(AskLimits.total)) s"
        case .noResponse: return "No answer from \(provider.name)"
        case .exited(let status): return "\(provider.title) stopped unexpectedly (exit \(status))"
        case .provider(let message): return "\(provider.title): \(message)"
        case .cantSee: return "\(provider.name) can't see pictures" + (other.map { " — ask \($0.name), which can?" } ?? "")
        }
    }

    /// Whether Try again could help.
    var canRetry: Bool {
        switch self {
        case .timedOut, .noResponse, .busy, .exited, .provider, .offline: true
        default: false
        }
    }
}

/// How long a question may take.
enum AskLimits {
    /// A command line tool says nothing at all in this long, and is given up on.
    static let firstOutput: TimeInterval = 20
    /// "Still waiting for …" once nothing of the answer has come in this long.
    static let slow: TimeInterval = 8
    /// The whole answer, however it comes. ChatGPT has been seen to take 48 s.
    static let total: TimeInterval = 90
}

/// One way of answering: Apple's model in the process, or a command line tool run for
/// each question.
@MainActor
protocol AskBackend: AnyObject {
    var provider: AskProvider { get }
    /// Whether it can answer now; looked at afresh each time.
    func status() -> AskStatus
    /// The box opened with this provider chosen: a moment to warm up.
    func prepare()
    /// Answers `question`, after the exchanges already had: the whole answer so far each
    /// time more of it comes. Cancelling the stream's task stops the answer.
    func answer(_ question: String, after earlier: [AskTurn]) -> AsyncThrowingStream<String, Error>
    /// Whether a picture of the screen can go with a question now.
    var takesImages: Bool { get }
    /// Answers `question` about `image`, a picture of the screen, if there is one. A
    /// provider that can't take pictures says so rather than answer without it.
    func answer(_ question: String, showing image: ScreenSnapshot?, after earlier: [AskTurn]) -> AsyncThrowingStream<String, Error>
    /// The island closed: anything held for its conversation goes.
    func close()
}

extension AskBackend {
    var takesImages: Bool { false }

    func answer(_ question: String, showing image: ScreenSnapshot?, after earlier: [AskTurn]) -> AsyncThrowingStream<String, Error> {
        guard image != nil else { return answer(question, after: earlier) }
        return AsyncThrowingStream { $0.finish(throwing: AskFailure.cantSee) }
    }
}

/// The words every provider is given to answer by.
enum AskInstructions {
    static let text = "Answer briefly: usually one to three sentences. Plain text; use a short list or code block only when it helps. No preamble. Say so if you are not sure."

    /// The question with the exchanges before it, for a tool that starts afresh each
    /// time: nothing of a conversation outlives its box, so each follow-up carries it.
    static func prompt(_ question: String, after earlier: [AskTurn]) -> String {
        guard !earlier.isEmpty else { return question }
        let turns = earlier.map { turn in
            "Q\(turn.hadPicture ? " (with a picture of my screen, not sent again)" : ""): \(turn.question)\nA: \(turn.answer)"
        }
        return "Earlier in this conversation:\n\(turns.joined(separator: "\n\n"))\n\nNow: \(question)"
    }

    /// The question with a picture of the screen going with it: what the picture is of.
    static func prompt(_ question: String, showing image: ScreenSnapshot?, after earlier: [AskTurn]) -> String {
        let text = prompt(question, after: earlier)
        guard let image else { return text }
        return "(A picture of my screen comes with this: \(image.what).)\n\(text)"
    }
}

/// The environment a command line tool is run with: the few variables it needs to find
/// its own sign-in and a place for temporary files, and none of Islet's own.
enum AskEnvironment {
    static func base(extra: [String: String]) -> [String: String] {
        let process = ProcessInfo.processInfo.environment
        var environment = [
            "HOME": process["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": process["USER"] ?? NSUserName(),
            "PATH": "/usr/bin:/bin",
            "TMPDIR": process["TMPDIR"] ?? NSTemporaryDirectory(),
        ]
        if let lang = process["LANG"] { environment["LANG"] = lang }
        return environment.merging(extra) { $1 }
    }
}

enum AskErrors {
    /// A failure as the box tells it: a run given up on, or one that never started, in
    /// Islet's words.
    static func map(_ error: Error) -> Error {
        switch error {
        case AskProcess.Failure.silent: AskFailure.noResponse
        case AskProcess.Failure.timedOut: AskFailure.timedOut
        case AskProcess.Failure.couldNotStart: AskFailure.notInstalled
        default: error
        }
    }

    /// A provider's message on one line, and not too long for the box.
    static func oneLine(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 160 ? String(trimmed.prefix(159)) + "…" : trimmed
    }
}
