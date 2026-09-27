import AppKit
import SwiftUI

enum ClaudeCodePalette {
    /// A warm clay, for Claude at work.
    static let clay = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let clayNS = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    /// The iPhone's orange in its dark appearance, as the hook's banners use when Claude
    /// is waiting on you.
    static let attention = Color(red: 1.0, green: 0.62, blue: 0.04)
    /// The iPhone's red in its dark appearance, for an agent a workflow gave up on.
    static let failure = Color(red: 1.0, green: 0.27, blue: 0.23)
}

enum ClaudeCodeLayout {
    /// Room right of the notch for the turn's time, to an hour and past it (smaller),
    /// or for the background tasks' count beside a spinner, or beside a ring filling as
    /// the workflows get on.
    static let trailingWidth: CGFloat = 58
    static let compactSpinner: CGFloat = 16
    static let compactSymbol: CGFloat = 15
    static let minimalSymbol: CGFloat = 12
    /// Between the bubble's edge and the ring round the mark, as a share of its width;
    /// and the mark's size inside the ring.
    static let minimalRingInset: CGFloat = 0.1
    static let minimalRingMark: CGFloat = 0.75

    // The opened page: a row per session, its workflows under it.
    static let topInset: CGFloat = 4
    static let bottomInset: CGFloat = 2
    static let rowPadding: CGFloat = 5
    static let sessionSpacing: CGFloat = 4
    static let titleHeight: CGFloat = 18
    static let textHeight: CGFloat = 16
    static let workflowsTop: CGFloat = 3
    /// A background task's line: what it is, and for how long.
    static let workflowHeight: CGFloat = 17
    /// The line under a task whose progress is known: a workflow's bar and the agents
    /// at work in it, or what a background agent is doing.
    static let taskDetailHeight: CGFloat = 15
    /// The width of a workflow's progress bar.
    static let barWidth: CGFloat = 76
    /// Past this the rows scroll; or where a task under a session has a second line, past
    /// the taller height, so a session with a handful of workflows fits whole.
    static let maxListHeight: CGFloat = 200
    static let maxListHeightWithDetail: CGFloat = 280
    static let scrollFade: CGFloat = 18

    /// Between the spinner and the island's outer end, in a row `rowHeight` tall: the
    /// sparkle on the left is centred in the default wing, so the spinner is centred in
    /// the same width at the right, whatever the notch's height.
    static func trailingInset(rowHeight: CGFloat) -> CGFloat {
        max(0, (IslandLayout.defaultSide(for: CGSize(width: 0, height: rowHeight)) - compactSpinner) / 2)
    }

    static func rowHeight(_ session: ClaudeSession, showsText: Bool) -> CGFloat {
        var height = 2 * rowPadding + titleHeight
        if ClaudeCodeText.detail(session, showsText: showsText) != nil { height += textHeight }
        let tasks = tasksHeight(session)
        if tasks > 0 { height += workflowsTop + tasks }
        return height
    }

    /// The session's background tasks under it: a line each, and a second for those
    /// whose progress is known, but for a workflow that has ended.
    static func tasksHeight(_ session: ClaudeSession) -> CGFloat {
        CGFloat(taskCount(session)) * workflowHeight + CGFloat(detailCount(session)) * taskDetailHeight
    }

    static func taskCount(_ session: ClaudeSession) -> Int {
        session.runningWorkflows.count + session.runningAgents.count + session.runningOthers.count
    }

    /// How many of the session's tasks have a second line.
    static func detailCount(_ session: ClaudeSession) -> Int {
        session.runningWorkflows.filter { session.progress(of: $0).map { !$0.isEnded } ?? false }.count
            + session.runningAgents.filter { session.progress(of: $0) != nil }.count
    }

    static func listHeight(_ sessions: [ClaudeSession], showsText: Bool) -> CGFloat {
        guard !sessions.isEmpty else { return 2 * rowPadding + titleHeight }
        let rows = sessions.reduce(0) { $0 + rowHeight($1, showsText: showsText) }
        return rows + CGFloat(sessions.count - 1) * sessionSpacing
    }

    /// The most the rows take before they scroll.
    static func listLimit(_ sessions: [ClaudeSession]) -> CGFloat {
        sessions.contains { detailCount($0) > 0 } ? maxListHeightWithDetail : maxListHeight
    }

    static func pageHeight(for sessions: [ClaudeSession], showsText: Bool) -> CGFloat {
        topInset + min(listHeight(sessions, showsText: showsText), listLimit(sessions)) + bottomInset
    }
}

/// The words the island uses for a session.
enum ClaudeCodeText {
    /// How much of a prompt names a session outside a project.
    static let titleLimit = 34

    /// The project, or for Claude's scratch folders the prompt's first words, or the
    /// app it runs in.
    @MainActor
    static func title(_ session: ClaudeSession, showsText: Bool) -> String {
        let record = session.record
        if !record.project.isEmpty { return record.project }
        if showsText, let words = firstWords(record.prompt) { return words }
        return ClaudeHostApps.name(for: record.hostApp) ?? "Claude Code"
    }

    /// The start of `text`, cut at a word to at most `titleLimit` characters.
    static func firstWords(_ text: String) -> String? {
        let text = oneLine(text)
        guard !text.isEmpty else { return nil }
        guard text.count > titleLimit else { return text }
        let cut = text.prefix(titleLimit - 1)
        let words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return words.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:—–-")) + "…"
    }

    /// The line under the title: what was asked, or once it is done the start of the
    /// reply. A scratch session named by the whole of its prompt does not say it twice.
    static func detail(_ session: ClaudeSession, showsText: Bool) -> String? {
        guard showsText else { return nil }
        let record = session.record
        let text = oneLine(session.state == .idle && !record.reply.isEmpty ? record.reply : record.prompt)
        guard !text.isEmpty else { return nil }
        if record.isScratch, text == oneLine(record.prompt), firstWords(text) == text { return nil }
        return text
    }

    static func status(_ state: ClaudeSessionState) -> String {
        switch state {
        case .working: "Working"
        case .needsPermission: "Needs permission"
        case .waitingForInput: "Needs input"
        case .idle: "Done"
        }
    }

    static func color(_ state: ClaudeSessionState) -> Color {
        switch state {
        case .working: ClaudeCodePalette.clay
        case .needsPermission, .waitingForInput: ClaudeCodePalette.attention
        case .idle: .white.opacity(0.5)
        }
    }

    /// Where a workflow has got: "Implement · 3 of 8 done", the phase under way and how
    /// many of the agents started in it are done; without phases, of all its agents.
    static func phase(_ progress: ClaudeWorkflowProgress) -> String {
        let (done, started) = progress.phase == nil
            ? (progress.done, progress.started) : (progress.phaseDone, progress.phaseStarted)
        var parts: [String] = []
        if let phase = progress.phase.map(oneLine), !phase.isEmpty { parts.append(phase) }
        if started > 0 { parts.append("\(done) of \(started) done") }
        return parts.isEmpty ? "Starting" : parts.joined(separator: " · ")
    }

    /// The agents at work in a workflow now: two by name, then how many more.
    static func running(_ labels: [String]) -> String {
        let named = labels.prefix(2).map(oneLine).joined(separator: ", ")
        return labels.count > 2 ? "\(named) +\(labels.count - 2)" : named
    }

    /// How a workflow's run ended.
    static func outcome(_ outcome: ClaudeWorkflowProgress.Outcome) -> String {
        switch outcome {
        case .completed: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }

    /// How long a background agent has gone without writing: "quiet 12 min".
    static func quiet(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes < 60 ? "quiet \(minutes) min" : "quiet \(minutes / 60) h \(minutes % 60) min"
    }

    /// A command left running: what Claude Code said of it, or else the program it runs.
    static func command(_ task: ClaudeBackgroundTask) -> String? {
        let summary = oneLine(task.summary)
        if !summary.isEmpty { return summary }
        let program = oneLine(task.program)
        return program.isEmpty ? nil : "Running " + program
    }

    /// What a background agent is doing, and how far it has gone: "Editing
    /// IslandTheme.swift · 42 steps".
    static func agent(_ progress: ClaudeAgentProgress) -> String {
        let doing = progress.finished ? "Finished" : (progress.doing ?? "Starting")
        guard progress.steps > 0 else { return doing }
        let steps = progress.stepsAtLeast ? "\(progress.steps)+ steps"
            : progress.steps == 1 ? "1 step" : "\(progress.steps) steps"
        return "\(doing) · \(steps)"
    }

    /// The compact island's count, read out.
    static func background(workflows: Int, agents: Int, fraction: Double?) -> String {
        var parts: [String] = []
        if workflows > 0 { parts.append(workflows == 1 ? "1 workflow" : "\(workflows) workflows") }
        if agents > 0 { parts.append(agents == 1 ? "1 agent" : "\(agents) agents") }
        var label = parts.joined(separator: " and ") + " running"
        if let fraction { label += ", \(Int((fraction * 100).rounded()))% done" }
        return label
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Marks

/// The island's mark for what Claude is doing: a sparkle that breathes while it works,
/// still while only workflows run, and an orange hand or question while it waits on
/// you. Not Claude's logo: an ordinary symbol, in a warm clay.
struct ClaudeCodeMarkView: View {
    let mark: ClaudeCodeModel.Mark?
    var pointSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch mark {
            case .needsPermission?:
                glyph("hand.raised.fill", ClaudeCodePalette.attention)
            case .waitingForInput?:
                glyph("questionmark.bubble.fill", ClaudeCodePalette.attention)
            case .working?:
                if reduceMotion {
                    glyph("sparkle", ClaudeCodePalette.clay)
                } else {
                    ClaudeBreathingSymbol(name: "sparkle", pointSize: pointSize, color: ClaudeCodePalette.clayNS)
                        .transition(.opacity)
                }
            case .workflows?:
                glyph("sparkle", ClaudeCodePalette.clay.opacity(0.8))
            case nil:
                EmptyView()
            }
        }
        .frame(width: pointSize * 1.5, height: pointSize * 1.5)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: mark)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private func glyph(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: pointSize, weight: .semibold))
            .foregroundStyle(color)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    private var label: String {
        switch mark {
        case .needsPermission?: "Claude Code needs permission"
        case .waitingForInput?: "Claude Code needs input"
        case .working?: "Claude Code working"
        case .workflows?: "Claude Code background tasks running"
        case nil: ""
        }
    }
}

/// An SF Symbol that swells and fades a little, over and over, turned by Core
/// Animation: the render server runs it on its own, so a turn lasting an hour costs the
/// app nothing per frame. With Reduce Motion on, the symbol is drawn still instead.
struct ClaudeBreathingSymbol: NSViewRepresentable {
    let name: String
    let pointSize: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> ClaudeBreathingSymbolView {
        ClaudeBreathingSymbolView(name: name, pointSize: pointSize, color: color)
    }

    func updateNSView(_ view: ClaudeBreathingSymbolView, context: Context) {}
}

final class ClaudeBreathingSymbolView: NSView {
    /// One breath in and out.
    static let period: CFTimeInterval = 2.4
    static let animationKey = "breathe"
    /// How small and faint it gets at the bottom of a breath.
    static let smallest: CGFloat = 0.74
    static let faintest: Float = 0.5

    let symbolLayer = CALayer()
    private let image: NSImage?

    init(name: String, pointSize: CGFloat, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        super.init(frame: .zero)
        wantsLayer = true
        symbolLayer.contentsGravity = .center
        layer?.addSublayer(symbolLayer)
        updateContents()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContents()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startBreathing() }
    }

    /// The symbol drawn at the display's scale, in its colour, so the layer needs no
    /// tinting from the render server.
    private func updateContents() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let image, let raster = Self.raster(image, scale: scale) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.contentsScale = scale
        symbolLayer.contents = raster
        CATransaction.commit()
    }

    func startBreathing() {
        guard symbolLayer.animation(forKey: Self.animationKey) == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = Self.smallest
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = Self.faintest
        let breath = CAAnimationGroup()
        breath.animations = [scale, fade]
        breath.duration = Self.period / 2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.isRemovedOnCompletion = false
        symbolLayer.add(breath, forKey: Self.animationKey)
    }

    static func raster(_ image: NSImage, scale: CGFloat) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              )
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

/// Workflows running: the Shortcuts spinner, in clay, turned by Core Animation; still
/// with Reduce Motion on.
struct ClaudeCodeSpinner: View {
    var lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            ZStack {
                Circle().inset(by: lineWidth / 2)
                    .stroke(ClaudeCodePalette.clay.opacity(0.18), lineWidth: lineWidth)
                Circle().inset(by: lineWidth / 2)
                    .trim(from: 0, to: 0.3)
                    .stroke(ClaudeCodePalette.clay.opacity(0.9), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        } else {
            ShortcutSpinner(lineWidth: lineWidth, color: ClaudeCodePalette.clayNS)
        }
    }
}

/// How far workflows have got: a ring filling in clay, round from the top. Never quite
/// empty, so it reads as a ring under way rather than an empty circle.
struct ClaudeProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().inset(by: lineWidth / 2)
                .stroke(ClaudeCodePalette.clay.opacity(0.22), lineWidth: lineWidth)
            Circle().inset(by: lineWidth / 2)
                .trim(from: 0, to: max(0.04, min(1, fraction)))
                .stroke(ClaudeCodePalette.clay, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut(duration: 0.5), value: fraction)
    }
}

/// A workflow's progress as a thin bar, in clay; its unfilled part turns red once the
/// workflow has given up on an agent.
struct ClaudeProgressBar: View {
    let fraction: Double
    var failed = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(failed ? ClaudeCodePalette.failure.opacity(0.35) : .white.opacity(0.14))
                Capsule().fill(ClaudeCodePalette.clay)
                    .frame(width: max(proxy.size.height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .animation(.easeInOut(duration: 0.5), value: fraction)
    }
}

// MARK: - Compact

/// Left of the notch: the mark.
struct ClaudeCodeCompactLeading: View {
    let model: ClaudeCodeModel

    var body: some View {
        ClaudeCodeMarkView(mark: model.mark, pointSize: ClaudeCodeLayout.compactSymbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Right of the notch: how long the turn on show has been going; or while workflows or
/// background agents run, a ring filling as the workflows get on, with how many there
/// are beside it when there are several; or where no workflow's files say how far it
/// has got, how many beside a spinner.
struct ClaudeCodeCompactTrailing: View {
    let model: ClaudeCodeModel

    var body: some View {
        GeometryReader { proxy in
            Group {
                let count = model.backgroundCount
                if count > 0 {
                    let fraction = model.workflowFraction
                    HStack(spacing: 5) {
                        if fraction == nil || count > 1 {
                            Text("\(count)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.6))
                                .fixedSize()
                        }
                        Group {
                            if let fraction {
                                ClaudeProgressRing(fraction: fraction, lineWidth: 2.5)
                            } else {
                                ClaudeCodeSpinner(lineWidth: 2.5)
                            }
                        }
                        .frame(width: ClaudeCodeLayout.compactSpinner, height: ClaudeCodeLayout.compactSpinner)
                    }
                    .padding(.trailing, ClaudeCodeLayout.trailingInset(rowHeight: proxy.size.height))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ClaudeCodeText.background(
                        workflows: model.runningWorkflowCount, agents: model.runningAgentCount, fraction: fraction))
                } else if let session = model.displayed {
                    Text(session.record.turnStart, style: .timer)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ClaudeCodeText.color(session.state))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.trailing, 6)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
    }
}

/// In the bubble, or folded into the island: the mark, inside the ring while workflows
/// run whose files say how far they have got.
struct ClaudeCodeMinimal: View {
    let model: ClaudeCodeModel

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let fraction = model.workflowFraction
            ZStack {
                if let fraction {
                    ClaudeProgressRing(fraction: fraction, lineWidth: 2)
                        .padding(side * ClaudeCodeLayout.minimalRingInset)
                        .transition(.opacity)
                }
                // A little smaller inside the ring, so the two do not touch.
                ClaudeCodeMarkView(mark: model.mark, pointSize: ClaudeCodeLayout.minimalSymbol)
                    .scaleEffect(fraction == nil ? 1 : ClaudeCodeLayout.minimalRingMark)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: - Expanded

/// Opened: a row per session, those waiting on you first. Clicking one brings forward
/// the app it runs in.
struct ClaudeCodeExpanded: View {
    let model: ClaudeCodeModel
    let open: (ClaudeSession) -> Void
    @AppStorage(ClaudeCodePrefs.showPrompt) private var showsText = true

    var body: some View {
        let sessions = model.shown
        let list = ClaudeCodeLayout.listHeight(sessions, showsText: showsText)

        Group {
            // A scroll view only once the rows need one. Its foot fades, so the row cut
            // off there reads as more to come; the last row can scroll clear of it.
            if list > ClaudeCodeLayout.listLimit(sessions) {
                ScrollView(.vertical, showsIndicators: false) {
                    rows(sessions)
                        .padding(.bottom, ClaudeCodeLayout.scrollFade)
                }
                .scrollBounceBehavior(.basedOnSize)
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: ClaudeCodeLayout.scrollFade)
                    }
                }
            } else {
                rows(sessions)
            }
        }
        .frame(height: min(list, ClaudeCodeLayout.listLimit(sessions)), alignment: .top)
        .padding(.top, ClaudeCodeLayout.topInset)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.islandMorph, value: sessions.map(\.id))
    }

    private func rows(_ sessions: [ClaudeSession]) -> some View {
        VStack(spacing: ClaudeCodeLayout.sessionSpacing) {
            ForEach(sessions) { session in
                ClaudeSessionRow(session: session, showsText: showsText) { open(session) }
                    .frame(height: ClaudeCodeLayout.rowHeight(session, showsText: showsText))
                    .transition(.opacity)
            }
        }
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSession
    let showsText: Bool
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        let host = ClaudeHostApps.name(for: session.record.hostApp)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Button(action: open) {
            HStack(alignment: .top, spacing: 9) {
                mark
                    .frame(width: 18, height: ClaudeCodeLayout.titleHeight)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(ClaudeCodeText.title(session, showsText: showsText))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        status
                    }
                    .frame(height: ClaudeCodeLayout.titleHeight)

                    if let detail = ClaudeCodeText.detail(session, showsText: showsText) {
                        Text(detail)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .frame(height: ClaudeCodeLayout.textHeight, alignment: .leading)
                    }

                    if ClaudeCodeLayout.tasksHeight(session) > 0 {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(session.runningWorkflows) { workflow in
                                ClaudeWorkflowRow(workflow: workflow, progress: session.progress(of: workflow))
                            }
                            ForEach(session.runningAgents) { agent in
                                ClaudeAgentRow(task: agent, progress: session.progress(of: agent))
                            }
                            ForEach(session.runningOthers) { task in
                                ClaudeOtherTaskRow(task: task)
                            }
                        }
                        .padding(.top, ClaudeCodeLayout.workflowsTop)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, ClaudeCodeLayout.rowPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(.white.opacity(isHovering && host != nil ? 0.08 : 0)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(host.map { "Go to \($0)" } ?? "")
    }

    /// The session's mark; a session done with its reply, with only background tasks
    /// left running under it, gets a quiet tick rather than the sparkle.
    @ViewBuilder
    private var mark: some View {
        if session.state == .idle {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        } else {
            ClaudeCodeMarkView(mark: ClaudeCodeModel.Mark(session.state), pointSize: 12)
        }
    }

    private var status: some View {
        HStack(spacing: 0) {
            Text(ClaudeCodeText.status(session.state))
                .foregroundStyle(ClaudeCodeText.color(session.state))
            if session.state != .idle {
                Text(" · ")
                    .foregroundStyle(.white.opacity(0.35))
                Text(session.record.turnStart, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }
}

/// A workflow under its session: its name, and for how long it has run. Where its files
/// say how far it has got, the phase under way beside the name, and under it a bar and
/// the agents at work now, with any it gave up on or is trying again; otherwise, what it
/// was started to do. Once its record says it has ended, before Claude Code has said so
/// to the hook, how it ended, on the one line.
private struct ClaudeWorkflowRow: View {
    let workflow: ClaudeWorkflow
    let progress: ClaudeWorkflowProgress?

    var body: some View {
        if let outcome = progress?.outcome {
            ended(outcome)
        } else {
            going
        }
    }

    private func ended(_ outcome: ClaudeWorkflowProgress.Outcome) -> some View {
        HStack(spacing: 6) {
            Image(systemName: outcome == .failed ? "xmark.circle.fill" : outcome == .completed
                  ? "checkmark.circle.fill" : "stop.circle.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(outcome == .failed ? ClaudeCodePalette.failure : .white.opacity(0.45))
                .frame(width: 10, height: 10)
            Text(workflow.name.isEmpty ? "Workflow" : workflow.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .layoutPriority(1)
            Text(ClaudeCodeText.outcome(outcome))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(outcome == .failed ? ClaudeCodePalette.failure : .white.opacity(0.42))
                .lineLimit(1)
            Spacer(minLength: 6)
        }
        .frame(height: ClaudeCodeLayout.workflowHeight)
        .accessibilityElement(children: .combine)
    }

    private var going: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Group {
                    if let fraction = progress?.fraction {
                        ClaudeProgressRing(fraction: fraction, lineWidth: 1.8)
                    } else {
                        ClaudeCodeSpinner(lineWidth: 1.5)
                    }
                }
                .frame(width: 10, height: 10)
                Text(workflow.name.isEmpty ? "Workflow" : workflow.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .layoutPriority(1)
                let beside = progress.map(ClaudeCodeText.phase) ?? ClaudeCodeText.oneLine(workflow.summary)
                if !beside.isEmpty {
                    Text(beside)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(progress == nil ? 0.42 : 0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                ClaudeTaskTimer(since: progress?.began ?? workflow.firstSeen)
            }
            .frame(height: ClaudeCodeLayout.workflowHeight)

            if let progress {
                HStack(spacing: 7) {
                    ClaudeProgressBar(fraction: progress.fraction ?? 0, failed: progress.failed > 0)
                        .frame(width: ClaudeCodeLayout.barWidth, height: 3)
                    Text(ClaudeCodeText.running(progress.running))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if progress.failed > 0 {
                        ClaudeTaskTag(text: "\(progress.failed) failed", color: ClaudeCodePalette.failure)
                    } else if progress.retrying > 0 {
                        ClaudeTaskTag(text: progress.retrying == 1 ? "retrying" : "\(progress.retrying) retrying",
                                      color: ClaudeCodePalette.attention)
                    }
                }
                .padding(.leading, 16)
                .frame(height: ClaudeCodeLayout.taskDetailHeight, alignment: .top)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// An agent sent off in the background: what it was sent to do, and for how long; under
/// it, what it is doing now and how many steps it has taken, where its transcript says.
private struct ClaudeAgentRow: View {
    let task: ClaudeBackgroundTask
    let progress: ClaudeAgentProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Group {
                    if progress?.finished == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                    } else {
                        ClaudeCodeSpinner(lineWidth: 1.5)
                    }
                }
                .frame(width: 10, height: 10)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Text("Agent")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .fixedSize()
                Spacer(minLength: 6)
                ClaudeTaskTimer(since: [progress?.began, task.firstSeen > .distantPast ? task.firstSeen : nil]
                    .compactMap { $0 }.min() ?? .distantPast)
            }
            .frame(height: ClaudeCodeLayout.workflowHeight)

            if let progress {
                // Read again every few seconds anyway; the clock only moves the quiet
                // time on while the files stay the same.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 7) {
                        Text(ClaudeCodeText.agent(progress))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let quiet = progress.quiet(at: context.date) {
                            ClaudeTaskTag(text: ClaudeCodeText.quiet(quiet), color: ClaudeCodePalette.attention)
                        }
                    }
                }
                .padding(.leading, 16)
                .frame(height: ClaudeCodeLayout.taskDetailHeight, alignment: .top)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var title: String {
        let summary = ClaudeCodeText.oneLine(task.summary)
        if !summary.isEmpty { return summary }
        let own = ClaudeCodeText.oneLine(progress?.summary ?? "")
        return own.isEmpty ? "Background agent" : own
    }
}

/// A command left running, or a monitor: what it is, and for how long.
private struct ClaudeOtherTaskRow: View {
    let task: ClaudeBackgroundTask

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 10, height: 10)
            Text(ClaudeCodeText.command(task) ?? fallback)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 6)
            ClaudeTaskTimer(since: task.firstSeen)
        }
        .frame(height: ClaudeCodeLayout.workflowHeight)
    }

    private var symbol: String {
        switch task.kind {
        case .shell: "terminal.fill"
        case .other(let kind) where kind.lowercased().contains("monitor"): "waveform.path.ecg"
        default: "circle.dashed"
        }
    }

    private var fallback: String {
        switch task.kind {
        case .shell: "Command"
        case .agent: "Background agent"
        case .other(let kind): kind.isEmpty ? "Background task" : kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }
}

/// How long a background task has been going, or nothing where that is not known.
private struct ClaudeTaskTimer: View {
    let since: Date

    var body: some View {
        if since > .distantPast {
            Text(since, style: .timer)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.42))
                .fixedSize()
        }
    }
}

/// A word or two in colour at the end of a task's second line: agents given up on, or
/// tried again; an agent gone quiet.
private struct ClaudeTaskTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Settings

struct ClaudeCodeSettingsView: View {
    let model: ClaudeCodeModel
    @AppStorage(ClaudeCodePrefs.showPrompt) private var showPrompt = true
    @State private var copied = false

    var body: some View {
        Toggle(isOn: $showPrompt) {
            Text("Show what you asked")
            Text("Under each session in the opened island, its latest prompt, or the start of Claude's reply once it's done; a session outside a project goes by its prompt. Off, sessions show by project alone.")
        }

        LabeledContent {
            Button(copied ? "Copied" : "Copy Hooks") {
                ClaudeCodeHooks.copy()
                copied = true
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Text("Hooks")
            Text("Claude Code tells Islet what it's doing through hooks. Copy Scripts/claude-code-hook.sh from Islet's source to ~/.claude/hooks/islet-notify.sh, then add the copied hooks to ~/.claude/settings.json. Until then, nothing shows.")
        }

        LabeledContent("Last heard from Claude Code") {
            TimelineView(.everyMinute) { context in
                Text(Self.heard(model.lastHeard, now: context.date))
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func heard(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not yet" }
        guard now.timeIntervalSince(date) >= 60 else { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
