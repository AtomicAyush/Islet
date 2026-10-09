import AppKit
import SwiftUI

extension FeatureTint {
    /// A warm clay, for Claude at work: the mark, the rings, the bars and the spinner.
    static let claudeCode = FeatureTint.colour(RGB(0.85, 0.47, 0.34))
}

/// The colours that say something about a session, so they never take the accent and
/// are only fitted for contrast.
enum ClaudeCodePalette {
    /// The iPhone's orange in its dark appearance, as the hook's banners use when Claude
    /// is waiting on you.
    static let attention = RGB(1.0, 0.62, 0.04)
    /// The iPhone's red in its dark appearance, for an agent a workflow gave up on.
    static let failure = RGB(1.0, 0.27, 0.23)

    static var attentionMark: IslandStyle { .islandFitted(attention) }
    static var attentionText: IslandStyle { .islandFitted(attention, minimum: Contrast.text) }
    static var failureMark: IslandStyle { .islandFitted(failure) }
    static var failureText: IslandStyle { .islandFitted(failure, minimum: Contrast.text) }
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
    /// The tallest the page grows before its rows scroll: as tall as Up Next, the tallest
    /// page. The island is kept inside its window, which leaves no more room than this
    /// for a page under a notch 40 points deep; past it, the island's edge would cut the
    /// page's foot off.
    static let maxPageHeight: CGFloat = 244
    static let scrollFade: CGFloat = 18
    /// How far the page's foot cuts into the last line it shows, once the rows scroll:
    /// the fade then always lies across the top of a line of words, so there is plainly
    /// more below, never over the gap between two lines or two sessions.
    static let scrollPeek: CGFloat = 12
    /// The fade at the head of the rows once they are scrolled down, so a line going up
    /// under the page's header fades rather than showing a sliver of its words.
    static let topFade: CGFloat = 10

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

    /// The most the rows take before they scroll, below the usage line where it shows
    /// (`header` tall). The little room below rows that fit gives way before they do;
    /// rows that scroll end in their fade instead.
    static func listLimit(header: CGFloat = 0) -> CGFloat { maxPageHeight - topInset - header }

    /// Where each line of the rows begins, from the top of the list, in the order the
    /// rows show them: each session's title and what was asked, then its tasks' lines.
    static func lineTops(_ sessions: [ClaudeSession], showsText: Bool) -> [CGFloat] {
        var tops: [CGFloat] = []
        var rowTop: CGFloat = 0
        for session in sessions {
            var y = rowTop + rowPadding
            func line(_ height: CGFloat) {
                tops.append(y)
                y += height
            }
            line(titleHeight)
            if ClaudeCodeText.detail(session, showsText: showsText) != nil { line(textHeight) }
            if tasksHeight(session) > 0 { y += workflowsTop }
            for workflow in session.runningWorkflows {
                line(workflowHeight)
                if session.progress(of: workflow).map({ !$0.isEnded }) ?? false { line(taskDetailHeight) }
            }
            for agent in session.runningAgents {
                line(workflowHeight)
                if session.progress(of: agent) != nil { line(taskDetailHeight) }
            }
            for _ in session.runningOthers { line(workflowHeight) }
            rowTop += rowHeight(session, showsText: showsText) + sessionSpacing
        }
        return tops
    }

    /// How much of the rows the page shows: all of them where they fit; otherwise as
    /// much as fits that ends `scrollPeek` into a line, so the fade lies across its words.
    static func visibleHeight(_ sessions: [ClaudeSession], showsText: Bool, header: CGFloat = 0) -> CGFloat {
        let list = listHeight(sessions, showsText: showsText)
        let limit = listLimit(header: header)
        guard list > limit else { return list }
        return lineTops(sessions, showsText: showsText).map { $0 + scrollPeek }.last { $0 <= limit } ?? limit
    }

    /// The page's height with an approval card above the rows, the rows given what is
    /// left: no taller than any page, which the island's window has no room beyond.
    static let maxApprovalPageHeight: CGFloat = maxPageHeight

    static func pageHeight(for sessions: [ClaudeSession], showsText: Bool, approval: ApprovalItem?, waiting: Int = 0,
                           isPrivate: Bool = false, header: CGFloat = 0) -> CGFloat {
        guard let approval else { return pageHeight(for: sessions, showsText: showsText, header: header) }
        let block = ApprovalLayout.height(for: approval, waiting: waiting, isPrivate: isPrivate)
        guard !sessions.isEmpty else { return header + topInset + block + bottomInset }
        return min(header + topInset + block + pageHeight(for: sessions, showsText: showsText), maxApprovalPageHeight)
    }

    /// The page's height, the usage line atop it where it shows (`header` tall).
    static func pageHeight(for sessions: [ClaudeSession], showsText: Bool, header: CGFloat = 0) -> CGFloat {
        let list = listHeight(sessions, showsText: showsText)
        let limit = listLimit(header: header)
        guard list > limit else { return min(header + topInset + list + bottomInset, maxPageHeight) }
        return header + topInset + visibleHeight(sessions, showsText: showsText, header: header)
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

    /// The branch beside the title, where the title is the project and the hook found
    /// one, while Settings shows it.
    static func branch(_ session: ClaudeSession, showsBranch: Bool) -> String? {
        let record = session.record
        guard showsBranch, !record.project.isEmpty, !record.branch.isEmpty else { return nil }
        return record.branch
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

    /// The words for how a session stands: clay while it works, orange while it
    /// waits on you, grey once it is done.
    static func style(_ state: ClaudeSessionState) -> IslandStyle {
        switch state {
        case .working: .islandAccentText(.claudeCode)
        case .needsPermission, .waitingForInput: ClaudeCodePalette.attentionText
        case .idle: .islandText(0.5)
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
    @Environment(\.islandTheme) private var theme

    var body: some View {
        ZStack {
            switch mark {
            case .needsPermission?:
                glyph("hand.raised.fill", ClaudeCodePalette.attentionMark)
            case .waitingForInput?:
                glyph("questionmark.bubble.fill", ClaudeCodePalette.attentionMark)
            case .working?:
                if reduceMotion {
                    glyph("sparkle", .islandAccent(.claudeCode))
                } else {
                    ClaudeBreathingSymbol(name: "sparkle", pointSize: pointSize, ink: .accent(.claudeCode))
                        .transition(.opacity)
                }
            case .workflows?:
                // Softer on black, as it always was; elsewhere the fitted clay at full
                // strength, which a lower opacity would take under 3:1.
                glyph("sparkle", theme.isDefault ? .islandAccent(.claudeCode).opacity(0.8) : .islandAccent(.claudeCode))
            case nil:
                EmptyView()
            }
        }
        .frame(width: pointSize * 1.5, height: pointSize * 1.5)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: mark)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private func glyph(_ name: String, _ style: IslandStyle) -> some View {
        Image(systemName: name)
            .font(.system(size: pointSize, weight: .semibold))
            .foregroundStyle(style)
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
/// app nothing per frame. With Reduce Motion on, the symbol is drawn still instead, and
/// while the island saves energy it holds still, whole.
///
/// Its colour is one of the island's, worked out from the theme in the environment and
/// handed to the view, which draws the symbol again when the island's colours change.
struct ClaudeBreathingSymbol: NSViewRepresentable {
    let name: String
    let pointSize: CGFloat
    let ink: IslandInk

    func makeNSView(context: Context) -> ClaudeBreathingSymbolView {
        ClaudeBreathingSymbolView(name: name, pointSize: pointSize, color: ink.nsColor(in: context.environment.islandTheme))
    }

    func updateNSView(_ view: ClaudeBreathingSymbolView, context: Context) {
        view.color = ink.nsColor(in: context.environment.islandTheme)
    }
}

final class ClaudeBreathingSymbolView: NSView {
    /// One breath in and out.
    static let period: CFTimeInterval = 2.4
    static let animationKey = "breathe"
    /// How small and faint it gets at the bottom of a breath.
    static let smallest: CGFloat = 0.74
    static let faintest: Float = 0.5

    let symbolLayer = CALayer()
    private let name: String
    private let pointSize: CGFloat
    private var image: NSImage?
    private var saverObserver: NSObjectProtocol?
    /// What the symbol is drawn in. Setting another colour draws it again, and the
    /// breath goes on undisturbed.
    var color: NSColor {
        didSet {
            guard color != oldValue else { return }
            image = Self.symbol(name, pointSize: pointSize, color: color)
            updateContents()
        }
    }

    init(name: String, pointSize: CGFloat, color: NSColor) {
        self.name = name
        self.pointSize = pointSize
        self.color = color
        image = Self.symbol(name, pointSize: pointSize, color: color)
        super.init(frame: .zero)
        wantsLayer = true
        symbolLayer.contentsGravity = .center
        layer?.addSublayer(symbolLayer)
        updateContents()
        saverObserver = NotificationCenter.default.addObserver(
            forName: EnergySaver.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if EnergySaver.shared.isSaving {
                    self.symbolLayer.removeAnimation(forKey: Self.animationKey)
                } else if self.window != nil {
                    self.startBreathing()
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let saverObserver { NotificationCenter.default.removeObserver(saverObserver) }
    }

    private static func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

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

    /// Breathes, unless the island saves energy.
    func startBreathing() {
        guard symbolLayer.animation(forKey: Self.animationKey) == nil, !EnergySaver.shared.isSaving else { return }
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
    @Environment(\.islandTheme) private var theme

    var body: some View {
        if reduceMotion {
            ZStack {
                Circle().inset(by: lineWidth / 2)
                    .stroke(.islandAccent(.claudeCode).opacity(0.18), lineWidth: lineWidth)
                Circle().inset(by: lineWidth / 2)
                    .trim(from: 0, to: 0.3)
                    .stroke(theme.isDefault ? IslandStyle.islandAccent(.claudeCode).opacity(0.9) : .islandAccent(.claudeCode),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        } else {
            // Recoloured by the spinner itself when the theme changes: softened to 0.9 on
            // the black island, as always, and at full strength, fitted, anywhere else.
            ShortcutSpinner(lineWidth: lineWidth, tint: .accent(.claudeCode))
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
                .stroke(.islandAccent(.claudeCode).opacity(0.22), lineWidth: lineWidth)
            Circle().inset(by: lineWidth / 2)
                .trim(from: 0, to: max(0.04, min(1, fraction)))
                .stroke(.islandAccent(.claudeCode), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
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
                Capsule().fill(failed ? ClaudeCodePalette.failureMark.opacity(0.35) : .islandDecorative(0.14))
                Capsule().fill(.islandAccent(.claudeCode))
                    .frame(width: max(proxy.size.height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .animation(.easeInOut(duration: 0.5), value: fraction)
    }
}

// MARK: - Compact

/// Left of the notch: the mark, in a ring from 80% of a usage limit.
struct ClaudeCodeCompactLeading: View {
    let model: ClaudeCodeModel
    var approvals: ApprovalCenter? = nil
    var usage: UsageCenter? = nil

    var body: some View {
        if let approvals, !model.isPreviewing, approvals.front(for: .claude) != nil {
            ApprovalCompactLeading(center: approvals, agent: .claude)
        } else {
            usual
        }
    }

    private var usual: some View {
        UsageRingMark(usage: usage?.compact(.claude) ?? CompactUsage()) {
            ClaudeCodeMarkView(mark: model.mark, pointSize: ClaudeCodeLayout.compactSymbol)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Right of the notch: how long the turn on show has been going; or while workflows or
/// background agents run, a ring filling as the workflows get on, with how many there
/// are beside it when there are several; or where no workflow's files say how far it
/// has got, how many beside a spinner. At the usage limit, when it lifts in their place.
struct ClaudeCodeCompactTrailing: View {
    let model: ClaudeCodeModel
    var approvals: ApprovalCenter? = nil
    var usage: UsageCenter? = nil

    var body: some View {
        if let approvals, !model.isPreviewing, approvals.front(for: .claude) != nil {
            ApprovalCompactTrailing(center: approvals, agent: .claude)
        } else if let usage, !model.isPreviewing, usage.compact(.claude).atLimit {
            UsageLimitTrailing(usage: usage.compact(.claude), now: usage.now)
        } else {
            usual
        }
    }

    private var usual: some View {
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
                                .foregroundStyle(.islandText(0.6))
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
                        .foregroundStyle(ClaudeCodeText.style(session.state))
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
    var approvals: ApprovalCenter? = nil

    var body: some View {
        if let approvals, !model.isPreviewing, approvals.front(for: .claude) != nil {
            ApprovalMinimal()
        } else {
            usual
        }
    }

    private var usual: some View {
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

/// Opened: a row per session, those waiting on you first, under a line of Claude's
/// usage limits while they show. Clicking a row brings forward the app it runs in.
struct ClaudeCodeExpanded: View {
    let model: ClaudeCodeModel
    var approvals: ApprovalCenter? = nil
    var usage: UsageCenter? = nil
    let open: (ClaudeSession) -> Void
    @AppStorage(ClaudeCodePrefs.showPrompt) private var showsText = true
    @AppStorage(ClaudeCodePrefs.showBranch) private var showsBranch = true
    /// How deep the fade at the head of the rows is: as far as they are scrolled down,
    /// up to `ClaudeCodeLayout.topFade`.
    @State private var headFade: CGFloat = 0

    private static let listSpace = "claudeCodeList"

    var body: some View {
        let status = model.isPreviewing ? nil : usage?.status(.claude)
        VStack(spacing: 0) {
            if let status { UsageLine(status: status) }
            page(header: status == nil ? 0 : UsageLayout.lineHeight)
        }
    }

    /// The page below the usage line, which takes `header` of its height.
    @ViewBuilder
    private func page(header: CGFloat) -> some View {
        if let approvals, !model.isPreviewing, let card = approvals.card(for: .claude) {
            // The request above the rows, which get what room is left.
            let block = ApprovalLayout.height(for: card.item, waiting: approvals.waiting(for: .claude).count,
                                              isPrivate: approvals.isPrivate)
            VStack(spacing: 0) {
                ApprovalBlock(center: approvals, item: card.item, decided: card.decided) { request in
                    // At the session, as its row would, where it has one.
                    if let session = model.sessions.first(where: { $0.id == request.sessionId && !$0.record.hostApp.isEmpty }) {
                        open(session)
                    } else {
                        _ = ClaudeHostApps.activate(request.hostApp)
                    }
                }
                .id(card.item.id)
                .frame(height: block, alignment: .top)
                .padding(.top, ClaudeCodeLayout.topInset)
                if !model.shown.isEmpty {
                    list(header: header)
                        .frame(maxHeight: max(0, ClaudeCodeLayout.maxApprovalPageHeight - header - block
                                                 - ClaudeCodeLayout.topInset * 2))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            list(header: header)
        }
    }

    @ViewBuilder
    private func list(header: CGFloat) -> some View {
        let sessions = model.shown
        let height = ClaudeCodeLayout.visibleHeight(sessions, showsText: showsText, header: header)
        // The rows' heights are worked out line by line, each line a fixed height, so
        // the sum says whether they overflow. Were it ever short, the rows would still
        // scroll, being in a scroll view at their own heights; only the fade would be
        // missing.
        let scrolls = ClaudeCodeLayout.listHeight(sessions, showsText: showsText) > height + 0.5
        let waiting = Set(sessions.filter(\.state.needsYou).map(\.id))

        // Always in a scroll view, so the list keeps its place as the rows refresh. Its
        // foot fades while the rows overflow, so the line cut off there reads as more to
        // come; the last row can scroll clear of it.
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                rows(sessions)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        min(max(-proxy.frame(in: .named(Self.listSpace)).minY, 0), ClaudeCodeLayout.topFade)
                    } action: { headFade = $0 }
                    .padding(.bottom, scrolls ? ClaudeCodeLayout.scrollFade : 0)
            }
            .coordinateSpace(.named(Self.listSpace))
            // No scroller: the fade says there is more, as on the clipboard's page.
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .modifier(ClaudeCodeListFade(head: scrolls ? headFade : 0, foot: scrolls ? ClaudeCodeLayout.scrollFade : 0))
            // Those waiting on you are listed first: one starting to wait while the list
            // is scrolled down would be out of sight, so the list goes back to the top.
            // At once: after a gliding scroll there, the next scroll snapped back to it.
            .onChange(of: waiting) { before, now in
                guard !now.subtracting(before).isEmpty, let first = sessions.first else { return }
                withAnimation(nil) { reader.scrollTo(first.id, anchor: .top) }
            }
        }
        .frame(height: height, alignment: .top)
        .padding(.top, ClaudeCodeLayout.topInset)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.islandMorph, value: sessions.map(\.id))
    }

    /// The rows at their own heights, which `ClaudeCodeLayout.rowHeight` works out.
    private func rows(_ sessions: [ClaudeSession]) -> some View {
        VStack(spacing: ClaudeCodeLayout.sessionSpacing) {
            ForEach(sessions) { session in
                ClaudeSessionRow(session: session, showsText: showsText, showsBranch: showsBranch) { open(session) }
                    .transition(.opacity)
            }
        }
    }
}

/// The rows' fades, at their head and foot. Rows that fit have neither, and no mask at
/// all, so their spinners are not composited through one as they turn. Going from one
/// to the other makes a new list, at its top as the old one was or would have come to
/// be; it takes the old one's place at once rather than fading in over it.
private struct ClaudeCodeListFade: ViewModifier {
    let head: CGFloat
    let foot: CGFloat

    func body(content: Content) -> some View {
        if head == 0 && foot == 0 {
            content
                .transition(.identity)
        } else {
            content
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: head)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: foot)
                    }
                }
                .transition(.identity)
        }
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSession
    let showsText: Bool
    let showsBranch: Bool
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
                        if let branch = ClaudeCodeText.branch(session, showsBranch: showsBranch) {
                            FolderBranchLabel(folder: session.record.project, branch: branch)
                        } else {
                            Text(ClaudeCodeText.title(session, showsText: showsText))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.islandPrimary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        status
                    }
                    .frame(height: ClaudeCodeLayout.titleHeight)

                    if let detail = ClaudeCodeText.detail(session, showsText: showsText) {
                        Text(detail)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.islandText(0.5))
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(shape.fill(.islandDecorative(isHovering && host != nil ? 0.08 : 0)))
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
                .foregroundStyle(.islandGraphic(0.45))
        } else {
            ClaudeCodeMarkView(mark: ClaudeCodeModel.Mark(session.state), pointSize: 12)
        }
    }

    private var status: some View {
        HStack(spacing: 0) {
            Text(ClaudeCodeText.status(session.state))
                .foregroundStyle(ClaudeCodeText.style(session.state))
            if session.state != .idle {
                Text(" · ")
                    .foregroundStyle(.islandText(0.35))
                Text(session.record.turnStart, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(.islandText(0.55))
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
                .foregroundStyle(outcome == .failed ? ClaudeCodePalette.failureMark : .islandGraphic(0.45))
                .frame(width: 10, height: 10)
            Text(workflow.name.isEmpty ? "Workflow" : workflow.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.islandText(0.6))
                .lineLimit(1)
                .layoutPriority(1)
            Text(ClaudeCodeText.outcome(outcome))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(outcome == .failed ? ClaudeCodePalette.failureText : .islandText(0.42))
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
                    .foregroundStyle(.islandText(0.8))
                    .lineLimit(1)
                    .layoutPriority(1)
                let beside = progress.map(ClaudeCodeText.phase) ?? ClaudeCodeText.oneLine(workflow.summary)
                if !beside.isEmpty {
                    Text(beside)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.islandText(progress == nil ? 0.42 : 0.55))
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
                        .foregroundStyle(.islandText(0.42))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if progress.failed > 0 {
                        ClaudeTaskTag(text: "\(progress.failed) failed", style: ClaudeCodePalette.failureText)
                    } else if progress.retrying > 0 {
                        ClaudeTaskTag(text: progress.retrying == 1 ? "retrying" : "\(progress.retrying) retrying",
                                      style: ClaudeCodePalette.attentionText)
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
                            .foregroundStyle(.islandGraphic(0.45))
                    } else {
                        ClaudeCodeSpinner(lineWidth: 1.5)
                    }
                }
                .frame(width: 10, height: 10)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.islandText(0.8))
                    .lineLimit(1)
                Text("Agent")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.islandText(0.35))
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
                            .foregroundStyle(.islandText(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let quiet = progress.quiet(at: context.date) {
                            ClaudeTaskTag(text: ClaudeCodeText.quiet(quiet), style: ClaudeCodePalette.attentionText)
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
                .foregroundStyle(.islandGraphic(0.45))
                .frame(width: 10, height: 10)
            Text(ClaudeCodeText.command(task) ?? fallback)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.islandText(0.6))
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
                .foregroundStyle(.islandText(0.42))
                .fixedSize()
        }
    }
}

/// A word or two in colour at the end of a task's second line: agents given up on, or
/// tried again; an agent gone quiet.
private struct ClaudeTaskTag: View {
    let text: String
    let style: IslandStyle

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(style)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Settings

struct ClaudeCodeSettingsView: View {
    let model: ClaudeCodeModel
    @AppStorage(ClaudeCodePrefs.showPrompt) private var showPrompt = true
    @AppStorage(ClaudeCodePrefs.showBranch) private var showBranch = true
    @State private var copied = false

    @AppStorage(ClaudeCodePrefs.approveFromIsland) private var approveFromIsland = true
    @AppStorage(ClaudeCodePrefs.openForApproval) private var openForApproval = true
    @AppStorage(ClaudeCodePrefs.skipDoneOnScreen) private var skipDoneOnScreen = true

    var body: some View {
        Toggle(isOn: $approveFromIsland) {
            Text("Approve from the island")
            Text("When Claude Code asks permission, the island shows what it wants to do, with Allow, Deny and Answer in Claude. Claude's own prompt still works; nothing is allowed without your click.")
        }

        Toggle(isOn: $openForApproval) {
            Text("Open the island for each request")
            Text("The island opens on the request by itself, once, unless you're presenting, the screen is locked or Claude is in front, and closes again after 12 seconds unless you move the pointer into it.")
        }
        .disabled(!approveFromIsland)

        ApprovalKeyRow(agent: .claude)

        Toggle(isOn: $showPrompt) {
            Text("Show what you asked")
            Text("Under each session in the opened island, its latest prompt, or the start of Claude's reply once it's done; a session outside a project goes by its prompt. Off, sessions show by project alone.")
        }

        Toggle(isOn: $showBranch) {
            Text("Show the git branch")
            Text("Beside each session's project, in the opened island and in its banners, the branch it's on, or the commit where none is checked out. The hook reads it at each event, so a checkout shows at the next. Off, the project alone.")
        }

        Toggle(isOn: $skipDoneOnScreen) {
            Text("Skip Done when the chat is on screen")
            Text("No Done banner when Claude finishes in the session the Claude app is showing in front; its row still updates. The app says which session it last showed, so one you've left for a chat elsewhere in the app still counts. Sessions in a terminal or an editor always get one.")
        }

        UsageSettingsRows(agent: .claude)

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
            Text("Claude Code tells Islet what it's doing through hooks. Copy Scripts/claude-code-hook.sh from Islet's source to ~/.claude/hooks/islet-notify.sh, then add the copied hooks to ~/.claude/settings.json. Until then, nothing shows. Copy the script again after updating Islet: hooks an older copy doesn't know are left out until you do.")
            Text("For approving from the island, the PermissionRequest hook waits up to 10 minutes and runs the script through bash -p. With an older line, whose timeout is 10 seconds, a request stays in the island only about 9 seconds before Claude Code stops waiting for it.")
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
