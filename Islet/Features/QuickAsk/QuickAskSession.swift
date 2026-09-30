import AppKit
import SwiftUI
import Observation

/// One open box's conversation: each question asked and its answer, in memory only.
/// Follow-ups go on from it; closing the box forgets all of it (`close()`), stopping any
/// answer still coming.
@MainActor
@Observable
final class QuickAskSession: InputSession {
    struct Exchange: Identifiable, Equatable {
        let id: Int
        let question: String
        var provider: AskProvider
        var answer = ""
        var state = State.waiting
    }

    enum State: Equatable {
        /// Asked, and nothing of the answer yet.
        case waiting
        /// Nothing of the answer after `AskLimits.slow`.
        case slow
        case answering
        case done
        case failed(AskFailure)
        case stopped
    }

    /// The most exchanges kept and resent with a follow-up; the oldest go first.
    static let maxExchanges = 6

    private(set) var exchanges: [Exchange] = []
    /// Who answers the next question: the one chosen in the chip's menu, kept.
    private(set) var provider: AskProvider
    /// Earlier exchanges are no longer resent with a follow-up.
    private(set) var droppedEarlier = false
    /// The answer just copied, for "Copied".
    private(set) var justCopied: Int?

    @ObservationIgnored let ask: QuickAskModel
    /// How long before "Still waiting", and before an answer is given up on. Tests
    /// shorten them.
    @ObservationIgnored var slowAfter = AskLimits.slow
    @ObservationIgnored var giveUpAfter = AskLimits.total
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var nextID = 0
    /// The exchange whose time ran out, as its task ends.
    @ObservationIgnored private var timedOut: Int?

    init(ask: QuickAskModel) {
        self.ask = ask
        provider = ask.provider
    }

    var isBusy: Bool {
        guard let last = exchanges.last else { return false }
        return [.waiting, .slow, .answering].contains(last.state)
    }

    // MARK: InputSession

    func above() -> AnyView? {
        exchanges.isEmpty ? nil : AnyView(QuickAskConversation(session: self))
    }

    func trailingChip() -> AnyView? {
        AnyView(QuickAskProviderChip(session: self))
    }

    func opened() {
        ask.refreshStatuses()
        provider = ask.provider
        ask.backend(provider).prepare()
    }

    func submit(_ draft: String) -> Bool {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy else { return false }
        nextID += 1
        exchanges.append(Exchange(id: nextID, question: question, provider: provider))
        run(exchanges.count - 1)
        return true
    }

    func stop() {
        task?.cancel()
    }

    func close() {
        task?.cancel()
        task = nil
        exchanges = []
        droppedEarlier = false
        justCopied = nil
        ask.closeBackends()
    }

    // MARK: Asking

    /// Asks the next question of `provider`, and remembers the choice.
    func choose(_ provider: AskProvider) {
        self.provider = provider
        ask.choose(provider)
        ask.backend(provider).prepare()
    }

    /// Asks the last question again of `provider` ("Ask ChatGPT" under an answer from
    /// this Mac), in the answer's place.
    func askAgain(with provider: AskProvider) {
        guard !isBusy, let last = exchanges.indices.last else { return }
        self.provider = provider
        exchanges[last].provider = provider
        exchanges[last].answer = ""
        exchanges[last].state = .waiting
        run(last)
    }

    /// The last question alone, without the exchanges before it: after one too long
    /// for Apple's model to hold.
    func startAfresh() {
        guard !isBusy, let last = exchanges.last else { return }
        exchanges = [last]
        askAgain(with: last.provider)
    }

    /// Try again, after a failure.
    func retry() {
        guard let last = exchanges.last, case .failed = last.state else { return }
        askAgain(with: last.provider)
    }

    private func run(_ index: Int) {
        let exchange = exchanges[index]
        // Only exchanges that were answered go with a follow-up, the latest few of them.
        let answered = exchanges[..<index].filter { $0.state == .done }
        let earlier = answered.suffix(Self.maxExchanges - 1).map { AskTurn(question: $0.question, answer: $0.answer) }
        droppedEarlier = answered.count > earlier.count
        let backend = ask.backend(exchange.provider)
        let id = exchange.id
        let slowAfter = slowAfter
        let giveUpAfter = giveUpAfter
        timedOut = nil
        task?.cancel()
        task = Task { [weak self] in
            let slow = Task { [weak self] in
                try? await Task.sleep(for: .seconds(slowAfter))
                guard !Task.isCancelled else { return }
                self?.update(id) { if $0.state == .waiting { $0.state = .slow } }
            }
            let limit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(giveUpAfter))
                guard !Task.isCancelled else { return }
                self?.timedOut = id
                self?.task?.cancel()
            }
            defer {
                slow.cancel()
                limit.cancel()
            }
            do {
                for try await answer in backend.answer(exchange.question, after: Array(earlier)) {
                    self?.update(id) {
                        $0.answer = answer
                        $0.state = .answering
                    }
                }
                self?.finish(id, failure: nil)
            } catch {
                self?.finish(id, failure: error as? AskFailure ?? .provider(AskErrors.oneLine(error.localizedDescription)))
            }
        }
    }

    private func update(_ id: Int, _ change: (inout Exchange) -> Void) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        change(&exchanges[index])
    }

    private func finish(_ id: Int, failure: AskFailure?) {
        let wasTimedOut = timedOut == id
        let isCancelled = Task.isCancelled
        update(id) { exchange in
            if let failure {
                exchange.state = .failed(failure)
            } else if wasTimedOut {
                exchange.state = .failed(.timedOut)
            } else if isCancelled {
                exchange.state = .stopped
            } else if exchange.answer.isEmpty {
                exchange.state = .failed(.exited(0))
            } else {
                exchange.state = .done
            }
        }
        guard let exchange = exchanges.first(where: { $0.id == id }), exchange.state == .done else { return }
        QuickAskSpeech.announce(exchange.answer)
    }

    // MARK: Copy

    func copy(_ exchange: Exchange) {
        ask.copy(exchange.answer)
        justCopied = exchange.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.justCopied == exchange.id { self?.justCopied = nil }
        }
    }
}

/// What VoiceOver says of an answer as it finishes: the answer, to the person's
/// VoiceOver only.
enum QuickAskSpeech {
    @MainActor
    static func announce(_ answer: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: answer,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}
