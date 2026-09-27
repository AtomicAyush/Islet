import AppKit
import SwiftUI

enum ClaudeCodePalette {
    /// A warm clay, for Claude at work.
    static let clay = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let clayNS = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    /// The iPhone's orange in its dark appearance, as the hook's banners use when Claude
    /// is waiting on you.
    static let attention = Color(red: 1.0, green: 0.62, blue: 0.04)
}

enum ClaudeCodeLayout {
    /// Room right of the notch for the turn's time, to an hour and past it (smaller),
    /// or for the workflows' count beside a spinner.
    static let trailingWidth: CGFloat = 58
    static let compactSpinner: CGFloat = 16
    static let compactSymbol: CGFloat = 15
    static let minimalSymbol: CGFloat = 12

    // The opened page: a row per session, its workflows under it.
    static let topInset: CGFloat = 4
    static let bottomInset: CGFloat = 2
    static let rowPadding: CGFloat = 5
    static let sessionSpacing: CGFloat = 4
    static let titleHeight: CGFloat = 18
    static let textHeight: CGFloat = 16
    static let workflowsTop: CGFloat = 3
    static let workflowHeight: CGFloat = 17
    /// Past this the rows scroll.
    static let maxListHeight: CGFloat = 200
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
        let workflows = session.runningWorkflows.count
        if workflows > 0 { height += workflowsTop + CGFloat(workflows) * workflowHeight }
        return height
    }

    static func listHeight(_ sessions: [ClaudeSession], showsText: Bool) -> CGFloat {
        guard !sessions.isEmpty else { return 2 * rowPadding + titleHeight }
        let rows = sessions.reduce(0) { $0 + rowHeight($1, showsText: showsText) }
        return rows + CGFloat(sessions.count - 1) * sessionSpacing
    }

    static func pageHeight(for sessions: [ClaudeSession], showsText: Bool) -> CGFloat {
        topInset + min(listHeight(sessions, showsText: showsText), maxListHeight) + bottomInset
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
        case .workflows?: "Claude Code workflows running"
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

// MARK: - Compact

/// Left of the notch: the mark.
struct ClaudeCodeCompactLeading: View {
    let model: ClaudeCodeModel

    var body: some View {
        ClaudeCodeMarkView(mark: model.mark, pointSize: ClaudeCodeLayout.compactSymbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Right of the notch: how long the turn on show has been going, or while workflows
/// run, how many beside a spinner.
struct ClaudeCodeCompactTrailing: View {
    let model: ClaudeCodeModel

    var body: some View {
        GeometryReader { proxy in
            Group {
                let count = model.runningWorkflowCount
                if count > 0 {
                    HStack(spacing: 5) {
                        Text("\(count)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize()
                        ClaudeCodeSpinner(lineWidth: 2.5)
                            .frame(width: ClaudeCodeLayout.compactSpinner, height: ClaudeCodeLayout.compactSpinner)
                    }
                    .padding(.trailing, ClaudeCodeLayout.trailingInset(rowHeight: proxy.size.height))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(count == 1 ? "1 workflow running" : "\(count) workflows running")
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

/// In the bubble, or folded into the island: the mark alone.
struct ClaudeCodeMinimal: View {
    let model: ClaudeCodeModel

    var body: some View {
        ClaudeCodeMarkView(mark: model.mark, pointSize: ClaudeCodeLayout.minimalSymbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if list > ClaudeCodeLayout.maxListHeight {
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
        .frame(height: min(list, ClaudeCodeLayout.maxListHeight), alignment: .top)
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

                    if !session.runningWorkflows.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(session.runningWorkflows) { workflow in
                                ClaudeWorkflowRow(workflow: workflow)
                                    .frame(height: ClaudeCodeLayout.workflowHeight)
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

    /// The session's mark; a session done with its reply, with only workflows left
    /// running under it, gets a quiet tick rather than the sparkle.
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

/// A workflow under its session: its name, what it is doing, and for how long.
private struct ClaudeWorkflowRow: View {
    let workflow: ClaudeWorkflow

    var body: some View {
        HStack(spacing: 6) {
            ClaudeCodeSpinner(lineWidth: 1.5)
                .frame(width: 10, height: 10)
            Text(workflow.name.isEmpty ? "Workflow" : workflow.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .layoutPriority(1)
            let summary = ClaudeCodeText.oneLine(workflow.summary)
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if workflow.firstSeen > .distantPast {
                Text(workflow.firstSeen, style: .timer)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.42))
                    .fixedSize()
            }
        }
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
