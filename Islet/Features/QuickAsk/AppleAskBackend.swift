import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, on macOS 26 and later with Apple Intelligence on: nothing
/// leaves the Mac. One conversation is kept while the island is open, warmed up as the
/// box first opens, and dropped as the island closes.
@MainActor
final class AppleAskBackend: AskBackend {
    let provider = AskProvider.onDevice

    /// How available the model is, looked up afresh. Tests replace it.
    var availability: () -> AskStatus = { AppleAskBackend.systemAvailability() }

    /// The open box's conversation (`LanguageModelSession`), and how many exchanges it
    /// has seen, so a follow-up goes on from it rather than starting again.
    private var conversation: AnyObject?
    private var turnsSeen = 0

    func status() -> AskStatus {
        availability()
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
            let session = LanguageModelSession(instructions: AskInstructions.text)
            session.prewarm()
            conversation = session
            turnsSeen = 0
        }
        #endif
    }

    func close() {
        conversation = nil
        turnsSeen = 0
    }

    func answer(_ question: String, after earlier: [AskTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let status = status()
            guard status == .ready else { return continuation.finish(throwing: AskFailure.unavailable(status)) }
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                // A conversation that has seen every exchange so far goes on; otherwise one
                // starts afresh with them in the question (another provider had them).
                var prompt = question
                let session: LanguageModelSession
                if let current = conversation as? LanguageModelSession, turnsSeen == earlier.count {
                    session = current
                } else {
                    session = LanguageModelSession(instructions: AskInstructions.text)
                    prompt = AskInstructions.prompt(question, after: earlier)
                }
                conversation = session
                turnsSeen = earlier.count + 1
                let task = Task { @MainActor in
                    do {
                        for try await snapshot in session.streamResponse(to: prompt) {
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
}
