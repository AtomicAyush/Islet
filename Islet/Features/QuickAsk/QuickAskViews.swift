import AppKit
import SwiftUI

// MARK: - The conversation

/// The box's conversation above the field: each question, quietly, and its answer, from a
/// model or from a command on this Mac (the day summed up).
struct QuickAskConversation: View {
    let session: QuickAskSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.droppedEarlier {
                Text("Earlier questions are no longer sent with follow-ups")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.islandText(0.5))
            }
            ForEach(session.exchanges) { exchange in
                QuickAskExchangeView(session: session, exchange: exchange)
                    // For the box to scroll to the top of the day summed up.
                    .id(exchange.id)
            }
        }
        .padding(.horizontal, 6)
        .animation(.easeOut(duration: 0.18), value: session.exchanges.map(\.state))
    }
}

private struct QuickAskExchangeView: View {
    let session: QuickAskSession
    let exchange: QuickAskSession.Exchange

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(exchange.question)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.islandText(0.55))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("You asked: \(exchange.question)")
            if let local = exchange.local {
                local.answer.view(session.anyway(for: exchange))
            } else {
                if let subject = session.keptHere(before: exchange) {
                    QuickAskKeptHereRow(session: session, exchange: exchange, subject: subject)
                }
                answer
            }
        }
    }

    @ViewBuilder
    private var answer: some View {
        switch exchange.state {
        case .waiting, .slow:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(exchange.state == .slow ? "Still waiting for \(exchange.provider.name)…" : "Thinking…")
                    .font(.system(size: 12))
                    .foregroundStyle(.islandText(0.5))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Answer")
            .accessibilityValue("Answering…")
            // Static text is what carries a value to VoiceOver.
            .accessibilityAddTraits(.isStaticText)
        case .answering:
            AnswerText(text: exchange.answer)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Answer, still coming")
                .accessibilityValue(exchange.answer)
                .accessibilityAddTraits(.isStaticText)
        case .done, .stopped:
            VStack(alignment: .leading, spacing: 6) {
                // The whole answer, to go back to after it is announced.
                AnswerText(text: exchange.answer)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Answer from \(exchange.provider.name)")
                    .accessibilityValue(exchange.answer)
                    .accessibilityAddTraits(.isStaticText)
                QuickAskAnswerActions(session: session, exchange: exchange)
            }
        case .failed(let failure):
            QuickAskFailureRow(session: session, exchange: exchange, failure: failure)
        }
    }
}

/// Over an answer from ChatGPT or Claude to a follow-up to the day summed up: that they
/// weren't shown it, and Apple's model, which would be, to ask instead.
private struct QuickAskKeptHereRow: View {
    let session: QuickAskSession
    let exchange: QuickAskSession.Exchange
    let subject: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.islandGraphic(0.4))
                .accessibilityHidden(true)
            Text("\(subject) stays on this Mac — \(exchange.provider.title) wasn't shown it")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.islandText(0.45))
                .lineLimit(1)
            if exchange.id == session.exchanges.last?.id, !session.isBusy, session.ask.status(of: .onDevice) == .ready {
                InputQuietButton(title: "Ask \(AskProvider.onDevice.name)", symbol: AskProvider.onDevice.symbol) {
                    session.askAgain(with: .onDevice)
                }
                .fixedSize()
                .help("Ask Apple's model on this Mac, which is given \(subject.lowercased())")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Under an answer: Copy, and, under one from this Mac, the same question asked of
/// ChatGPT or Claude.
private struct QuickAskAnswerActions: View {
    let session: QuickAskSession
    let exchange: QuickAskSession.Exchange

    var body: some View {
        HStack(spacing: 8) {
            if exchange.state == .stopped {
                Text("Stopped")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.islandText(0.5))
            }
            if !exchange.answer.isEmpty {
                if session.justCopied == exchange.id {
                    Label("Copied", systemImage: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .islandWashed(.hue(.success, minimum: Contrast.text), wash: 0.16, in: Capsule())
                        .transition(.opacity)
                } else {
                    InputQuietButton(title: "Copy", symbol: "doc.on.doc") { session.copy(exchange) }
                        .help("Copy the answer")
                }
            }
            if exchange.provider == .onDevice, exchange.id == session.exchanges.last?.id,
               let other = QuickAskFallback.cloud(session.ask) {
                InputQuietButton(title: "Ask \(other.name)", symbol: other.symbol) {
                    session.askAgain(with: other)
                }
                .help("Ask \(other.name) the same question")
            }
        }
        .animation(.easeOut(duration: 0.15), value: session.justCopied)
    }
}

/// A question that went unanswered: why, and what might help.
private struct QuickAskFailureRow: View {
    let session: QuickAskSession
    let exchange: QuickAskSession.Exchange
    let failure: AskFailure

    /// Who is offered instead: the sentence names only them.
    private var other: AskProvider? {
        QuickAskFallback.instead(of: exchange.provider, after: failure, session.ask)
    }

    /// Too much for Apple's model with the earlier questions, which can be left out.
    private var canStartAfresh: Bool {
        failure == .tooLong && session.exchanges.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.islandHue(.warning))
                    .accessibilityHidden(true)
                Text(failure.text(for: exchange.provider, instead: other, afresh: canStartAfresh))
                    .font(.system(size: 12))
                    .foregroundStyle(.islandText(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if failure.canRetry {
                    InputQuietButton(title: "Try again", symbol: "arrow.clockwise") { session.retry() }
                }
                if canStartAfresh {
                    InputQuietButton(title: "Start afresh", symbol: "arrow.counterclockwise") { session.startAfresh() }
                        .help("Ask this question again without the earlier ones")
                }
                if let other {
                    InputQuietButton(title: "Ask \(other.name)", symbol: other.symbol) {
                        session.askAgain(with: other)
                    }
                }
                if failure == .notSignedIn, exchange.provider == .claude {
                    InputQuietButton(title: "Connect Claude", symbol: "key.fill") {
                        QuickAskSettingsLink.open()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Where a question goes when its provider can't answer it.
enum QuickAskFallback {
    /// ChatGPT, or Claude, whichever is ready first: for an answer from this Mac.
    @MainActor
    static func cloud(_ ask: QuickAskModel) -> AskProvider? {
        [AskProvider.chatGPT, .claude].first { ask.status(of: $0) == .ready }
    }

    /// Another provider for a question `provider` couldn't answer: this Mac for a
    /// cloud one offline, limited or busy; the cloud for one this Mac refused or
    /// couldn't hold.
    @MainActor
    static func instead(of provider: AskProvider, after failure: AskFailure, _ ask: QuickAskModel) -> AskProvider? {
        switch failure {
        case .offline, .usageLimit, .busy:
            guard provider != .onDevice, ask.status(of: .onDevice) == .ready else { return nil }
            return .onDevice
        case .refused, .tooLong, .unavailable:
            guard provider == .onDevice else { return nil }
            return cloud(ask)
        default:
            return nil
        }
    }
}

/// Settings, on the Activities tab where Quick Ask's own are: to connect Claude.
enum QuickAskSettingsLink {
    @MainActor
    static func open() {
        IslandManager.shared.controllers.values.forEach { $0.model.collapse("Settings for Quick Ask") }
        SettingsWindowController.shared.show(tab: "activities")
    }
}

// MARK: - Who answers

/// The chip after the field: who answers, and a menu to choose, each with whether it
/// can answer now.
struct QuickAskProviderChip: View {
    let session: QuickAskSession

    var body: some View {
        let current = session.provider
        Menu {
            ForEach(AskProvider.allCases) { provider in
                let status = session.ask.status(of: provider)
                Button {
                    session.choose(provider)
                } label: {
                    if provider == current {
                        Label(provider.title, systemImage: "checkmark")
                    } else {
                        Text(provider.title)
                    }
                    Text(status.text(for: provider))
                }
            }
        } label: {
            InputChipLabel(title: current.title, symbol: current.symbol, tint: .quickAsk)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Answered by \(current.title)")
        .accessibilityHint("Chooses who answers")
    }
}

// MARK: - Home

/// The home page tile: a field to click, which opens the box ready to type.
struct QuickAskHomeTile: View {
    let model: QuickAskModel
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ask", systemImage: "questionmark.bubble.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.islandAccentText(.quickAsk, on: .homeTile))
                .lineLimit(1)
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: model.provider.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.islandAccent(.quickAsk, on: IslandBackdrop.homeTile.stacked(0.12)))
                    Text("Ask anything")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.islandText(0.6, on: IslandBackdrop.homeTile.stacked(0.12)))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(.islandSurface(isHovering ? 0.16 : 0.12, on: .homeTile)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(model.shortcut.map { "Ask a quick question (\($0.display))" } ?? "Ask a quick question")
            .accessibilityLabel("Ask anything")
            .accessibilityHint("Opens a box to ask a quick question")
            if let shortcut = model.shortcut {
                Text(shortcut.display)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.islandText(0.45, on: .homeTile))
                    .accessibilityHidden(true)
            }
        }
    }
}
