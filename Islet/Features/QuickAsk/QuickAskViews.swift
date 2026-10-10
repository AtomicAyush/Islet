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
            if let snapshot = exchange.snapshot {
                QuickAskPictureLine(snapshot: snapshot, provider: exchange.provider)
            }
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
        case .offered:
            QuickAskCalendarOffer(session: session, exchange: exchange)
        }
    }
}

/// A question about the calendar meant for ChatGPT or Claude, not sent: that the calendar
/// stays on this Mac, and Apple's model, which reads it here, to ask instead; or the
/// question alone, asked anyway.
private struct QuickAskCalendarOffer: View {
    let session: QuickAskSession
    let exchange: QuickAskSession.Exchange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.islandGraphic(0.5))
                    .accessibilityHidden(true)
                Text("Your calendar stays on this Mac, so \(exchange.provider.title) can't see it. \(AskProvider.onDevice.name) can read it here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.islandText(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if exchange.id == session.exchanges.last?.id, !session.isBusy {
                HStack(spacing: 8) {
                    InputQuietButton(title: "Ask \(AskProvider.onDevice.name)", symbol: AskProvider.onDevice.symbol) {
                        session.askAgain(with: .onDevice)
                    }
                    .help("Ask Apple's model on this Mac, which reads your calendar here")
                    InputQuietButton(title: "Ask \(exchange.provider.title) anyway", symbol: exchange.provider.symbol) {
                        session.askAgain(with: exchange.provider)
                    }
                    .help("Send \(exchange.provider.title) just the question, without your calendar")
                }
            }
        }
        .accessibilityElement(children: .contain)
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
/// ChatGPT or Claude (unless it was answered from the calendar), or a way to allow
/// calendar access when Apple's model found it off.
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
            // As Quick Calendar's box offers it: nothing to press when a profile restricts it.
            if let access = exchange.calendarAccess, access != .restricted {
                let allow = access == .undetermined
                InputQuietButton(title: allow ? "Allow Calendar access" : "Open Privacy Settings",
                                 symbol: allow ? "lock.open" : "gearshape") {
                    session.ask.calendar.allowAccess()
                }
                .help(allow ? "Let Islet read your calendars" : "Calendar access is off in System Settings")
            }
            // ChatGPT and Claude can't answer from the calendar: not offered under an answer that did.
            if exchange.provider == .onDevice, exchange.id == session.exchanges.last?.id, !exchange.fromCalendar,
               let other = QuickAskFallback.cloud(session.ask, seeing: exchange.snapshot != nil) {
                InputQuietButton(title: "Ask \(other.name)", symbol: other.symbol) {
                    session.askAgain(with: other)
                }
                .help(exchange.snapshot == nil ? "Ask \(other.name) the same question"
                      : "Ask \(other.name) the same question, sending it the picture")
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
        QuickAskFallback.instead(of: exchange.provider, after: failure, seeing: exchange.snapshot != nil, session.ask)
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
                    .help(exchange.snapshot == nil || other == .onDevice ? "Ask \(other.name) the same question"
                          : "Ask \(other.name) the same question, sending it the picture")
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
    /// ChatGPT, Claude or Gemini, whichever is ready first: for an answer from this Mac.
    /// `seeing`, the question came with a picture, and only one that can see it will do.
    @MainActor
    static func cloud(_ ask: QuickAskModel, seeing: Bool = false) -> AskProvider? {
        [AskProvider.chatGPT, .claude, .gemini].first { ask.status(of: $0) == .ready && (!seeing || ask.takesImages($0)) }
    }

    /// Another that can see a picture, for one that can't: this Mac first, where it stays.
    @MainActor
    static func seeing(besides provider: AskProvider, _ ask: QuickAskModel) -> AskProvider? {
        AskProvider.allCases.first { $0 != provider && ask.takesImages($0) }
    }

    /// Another provider for a question `provider` couldn't answer: this Mac for a
    /// cloud one offline, limited or busy; the cloud for one this Mac refused or
    /// couldn't hold; any other that is ready, the cloud first, for one that couldn't
    /// sign in. `seeing`, the question came with a picture, which it must see.
    @MainActor
    static func instead(of provider: AskProvider, after failure: AskFailure, seeing: Bool = false,
                        _ ask: QuickAskModel) -> AskProvider? {
        switch failure {
        case .offline, .usageLimit, .busy:
            guard provider != .onDevice, ask.status(of: .onDevice) == .ready, !seeing || ask.takesImages(.onDevice)
            else { return nil }
            return .onDevice
        case .refused, .tooLong, .unavailable:
            guard provider == .onDevice else { return nil }
            return cloud(ask, seeing: seeing)
        case .cantSee:
            return Self.seeing(besides: provider, ask)
        case .signIn:
            return [AskProvider.chatGPT, .claude, .onDevice].first {
                $0 != provider && ask.status(of: $0) == .ready && (!seeing || ask.takesImages($0))
            }
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
            ForEach(AskProvider.allCases.filter { $0 == current || AskProvider.isOffered($0, session.ask.status(of:)) }) { provider in
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

// MARK: - Looking at the screen

/// Beside the field: "Look at my screen" (⇧⌘S). A click takes one picture, then, of the
/// front window or the whole display as chosen, for the next question; held, a menu to
/// choose which, which is remembered.
struct QuickAskLookButton: View {
    let session: QuickAskSession

    var body: some View {
        let target = session.ask.lookTarget
        Menu {
            ForEach(ScreenLookTarget.allCases) { choice in
                Button {
                    session.look(at: choice)
                } label: {
                    if choice == target {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            QuickAskLookLabel(isOn: session.snapshot != nil)
        } primaryAction: {
            session.look(at: nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Look at my screen (⇧⌘S): a picture of the \(target.title.lowercased()) goes with your next question. Hold to choose what")
        .accessibilityLabel("Look at my screen")
        .accessibilityHint("Takes a picture of the \(target.title.lowercased()) for your next question")
    }
}

/// The look button's face: an eye, lit while a picture waits to go.
struct QuickAskLookLabel: View {
    let isOn: Bool

    var body: some View {
        Group {
            if isOn {
                Image(systemName: "eye.fill")
                    .islandWashed(.accent(.quickAsk, minimum: Contrast.text), wash: 0.2, in: Circle())
            } else {
                Image(systemName: "eye")
                    .foregroundStyle(.islandText(0.7, on: .surface(0.12)))
                    .background(Circle().fill(.islandSurface(0.12)))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(width: InputBoxLayout.chipHeight, height: InputBoxLayout.chipHeight)
        .contentShape(Circle())
    }
}

/// Over the field: the picture that goes with the next question as it will be sent, what
/// it is of, and where it goes, with ✕ to take it away; or, while there is none, why.
struct QuickAskLookPreview: View {
    let session: QuickAskSession

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            content
            Spacer(minLength: 0)
            Button {
                session.removeSnapshot()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.islandText(0.7, on: .surface(0.12)))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.islandSurface(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(session.snapshot == nil ? "Close" : "Don't send the picture")
            .accessibilityLabel(session.snapshot == nil ? "Close" : "Remove the picture")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.islandSurface(0.08)))
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = session.snapshot {
            picture(snapshot)
        } else {
            switch session.lookState {
            case .looking:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    line("Looking…", 0.6)
                }
            case .failed(.permissionOff):
                problem(symbol: "eye.slash", title: "Islet can't see your screen yet",
                        detail: "Turn Islet on in Privacy & Security › Screen Recording, then press Look again.") {
                    InputQuietButton(title: "Open System Settings", symbol: "gearshape") { ScreenPermission.openSettings() }
                }
            case .failed(.noWindow(let app)):
                problem(symbol: "macwindow", title: "\(app ?? "The app in front") has no window to look at", detail: nil) {
                    InputQuietButton(title: "Look at the whole display", symbol: ScreenLookTarget.display.symbol) {
                        session.look(at: .display, remember: false)
                    }
                }
            case .failed(.failed), nil:
                problem(symbol: "exclamationmark.triangle.fill", title: "The picture couldn't be taken", detail: nil) {
                    InputQuietButton(title: "Try again", symbol: "arrow.clockwise") { session.look(at: nil) }
                }
            }
        }
    }

    private func picture(_ snapshot: ScreenSnapshot) -> some View {
        let provider = session.provider
        let sees = session.ask.takesImages(provider)
        let other = sees ? nil : QuickAskFallback.seeing(besides: provider, session.ask)
        return HStack(spacing: 10) {
            Image(decorative: snapshot.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 76, maxHeight: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.islandDecorative(0.2)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                line("\(snapshot.source) — \(snapshot.target.title.lowercased())", 0.85, weight: .semibold)
                if sees {
                    HStack(spacing: 4) {
                        Image(systemName: provider == .onDevice ? "lock.fill" : "arrow.up.forward")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.islandGraphic(0.5))
                            .accessibilityHidden(true)
                        line(provider.pictureGoes, 0.6)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.islandHue(.warning))
                            .accessibilityHidden(true)
                        line("\(provider.name) can't see pictures", 0.75)
                        if let other {
                            InputQuietButton(title: "Ask \(other.name)", symbol: other.symbol) { session.choose(other) }
                                .fixedSize()
                                .help("\(other.name) answers instead: \(other.pictureGoes.lowercased())")
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Picture of \(snapshot.what), for your next question. "
                            + (sees ? provider.pictureGoes : "\(provider.name) can't see pictures"))
    }

    private func problem(symbol: String, title: String, detail: String?, @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.islandHue(.warning))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                line(title, 0.85, weight: .semibold)
                if let detail {
                    line(detail, 0.6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                action()
            }
        }
    }

    private func line(_ text: String, _ alpha: Double, weight: Font.Weight = .medium) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: weight))
            .foregroundStyle(.islandText(alpha))
            .lineLimit(2)
    }
}

/// Over a question that went with a picture: a thumbnail of it, and where it went.
private struct QuickAskPictureLine: View {
    let snapshot: ScreenSnapshot
    let provider: AskProvider

    var body: some View {
        HStack(spacing: 6) {
            Image(decorative: snapshot.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 30, maxHeight: 18)
                .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                .accessibilityHidden(true)
            Text("With a picture of \(snapshot.what) · \(provider == .onDevice ? "stayed on this Mac" : "sent to \(provider.title)")")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.islandText(0.45))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
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
