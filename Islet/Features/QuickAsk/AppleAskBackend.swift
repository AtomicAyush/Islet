import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, on macOS 26 and later with Apple Intelligence on: nothing
/// leaves the Mac. One conversation is kept while the island is open, warmed up as the
/// box first opens, and dropped as the island closes. Its instructions say what day and
/// time it is as it is asked, and, while Settings lets it, it can read the calendar
/// (`AskCalendar`).
@MainActor
final class AppleAskBackend: AskBackend {
    let provider = AskProvider.onDevice

    /// How available the model is, looked up afresh. Tests replace it.
    var availability: () -> AskStatus = { AppleAskBackend.systemAvailability() }
    /// Whether the model can see pictures: on macOS 27, where it says it can. Tests
    /// replace it.
    var seesImages: () -> Bool = { AppleAskBackend.systemSeesImages() }

    /// The calendar, for the model to read while Settings lets it; `nil`, it has no tool.
    var calendar: AskCalendar?

    /// The open box's conversation (`LanguageModelSession`), and how many exchanges it
    /// has seen, so a follow-up goes on from it rather than starting again.
    private var conversation: AnyObject?
    private var turnsSeen = 0
    /// When the conversation was last told the time: in its instructions, or since.
    private var toldTime: Date?

    /// A conversation warmed up but not yet asked anything is made afresh after this long,
    /// so its instructions have the time it is asked at.
    static let freshFor: TimeInterval = 60
    /// A conversation going on is told the time again with a question after this long, or
    /// on another day.
    static let retellAfter: TimeInterval = 10 * 60

    func status() -> AskStatus {
        availability()
    }

    var takesImages: Bool {
        status() == .ready && seesImages()
    }

    static func systemSeesImages() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 27, *) {
            return SystemLanguageModel.default.capabilities.contains(.vision)
        }
        #endif
        return false
    }

    static func systemAvailability() -> AskStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .notEligible
                case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
                case .modelNotReady: return .modelDownloading
                @unknown default: return .notEligible
                }
            @unknown default:
                return .notEligible
            }
        }
        #endif
        return .needsNewerMacOS
    }

    #if canImport(FoundationModels)
    /// The model's errors in Islet's words: a refusal, too much to hold, too many asks.
    @available(macOS 26, *)
    static func failure(for error: Error) -> Error {
        if #available(macOS 27, *), let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: return AskFailure.refused
            case .contextSizeExceeded: return AskFailure.tooLong
            case .rateLimited: return AskFailure.busy
            case .unsupportedCapability: return AskFailure.cantSee
            default: return AskFailure.provider(AskErrors.oneLine(error.localizedDescription))
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return AskFailure.refused
            case .exceededContextWindowSize: return AskFailure.tooLong
            case .rateLimited, .concurrentRequests: return AskFailure.busy
            default: return AskFailure.provider(AskErrors.oneLine(error.localizedDescription))
            }
        }
        return error
    }
    #endif

    func prepare() {
        // The box opened again with the island still open: its conversation goes on.
        guard conversation == nil, status() == .ready else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = newSession()
            session.prewarm()
            conversation = session
            turnsSeen = 0
        }
        #endif
    }

    func close() {
        conversation = nil
        turnsSeen = 0
        toldTime = nil
        calendar?.conversationStarted()
    }

    /// Whether a new conversation is given the calendar tool: Settings' switch on, and
    /// Quick Calendar there to read through.
    var readsCalendar: Bool {
        calendar?.offered == true
    }

    /// The moment of asking, in the calendar and locale the calendar is read in.
    private func clock() -> (now: Date, calendar: Calendar, locale: Locale) {
        calendar?.clock() ?? (Date(), .autoupdatingCurrent, .autoupdatingCurrent)
    }

    /// The instructions a conversation starting now is given.
    func instructions() -> String {
        let clock = clock()
        return AskInstructions.apple(now: clock.now, calendar: clock.calendar, locale: clock.locale, readsCalendar: readsCalendar)
    }

    /// `prompt` for a conversation going on, with the time again in front of it once it
    /// has moved on a while (or to another day) since the conversation was last told it.
    private func timed(_ prompt: String) -> String {
        let clock = clock()
        guard let told = toldTime,
              clock.now.timeIntervalSince(told) >= Self.retellAfter || !clock.calendar.isDate(told, inSameDayAs: clock.now)
        else { return prompt }
        toldTime = clock.now
        return "(\(AskInstructions.moment(clock.now, calendar: clock.calendar, locale: clock.locale)))\n\(prompt)"
    }

    #if canImport(FoundationModels)
    /// A conversation, with the day and time in its instructions and, while Settings lets
    /// it, the calendar tool.
    @available(macOS 26, *)
    func newSession() -> LanguageModelSession {
        toldTime = clock().now
        calendar?.conversationStarted()
        let instructions = instructions()
        guard readsCalendar else { return LanguageModelSession(instructions: instructions) }
        let tool = CalendarTool { [weak calendar] query in calendar?.read(query) ?? CalendarReading.turnedOff }
        return LanguageModelSession(tools: [tool], instructions: instructions)
    }
    #endif

    func answer(_ question: String, after earlier: [AskTurn]) -> AsyncThrowingStream<String, Error> {
        answer(question, showing: nil, after: earlier)
    }

    /// A picture goes to the model in memory, and stays in its conversation, on this Mac,
    /// for follow-ups to go on from until the island closes.
    func answer(_ question: String, showing image: ScreenSnapshot?, after earlier: [AskTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let status = status()
            guard status == .ready else { return continuation.finish(throwing: AskFailure.unavailable(status)) }
            if image != nil, !seesImages() { return continuation.finish(throwing: AskFailure.cantSee) }
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                // A conversation that has seen every exchange so far goes on; otherwise one
                // starts afresh with them in the question (another provider had them).
                // One warmed up a while ago and not yet asked is made afresh, for the time.
                var prompt = question
                let session: LanguageModelSession
                let current = conversation as? LanguageModelSession
                let stale = turnsSeen == 0 && toldTime.map { clock().now.timeIntervalSince($0) >= Self.freshFor } != false
                if let current, turnsSeen == earlier.count, !stale {
                    session = current
                    prompt = turnsSeen == 0 ? question : timed(question)
                } else {
                    session = newSession()
                    prompt = AskInstructions.prompt(question, after: earlier)
                }
                conversation = session
                turnsSeen = earlier.count + 1
                let task = Task { @MainActor in
                    do {
                        for try await snapshot in Self.stream(session, prompt, image: image) {
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: Self.failure(for: error))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            #endif
            continuation.finish(throwing: AskFailure.unavailable(.needsNewerMacOS))
        }
    }

    #if canImport(FoundationModels)
    /// The words, and the picture after them where there is one (macOS 27).
    @available(macOS 26, *)
    private static func stream(
        _ session: LanguageModelSession, _ prompt: String, image: ScreenSnapshot?
    ) -> LanguageModelSession.ResponseStream<String> {
        if #available(macOS 27, *), let image {
            let picture = Attachment(image.image).label("A picture of my screen: \(image.what)")
            return session.streamResponse(to: Prompt { prompt; picture })
        }
        return session.streamResponse(to: prompt)
    }
    #endif
}
