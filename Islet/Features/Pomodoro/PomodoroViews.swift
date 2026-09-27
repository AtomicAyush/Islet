import AppKit
import SwiftUI

/// A ripe tomato's red, for focus: the method is named after a tomato-shaped kitchen
/// timer. Redder than the timer's orange, so the two are told apart side by side.
let pomodoroFocusTint = Color(red: 1.0, green: 0.39, blue: 0.28)
/// A leaf's green, for a break.
let pomodoroBreakTint = Color(red: 0.37, green: 0.84, blue: 0.52)

/// The symbols Pomodoro goes by: one for focus, one for a break.
enum PomodoroSymbol {
    static let focus = "brain.head.profile"
    static let rest = "leaf.fill"
}

extension PomodoroModel.Phase {
    var symbol: String { isBreak ? PomodoroSymbol.rest : PomodoroSymbol.focus }
    var tint: Color { isBreak ? pomodoroBreakTint : pomodoroFocusTint }
}

/// The words the island uses.
enum PomodoroWords {
    /// "Focus 2 of 4", "Short break", "Long break".
    static func title(_ session: PomodoroModel.Session, rounds: Int) -> String {
        switch session.phase {
        case .focus: "Focus \(session.round) of \(rounds)"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }

    /// Said after the title while the clock is not running.
    static func status(_ session: PomodoroModel.Session) -> String? {
        switch session.clock {
        case .running: nil
        case .paused: "Paused"
        case .waiting: "Ready"
        }
    }

    /// "The title · Paused", for the opened island.
    static func heading(_ session: PomodoroModel.Session, rounds: Int) -> String {
        let title = title(session, rounds: rounds)
        return status(session).map { "\(title) · \($0)" } ?? title
    }

    /// "24:59", or "1:02:03" past an hour. Rounds up, so a phase never reads 0:00 while
    /// it is still running.
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(min(max(0, seconds.rounded(.up)), 24 * 3600))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Whole minutes, for words: a phase set in Settings is always whole minutes.
    static func minutes(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded()))
    }

    /// "Focus done", "Break over": left of the notch as one phase gives way.
    static func finished(_ phase: PomodoroModel.Phase) -> String {
        phase == .focus ? "Focus done" : "Break over"
    }

    /// "5 minute break", "Back to it": right of the notch, what comes next.
    static func next(_ session: PomodoroModel.Session) -> String {
        session.phase.isBreak ? "\(minutes(session.length)) minute break" : "Back to it"
    }

    /// "18 minutes 25 seconds left of 25 minutes", for VoiceOver, rounded up as the
    /// time is.
    static func left(_ remaining: TimeInterval, of length: TimeInterval) -> String {
        let total = Int(min(max(0, remaining.isFinite ? remaining : 0), 24 * 3600).rounded(.up))
        let m = total / 60, s = total % 60
        var words: [String] = []
        if m > 0 { words.append(m == 1 ? "1 minute" : "\(m) minutes") }
        if s > 0 || m == 0 { words.append(s == 1 ? "1 second" : "\(s) seconds") }
        return words.joined(separator: " ") + " left of \(minutes(length)) minutes"
    }

    /// "3 today", or "None yet today".
    static func today(_ count: Int) -> String {
        count == 0 ? "None yet today" : "\(count) today"
    }
}

/// Time left, counting down on its own while the phase runs, as the timer's does, and
/// dimmed while it is held.
struct PomodoroTimeText: View {
    let session: PomodoroModel.Session
    var size: CGFloat
    var weight: Font.Weight = .semibold
    /// The time left at the scrubber's knob while it is dragged, shown in place of the
    /// countdown, and undimmed: it is what letting go will set.
    var held: TimeInterval?

    var body: some View {
        Group {
            if let held {
                Text(PomodoroWords.clock(held))
            } else if case .running(let end) = session.clock, end > Date() {
                Text(timerInterval: Date()...end, countsDown: true, showsHours: true)
            } else {
                Text(PomodoroWords.clock(session.remaining(at: Date())))
            }
        }
        .font(.system(size: size, weight: weight, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(session.phase.tint.opacity(session.isRunning || held != nil ? 1 : 0.55))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// A ring that drains as the phase runs, redrawn once a second: phases last minutes, so
/// nothing finer would show. Held still while paused, and full while waiting.
struct PomodoroRing: View {
    let session: PomodoroModel.Session
    var lineWidth: CGFloat = 3
    /// The time left at the scrubber's knob while it is dragged, which the ring follows.
    var held: TimeInterval?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !session.isRunning || held != nil)) { context in
            ProgressRing(fraction: fraction(at: context.date), lineWidth: lineWidth, tint: session.phase.tint)
        }
    }

    private func fraction(at date: Date) -> Double {
        guard let held else { return session.progress(at: date) }
        return session.length > 0 ? min(1, max(0, held / session.length)) : 0
    }
}

/// The ring with the phase's symbol in it, as the bubble and the opened island show it.
private struct PomodoroBadge: View {
    let session: PomodoroModel.Session
    var lineWidth: CGFloat
    var symbolSize: CGFloat
    var held: TimeInterval?

    var body: some View {
        PomodoroRing(session: session, lineWidth: lineWidth, held: held)
            .overlay(
                Image(systemName: session.phase.symbol)
                    .font(.system(size: symbolSize, weight: .bold))
                    .foregroundStyle(session.phase.tint)
            )
            .accessibilityHidden(true)
    }
}

/// A dot for each focus session of the cycle: filled once done, ringed for the one
/// under way, faint for those to come.
struct PomodoroCycleDots: View {
    let session: PomodoroModel.Session
    let rounds: Int
    var size: CGFloat = 6

    var body: some View {
        HStack(spacing: size * 0.6) {
            ForEach(1...max(1, rounds), id: \.self) { round in
                dot(round)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.roundsDone) of \(rounds) focus sessions done")
    }

    @ViewBuilder
    private func dot(_ round: Int) -> some View {
        if round <= session.roundsDone {
            Circle().fill(pomodoroFocusTint)
        } else if round == session.round, session.phase == .focus {
            Circle().strokeBorder(pomodoroFocusTint, lineWidth: 1.5)
        } else {
            Circle().fill(Color.white.opacity(0.2))
        }
    }
}

struct PomodoroCompactLeading: View {
    let model: PomodoroModel

    var body: some View {
        if let session = model.shown {
            Image(systemName: session.phase.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(session.phase.tint)
                .accessibilityLabel(PomodoroWords.title(session, rounds: model.settings.rounds))
        }
    }
}

struct PomodoroCompactTrailing: View {
    let model: PomodoroModel

    var body: some View {
        if let session = model.shown {
            Group {
                // Not a pause: the next phase waits for a click to start, and says so.
                if session.isWaiting {
                    Text(PomodoroWords.status(session) ?? "")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(session.phase.tint)
                        .lineLimit(1)
                        .accessibilityLabel(PomodoroWords.title(session, rounds: model.settings.rounds) + ", ready")
                } else {
                    PomodoroTimeText(session: session, size: 13)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 6)
        }
    }
}

/// In the bubble, beside music: the draining ring, which says as much as the minutes
/// would at a glance. Folded into the island's end, where the circle is too small for
/// a ring with a symbol inside it, the symbol alone.
struct PomodoroMinimal: View {
    let model: PomodoroModel

    var body: some View {
        if let session = model.shown {
            GeometryReader { proxy in
                if proxy.size.width < 24 {
                    Image(systemName: session.phase.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(session.phase.tint)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .accessibilityLabel(PomodoroWords.title(session, rounds: model.settings.rounds))
                } else {
                    PomodoroBadge(session: session, lineWidth: 2.5, symbolSize: 7.5)
                        .padding(5)
                }
            }
        }
    }
}

/// The opened island: which phase, the time left with a bar under it to move through
/// the phase, the cycle so far, and the three things to do with it.
struct PomodoroExpanded: View {
    let model: PomodoroModel
    /// Where the bar's knob is held while it is dragged, as the fraction of the phase
    /// gone: the time and the ring show the time left there until it is let go.
    @State private var dragging: Double?
    private let hovering: Bool

    /// The timer's height, and room for the bar.
    static let height: CGFloat = 92

    /// `hovering` and `dragging` start the bar so, for pictures of it.
    init(model: PomodoroModel, hovering: Bool = false, dragging: Double? = nil) {
        self.model = model
        self.hovering = hovering
        _dragging = State(initialValue: dragging)
    }

    var body: some View {
        if let session = model.shown {
            let held = dragging.map { PomodoroScrubber.remaining(at: $0, of: session.length) }
            HStack(spacing: 16) {
                PomodoroBadge(session: session, lineWidth: 5, symbolSize: 20, held: held)
                    .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(PomodoroWords.heading(session, rounds: model.settings.rounds))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                        PomodoroCycleDots(session: session, rounds: model.settings.rounds)
                    }
                    PomodoroTimeText(session: session, size: 40, weight: .medium, held: held)
                    PomodoroScrubber(
                        session: session,
                        dragging: $dragging,
                        isEnabled: model.preview == nil && !session.isWaiting,
                        hovering: hovering,
                        grab: { model.hold() },
                        release: { gone in
                            model.letGo(atRemaining: gone.map { PomodoroScrubber.remaining(at: $0, of: session.length) })
                        },
                        nudge: { minutes in model.move(by: TimeInterval(minutes * 60)) }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RoundButton(symbol: session.isRunning ? "pause.fill" : "play.fill", tint: session.phase.tint) {
                    act { model.toggle() }
                }
                .accessibilityLabel(session.isRunning ? "Pause" : session.isPaused ? "Resume" : "Start")
                RoundButton(symbol: "forward.end.fill", tint: .white) {
                    act { model.skip() }
                }
                .accessibilityLabel(session.phase.isBreak ? "Skip the break" : "Skip to the break")
                RoundButton(symbol: "xmark", tint: .white) {
                    act { model.stop() }
                }
                .accessibilityLabel("Stop")
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
        }
    }

    /// A preview's buttons only end the preview: there is nothing real to pause.
    private func act(_ action: () -> Void) {
        if model.preview != nil { model.endPreview() } else { action() }
    }
}

/// Where the phase has got to, as a bar under the time left that fills as it runs, and
/// that can be dragged to move through it, as Now Playing's can: on to skip ahead, back
/// for more time, between the phase's start and its end. A knob shows under the pointer
/// and while dragging, and letting go at the very end finishes the phase as if its time
/// had run out. The phase is held still while the knob is held, so it cannot run out
/// under it. A drag called off, by the bar going or being disabled under the pointer,
/// or one whose phase gave way to another meanwhile, moves nothing. A phase waiting for
/// a click has not begun, so its bar stays empty and cannot be moved. VoiceOver, and
/// Full Keyboard Access, move it a minute at a time.
struct PomodoroScrubber: View {
    let session: PomodoroModel.Session
    /// Where the knob is held, as the fraction of the phase gone, while it is dragged,
    /// for the time and the ring to show.
    @Binding var dragging: Double?
    let isEnabled: Bool
    /// Taken hold of: the phase is held still until let go.
    let grab: () -> Void
    /// Let go, at a fraction of the phase gone, or `nil` for a drag that moves nothing.
    let release: (Double?) -> Void
    /// A minute on (1) or back (-1).
    let nudge: (Int) -> Void
    @State private var hovering: Bool
    /// The knob's place as it is dragged. SwiftUI puts it back to `nil` as the drag ends,
    /// and also as it is called off, when no word of the end ever comes.
    @GestureState private var live: Double?
    /// Which phase the knob was taken hold of in, until let go.
    @State private var grabbed: Grip?

    /// A phase as far as a drag is concerned: one that gives way to another, or to a
    /// click, mid-drag is not the one being moved.
    struct Grip: Equatable {
        var phase: PomodoroModel.Phase
        var round: Int
        var length: TimeInterval
        var isWaiting: Bool

        init(_ session: PomodoroModel.Session) {
            phase = session.phase
            round = session.round
            length = session.length
            isWaiting = session.isWaiting
        }
    }

    /// Room to take hold of the bar, and the bar itself, thicker under the pointer.
    static let height: CGFloat = 14
    static let thickness: CGFloat = 4
    static let raisedThickness: CGFloat = 6
    static let knob: CGFloat = 12

    init(
        session: PomodoroModel.Session,
        dragging: Binding<Double?>,
        isEnabled: Bool,
        hovering: Bool = false,
        grab: @escaping () -> Void,
        release: @escaping (Double?) -> Void,
        nudge: @escaping (Int) -> Void
    ) {
        self.session = session
        _dragging = dragging
        self.isEnabled = isEnabled
        self.grab = grab
        self.release = release
        self.nudge = nudge
        _hovering = State(initialValue: hovering)
    }

    /// The time left with the knob at `gone`, the fraction of the phase gone, to the
    /// whole second, so letting go sets the time the knob showed.
    static func remaining(at gone: Double, of length: TimeInterval) -> TimeInterval {
        (length * (1 - min(1, max(0, gone.isFinite ? gone : 0)))).rounded()
    }

    /// The fraction of the phase gone at `x` along a bar `width` wide, kept to the bar.
    static func fraction(atX x: CGFloat, width: CGFloat) -> Double {
        width > 0 ? min(1, max(0, Double(x / width))) : 0
    }

    /// The minutes VoiceOver's increment (on) or decrement (back) moves the phase by, or
    /// nil while the bar cannot be moved.
    static func minutes(for direction: AccessibilityAdjustmentDirection, isEnabled: Bool) -> Int? {
        guard isEnabled else { return nil }
        switch direction {
        case .increment: return 1
        case .decrement: return -1
        @unknown default: return nil
        }
    }

    private var isRaised: Bool { isEnabled && (hovering || dragging != nil) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !session.isRunning || dragging != nil)) { context in
            let gone = dragging ?? 1 - session.progress(at: context.date)
            bar(gone: gone)
                .accessibilityElement()
                .accessibilityLabel("Time left")
                .accessibilityValue(PomodoroWords.left(
                    PomodoroScrubber.remaining(at: gone, of: session.length), of: session.length
                ))
                .accessibilityHint("Moves the phase on or back a minute")
                .accessibilityAdjustableAction { direction in
                    if let minutes = Self.minutes(for: direction, isEnabled: isEnabled) { nudge(minutes) }
                }
        }
        .frame(height: Self.height)
        .allowsHitTesting(isEnabled)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRaised)
        .onChange(of: live) { _, place in
            if let place {
                dragging = place
            } else {
                // Called off, if the end never came; on the next turn, since the end may be
                // told after this.
                DispatchQueue.main.async { callOff() }
            }
        }
        .onChange(of: Grip(session)) { callOff() }
        .onDisappear { callOff() }
    }

    /// Ends a drag without moving the phase, if one is under way.
    private func callOff() {
        guard grabbed != nil else { return }
        grabbed = nil
        dragging = nil
        release(nil)
    }

    private func bar(gone: Double) -> some View {
        let thickness = isRaised ? Self.raisedThickness : Self.thickness
        let lit = session.isRunning || dragging != nil
        return GeometryReader { geo in
            let width = max(1, geo.size.width)
            let x = width * min(1, max(0, gone))
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(isEnabled ? 0.18 : 0.1))
                    Rectangle().fill(session.phase.tint.opacity(lit ? 1 : 0.55)).frame(width: x)
                }
                .frame(height: thickness)
                .clipShape(Capsule())
                if isRaised {
                    Circle()
                        .fill(.white)
                        .frame(width: Self.knob, height: Self.knob)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: x - Self.knob / 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($live) { value, place, _ in
                        place = Self.fraction(atX: value.location.x, width: width)
                    }
                    .onChanged { _ in
                        guard grabbed == nil else { return }
                        grabbed = Grip(session)
                        grab()
                    }
                    .onEnded { value in
                        guard let grip = grabbed else { return }
                        grabbed = nil
                        dragging = nil
                        release(grip == Grip(session) ? Self.fraction(atX: value.location.x, width: width) : nil)
                    }
            )
        }
    }
}

/// On the home page: the length of a focus and Start, or, while a session is under way,
/// the phase, its time left and its controls; and underneath, today's count.
struct PomodoroHomeTile: View {
    let model: PomodoroModel
    /// Starts a session. The feature's, since it checks it is still on.
    let start: () -> Void

    /// Four rows in a tile's height, with the time at the size that leaves them all
    /// their room: squeezed, a time held still is shrunk to fit and loses its last digit.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let session = model.shown {
                Label(PomodoroWords.title(session, rounds: model.settings.rounds), systemImage: session.phase.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(session.phase.tint)
                    .lineLimit(1)
                PomodoroTimeText(session: session, size: 22, weight: .medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    pill { Image(systemName: session.isRunning ? "pause.fill" : "play.fill") } action: {
                        act { model.toggle() }
                    }
                    .accessibilityLabel(session.isRunning ? "Pause" : session.isPaused ? "Resume" : "Start")
                    pill { Image(systemName: "forward.end.fill") } action: { act { model.skip() } }
                        .accessibilityLabel("Skip")
                    pill { Image(systemName: "xmark") } action: { act { model.stop() } }
                        .accessibilityLabel("Stop")
                }
            } else {
                Label("Pomodoro", systemImage: PomodoroSymbol.focus)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pomodoroFocusTint)
                    .lineLimit(1)
                Text(PomodoroWords.clock(model.settings.focus))
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                pill { Text("Start") } action: { start() }
                    .accessibilityLabel("Start a focus session")
            }
            PomodoroTodayCount(count: model.completedToday)
        }
    }

    private func act(_ action: () -> Void) {
        if model.preview != nil { model.endPreview() } else { action() }
    }

    private func pill(@ViewBuilder _ label: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Today's finished focus sessions: a dot for each, up to four, and the number.
struct PomodoroTodayCount: View {
    let count: Int
    static let mostDots = 4

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<min(count, Self.mostDots), id: \.self) { _ in
                Circle().fill(pomodoroFocusTint).frame(width: 5, height: 5)
            }
            Text(PomodoroWords.today(count))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .padding(.leading, count > 0 ? 2 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 0 ? "No focus sessions yet today" : "\(count) focus sessions today")
    }
}

// MARK: - Banner

/// Left of the notch as a phase ends: its symbol and "Focus done" or "Break over". With
/// no room for the words (the opened island's header), the symbol alone.
struct PomodoroBannerLeading: View {
    let finished: PomodoroModel.Phase

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PomodoroBannerLayout.symbolSpacing) {
                symbol
                Text(PomodoroWords.finished(finished))
                    .font(Font(PomodoroBannerLayout.font))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, PomodoroBannerLayout.outerInset)
            .padding(.trailing, PomodoroBannerLayout.innerInset)
            symbol
                .padding(.leading, PomodoroBannerLayout.outerInset)
                .padding(.trailing, PomodoroBannerLayout.innerInset)
            symbol
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: some View {
        Image(systemName: finished.symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .fontWeight(.semibold)
            .foregroundStyle(finished.tint)
            .frame(width: PomodoroBannerLayout.symbolSize.width, height: PomodoroBannerLayout.symbolSize.height)
            .accessibilityHidden(true)
    }
}

/// Right of the notch: what comes next, in its phase's colour. Only as wide as the
/// words, so the opened island's header can set it beside the symbol.
struct PomodoroBannerTrailing: View {
    let next: PomodoroModel.Session

    var body: some View {
        Text(PomodoroWords.next(next))
            .font(Font(PomodoroBannerLayout.font))
            .foregroundStyle(next.phase.tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, PomodoroBannerLayout.innerInset)
            .padding(.trailing, PomodoroBannerLayout.outerInset)
    }
}

/// The banner's measurements, Keep Awake's: 13-point semibold words, the same insets,
/// and each side only as wide as it needs, the island evening the two up.
enum PomodoroBannerLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let symbolSize = CGSize(width: 17, height: 16)
    static let symbolSpacing: CGFloat = 7
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10

    static func widths(
        finished: PomodoroModel.Phase, next: PomodoroModel.Session
    ) -> (leading: CGFloat, trailing: CGFloat) {
        (
            outerInset + symbolSize.width + symbolSpacing + textWidth(PomodoroWords.finished(finished)) + innerInset,
            innerInset + textWidth(PomodoroWords.next(next)) + outerInset
        )
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it.
    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}
