import AppKit
import SwiftUI
import Observation

/// The box's conversation: each question asked and its answer, in order, whether a
/// model answered it or a command did on this Mac (the day summed up), in memory only.
/// Follow-ups go on from it while the island is open, the box closed and opened again
/// meanwhile or not; the island closing forgets all of it (`close()`), stopping any
/// answer still coming.
///
/// "Look at my screen" takes one picture, then and only then, which goes with the next
/// question asked of a model and stays with that exchange. It is sent once: follow-ups
/// to ChatGPT and Claude carry the conversation in words, saying a picture went, and not
/// the picture again (press the control again for a fresh look); Apple's model, whose
/// conversation goes on in memory on this Mac, still has it. What a command answers on
/// this Mac (the day summed up) is never sent with it, and leaves it for the next question.
@MainActor
@Observable
final class QuickAskSession: InputSession {
    struct Exchange: Identifiable, Equatable {
        let id: Int
        let question: String
        var provider: AskProvider
        var answer = ""
        var state = State.waiting
        /// Answered on this Mac by a command rather than by a model.
        var local: Local?
        /// Answered by Apple's model given a command's answer, which it may repeat: kept
        /// from ChatGPT and Claude as that answer is.
        var drawsOn: Local?
        /// The picture of the screen that went with the question.
        var snapshot: ScreenSnapshot?
    }

    /// "Look at my screen", before a picture is ready or instead of one.
    enum Look: Equatable {
        case looking
        case failed(ScreenLookFailure)
    }

    /// A command's answer in the conversation.
    struct Local: Equatable {
        let commandID: String
        let symbol: String
        let answer: InputCommandAnswer

        static func == (lhs: Local, rhs: Local) -> Bool {
            lhs.commandID == rhs.commandID && lhs.answer.key == rhs.answer.key
        }
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
    /// The picture of the screen for the next question, shown over the field until it goes.
    private(set) var snapshot: ScreenSnapshot?
    /// Taking the picture, or why it wasn't taken.
    private(set) var lookState: Look?

    @ObservationIgnored let ask: QuickAskModel
    /// How long before "Still waiting", and before an answer is given up on. Tests
    /// shorten them.
    @ObservationIgnored var slowAfter = AskLimits.slow
    @ObservationIgnored var giveUpAfter = AskLimits.total
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var nextID = 0
    /// The exchange whose time ran out, as its task ends.
    @ObservationIgnored private var timedOut: Int?
    @ObservationIgnored private var lookTask: Task<Void, Never>?
    /// The box, for the island it is on.
    @ObservationIgnored private weak var box: InputBox?

    init(ask: QuickAskModel) {
        self.ask = ask
        provider = ask.provider
    }

    /// An answer is coming: to the latest question asked of a model, whatever was
    /// answered on this Mac since.
    var isBusy: Bool {
        exchanges.contains { [.waiting, .slow, .answering].contains($0.state) }
    }

    // MARK: InputSession

    func above() -> AnyView? {
        exchanges.isEmpty ? nil : AnyView(QuickAskConversation(session: self))
    }

    func overField() -> AnyView? {
        snapshot == nil && lookState == nil ? nil : AnyView(QuickAskLookPreview(session: self))
    }

    func trailingChip() -> AnyView? {
        AnyView(HStack(spacing: 6) {
            QuickAskLookButton(session: self)
            QuickAskProviderChip(session: self)
        })
    }

    func attach(to box: InputBox) {
        self.box = box
    }

    func lookAtScreen() {
        look(at: nil)
    }

    func opened() {
        ask.refreshStatuses()
        provider = ask.provider
        ask.backend(provider).prepare()
    }

    func submit(_ draft: String) -> Bool {
        // A follow-up to what a command answered, that it answers too, is answered here.
        if let local = localFollowUp(draft) {
            append(draft.trimmingCharacters(in: .whitespacesAndNewlines), local)
            return true
        }
        // A picture being taken goes with this question: Return waits for it.
        guard lookState != .looking else { return false }
        return send(draft, showing: snapshot)
    }

    /// Words a command answered, sent on: without the picture, which wasn't asked about.
    func sendOn(_ text: String) -> Bool {
        send(text, showing: nil)
    }

    /// Asks `text` of the provider, with the picture if there is one; one that can't
    /// see pictures isn't asked, and the preview says so.
    private func send(_ text: String, showing image: ScreenSnapshot?) -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy else { return false }
        if image != nil, !ask.takesImages(provider) { return false }
        nextID += 1
        exchanges.append(Exchange(id: nextID, question: question, provider: provider, snapshot: image))
        if image != nil {
            snapshot = nil
            lookState = nil
        }
        run(exchanges.count - 1)
        return true
    }

    func keep(_ answer: InputCommandAnswer, to text: String, from command: InputCommand) -> Bool {
        append(text, Local(commandID: command.id, symbol: command.symbol, answer: answer))
        return true
    }

    func answersHere(_ draft: String) -> InputHint? {
        localFollowUp(draft).map { InputHint(text: $0.answer.hint, symbol: $0.symbol) }
    }

    func commandStopped(_ id: String) {
        exchanges.removeAll { $0.local?.commandID == id }
    }

    var latestFromTop: AnyHashable? {
        guard let last = exchanges.last, last.local != nil else { return nil }
        return AnyHashable(last.id)
    }

    func stop() {
        task?.cancel()
    }

    func close() {
        task?.cancel()
        task = nil
        lookTask?.cancel()
        lookTask = nil
        exchanges = []
        snapshot = nil
        lookState = nil
        droppedEarlier = false
        justCopied = nil
        ask.closeBackends()
    }

    // MARK: Looking at the screen

    /// Takes one picture, now, of what `target` says (or the setting), for the next
    /// question; it replaces one not yet sent, which goes as it starts. `remember`, the
    /// choice becomes the setting (the eye's menu); otherwise it is for this picture only.
    /// With Screen Recording off, macOS is asked (the first time) and the box says how to
    /// turn it on; nothing is taken.
    func look(at target: ScreenLookTarget?, remember: Bool = true) {
        if let target, remember { ask.lookTarget = target }
        guard lookTask == nil else { return }
        ask.refreshScreenPermission()
        guard ask.screenPermission == .granted else {
            ask.askForScreen()
            snapshot = nil
            lookState = .failed(.permissionOff)
            return
        }
        let request = ScreenCaptureRequest(
            target: target ?? ask.lookTarget, displayID: ask.islandDisplay(box?.island),
            frontmost: box?.island?.appInFront(), excluding: getpid()
        )
        let capturer = ask.capturer
        snapshot = nil
        lookState = .looking
        lookTask = Task { [weak self] in
            let result: Result<ScreenSnapshot, ScreenLookFailure>
            do {
                let capture = try await capturer.capture(request)
                result = ScreenSnapshot.make(from: capture, target: request.target).map { .success($0) } ?? .failure(.failed)
            } catch {
                result = .failure(error as? ScreenLookFailure ?? .failed)
            }
            guard let self, !Task.isCancelled else { return }
            lookTask = nil
            switch result {
            case .success(let taken):
                snapshot = taken
                lookState = nil
            case .failure(let failure):
                lookState = .failed(failure)
            }
        }
    }

    /// ✕ on the preview: the picture goes, unsent, or the line saying why there isn't one.
    func removeSnapshot() {
        lookTask?.cancel()
        lookTask = nil
        snapshot = nil
        lookState = nil
    }

    // MARK: Asking

    /// Asks the next question of `provider`, and remembers the choice.
    func choose(_ provider: AskProvider) {
        self.provider = provider
        ask.choose(provider)
        ask.backend(provider).prepare()
    }

    /// Asks the last question again of `provider` ("Ask ChatGPT" under an answer from
    /// this Mac, or "Ask ChatGPT anyway" under the day), in the answer's place.
    func askAgain(with provider: AskProvider) {
        guard !isBusy, let last = exchanges.indices.last else { return }
        self.provider = provider
        exchanges[last].provider = provider
        exchanges[last].answer = ""
        exchanges[last].state = .waiting
        exchanges[last].local = nil
        run(last)
    }

    /// Under the latest answer a command gave, while nothing is coming: its words asked
    /// of whoever answers, in its place.
    func anyway(for exchange: Exchange) -> InputAnyway? {
        guard exchange.local != nil, exchange.id == exchanges.last?.id, !isBusy else { return nil }
        let provider = provider
        return InputAnyway(name: provider.name, onThisMac: provider == .onDevice) { [weak self] in self?.askAgain(with: provider) }
    }

    /// What a model off this Mac wasn't shown, over its answer to the question straight
    /// after a command's, or after Apple's model's answer from one: "Your day".
    func keptHere(before exchange: Exchange) -> String? {
        guard exchange.local == nil, exchange.provider != .onDevice,
              let index = exchanges.firstIndex(where: { $0.id == exchange.id }), index > 0
        else { return nil }
        let before = exchanges[index - 1]
        return (before.local ?? before.drawsOn)?.answer.subject
    }

    /// The answer a command gives to `text` as a follow-up to the latest exchange, if
    /// that was the command's.
    private func localFollowUp(_ text: String) -> Local? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let last = exchanges.last?.local, let answer = last.answer.followUp(text) else { return nil }
        return Local(commandID: last.commandID, symbol: last.symbol, answer: answer)
    }

    private func append(_ question: String, _ local: Local) {
        nextID += 1
        exchanges.append(Exchange(id: nextID, question: question, provider: provider, state: .done, local: local))
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
        // Only exchanges that were answered go with a follow-up, the latest few of them.
        let answered = exchanges[..<index].filter { $0.state == .done }
        let given = answered.suffix(Self.maxExchanges - 1)
        // Apple's model given a command's answer, or its own answer from one, may repeat it.
        exchanges[index].drawsOn = exchanges[index].provider == .onDevice
            ? given.compactMap { $0.local ?? $0.drawsOn }.last : nil
        let exchange = exchanges[index]
        let earlier = given.map { Self.turn($0, for: exchange.provider) }
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
                for try await answer in backend.answer(exchange.question, showing: exchange.snapshot, after: Array(earlier)) {
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

    /// An exchange as it goes with a follow-up to `provider`. What a command answered goes
    /// in words only to Apple's model, on this Mac; ChatGPT and Claude are told only that
    /// there was such an answer, and that it stays private, and are told the same in place
    /// of Apple's model's answers from it.
    static func turn(_ exchange: Exchange, for provider: AskProvider) -> AskTurn {
        if let local = exchange.local {
            return AskTurn(question: exchange.question, answer: provider == .onDevice ? local.answer.words() : local.answer.note)
        }
        if provider != .onDevice, let local = exchange.drawsOn {
            return AskTurn(question: exchange.question, answer: local.answer.note, hadPicture: exchange.snapshot != nil)
        }
        return AskTurn(question: exchange.question, answer: exchange.answer, hadPicture: exchange.snapshot != nil)
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
