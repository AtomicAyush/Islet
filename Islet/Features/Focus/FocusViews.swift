import AppKit
import SwiftUI

extension FocusTint {
    /// The Focus's colour as one of the island's hues: the iPhone's system colour in its
    /// dark appearance on the black island, fitted to whatever colour the island is.
    var hue: SystemHue {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }
}

enum FocusPalette {
    /// A Focus that is off: its name and the word "Off", and, as a symbol, its symbol.
    static let off = IslandInk.text(0.5)
    static let offSymbol = IslandInk.graphic(0.5)
    /// Something went wrong running the shortcut.
    static let problem = SystemHue.warning
}

/// A Focus's symbol, fitted into a box so wide symbols (a bed, a games controller)
/// take no more room than round ones.
struct FocusSymbol: View {
    let symbol: String
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .fontWeight(.semibold)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

// MARK: - Banner

/// What a Focus banner says: a symbol and a name left of the notch, a word right of
/// it. Built for a Focus turning on or off, or for the shortcut that was to toggle it
/// failing.
struct FocusAnnouncement: Equatable {
    var symbol: String
    var symbolColor: IslandInk
    var name: String
    var nameColor: IslandInk
    var status: String
    var statusColor: IslandInk

    /// "Do Not Disturb · On" in the Focus's colour; "… · Off" in grey.
    static func focus(_ mode: FocusMode, isOn: Bool) -> FocusAnnouncement {
        FocusAnnouncement(
            symbol: mode.symbol,
            symbolColor: isOn ? .hue(mode.tint.hue) : FocusPalette.offSymbol,
            name: mode.name,
            nameColor: isOn ? .text(1) : FocusPalette.off,
            status: isOn ? "On" : "Off",
            statusColor: isOn ? .hue(mode.tint.hue, minimum: Contrast.text) : FocusPalette.off
        )
    }

    /// The shortcut chosen to toggle Focus did not run. It is not named: there is only
    /// the one, chosen in Settings, and names people give shortcuts ("Toggle Do Not
    /// Disturb") are too long for the island.
    static func problem(_ failure: FocusShortcut.Failure) -> FocusAnnouncement {
        FocusAnnouncement(
            symbol: "exclamationmark.triangle.fill",
            symbolColor: .hue(FocusPalette.problem),
            name: "Shortcut",
            nameColor: .text(1),
            status: failure == .notFound ? "Not Found" : "Failed",
            statusColor: .hue(FocusPalette.problem, minimum: Contrast.text)
        )
    }
}

/// Left of the notch: the symbol and the name. Where there is no room for the name,
/// or even the insets (the opened island's header gives it 24 points), the symbol.
struct FocusBannerLeading: View {
    let announcement: FocusAnnouncement

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: FocusBannerLayout.symbolSpacing) {
                symbol
                Text(announcement.name)
                    .font(Font(FocusBannerLayout.font))
                    .foregroundStyle(.island(announcement.nameColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: FocusBannerLayout.maximumNameWidth, alignment: .leading)
            }
            .padding(.leading, FocusBannerLayout.outerInset)
            .padding(.trailing, FocusBannerLayout.innerInset)
            symbol
                .padding(.leading, FocusBannerLayout.outerInset)
                .padding(.trailing, FocusBannerLayout.innerInset)
            symbol
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: some View {
        FocusSymbol(
            symbol: announcement.symbol,
            width: FocusBannerLayout.symbolSize.width,
            height: FocusBannerLayout.symbolSize.height
        )
        .foregroundStyle(.island(announcement.symbolColor))
    }
}

/// Right of the notch: "On" or "Off", against the wing's outer edge. Only as wide as
/// its content: the opened island's header sets it beside the leading symbol, where a
/// view that filled its width would push the two apart.
struct FocusBannerTrailing: View {
    let announcement: FocusAnnouncement

    var body: some View {
        Text(announcement.status)
            .font(Font(FocusBannerLayout.font))
            .foregroundStyle(.island(announcement.statusColor))
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, FocusBannerLayout.innerInset)
            .padding(.trailing, FocusBannerLayout.outerInset)
    }
}

/// The banner's measurements, matching the other compact banners: 13-point semibold
/// words, a symbol about the size of the headphones' glyph, the same insets. The
/// island makes both wings as wide as the wider side asks, so it stays centred on
/// the notch; each side asks only for its own width, and sits against the island's
/// outer edge.
enum FocusBannerLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let symbolSize = CGSize(width: 22, height: 17)
    static let symbolSpacing: CGFloat = 7
    /// Wide enough for Apple's longest name, "Reduce Interruptions"; anything longer
    /// truncates rather than push the island over half the menu bar.
    static let maximumNameWidth: CGFloat = 136
    /// Room between each wing's content and the island's outer edge, and the notch.
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10

    static func widths(for announcement: FocusAnnouncement) -> (leading: CGFloat, trailing: CGFloat) {
        (
            outerInset + symbolSize.width + symbolSpacing
                + min(textWidth(announcement.name), maximumNameWidth) + innerInset,
            innerInset + textWidth(announcement.status) + outerInset
        )
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it,
    /// which would otherwise truncate a name that just fits.
    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}

// MARK: - Home

/// The home page tile: the Focus that is on and until when, or that none is. Clicking
/// it runs the toggle shortcut; without Full Disk Access it says so, and clicking it
/// opens that list in System Settings.
struct FocusHomeTile: View {
    let model: FocusModel
    let toggle: FocusToggle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var content: some View {
        let display = FocusTileDisplay(
            state: model.shown,
            needsAccess: model.preview == nil && model.access == .needsFullDiskAccess,
            failure: model.preview == nil ? toggle.failure : nil
        )
        return VStack(alignment: .leading, spacing: 0) {
            FocusBadge(symbol: display.symbol, hue: display.hue, backdrop: .homeTile)
            Spacer(minLength: 6)
            Text(display.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.islandText(display.isOn ? 1 : 0.8, on: .homeTile))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            TimelineView(.everyMinute) { context in
                Text(display.status(at: context.date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.island(display.statusColor(on: .homeTile)))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(toggle.isRunning ? 0.55 : 1)
        .animation(.smooth(duration: 0.3), value: display)
    }

    private var help: String {
        if model.access == .needsFullDiskAccess { return "Open Full Disk Access in System Settings" }
        let hasShortcut = !(UserDefaults.standard.string(forKey: FocusPrefs.shortcut) ?? "").isEmpty
        return hasShortcut ? "Turn Focus on or off" : "Open Focus in System Settings"
    }
}

/// What the tile shows, worked out from the model once so the view only lays it out.
struct FocusTileDisplay: Equatable {
    var state: FocusState?
    var needsAccess: Bool
    var failure: FocusShortcut.Failure?

    var isOn: Bool { !needsAccess && state?.mode != nil }
    var symbol: String { (needsAccess ? nil : state?.mode?.symbol) ?? "moon.fill" }
    var title: String { (needsAccess ? nil : state?.mode?.name) ?? "Focus" }
    /// The Focus's colour while one is on.
    var hue: SystemHue? { isOn ? state?.mode?.tint.hue : nil }

    func status(at now: Date) -> String {
        if let failure { return failure == .notFound ? "Shortcut not found" : "Shortcut failed" }
        if needsAccess { return "Needs Full Disk Access" }
        guard isOn else { return "Off" }
        guard let until = state?.until, until > now else { return "On" }
        let time = until.formatted(date: .omitted, time: .shortened)
        // Within a day the time alone is clear, as the iPhone has it: at night, "Until
        // 7:00 AM" is tomorrow morning. Further off, the day is named too.
        if until.timeIntervalSince(now) < 24 * 60 * 60 { return "Until \(time)" }
        return "Until \(until.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    /// The status's words, on `backdrop`: a warning, the Focus's colour, or grey.
    func statusColor(on backdrop: IslandBackdrop) -> IslandInk {
        if failure != nil { return .hue(FocusPalette.problem, minimum: Contrast.text, on: backdrop) }
        return hue.map { .hue($0, minimum: Contrast.text, on: backdrop) } ?? .text(0.55, on: backdrop)
    }
}

// MARK: - Indicator card

/// The card the Focus's symbol opens in the opened island: which Focus is on and until
/// when, in the home tile's words, and, while that is Do Not Disturb and Settings names
/// a shortcut to toggle Focus, a button that turns it off with that shortcut, as
/// clicking the tile does. Once the Focus is off, the card says so for the moment
/// before it closes.
///
/// Only Do Not Disturb is offered "Turn Off": the shortcut Islet asks for toggles Do
/// Not Disturb, and run while another Focus is on it would turn Do Not Disturb on in
/// that one's place. The tile, which promises only to turn Focus on or off, runs it
/// whatever is on.
struct FocusIndicatorCard: View {
    let model: FocusModel
    let toggle: FocusToggle
    let turnOff: () -> Void
    @AppStorage(FocusPrefs.shortcut) private var shortcut = ""

    /// Wide enough for Apple's longest name, "Reduce Interruptions", whole; a longer
    /// one shrinks a little, then truncates. The card is no wider than its words and
    /// button need.
    static let maxWidth: CGFloat = 276

    var body: some View {
        let display = FocusTileDisplay(
            state: model.shown,
            needsAccess: false,
            failure: model.preview == nil ? toggle.failure : nil
        )
        let offersTurnOff = display.isOn && model.shown?.mode?.isDoNotDisturb == true && !shortcut.isEmpty
        HStack(spacing: 10) {
            FocusBadge(symbol: display.symbol, hue: display.hue, backdrop: .indicatorCard)
            VStack(alignment: .leading, spacing: 1) {
                Text(display.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.islandText(display.isOn ? 1 : 0.8, on: .indicatorCard))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                TimelineView(.everyMinute) { context in
                    Text(display.status(at: context.date))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.island(display.statusColor(on: .indicatorCard)))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if offersTurnOff {
                FocusTurnOffButton(hue: display.hue ?? FocusPalette.problem, isRunning: toggle.isRunning, action: turnOff)
                    .padding(.leading, 4)
            }
        }
        .animation(.smooth(duration: 0.3), value: display)
    }
}

extension FocusMode {
    /// Do Not Disturb itself, the Focus the toggle shortcut Islet asks for turns off.
    var isDoNotDisturb: Bool { identifier == "com.apple.donotdisturb.mode.default" }
}

/// "Turn Off", in the Focus's colour on a capsule of it, matching `RoundButton`. Dimmed
/// while the shortcut runs, as the tile is.
private struct FocusTurnOffButton: View {
    let hue: SystemHue
    let isRunning: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("Turn Off")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .islandWashed(
                    .hue(hue, minimum: Contrast.text), wash: isHovering ? 0.3 : 0.2, in: Capsule(), on: .indicatorCard
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .opacity(isRunning ? 0.55 : 1)
        .onHover { isHovering = $0 }
    }
}

/// The Focus's symbol on a disc of its colour, matching `RoundButton`; grey when off.
/// The disc lies on `backdrop`, a home tile or an indicator card.
struct FocusBadge: View {
    let symbol: String
    let hue: SystemHue?
    var backdrop: IslandBackdrop = .island
    var diameter: CGFloat = 30
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let colours = hue.map { theme.onWash(.hue($0), wash: 0.2, on: backdrop) }
            ?? (mark: FocusPalette.offSymbol.on(backdrop.stacked(0.1)).color(in: theme), wash: theme.surface(0.1, on: backdrop))
        FocusSymbol(symbol: symbol, width: diameter * 0.5, height: diameter * 0.44)
            .foregroundStyle(colours.mark)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(colours.wash))
    }
}

// MARK: - Settings

struct FocusSettingsView: View {
    let model: FocusModel
    let shortcuts: FocusShortcutList
    @AppStorage(FocusPrefs.announce) private var announce = false
    @AppStorage(FocusPrefs.showIndicator) private var showIndicator = true
    @AppStorage(FocusPrefs.quietMinorAlerts) private var quietMinorAlerts = true
    @AppStorage(FocusPrefs.shortcut) private var shortcut = ""

    var body: some View {
        FocusAccessRow(model: model)

        Toggle(isOn: $announce) {
            Text("Announce Focus changes")
            Text("macOS already shows its own banner for every Focus change, so this doubles it.")
        }
        Toggle(isOn: $showIndicator) {
            Text("Show while on")
            Text("The Focus's symbol beside the notch, in its colour.")
        }
        Toggle(isOn: $quietMinorAlerts) {
            Text("Quiet minor alerts during Focus")
            Text("Song changes go unannounced while a Focus is on.")
        }

        Picker(selection: $shortcut) {
            Text("None").tag("")
            ForEach(choices, id: \.self) { name in
                Text(isMissing(name) ? "\(name) (not found)" : name).tag(name)
            }
        } label: {
            Text("Toggle Focus with")
            Text("Clicking the Focus tile on the home page runs this shortcut, as does islet://focus/toggle.")
        }
        .onHover { if $0 { shortcuts.refresh() } }
        .onAppear { shortcuts.refresh() }

        LabeledContent {
            Button("Open Shortcuts") { FocusShortcut.openShortcutsApp() }
        } label: {
            Text("Make a shortcut with the Set Focus action set to toggle Do Not Disturb.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from Shortcuts, perhaps with a new one.
            shortcuts.refresh()
        }
    }

    /// The person's shortcuts, and the chosen one even when it is not among them, so
    /// the picker never shows an empty selection.
    private var choices: [String] {
        var names = shortcuts.names ?? []
        if !shortcut.isEmpty, !names.contains(shortcut) { names.append(shortcut) }
        return names
    }

    private func isMissing(_ name: String) -> Bool {
        guard let names = shortcuts.names else { return false }
        return !names.contains(name)
    }
}

/// Whether Islet can read Focus, and the way to let it.
private struct FocusAccessRow: View {
    let model: FocusModel

    var body: some View {
        LabeledContent {
            switch model.access {
            case .granted:
                Label {
                    Text("Allowed")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
            case .needsFullDiskAccess:
                Button("Open Privacy Settings…") { FocusSystemSettings.openFullDiskAccess() }
            case .unavailable:
                Text("Unavailable").foregroundStyle(.secondary)
            case .unknown:
                ProgressView().controlSize(.small)
            }
        } label: {
            Text("Full Disk Access")
            Text(explanation)
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private var explanation: String {
        switch model.access {
        case .granted, .unknown:
            "Islet reads which Focus is on from the Focus database."
        case .needsFullDiskAccess:
            "macOS keeps Focus in a folder only apps with Full Disk Access can read. Switch Islet on in that list; until then the island shows no Focus."
        case .unavailable:
            "This version of macOS keeps Focus somewhere Islet cannot read, so the island shows none."
        }
    }
}
