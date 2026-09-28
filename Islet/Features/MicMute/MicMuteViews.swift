import AppKit
import SwiftUI

/// Mic Mute's colours all mean something, so none of them takes the accent: the mic
/// state sits beside the privacy lights.
enum MicMutePalette {
    /// Muted: the system red.
    static let muted = SystemHue.muted
    /// Something to notice: the mute came off elsewhere, or could not go on.
    static let warning = SystemHue.warning
    /// A microphone that cannot be muted, or none at all: its symbol, greyed.
    static let unavailable = IslandInk.graphic(0.5)
}

/// What the tile and the card say, worked out from the model once so the views only lay
/// it out.
struct MicMuteDisplay: Equatable {
    var snapshot: MicMuteSnapshot

    var isMuted: Bool { snapshot.isMuted }
    var canToggle: Bool { snapshot.isMuted || snapshot.microphone?.way != nil }
    var symbol: String { isMuted ? "mic.slash.fill" : "mic.fill" }
    /// The symbol's colour: red while muted, the island's ink while it can be muted,
    /// and `nil` when it can't, when it is greyed.
    var tint: IslandInk? {
        if isMuted { return .hue(MicMutePalette.muted) }
        return canToggle ? .graphic(1) : nil
    }

    var status: String {
        if isMuted { return "Muted" }
        guard let microphone = snapshot.microphone else { return "None connected" }
        return microphone.way == nil ? "Can't be muted" : "On"
    }

    /// The status's words, on `backdrop`.
    func statusColor(on backdrop: IslandBackdrop) -> IslandInk {
        isMuted ? .hue(MicMutePalette.muted, minimum: Contrast.text, on: backdrop) : .text(0.55, on: backdrop)
    }

    /// Which microphone, where there is one.
    var device: String? { snapshot.microphone?.name }

    var help: String {
        if isMuted { return "Unmute the microphone" }
        return canToggle ? "Mute the microphone for every app" : "This microphone can't be muted"
    }
}

/// The microphone on a disc, matching `RoundButton`: red and crossed out while muted,
/// in the island's ink while on, grey where it cannot be muted.
struct MicMuteBadge: View {
    let display: MicMuteDisplay
    var diameter: CGFloat = 30
    /// What the disc lies on: a home tile, or an indicator card.
    var backdrop: IslandBackdrop = .island
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let colours = display.tint.map { theme.onWash($0, wash: display.isMuted ? 0.2 : 0.12, on: backdrop) }
            ?? (mark: MicMutePalette.unavailable.on(backdrop.stacked(0.12)).color(in: theme), wash: theme.surface(0.12, on: backdrop))
        Image(systemName: display.symbol)
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .foregroundStyle(colours.mark)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(colours.wash))
            .accessibilityHidden(true)
    }
}

// MARK: - Home

/// The home page tile: the microphone, whether it is muted, and which one it is. A
/// click mutes or unmutes; where the microphone cannot be muted, it says so, and takes
/// no clicks.
struct MicMuteHomeTile: View {
    let model: MicMuteModel

    var body: some View {
        let display = MicMuteDisplay(snapshot: model.shown)
        Button {
            model.perform(.toggle, from: .island)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                MicMuteBadge(display: display, backdrop: .homeTile)
                Spacer(minLength: 6)
                Text("Microphone")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.islandText(display.canToggle ? 1 : 0.8, on: .homeTile))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(display.status)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.island(display.statusColor(on: .homeTile)))
                    .lineLimit(1)
                if let device = display.device {
                    Text(device)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.islandText(0.4, on: .homeTile))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!display.canToggle)
        .opacity(model.isBusy ? 0.55 : 1)
        .help(display.help)
        .animation(.smooth(duration: 0.3), value: display)
    }
}

// MARK: - Indicator card

/// The card the red mark opens in the opened island: that the microphone is muted, and
/// which one, with Unmute. Once unmuted it says so for the moment before it closes.
struct MicMuteIndicatorCard: View {
    let model: MicMuteModel

    /// Wide enough for "MacBook Pro Microphone" whole beside the button; a longer name
    /// truncates.
    static let maxWidth: CGFloat = 300

    var body: some View {
        let display = MicMuteDisplay(snapshot: model.shown)
        HStack(spacing: 10) {
            MicMuteBadge(display: display, backdrop: .indicatorCard)
            VStack(alignment: .leading, spacing: 1) {
                Text(display.isMuted ? "Microphone muted" : "Microphone on")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.islandText(1, on: .indicatorCard))
                    .lineLimit(1)
                if let device = display.device {
                    Text(device)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.islandText(0.55, on: .indicatorCard))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MicMuteButton(model: model)
                .padding(.leading, 4)
        }
        .animation(.smooth(duration: 0.3), value: display)
    }
}

/// "Mute", or "Unmute" in red while muted, on a capsule of its colour, matching
/// `RoundButton`: in the red mark's card, and on the microphone's line of the privacy
/// card while an app is using it. It says what a click does, and does that. Dimmed
/// while a request is on its way.
struct MicMuteButton: View {
    let model: MicMuteModel
    var height: CGFloat = 24
    /// What the capsule lies on: both of its places are indicator cards.
    var backdrop: IslandBackdrop = .indicatorCard
    @State private var isHovering = false

    var body: some View {
        let isMuted = model.shown.isMuted
        let tint: IslandInk = isMuted ? .hue(MicMutePalette.muted, minimum: Contrast.text) : .text(1)
        Button {
            model.perform(isMuted ? .unmute : .mute, from: .island)
        } label: {
            Text(isMuted ? "Unmute" : "Mute")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: height)
                .islandWashed(tint, wash: isHovering ? 0.3 : 0.2, in: Capsule(), on: backdrop)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(model.isBusy || !model.canToggle)
        .opacity(model.isBusy ? 0.55 : 1)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isMuted ? "Unmute the microphone" : "Mute the microphone")
    }
}

// MARK: - Banner

/// What a banner says: the microphone left of the notch, what became of it right of it.
struct MicMuteAnnouncement: Equatable {
    var symbol: String
    var symbolColor: IslandInk
    var name: String
    var status: String
    var statusColor: IslandInk
    /// Not asked for, or not done: said for longer, and felt.
    var isWarning: Bool

    init(_ event: MicMuteEvent) {
        switch event {
        case .muted:
            self.init("mic.slash.fill", .hue(.muted), "Microphone", "Muted", .hue(.muted, minimum: Contrast.text))
        case .unmuted:
            self.init("mic.fill", .graphic(1), "Microphone", "On", .text(0.9))
        case .unmutedElsewhere:
            self.init(
                "mic.fill", .hue(.warning), "Microphone", "Unmuted", .hue(.warning, minimum: Contrast.text), isWarning: true
            )
        case .cannotMute(let name):
            self.init(
                "mic.fill", .hue(.warning), name ?? "Microphone", "Can't Mute", .hue(.warning, minimum: Contrast.text),
                isWarning: true
            )
        }
    }

    private init(
        _ symbol: String, _ symbolColor: IslandInk, _ name: String, _ status: String, _ statusColor: IslandInk,
        isWarning: Bool = false
    ) {
        self.symbol = symbol
        self.symbolColor = symbolColor
        self.name = name
        self.status = status
        self.statusColor = statusColor
        self.isWarning = isWarning
    }
}

/// Left of the notch: the microphone's symbol and "Microphone", or the name of the one
/// that could not be muted. Where there is no room for the name, or even the insets
/// (the opened island's header gives it 24 points), the symbol.
struct MicMuteBannerLeading: View {
    let announcement: MicMuteAnnouncement

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MicMuteBannerLayout.symbolSpacing) {
                symbol
                Text(announcement.name)
                    .font(Font(MicMuteBannerLayout.font))
                    .foregroundStyle(.islandPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: MicMuteBannerLayout.maximumNameWidth, alignment: .leading)
            }
            .padding(.leading, MicMuteBannerLayout.outerInset)
            .padding(.trailing, MicMuteBannerLayout.innerInset)
            symbol
                .padding(.leading, MicMuteBannerLayout.outerInset)
                .padding(.trailing, MicMuteBannerLayout.innerInset)
            symbol
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: some View {
        Image(systemName: announcement.symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .fontWeight(.semibold)
            .foregroundStyle(.island(announcement.symbolColor))
            .frame(width: MicMuteBannerLayout.symbolSize.width, height: MicMuteBannerLayout.symbolSize.height)
            .accessibilityHidden(true)
    }
}

/// Right of the notch: "Muted" in red, "On", or a warning in orange, against the
/// wing's outer edge. Only as wide as its content: the opened island's header sets it
/// beside the leading symbol, where a view that filled its width would push the two
/// apart.
struct MicMuteBannerTrailing: View {
    let announcement: MicMuteAnnouncement

    var body: some View {
        Text(announcement.status)
            .font(Font(MicMuteBannerLayout.font))
            .foregroundStyle(.island(announcement.statusColor))
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, MicMuteBannerLayout.innerInset)
            .padding(.trailing, MicMuteBannerLayout.outerInset)
    }
}

/// The banner's measurements, matching the other compact banners: 13-point semibold
/// words, a symbol a capital and a half tall, the same insets. The island makes both
/// wings as wide as the wider side asks, so it stays centred on the notch; each side
/// asks only for its own width, and sits against the island's outer edge.
enum MicMuteBannerLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// As tall as the Caps Lock and Focus banners' symbols, and only as wide as the
    /// crossed-out microphone, the wider of the two.
    static let symbolSize = CGSize(width: 17, height: 17)
    static let symbolSpacing: CGFloat = 7
    /// Wide enough for the usual microphone names whole ("MacBook Pro Microphone"
    /// needs more, and truncates), keeping the island off most of the menu bar.
    static let maximumNameWidth: CGFloat = 136
    /// Room between each wing's content and the island's outer edge, and the notch.
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10

    static func widths(for announcement: MicMuteAnnouncement) -> (leading: CGFloat, trailing: CGFloat) {
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

// MARK: - Settings

/// Under the feature's toggle: the tile, which microphone is muted and how, and the
/// way to mute from a key.
struct MicMuteSettingsView: View {
    let model: MicMuteModel
    @AppStorage(MicMutePrefs.showTile) private var showTile = true

    var body: some View {
        Toggle(isOn: $showTile) {
            Text("Show on the home page")
            Text("A button to mute and unmute. The microphone's dot offers one too while an app is using it.")
        }
        LabeledContent {
            Text(model.reading.microphone?.name ?? "None")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } label: {
            Text("Microphone")
            Text(Self.explanation(for: model.reading.microphone))
        }
        LabeledContent {
            Button("Open Shortcuts") { ShortcutsTool.openShortcutsApp() }
        } label: {
            Text("Mute with a key")
            Text("Make a shortcut with Islet's Mute Microphone action, then give it a keyboard shortcut in its details. islet://micMute/toggle does the same.")
        }
    }

    /// How the Mac's input is muted, and what that leaves out.
    static func explanation(for microphone: MicMuteSnapshot.Microphone?) -> String {
        guard let microphone else {
            return "The Mac's input from Sound settings, muted for every app that records from it. There is no microphone now."
        }
        switch microphone.way {
        case .mute:
            return "The Mac's input from Sound settings, muted with its own mute for every app that records from it. An app set to a microphone of its own isn't muted. Quitting Islet unmutes."
        case .level:
            return "This one has no mute of its own, so Islet turns its input level right down. An app that sets the level itself, as Zoom can, may turn it up again, and the island says so. Quitting Islet puts the level back."
        case nil:
            return "This one has no mute of its own, and its level doesn't go down to silence, so Islet can't mute it."
        }
    }
}
