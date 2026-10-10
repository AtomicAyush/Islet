import AppKit
import SwiftUI

extension FeatureTint {
    /// The eye line, the progress and the controls: a calm teal, clear of the camera's
    /// green and the microphone's orange beside the notch.
    static let teleprompter = FeatureTint.colour(RGB(0.36, 0.84, 0.80))
}

enum TeleprompterSymbol {
    static let feature = "scroll"
}

/// What the page's and the tile's buttons do beyond the model: the feature's, since
/// starting, and carrying on, holds the island open and stopping lets it go.
struct TeleprompterActions {
    var start: @MainActor () -> Void
    var togglePause: @MainActor () -> Void
    var stop: @MainActor () -> Void
    var choose: @MainActor (UUID) -> Void
    var editScripts: @MainActor () -> Void
}

// MARK: - The page

/// The opened island under the camera: the script, the line being read at the eye line
/// just under the notch row with the half of the line before it fading above, and a row
/// beneath with the progress and the time left, which turns into the controls while the
/// pointer is on the page. A click on the script gives it the keyboard: Space, the
/// arrows, + and −, and Escape to hand the keyboard back.
struct TeleprompterPage: View {
    let model: TeleprompterModel
    let scripts: TeleprompterScripts
    let actions: TeleprompterActions
    @Environment(\.island) private var island
    @State private var isHovering = false
    @SwiftUI.FocusState private var isFocused: Bool

    private var size: CGFloat { model.settings.textSize }
    private var lineHeight: CGFloat { TeleprompterLayout.lineHeight(size: size) }
    private var shownLines: Int { TeleprompterLayout.shownLines(wanted: model.settings.lines, size: size) }
    private var isTypingHere: Bool { island?.typingPlace == .page(TeleprompterFeature.pageID) }

    var body: some View {
        VStack(spacing: 6) {
            ScriptViewport(model: model, lineHeight: lineHeight, shownLines: shownLines)
                .frame(height: (CGFloat(shownLines) + TeleprompterLayout.lineAbove) * lineHeight)
                .overlay { CountdownOverlay(phase: model.phase) }
                .overlay {
                    ScrollCatcher(lineHeight: lineHeight) { lines in
                        model.scroll(byLines: lines)
                    } clicked: {
                        takeKeys()
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Script")
                .accessibilityValue(spokenPlace)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityAction(named: "Back a line") { model.lineBack() }
                .accessibilityAction(named: "On a line") { model.lineOn() }

            TeleprompterFooter(model: model, scripts: scripts, actions: actions, showsControls: isHovering || isTypingHere)
                .frame(height: TeleprompterLayout.footerHeight)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .focusable(isTypingHere)
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down) { press in key(press) }
        .onChange(of: island?.focusRequest ?? 0) { _, _ in
            if isTypingHere { isFocused = true }
        }
        .onAppear { model.pageAppeared() }
        .onDisappear { model.pageDisappeared() }
    }

    private var spokenPlace: String {
        let percent = Int((model.progress(at: Date()) * 100).rounded())
        return "\(percent)% read, \(model.timeLeft(at: Date()).readingTimeText) left"
    }

    /// The script clicked: the island takes the keyboard for the page, through the same
    /// way as typing in it, and gives it back on Escape, a click elsewhere or ⌘Tab.
    private func takeKeys() {
        guard let island else { return }
        IslandManager.shared.beginTyping(on: island, in: .page(TeleprompterFeature.pageID), client: TypingClient(
            key: { action in
                if action == .close { actions.stop() }
            },
            leavesPage: false
        ))
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard isTypingHere else { return .ignored }
        switch press.key {
        case .space: actions.togglePause()
        case .upArrow: model.lineBack()
        case .downArrow: model.lineOn()
        case .leftArrow: model.slower()
        case .rightArrow: model.faster()
        case .pageUp: model.screen(by: -1)
        case .pageDown: model.screen(by: 1)
        case .escape: island?.endTyping(.escape)
        default:
            switch press.characters {
            case "+", "=": model.bigger()
            case "-", "_": model.smaller()
            default: return .ignored
            }
        }
        return .handled
    }
}

/// The script's lines around the eye line, moved as the reading moves: drawn afresh
/// every frame only while it moves at a set pace; a line at a time when the island
/// saves energy or Reduce Motion is on; and following the voice, with a spring to each
/// new line, or a cross-fade under Reduce Motion.
private struct ScriptViewport: View {
    let model: TeleprompterModel
    let lineHeight: CGFloat
    let shownLines: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let stepped = reduceMotion || EnergySaver.shared.isSaving
        Group {
            if let pace = model.pace, model.isRunning {
                if stepped {
                    TimelineView(.explicit(pace.lineChanges(after: Date(), in: model.lines))) { context in
                        lines(at: model.linePosition(at: context.date).rounded(.down), read: model.word(at: context.date))
                    }
                } else {
                    TimelineView(.animation) { context in
                        lines(at: model.linePosition(at: context.date), read: model.word(at: context.date))
                    }
                }
            } else {
                let place = model.linePosition(at: Date())
                lines(at: place, read: model.word(at: Date()))
                    .animation(stepped ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.86), value: place)
            }
        }
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: TeleprompterLayout.lineAbove / (CGFloat(shownLines) + TeleprompterLayout.lineAbove)),
                    .init(color: .black, location: 0.86),
                    .init(color: .black.opacity(0.55), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(alignment: .topLeading) {
            // The eye line's mark, where the line being read sits.
            Capsule()
                .fill(.islandAccent(.teleprompter))
                .frame(width: 3, height: lineHeight * 0.62)
                .offset(y: TeleprompterLayout.lineAbove * lineHeight + lineHeight * 0.19)
        }
    }

    private func lines(at place: Double, read: Double) -> some View {
        ScriptLinesView(
            text: model.text, lines: model.lines, place: place, readWord: Int(read.rounded(.down)),
            size: model.settings.textSize, lineHeight: lineHeight, shownLines: shownLines,
            mirror: model.settings.mirror, dimsRead: model.mode != .manual
        )
    }
}

/// The lines from just above the eye line to just below the last shown, each placed by
/// how far it is from `place`, the line at the eye line (fractional while moving).
private struct ScriptLinesView: View {
    let text: ScriptText
    let lines: ScriptLines
    let place: Double
    let readWord: Int
    let size: CGFloat
    let lineHeight: CGFloat
    let shownLines: Int
    let mirror: Bool
    let dimsRead: Bool

    var body: some View {
        let first = max(0, Int(place.rounded(.down)) - 2)
        let last = min(lines.lines.count, Int(place.rounded(.down)) + shownLines + 2)
        ZStack(alignment: .topLeading) {
            if lines.isEmpty {
                Text("This script has no words yet.")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.islandText(0.5))
                    .offset(y: TeleprompterLayout.lineAbove * lineHeight)
            }
            ForEach(first..<max(first, last), id: \.self) { index in
                line(index)
                    .frame(width: TeleprompterLayout.textWidth, height: lineHeight, alignment: .leading)
                    .offset(y: (Double(index) - place + TeleprompterLayout.lineAbove) * lineHeight)
            }
        }
        .frame(width: TeleprompterLayout.textWidth, alignment: .topLeading)
        .scaleEffect(x: mirror ? -1 : 1)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func line(_ index: Int) -> some View {
        let range = lines.lines[index].words
        let atEye = index == Int(place.rounded(.down))
        var shown = Text("")
        for word in range {
            let piece = text.words[word]
            let isRead = dimsRead && word < readWord
            let alpha = piece.isCue ? 0.4 : isRead ? 0.42 : atEye ? 1 : 0.8
            var run = Text(piece.text).foregroundStyle(.islandText(alpha))
            if piece.isCue { run = run.italic() }
            shown = shown + run + (word < range.upperBound - 1 ? Text(" ") : Text(""))
        }
        return shown
            .font(.system(size: size, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

/// Three, two, one over the script before it starts: a number a second, with no
/// growing or shrinking, so it reads the same under Reduce Motion.
private struct CountdownOverlay: View {
    let phase: TeleprompterModel.Phase

    var body: some View {
        if case .countdown(let end) = phase {
            let seconds = Int(end.timeIntervalSinceNow.rounded(.up))
            let changes = (0..<max(0, seconds)).map { end.addingTimeInterval(-Double($0)) }.reversed()
            TimelineView(.explicit(Array(changes))) { context in
                let left = max(1, Int(end.timeIntervalSince(context.date).rounded(.up)))
                Text("\(left)")
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.islandAccentText(.teleprompter))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.islandBackground.opacity(0.82))
                    .accessibilityLabel("Starting in \(left)")
            }
            .transition(.opacity)
        }
    }
}

/// Under the script: what it is doing and how far it has come; under the pointer or
/// with the keyboard, the controls in the same room, so nothing moves as they come.
private struct TeleprompterFooter: View {
    let model: TeleprompterModel
    let scripts: TeleprompterScripts
    let actions: TeleprompterActions
    let showsControls: Bool

    var body: some View {
        Group {
            if showsControls || !model.hasStarted || model.phase == .finished || model.message != nil && !model.isRunning {
                controls
            } else {
                status
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showsControls)
    }

    // MARK: Status

    private var status: some View {
        HStack(spacing: 10) {
            ModeMark(model: model)
            if model.isRunning, model.pace != nil {
                TimelineView(.periodic(from: Date(), by: EnergySaver.shared.isSaving ? 5 : 1)) { context in
                    progress(at: context.date)
                }
            } else {
                progress(at: Date())
            }
        }
        .padding(.horizontal, 6)
    }

    private func progress(at date: Date) -> some View {
        HStack(spacing: 10) {
            ProgressBar(fraction: model.progress(at: date))
            Text("\(model.timeLeft(at: date).readingTimeText) left")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.islandText(0.6))
                .fixedSize()
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 6) {
            if let message = model.message {
                Text(message)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.islandText(0.75))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let url = model.refusal?.settingsURL {
                    PillButton(title: "Settings") { NSWorkspace.shared.open(url) }
                }
            } else if !model.hasStarted || model.phase == .finished {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.phase == .finished ? "Done" : model.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.islandText(0.9))
                        .lineLimit(1)
                    Text(readingHint)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.islandText(0.55))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ScriptMenu(scripts: scripts, current: model.scriptID, choose: actions.choose, edit: actions.editScripts)
                ModeMenu(model: model)
            } else {
                SmallButton(symbol: "arrow.up", help: "Back a line (⌃⌥↑)") { model.lineBack() }
                SmallButton(symbol: "arrow.down", help: "On a line (⌃⌥↓)") { model.lineOn() }
                if model.mode == .pace {
                    SmallButton(symbol: "minus", help: "Slower (⌃⌥←)") { model.slower() }
                    Text("\(model.settings.wordsPerMinute)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.islandText(0.75))
                        .frame(minWidth: 26)
                        .accessibilityLabel("\(model.settings.wordsPerMinute) words a minute")
                    SmallButton(symbol: "plus", help: "Faster (⌃⌥→)") { model.faster() }
                } else {
                    ModeMark(model: model)
                }
                Spacer(minLength: 4)
                SmallButton(symbol: "textformat.size.smaller", help: "Smaller text (−)") { model.smaller() }
                    .disabled(model.settings.textSize <= TeleprompterLayout.sizes.lowerBound)
                SmallButton(symbol: "textformat.size.larger", help: "Larger text (+)") { model.bigger() }
                    .disabled(model.settings.textSize >= TeleprompterLayout.sizes.upperBound)
                ModeMenu(model: model)
            }
            playButton
            if model.hasStarted, model.phase != .finished {
                SmallButton(symbol: "stop.fill", help: "Stop (⌘W)") { actions.stop() }
            }
        }
        .padding(.horizontal, 2)
    }

    private var readingHint: String {
        let words = model.text.wordCount
        let minutes = max(1, Int((Double(words) / Double(model.settings.wordsPerMinute)).rounded()))
        return "\(words) words · about \(minutes) min at \(model.settings.wordsPerMinute) words a minute"
    }

    private var playButton: some View {
        let isGoing = model.isRunning || isCounting || model.isPreparing
        return RoundButton(
            symbol: isGoing ? "pause.fill" : "play.fill", tint: .accent(.teleprompter), diameter: 24
        ) {
            actions.togglePause()
        }
        .help(isGoing ? "Pause (⌃⌥Space)" : model.hasStarted ? "Carry on (⌃⌥Space)" : "Start (⌃⌥Space)")
        .accessibilityLabel(isGoing ? "Pause" : model.hasStarted ? "Carry on" : "Start")
    }

    private var isCounting: Bool {
        if case .countdown = model.phase { return true }
        return false
    }
}

/// The mode's symbol, and while the voice is followed, how loud it is.
private struct ModeMark: View {
    let model: TeleprompterModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.phase == .paused ? "pause.fill" : model.mode.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.islandAccent(.teleprompter))
                .frame(width: 14)
            if model.mode == .follow, model.isListening {
                LevelBars(level: model.level)
            } else if model.mode == .pace {
                Text("\(model.settings.wordsPerMinute) wpm")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.islandText(0.6))
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.mode.title)
    }
}

/// Three bars that rise with the microphone's loudness: proof it hears. They ease to
/// each new level, except while the island saves energy or with Reduce Motion, when they
/// step (and the model passes the level on less often).
private struct LevelBars: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                let reach = max(0.18, min(1, Double(level) * (1.4 - Double(index) * 0.25)))
                Capsule()
                    .fill(.islandText(0.7))
                    .frame(width: 2.5, height: 4 + 9 * reach)
            }
        }
        .frame(height: 13)
        .animation(reduceMotion || EnergySaver.shared.isSaving ? nil : .easeOut(duration: 0.12), value: level)
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.islandSurface(0.16))
                Capsule()
                    .fill(.islandAccent(.teleprompter))
                    .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct SmallButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        RoundButton(symbol: symbol, diameter: 22, action: action)
            .help(help)
            .accessibilityLabel(help.components(separatedBy: " (").first ?? help)
    }
}

private struct PillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .islandWashed(.accent(.teleprompter, minimum: Contrast.text), wash: 0.2, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Follow my voice, Set pace or Manual.
private struct ModeMenu: View {
    let model: TeleprompterModel

    var body: some View {
        Menu {
            ForEach(TeleprompterMode.allCases) { mode in
                Button {
                    model.setMode(mode)
                } label: {
                    if mode == model.mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            Image(systemName: model.mode.symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .islandWashed(.text(1), wash: 0.2, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mode: \(model.mode.title)")
        .accessibilityLabel("Mode, \(model.mode.title)")
    }
}

/// The scripts kept, to read another, and the way to Settings to edit them.
private struct ScriptMenu: View {
    let scripts: TeleprompterScripts
    let current: UUID?
    let choose: @MainActor (UUID) -> Void
    let edit: @MainActor () -> Void

    var body: some View {
        Menu {
            ForEach(scripts.scripts) { script in
                Button {
                    choose(script.id)
                } label: {
                    if script.id == current {
                        Label(script.shownTitle, systemImage: "checkmark")
                    } else {
                        Text(script.shownTitle)
                    }
                }
            }
            if !scripts.scripts.isEmpty { Divider() }
            Button("Edit Scripts…") { edit() }
        } label: {
            Image(systemName: "doc.text")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .islandWashed(.text(1), wash: 0.2, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Scripts")
        .accessibilityLabel("Scripts")
    }
}

/// Takes the trackpad's scrolling and clicks over the script: scrolling moves it by
/// hand, a click gives it the keyboard. An AppKit view, since SwiftUI on macOS 14 has no
/// way to see a scroll that moves nothing of its own.
struct ScrollCatcher: NSViewRepresentable {
    let lineHeight: CGFloat
    let scrolled: (Double) -> Void
    let clicked: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.lineHeight = lineHeight
        view.scrolled = scrolled
        view.clicked = clicked
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.lineHeight = lineHeight
        view.scrolled = scrolled
        view.clicked = clicked
    }

    final class CatcherView: NSView {
        var lineHeight: CGFloat = 28
        var scrolled: (Double) -> Void = { _ in }
        var clicked: () -> Void = {}

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func scrollWheel(with event: NSEvent) {
            scrolled(Self.lines(scrolledBy: event, lineHeight: lineHeight))
        }

        /// Lines on through the script for a scroll, the way a page scrolls under the
        /// natural-scrolling setting: macOS has already turned the delta about for it.
        static func lines(scrolledBy event: NSEvent, lineHeight: CGFloat) -> Double {
            let points = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * lineHeight
            return Double(-points / max(lineHeight, 1))
        }

        override func mouseDown(with event: NSEvent) {
            clicked()
        }
    }
}

// MARK: - Beside the notch

/// Left of the notch: the mode, or a pause; a tick when it has been read to the end.
struct TeleprompterCompactLeading: View {
    let model: TeleprompterModel

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.islandAccent(.teleprompter))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch model.phase {
        case .finished: "checkmark"
        case .paused: "pause.fill"
        default: model.mode.symbol
        }
    }
}

/// Right of the notch: how far through, as a ring.
struct TeleprompterCompactTrailing: View {
    let model: TeleprompterModel

    var body: some View {
        ProgressWingTrailing(count: 1) {
            TeleprompterRing(model: model, lineWidth: 2.5)
        }
    }
}

struct TeleprompterMinimal: View {
    let model: TeleprompterModel

    var body: some View {
        TeleprompterRing(model: model, lineWidth: 2.5)
            .overlay(
                Image(systemName: model.phase == .paused ? "pause.fill" : TeleprompterSymbol.feature)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.islandAccent(.teleprompter))
            )
            .padding(5)
    }
}

/// The progress ring, redrawn once a second while it moves at a set pace (every five
/// while the island saves energy), and otherwise as the place changes.
struct TeleprompterRing: View {
    let model: TeleprompterModel
    var lineWidth: CGFloat = 3

    var body: some View {
        if model.isRunning, model.pace != nil {
            TimelineView(.periodic(from: Date(), by: EnergySaver.shared.isSaving ? 5 : 1)) { context in
                ProgressRing(fraction: model.progress(at: context.date), lineWidth: lineWidth, tint: .accent(.teleprompter))
            }
        } else {
            ProgressRing(fraction: model.progress(at: Date()), lineWidth: lineWidth, tint: .accent(.teleprompter))
        }
    }
}

// MARK: - Home

/// The script chosen, how long it reads, and Start; while a reading is under way, its
/// place and Stop.
struct TeleprompterHomeTile: View {
    let model: TeleprompterModel
    let scripts: TeleprompterScripts
    let actions: TeleprompterActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Teleprompter", systemImage: TeleprompterSymbol.feature)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.islandAccentText(.teleprompter, on: .homeTile))
                .lineLimit(1)

            if let script = scripts.selected {
                VStack(alignment: .leading, spacing: 1) {
                    Text(script.shownTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.islandText(1, on: .homeTile))
                        .lineLimit(1)
                    Text(model.hasStarted ? "\(Int((model.progress(at: Date()) * 100).rounded()))% read" : hint(for: script))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.islandText(0.55, on: .homeTile))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if model.hasStarted {
                        pill("Stop") { actions.stop() }
                    } else {
                        pill(script.lastWord > 0 && script.lastWord < script.wordCount ? "Carry On" : "Start") { actions.start() }
                    }
                    pill("Scripts") { actions.editScripts() }
                }
            } else {
                Text("Paste or import a script in Settings.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.islandText(0.6, on: .homeTile))
                    .lineLimit(2)
                pill("Add a Script") { actions.editScripts() }
            }
        }
    }

    private func hint(for script: TeleprompterScript) -> String {
        let minutes = max(1, Int((Double(script.wordCount) / Double(model.settings.wordsPerMinute)).rounded()))
        return "\(script.wordCount) words · about \(minutes) min"
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.islandText(1, on: IslandBackdrop.homeTile.stacked(0.12)))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Capsule().fill(.islandSurface(0.12, on: .homeTile)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
