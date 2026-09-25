import AppKit
import SwiftUI

extension FocusTint {
    /// The iPhone's system colours in their dark appearance, which is what the black
    /// island shows them against.
    var color: Color {
        switch self {
        case .red: Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)
        case .orange: Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
        case .yellow: Color(red: 255 / 255, green: 214 / 255, blue: 10 / 255)
        case .green: Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
        case .mint: Color(red: 99 / 255, green: 230 / 255, blue: 226 / 255)
        case .teal: Color(red: 64 / 255, green: 200 / 255, blue: 224 / 255)
        case .cyan: Color(red: 100 / 255, green: 210 / 255, blue: 255 / 255)
        case .blue: Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
        case .indigo: Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255)
        case .purple: Color(red: 191 / 255, green: 90 / 255, blue: 242 / 255)
        case .pink: Color(red: 255 / 255, green: 55 / 255, blue: 95 / 255)
        case .brown: Color(red: 172 / 255, green: 142 / 255, blue: 104 / 255)
        case .gray: Color(red: 152 / 255, green: 152 / 255, blue: 157 / 255)
        }
    }
}

enum FocusPalette {
    /// A Focus that is off: its symbol, its name and the word "Off".
    static let off = Color.white.opacity(0.5)
    /// Something went wrong running the shortcut.
    static let problem = FocusTint.orange.color
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
    var symbolColor: Color
    var name: String
    var nameColor: Color
    var status: String
    var statusColor: Color

    /// "Do Not Disturb · On" in the Focus's colour; "… · Off" in grey.
    static func focus(_ mode: FocusMode, isOn: Bool) -> FocusAnnouncement {
        FocusAnnouncement(
            symbol: mode.symbol,
            symbolColor: isOn ? mode.tint.color : FocusPalette.off,
            name: mode.name,
            nameColor: isOn ? .white : FocusPalette.off,
            status: isOn ? "On" : "Off",
            statusColor: isOn ? mode.tint.color : FocusPalette.off
        )
    }

    /// The shortcut chosen to toggle Focus did not run. It is not named: there is only
    /// the one, chosen in Settings, and names people give shortcuts ("Toggle Do Not
    /// Disturb") are too long for the island.
    static func problem(_ failure: FocusShortcut.Failure) -> FocusAnnouncement {
        FocusAnnouncement(
            symbol: "exclamationmark.triangle.fill",
            symbolColor: FocusPalette.problem,
            name: "Shortcut",
            nameColor: .white,
            status: failure == .notFound ? "Not Found" : "Failed",
            statusColor: FocusPalette.problem
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
                    .foregroundStyle(announcement.nameColor)
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
        .foregroundStyle(announcement.symbolColor)
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
            .foregroundStyle(announcement.statusColor)
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
            FocusBadge(symbol: display.symbol, tint: display.tint)
            Spacer(minLength: 6)
            Text(display.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(display.isOn ? .white : .white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            TimelineView(.everyMinute) { context in
                Text(display.status(at: context.date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(display.statusColor)
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
    var tint: Color? { isOn ? state?.mode?.tint.color : nil }

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

    var statusColor: Color {
        if failure != nil { return FocusPalette.problem }
        return tint ?? .white.opacity(0.55)
    }
}

/// The Focus's symbol on a disc of its colour, matching `RoundButton`; grey when off.
struct FocusBadge: View {
    let symbol: String
    let tint: Color?
    var diameter: CGFloat = 30

    var body: some View {
        FocusSymbol(symbol: symbol, width: diameter * 0.5, height: diameter * 0.44)
            .foregroundStyle(tint ?? FocusPalette.off)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill((tint ?? .white).opacity(tint == nil ? 0.1 : 0.2)))
    }
}

// MARK: - Settings

struct FocusSettingsView: View {
    let model: FocusModel
    let shortcuts: FocusShortcutList
    @AppStorage(FocusPrefs.announce) private var announce = true
    @AppStorage(FocusPrefs.showIndicator) private var showIndicator = true
    @AppStorage(FocusPrefs.quietMinorAlerts) private var quietMinorAlerts = true
    @AppStorage(FocusPrefs.shortcut) private var shortcut = ""

    var body: some View {
        FocusAccessRow(model: model)

        Toggle("Announce Focus changes", isOn: $announce)
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
