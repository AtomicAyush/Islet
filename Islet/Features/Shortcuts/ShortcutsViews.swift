import AppKit
import SwiftUI

enum ShortcutsPalette {
    /// The iPhone's green and red in their dark appearance, for a run's tick and cross.
    static let succeeded = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let failed = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)
    /// Stopped from Islet: neither a success nor a failure.
    static let stopped = Color.white.opacity(0.45)
    /// The label on the home tile, after the Shortcuts app's own icon.
    static let label = LinearGradient(
        colors: [Color(red: 1.0, green: 0.42, blue: 0.56), Color(red: 0.49, green: 0.47, blue: 1.0)],
        startPoint: .leading, endPoint: .trailing
    )
}

enum ShortcutsLayout {
    static let compactTile: CGFloat = 20
    static let compactMark: CGFloat = 16
    /// The icon, or the outcome in its place, in the bubble or folded into the island.
    static let minimalSize: CGFloat = 16
    /// Room for the count beside the spinner while several run.
    static let countedTrailingWidth: CGFloat = 60
    static let expandedHeight: CGFloat = 76

    /// Between the spinner and the island's outer end, in a row `rowHeight` tall: the
    /// tile on the left is centred in the default wing, so the spinner is centred in
    /// the same width at the right, whatever the notch's height, and stays there when
    /// the count widens its wing.
    static func trailingInset(rowHeight: CGFloat) -> CGFloat {
        max(0, (IslandLayout.defaultSide(for: CGSize(width: 0, height: rowHeight)) - compactMark) / 2)
    }
}

// MARK: - Pieces

/// A shortcut's icon as Shortcuts draws it: a white symbol on a tile of its colour,
/// lit a little from the top. Without Full Disk Access there is no icon to read, and
/// the tile is slate with the name's first letter.
struct ShortcutTile: View {
    let shortcut: ShortcutInfo
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        ZStack {
            shape.fill(ShortcutPalette.color(shortcut.icon?.colour ?? ShortcutPalette.grayBlue))
            shape.fill(LinearGradient(
                colors: [.white.opacity(0.14), .white.opacity(0)], startPoint: .top, endPoint: .bottom
            ))
            if let icon = shortcut.icon {
                Image(systemName: icon.symbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .fontWeight(.semibold)
                    .frame(width: size * 0.56, height: size * 0.5)
            } else {
                Text(initial)
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.5)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initial: String {
        shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? ""
    }
}

/// A run's state as a mark: a spinner while it runs, then a tick, a cross, or nothing
/// for a run whose end went unrecorded.
struct ShortcutRunMark: View {
    let phase: ShortcutRun.Phase?
    var size: CGFloat
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            switch phase {
            case .running?, nil:
                ShortcutSpinner(lineWidth: lineWidth)
                    .transition(.opacity)
            case .succeeded?:
                mark("checkmark.circle.fill", ShortcutsPalette.succeeded)
            case .failed?:
                mark("xmark.circle.fill", ShortcutsPalette.failed)
            case .stopped?:
                mark("xmark.circle.fill", ShortcutsPalette.stopped)
            case .vanished?:
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: phase)
    }

    private func mark(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
    }
}

/// A spinning arc, turned by Core Animation: the render server spins it on its own, so
/// a shortcut running for minutes costs the app nothing per frame. It exists only
/// while a run does.
struct ShortcutSpinner: NSViewRepresentable {
    var lineWidth: CGFloat = 2
    var color: NSColor = .white

    func makeNSView(context: Context) -> ShortcutSpinnerView {
        ShortcutSpinnerView(lineWidth: lineWidth, color: color)
    }

    func updateNSView(_ view: ShortcutSpinnerView, context: Context) {}
}

final class ShortcutSpinnerView: NSView {
    /// One turn, as quick as the system's own spinners.
    static let period: CFTimeInterval = 0.9

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let lineWidth: CGFloat

    init(lineWidth: CGFloat, color: NSColor) {
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
        for layer in [track, arc] {
            layer.fillColor = nil
            layer.lineWidth = lineWidth
            layer.lineCap = .round
            self.layer?.addSublayer(layer)
        }
        track.strokeColor = color.withAlphaComponent(0.18).cgColor
        arc.strokeColor = color.withAlphaComponent(0.9).cgColor
        arc.strokeEnd = 0.3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        let square = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let circle = CGRect(origin: .zero, size: square.size).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = CGPath(ellipseIn: circle, transform: nil)
        for layer in [track, arc] {
            layer.frame = square
            layer.path = path
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        // Clockwise: the layer's y axis points up.
        spin.toValue = -2 * CGFloat.pi
        spin.duration = Self.period
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "spin")
    }
}

// MARK: - Compact

/// Left of the notch: the icon of the shortcut the island is showing.
struct ShortcutsCompactLeading: View {
    let runs: ShortcutRuns

    var body: some View {
        ZStack {
            if let run = runs.displayed {
                ShortcutTile(shortcut: run.shortcut, size: ShortcutsLayout.compactTile)
                    .id(run.shortcut.id)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: runs.displayed?.shortcut.id)
    }
}

/// Right of the notch: the spinner, or the outcome, with the count of runs going when
/// there are several.
struct ShortcutsCompactTrailing: View {
    let runs: ShortcutRuns

    var body: some View {
        // The row's height is the notch's, which sets the inset that mirrors the tile.
        GeometryReader { proxy in
            HStack(spacing: 5) {
                if runs.count > 1 {
                    Text("\(runs.count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize()
                        .transition(.opacity)
                }
                ShortcutRunMark(phase: runs.displayed?.phase, size: ShortcutsLayout.compactMark)
            }
            .padding(.trailing, ShortcutsLayout.trailingInset(rowHeight: proxy.size.height))
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
    }
}

/// In the bubble, or folded into the island: the icon while the run goes, then the
/// tick or cross in its place, as large. The circle can be as small as 20 points,
/// with no room beside the icon for a badge that would still read.
struct ShortcutsMinimal: View {
    let runs: ShortcutRuns

    var body: some View {
        ZStack {
            if let run = runs.displayed {
                if Self.showsOutcome(run.phase) {
                    ShortcutRunMark(phase: run.phase, size: ShortcutsLayout.minimalSize)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    ShortcutTile(shortcut: run.shortcut, size: ShortcutsLayout.minimalSize)
                        .id(run.shortcut.id)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: runs.displayed.map { Self.showsOutcome($0.phase) })
    }

    /// A run that has ended with a verdict; one whose end went unrecorded keeps its icon.
    private static func showsOutcome(_ phase: ShortcutRun.Phase) -> Bool {
        switch phase {
        case .succeeded, .failed, .stopped: true
        case .running, .vanished: false
        }
    }
}

// MARK: - Expanded

struct ShortcutsExpanded: View {
    let runs: ShortcutRuns
    let stop: (String) -> Void

    var body: some View {
        HStack(spacing: 14) {
            if let run = runs.displayed {
                ShortcutTile(shortcut: run.shortcut, size: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text(run.shortcut.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    status(run)
                    if let caption = caption(run) {
                        Text(caption)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if run.canStop {
                    // The spinner rings the button, so it still says the run is going.
                    ZStack {
                        ShortcutSpinner(lineWidth: 2.5)
                            .frame(width: 46, height: 46)
                        RoundButton(symbol: "stop.fill", tint: .white) { stop(run.id) }
                    }
                    .help("Stop the shortcut")
                } else {
                    ShortcutRunMark(phase: run.phase, size: 30, lineWidth: 3)
                        .padding(.trailing, 4)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func status(_ run: ShortcutRun) -> some View {
        Group {
            switch run.phase {
            case .running:
                // Counts up by itself: nothing drives it frame by frame.
                Text("Running… ") + Text(run.startedAt, style: .timer)
            case .succeeded:
                Text("Done").foregroundStyle(ShortcutsPalette.succeeded)
            case .failed(let failure):
                Text(Self.words(for: failure)).foregroundStyle(ShortcutsPalette.failed)
            case .stopped:
                Text("Stopped")
            case .vanished:
                Text("Ended")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
    }

    static func words(for failure: ShortcutRunFailure?) -> String {
        switch failure {
        case .notFound?: "Not found"
        case .timedOut?: "Timed out"
        case .failed?, nil: "Didn't finish"
        }
    }

    /// Where a run started elsewhere came from, and how many more are going.
    private func caption(_ run: ShortcutRun) -> String? {
        var parts: [String] = []
        if case .elsewhere(let source) = run.origin, let place = ShortcutSources.place(source) {
            parts.append("From \(place)")
        }
        let others = runs.running.filter { $0.id != run.id }.count
        if others > 0 { parts.append("\(others) more running") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The words for where a run started, from the database's name for its source.
enum ShortcutSources {
    static func place(_ source: String?) -> String? {
        guard let source else { return nil }
        if source.hasPrefix("siri") { return "Siri" }
        return switch source {
        case "menu_bar", "menubar": "the menu bar"
        case "spotlight-search", "spotlight": "Spotlight"
        case "my-workflows", "folder", "shortcuts-app": "Shortcuts"
        case "trigger", "automation": "an automation"
        case "keyboard", "services-keyboard-shortcut": "a keyboard shortcut"
        case "services-menu": "the Services menu"
        case "commandline": "the command line"
        case "widget", "widgetkit": "a widget"
        case "controls": "Control Center"
        case "dockmenu": "the Dock"
        case "apple-event": "a script"
        case "x-callback-url": "a link"
        case "run_workflow_action": "another shortcut"
        default: nil
        }
    }
}

// MARK: - Result

enum ShortcutResultLayout {
    static let width: CGFloat = 420
    static let font = NSFont.systemFont(ofSize: 12)
    static let header: CGFloat = 26
    static let spacing: CGFloat = 8
    /// Past this many lines the text scrolls.
    static let visibleLines = 6
    /// Shown in the card; the rest is still copied.
    static let shownCharacters = 2_000

    /// The card's text width: its width less the island's insets either side.
    static var textWidth: CGFloat { width - 2 * IslandLayout.expandedInset.leading }

    static func shown(_ output: ShortcutOutput) -> String {
        guard output.text.count > shownCharacters || output.isTruncated else { return output.text }
        return String(output.text.prefix(shownCharacters)) + "…"
    }

    /// The card's body height: the header, and the text up to `visibleLines` lines.
    /// SwiftUI sets each line at the font's line height rounded up to a whole point,
    /// so the lines are counted and given that much each, rather than the measured
    /// height taken as it is (which would show a sliver of a seventh line).
    static func height(for output: ShortcutOutput) -> CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: font)
        let measured = (shown(output) as NSString).boundingRect(
            with: CGSize(width: textWidth - 4, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        let lines = min(max(1, Int((measured / line).rounded())), visibleLines)
        return header + spacing + CGFloat(lines) * ceil(line) + 1
    }
}

/// What a shortcut Islet ran gave back: selectable, and copied whole with one click.
struct ShortcutResultCard: View {
    let shortcut: ShortcutInfo
    let output: ShortcutOutput
    /// The pointer arrived or left: the card's time starts again.
    let keep: () -> Void
    let dismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: ShortcutResultLayout.spacing) {
            HStack(spacing: 10) {
                ShortcutTile(shortcut: shortcut, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(shortcut.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(output.isTruncated ? "Result (cut short)" : "Result")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 8)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                RoundButton(symbol: "xmark", tint: .white, diameter: 24, action: dismiss)
            }
            .frame(height: ShortcutResultLayout.header)

            ScrollView(.vertical) {
                Text(ShortcutResultLayout.shown(output))
                    .font(Font(ShortcutResultLayout.font))
                    .foregroundStyle(.white.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onHover { _ in keep() }
    }

    private func copy() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(output.text, forType: .string)
        copied = true
        keep()
    }
}

// MARK: - Home

/// The home page tile: up to six shortcuts, each a click from running. The one under
/// the pointer names itself in the tile's label.
struct ShortcutsHomeTile: View {
    let catalogue: ShortcutCatalogue
    let runs: ShortcutRuns
    let run: (ShortcutInfo) -> Void
    let choose: () -> Void
    @AppStorage(ShortcutsPrefs.pinned) private var pinned = ""
    @State private var hovered: String?

    static let tile: CGFloat = 26
    static let spacing: CGFloat = 7

    var body: some View {
        let shortcuts = pinnedShortcuts
        VStack(alignment: .leading, spacing: 8) {
            label(shortcuts.first { $0.id == hovered }?.name)
            if shortcuts.isEmpty {
                empty
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(Self.tile), spacing: Self.spacing), count: 3),
                    alignment: .leading,
                    spacing: Self.spacing
                ) {
                    ForEach(shortcuts) { shortcut in
                        button(shortcut)
                    }
                }
            }
        }
    }

    /// The pinned shortcuts the catalogue still has, in the order they were pinned.
    private var pinnedShortcuts: [ShortcutInfo] {
        ShortcutsPrefs.identifiers(pinned).compactMap { catalogue.shortcut(identifier: $0) }
    }

    private func label(_ name: String?) -> some View {
        Group {
            if let name {
                Text(name)
                    .foregroundStyle(.white)
            } else {
                Label("Shortcuts", systemImage: "square.2.layers.3d.fill")
                    .foregroundStyle(ShortcutsPalette.label)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run shortcuts from here.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: choose) {
                // The whole label where the tile has room for it.
                ViewThatFits(in: .horizontal) {
                    Text("Choose Shortcuts…")
                    Text("Choose…")
                }
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Choose shortcuts in Settings")
        }
    }

    private func button(_ shortcut: ShortcutInfo) -> some View {
        let phase = runs.phase(of: shortcut)
        let isHovered = hovered == shortcut.id
        return Button {
            run(shortcut)
        } label: {
            ShortcutTile(shortcut: shortcut, size: Self.tile)
                .overlay {
                    if let phase {
                        RoundedRectangle(cornerRadius: Self.tile * 0.24, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                        ShortcutRunMark(phase: phase, size: 14)
                    }
                }
                .scaleEffect(isHovered ? 1.08 : 1)
                .animation(.islandHover, value: isHovered)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shortcut.name)
        .accessibilityLabel(shortcut.name)
        .onHover { inside in
            if inside {
                hovered = shortcut.id
            } else if hovered == shortcut.id {
                hovered = nil
            }
        }
    }
}
