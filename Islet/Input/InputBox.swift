import AppKit
import SwiftUI
import Observation

/// What the input box holds: its mode, the draft and each mode's session. Memory only:
/// the draft until typing in the box ends (kept open, until the island closes), and the
/// rest, the conversation among it, until the island it was typed in closes
/// (`typingEnded(_:)`, `forget()`). Nothing of it is written anywhere, logged or put in a
/// URL.
@MainActor
@Observable
final class InputBox {
    enum Key {
        /// Keep Open's hint has been shown (`showsKeepOpenHint`): a flag, never anything
        /// typed.
        static let keepOpenHintShown = "input.keepOpenHintShown"
    }

    /// The mode the box is in, while it is open.
    var modeID: String?
    var draft = "" {
        didSet {
            guard draft != oldValue else { return }
            if switchesMode() { return }
            session?.draftChanged(draft)
            suggestion = offer()
        }
    }
    /// Another mode offering to take the draft over, and its line.
    private(set) var suggestion: (modeID: String, line: String)?
    /// A command answered in a mode that keeps no conversation, with the words that
    /// asked for it: shown until the next thing is sent, the mode changes or the island
    /// closes.
    private(set) var command: (id: String, text: String, answer: InputCommandAnswer)?
    /// The island typing in the box.
    @ObservationIgnored weak var island: IslandViewModel?
    @ObservationIgnored weak var center: InputCenter?
    /// Told as the box's height changes, for the page to be published at it.
    @ObservationIgnored var heightChanged: () -> Void = {}
    /// Where Keep Open's hint is remembered. Tests replace it.
    @ObservationIgnored var defaults = UserDefaults.standard
    /// Whether the box shows its header, with Keep Open: from the first time something
    /// is asked or added in it, or anything shows above the field, for as long as the
    /// island is open, so the field does not move as the next thing is typed.
    private(set) var showsHeader = false { didSet { reportHeight(oldValue != showsHeader) } }
    /// Keep Open's hint in the header, "Keep Open to read it while you work": up from
    /// the first time there is something above the field while the box is typed in and
    /// the pointer is away from the island, the person on their way to another app,
    /// until Keep Open is clicked or the island closes. Only ever once
    /// (`Key.keepOpenHintShown`).
    private(set) var showsKeepOpenHint = false

    private var sessions: [String: any InputSession] = [:]

    init() {
        // What the box holds goes as the island it was typed in closes, however long
        // after typing ended.
        NotificationCenter.default.addObserver(forName: IslandViewModel.didCloseNotification, object: nil, queue: nil) { [weak self] note in
            let closed = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, let island = self.island, closed == ObjectIdentifier(island) else { return }
                self.forget()
            }
        }
    }

    /// The field's row, the conversation above it and the preview below, as drawn.
    var rowHeight: CGFloat = InputBoxLayout.rowHeight { didSet { reportHeight(oldValue != rowHeight) } }
    var aboveHeight: CGFloat = 0 {
        didSet {
            if aboveHeight > 0 { showsHeader = true }
            reportHeight(oldValue != aboveHeight)
            offerKeepOpenHint()
        }
    }
    var belowHeight: CGFloat = 0 { didSet { reportHeight(oldValue != belowHeight) } }
    var overHeight: CGFloat = 0 { didSet { reportHeight(oldValue != overHeight) } }

    var session: (any InputSession)? {
        modeID.flatMap { sessions[$0] }
    }

    var mode: InputMode? {
        center?.modes.first { $0.id == modeID }
    }

    /// The page's height: the row, with the header and what is above and below it, up to
    /// the most the island has room for; past that, the conversation scrolls.
    var height: CGFloat {
        min(max(InputBoxLayout.inset * 2 + extra(headerHeight) + rowHeight + extra(aboveHeight) + extra(overHeight)
                + extra(belowHeight), InputBoxLayout.minimumHeight),
            InputBoxLayout.maximumHeight)
    }

    /// How tall the conversation above the field may be drawn, before it scrolls.
    var aboveRoom: CGFloat {
        max(0, min(aboveHeight, height - InputBoxLayout.inset * 2 - extra(headerHeight) - rowHeight - extra(overHeight)
                   - extra(belowHeight) - InputBoxLayout.spacing))
    }

    private var headerHeight: CGFloat {
        showsHeader ? InputBoxLayout.headerHeight : 0
    }

    private func extra(_ part: CGFloat) -> CGFloat {
        part > 0 ? part + InputBoxLayout.spacing : 0
    }

    private func reportHeight(_ changed: Bool) {
        if changed { heightChanged() }
    }

    /// Shows `mode`, making its session as it is first used while the box is open.
    func show(_ mode: InputMode) {
        if sessions[mode.id] == nil {
            let session = mode.makeSession()
            session.attach(to: self)
            sessions[mode.id] = session
        }
        guard modeID != mode.id else { return }
        modeID = mode.id
        command = nil
        belowHeight = 0
        aboveHeight = 0
        overHeight = 0
        session?.draftChanged(draft)
        suggestion = offer()
    }

    /// Takes up the offer of another mode: the box moves to it, the draft and all.
    func takeSuggestion() {
        guard let suggestion, let mode = center?.modes.first(where: { $0.id == suggestion.modeID }) else { return }
        show(mode)
        session?.opened()
    }

    /// The first other mode's offer for the draft.
    private func offer() -> (modeID: String, line: String)? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let modes = center?.modes, center?.command(for: text) == nil,
              session?.answersHere(text) == nil else { return nil }
        for mode in modes where mode.id != modeID {
            if let line = mode.suggest?(text) { return (mode.id, line) }
        }
        return nil
    }

    /// Return in the field.
    func submit() {
        if answersCommand() { return }
        guard let session, session.submit(draft) else { return }
        command = nil
        draft = ""
        showsHeader = true
    }

    // MARK: Commands

    /// The draft asks for a command: it is answered here, and goes nowhere else. A mode
    /// that keeps a conversation keeps the answer in it.
    private func answersCommand() -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let found = center?.command(for: text) else { return false }
        let answer = found.answer(text)
        command = session?.keep(answer, to: text, from: found) == true ? nil : (found.id, text, answer)
        draft = ""
        showsHeader = true
        return true
    }

    /// The command's answer, above the field, in a mode that keeps no conversation.
    func commandView() -> AnyView? {
        guard let command else { return nil }
        return AnyView(command.answer.view(anyway(command.text)).padding(.horizontal, 6))
    }

    /// The command the draft asks for, as it is typed.
    var pendingCommand: InputCommand? {
        center?.command(for: draft)
    }

    /// What Return will do instead of sending the draft, if it will: answer a command, or
    /// a follow-up to one, on this Mac.
    var pendingHint: InputHint? {
        if let command = pendingCommand { return InputHint(text: command.hint, symbol: command.symbol) }
        return session?.answersHere(draft)
    }

    /// Sending the words a command answered on to the mode that sends drafts off, if one
    /// is registered: only those words, never the command's answer.
    func anyway(_ text: String) -> InputAnyway? {
        guard let mode = center?.modes.first(where: { $0.recipient != nil }), let name = mode.recipient?() else { return nil }
        return InputAnyway(name: name) { [weak self] in
            guard let self, let mode = self.center?.modes.first(where: { $0.id == mode.id }) else { return }
            self.command = nil
            self.show(mode)
            _ = self.session?.sendOn(text)
        }
    }

    /// A command's feature stopped: its answers go.
    func forgetCommand(_ id: String) {
        if command?.id == id { command = nil }
        for session in sessions.values { session.commandStopped(id) }
    }

    /// One of the island's own key equivalents.
    func key(_ action: IslandKeyAction) {
        switch action {
        case .accept:
            if answersCommand() { return }
            if suggestion != nil {
                takeSuggestion()
                return
            }
            guard let session, session.accept(draft) else { return }
            draft = ""
            showsHeader = true
        case .mode(let index):
            guard let modes = center?.modes, modes.indices.contains(index) else { return }
            show(modes[index])
        case .close:
            island?.endTyping(.close)
        case .look:
            session?.lookAtScreen()
        }
    }

    /// Typing in the box ended. The draft goes; the conversation stays while the island
    /// is open, to go on from when the box is opened there again, and goes as it closes.
    /// Kept open, the draft stays too, to go on with once back from the other app.
    /// Typing ending as the island closes or goes, the feature stops or the box moves to
    /// another island forgets it at once.
    func typingEnded(_ reason: TypingEnd) {
        switch reason {
        case .collapse, .invalidated, .featureStopped, .otherIsland:
            forget()
        default:
            guard island?.isExpanded == true else { return forget() }
            if isKeptOpen { return }
            draft = ""
            suggestion = nil
        }
    }

    // MARK: Keep Open

    /// Whether the island the box is typed in is kept open on it, to read it while
    /// typing in another app.
    var isKeptOpen: Bool {
        island?.keptOpenPage == InputCenter.pageID
    }

    /// Keep Open, in the header, on the island showing the box.
    func toggleKeepingOpen(on island: IslandViewModel) {
        island.toggleKeepingOpen(InputCenter.pageID, for: .reading)
        if island.keptOpenPage == InputCenter.pageID { showsKeepOpenHint = false }
    }

    /// Shows Keep Open's hint if now is the first time for it (`showsKeepOpenHint`): as
    /// something shows above the field, and as the pointer leaves the island.
    func offerKeepOpenHint() {
        guard !showsKeepOpenHint, aboveHeight > 0, let island, !island.isHovering,
              island.typingPlace == .page(InputCenter.pageID), !isKeptOpen,
              !defaults.bool(forKey: Key.keepOpenHintShown) else { return }
        defaults.set(true, forKey: Key.keepOpenHintShown)
        showsKeepOpenHint = true
    }

    /// A mode's feature stopped: what the box held in it goes, and all of it if the box
    /// was in that mode.
    func forget(mode id: String) {
        if modeID == id {
            forget()
        } else {
            sessions.removeValue(forKey: id)?.close()
        }
    }

    /// The island closed, or the box moved to another: every session forgets what it
    /// held, and the draft goes.
    func forget() {
        for session in sessions.values { session.close() }
        sessions = [:]
        draft = ""
        island = nil
        modeID = nil
        suggestion = nil
        command = nil
        aboveHeight = 0
        belowHeight = 0
        overHeight = 0
        showsHeader = false
        showsKeepOpenHint = false
    }

    /// A draft that begins with another mode's prefix ("+") moves to that mode, without
    /// the prefix. The prefix goes first, so the mode is shown the draft it will keep
    /// (a change made here doesn't call `didSet` again).
    private func switchesMode() -> Bool {
        guard let first = draft.first,
              let target = center?.modes.first(where: { $0.prefix == first && $0.id != modeID })
        else { return false }
        draft.removeFirst()
        show(target)
        return true
    }
}

enum InputBoxLayout {
    /// The field's row as it first opens: one line, with its chips.
    static let rowHeight: CGFloat = 40
    static let inset: CGFloat = 8
    static let spacing: CGFloat = 8
    /// The page as it first opens: the row alone.
    static let minimumHeight: CGFloat = 56
    /// The most the page grows to: the opened island stays well inside its window.
    static let maximumHeight: CGFloat = 216
    static let chipHeight: CGFloat = 26
    /// The header's row, with Keep Open (`InputBox.showsHeader`).
    static let headerHeight: CGFloat = 18
    static let fieldLines = 1...4
}

/// The input box's page: its header with Keep Open once there is something to keep,
/// what the mode shows above the field, the field between the mode's chip and its own,
/// and what the mode shows below.
struct InputBoxView: View {
    let center: InputCenter
    @Environment(\.island) private var island
    @SwiftUI.FocusState private var isFocused: Bool
    private static let end = "end"

    var body: some View {
        let box = center.box
        VStack(spacing: InputBoxLayout.spacing) {
            if box.showsHeader, let island {
                InputBoxHeader(
                    isKept: island.keptOpenPage == InputCenter.pageID, showsHint: box.showsKeepOpenHint,
                    tint: box.mode?.tint ?? .quickAsk
                ) {
                    box.toggleKeepingOpen(on: island)
                }
            }
            if let above = box.commandView() ?? box.session?.above() {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            above
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear
                                .frame(height: 0)
                                .id(Self.end)
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.aboveHeight = $0 }
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: box.aboveRoom)
                    // Past the most the box grows to, it follows what comes in.
                    .onChange(of: [box.aboveHeight, box.aboveRoom]) { _, _ in
                        // A command's answer is read from its top, in the conversation too.
                        guard box.command == nil else { return }
                        let top = box.session?.latestFromTop
                        // Again once a row that fades in (Copy) has settled.
                        for delay in [0, 0.3] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                if let top {
                                    proxy.scrollTo(top, anchor: .top)
                                } else {
                                    proxy.scrollTo(Self.end, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            if let over = box.session?.overField() {
                over
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.overHeight = $0 }
                    .onDisappear { box.overHeight = 0 }
            }
            row(box)
                // Its own height, however many lines the field has, for the box to grow to.
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.rowHeight = $0 }
            if let below = box.pendingHint.map({ AnyView(InputCommandHint(hint: $0)) }) ?? box.session?.below()
                ?? box.suggestion.map({ AnyView(InputSuggestionRow(box: box, line: $0.line)) }) {
                below
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.belowHeight = $0 }
            }
        }
        .padding(.vertical, InputBoxLayout.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The pointer leaving for another app, with an answer showing: the first time,
        // the header says Keep Open would keep it.
        .onChange(of: island?.isHovering ?? false) { _, isHovering in
            if !isHovering { box.offerKeepOpenHint() }
        }
    }

    private var isTypingHere: Bool {
        island?.typingPlace == .page(InputCenter.pageID)
    }

    private func row(_ box: InputBox) -> some View {
        let mode = box.mode ?? center.modes.first
        return HStack(alignment: .center, spacing: 8) {
            if let mode {
                InputModeChip(center: center, mode: mode)
            }
            field(box, mode: mode)
            if let chip = box.session?.trailingChip() {
                chip
            }
            InputSendButton(box: box)
        }
        .frame(minHeight: InputBoxLayout.rowHeight)
    }

    private func field(_ box: InputBox, mode: InputMode?) -> some View {
        @Bindable var box = box
        return ZStack(alignment: .leading) {
            if box.draft.isEmpty {
                Text(mode?.placeholder ?? "")
                    .foregroundStyle(.islandText(0.45))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextField("", text: $box.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(.islandPrimary)
                .lineLimit(InputBoxLayout.fieldLines)
                .focused($isFocused)
                .onSubmit { box.submit() }
                .onKeyPress(.return, phases: .down) { press in
                    // Shift- or Option-Return starts a new line; Return alone sends.
                    guard !press.modifiers.isDisjoint(with: [.shift, .option]) else { return .ignored }
                    NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                    return .handled
                }
                .onKeyPress(.escape) {
                    island?.endTyping(.escape)
                    return .handled
                }
                .onExitCommand { island?.endTyping(.escape) }
                .accessibilityLabel(mode?.title ?? "")
                .accessibilityAction(.escape) { island?.endTyping(.escape) }
            if !isTypingHere {
                // Shown without the keyboard (from a URL, or on another display): a
                // click on the field is the person asking to type.
                Rectangle()
                    .fill(.islandDecorative(0))
                    .contentShape(Rectangle())
                    .onTapGesture { center.open(box.modeID, on: island) }
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: island?.focusRequest ?? 0, initial: true) { _, _ in takeCaret() }
        .onChange(of: box.modeID) { _, _ in takeCaret() }
    }

    /// The caret goes into the field once the island has the keyboard: a turn after
    /// typing begins.
    private func takeCaret() {
        guard isTypingHere else { return }
        DispatchQueue.main.async { isFocused = true }
    }
}

/// The box's header: Keep Open, to read what is in the box while typing in another app,
/// and the first time there is an answer to read, a line saying so.
struct InputBoxHeader: View {
    let isKept: Bool
    let showsHint: Bool
    let tint: FeatureTint
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 8)
            // Beside the button it points to.
            if showsHint, !isKept {
                HStack(spacing: 4) {
                    Text("Keep Open to read it while you work")
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .accessibilityHidden(true)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.islandText(0.55))
                .transition(.opacity)
            }
            KeepOpenButton(
                isOn: isKept, tint: tint, purpose: "to read it while you work in another app",
                letGoHelp: "Let the island close again (Esc in the box)", action: toggle
            )
        }
        .padding(.horizontal, 6)
        .frame(height: InputBoxLayout.headerHeight)
        .animation(.easeOut(duration: 0.2), value: showsHint && !isKept)
    }
}

/// The box's mode, as a chip before the field: a menu of the others where there are
/// others (⌘1, ⌘2…).
private struct InputModeChip: View {
    let center: InputCenter
    let mode: InputMode

    var body: some View {
        let label = InputChipLabel(title: mode.title, symbol: mode.symbol, tint: mode.tint)
        if center.modes.count > 1 {
            Menu {
                ForEach(Array(center.modes.enumerated()), id: \.element.id) { index, other in
                    Button {
                        center.box.show(other)
                    } label: {
                        Label(other.title, systemImage: other.symbol)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Mode: \(mode.title)")
            .accessibilityHint("Chooses what the box does")
        } else {
            label
                .accessibilityLabel("Mode: \(mode.title)")
        }
    }
}

/// A chip in the box's row: a symbol in its feature's colour, and a word, on a wash of
/// the colour.
struct InputChipLabel: View {
    let title: String
    let symbol: String
    let tint: FeatureTint

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: InputBoxLayout.chipHeight)
        .islandWashed(.accent(tint, minimum: Contrast.text), wash: 0.2, in: Capsule())
        .fixedSize()
    }
}

/// Send, or Stop while an answer is coming.
private struct InputSendButton: View {
    let box: InputBox

    var body: some View {
        let isBusy = box.session?.isBusy ?? false
        let isEmpty = box.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Faint while there is nothing to send.
        let ink: IslandInk = !isBusy && isEmpty ? .text(0.35) : .text(1)
        RoundButton(symbol: isBusy ? "stop.fill" : "arrow.up", tint: ink, diameter: InputBoxLayout.chipHeight) {
            if isBusy {
                box.session?.stop()
            } else {
                box.submit()
            }
        }
        .disabled(!isBusy && isEmpty)
        .help(isBusy ? "Stop" : "Send")
        .accessibilityLabel(isBusy ? "Stop" : "Send")
    }
}

/// Another mode's offer to take the draft over, under the field: a click, or ⌘Return,
/// takes it; Return still does what this mode does.
private struct InputSuggestionRow: View {
    let box: InputBox
    let line: String

    var body: some View {
        HStack(spacing: 6) {
            InputQuietButton(title: line, symbol: "arrow.turn.down.right") { box.takeSuggestion() }
                .accessibilityHint("Switches the box to it, without adding anything yet")
            Text("⌘↩")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.islandText(0.4))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 6)
    }
}

/// Under the field while the draft asks for a command, or a follow-up to one: what Return
/// will do instead of sending it.
private struct InputCommandHint: View {
    let hint: InputHint

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: hint.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.islandText(0.6))
                .accessibilityHidden(true)
            Text(hint.text)
                .font(.system(size: 11))
                .foregroundStyle(.islandText(0.7))
                .lineLimit(1)
            Text("↩")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.islandText(0.4))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A small word-and-symbol button in the box, lit under the pointer.
struct InputQuietButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.islandText(isHovering ? 0.9 : 0.6, on: .surface(0.12)))
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(.islandSurface(isHovering ? 0.16 : 0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
