import SwiftUI

/// Left of the notch: a speaker or a sun, drawn to match the level.
struct SystemHUDIcon: View {
    let state: SystemHUDState

    var body: some View {
        let symbol = Self.symbol(for: state)
        Image(systemName: symbol, variableValue: symbol == Self.speaker ? state.level : nil)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            // Level changes arrive unanimated, and the transition only plays inside
            // an animation.
            .animation(.smooth(duration: 0.2), value: symbol)
            .frame(width: 24, height: 20)
            .accessibilityHidden(true)
    }

    /// Lights its waves one by one as the volume rises.
    static let speaker = "speaker.wave.3.fill"
    static let mutedSpeaker = "speaker.slash.fill"
    static let dimSun = "sun.min.fill"
    static let brightSun = "sun.max.fill"

    static func symbol(for state: SystemHUDState) -> String {
        switch state.kind {
        case .volume: state.isMuted || state.level == 0 ? mutedSpeaker : speaker
        case .brightness: state.level < 0.5 ? dimSun : brightSun
        }
    }
}

/// Left of the notch: the speaker or sun, and — like the macOS overlay — what is
/// being changed: the output device, or the display. Where there is no room for the
/// name, or even the insets (the opened island's header gives it 24 points), just
/// the icon.
struct SystemHUDLeading: View {
    let state: SystemHUDState
    var showsName = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if showsName, let name = state.deviceName {
                HStack(spacing: SystemHUDLayout.iconSpacing) {
                    SystemHUDIcon(state: state)
                    Text(name)
                        .font(Font(SystemHUDLayout.nameFont))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: SystemHUDLayout.maximumNameWidth, alignment: .leading)
                }
                .modifier(SystemHUDLayout.LeadingInsets())
            }
            SystemHUDIcon(state: state)
                .modifier(SystemHUDLayout.LeadingInsets())
            SystemHUDIcon(state: state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Right of the notch: the level as a slim bar that fills the wing, greyed while
/// muted, with the percentage beside it if asked for.
struct SystemHUDLevel: View {
    let state: SystemHUDState
    let showsPercentage: Bool

    var body: some View {
        HStack(spacing: SystemHUDLayout.spacing) {
            LevelBar(level: state.level, isDimmed: state.isMuted)
                .frame(minWidth: SystemHUDLayout.minimumBarWidth, maxWidth: .infinity)
                .frame(height: 5)
            if showsPercentage {
                Text(percentage)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(state.isMuted ? 0.55 : 1))
                    .contentTransition(.numericText(value: state.level))
                    .frame(width: SystemHUDLayout.percentageWidth, alignment: .trailing)
            }
        }
        .animation(.smooth(duration: 0.2), value: state.level)
        .animation(.smooth(duration: 0.2), value: state.isMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.kind == .volume ? "Volume" : "Brightness")
        .accessibilityValue(state.isMuted ? "Muted" : percentage)
    }

    private var percentage: String {
        "\(Int((state.level * 100).rounded()))%"
    }
}

/// Under whatever the island is already showing (music playing, a timer): the
/// overlay's two wings side by side in one slim row — the speaker or sun and the
/// name, then the bar across the rest. The row spans the island, so it is centred on
/// the notch; on a much wider island the bar stops at `SystemHUDLayout.maximumRowBar`
/// and the row stays centred, rather than stretching the bar across it all.
struct SystemHUDRow: View {
    let state: SystemHUDState
    var showsName = true
    let showsPercentage: Bool

    var body: some View {
        let name = showsName ? state.deviceName : nil
        let leading = SystemHUDLayout.rowLeadingWidth(name: name)
        let trailing = SystemHUDLayout.rowTrailingInset(for: state, showsPercentage: showsPercentage)
        let widest = SystemHUDLayout.widestRowTrailingInset(kind: state.kind, showsPercentage: showsPercentage)
        HStack(spacing: 0) {
            SystemHUDLeading(state: state, showsName: showsName)
                .frame(width: leading)
            SystemHUDLevel(state: state, showsPercentage: showsPercentage)
                .padding(.trailing, trailing)
        }
        // Capped with the narrowest glyph's room at the far end, whichever glyph is
        // showing, so the icon and name hold still as it changes; the bar gives up
        // the difference.
        .frame(maxWidth: leading + SystemHUDLayout.maximumRowBarWidth(showsPercentage: showsPercentage) + widest)
        // The slashed speaker, without the waves, is narrower than the speaker: as
        // it comes and goes, the bar's end draws in and out with it, alongside the
        // bar dimming, so both ends stay the same distance from the island's edges.
        .animation(.smooth(duration: 0.2), value: trailing)
        // Another device or the other kind (the volume, then the brightness) moves
        // where the bar starts, with the name's width. That is laid out afresh rather
        // than animated: the level's animation would slide the bar in under a name
        // that is already there at its new width.
        .transaction(value: "\(state.kind) \(name ?? "")") { $0.disablesAnimations = true }
    }
}

/// The overlay's measurements. Both wings are always the same width, so the island
/// stays centred on the notch; it shifts sideways when one wing is wider than the
/// other, which in an overlay just looks off-centre.
enum SystemHUDLayout {
    static let nameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// Wide enough for the usual names whole ("Built-in Retina Display", "Studio
    /// Display Speakers"); anything longer truncates rather than push the island
    /// over half the menu bar.
    static let maximumNameWidth: CGFloat = 136
    static let iconWidth: CGFloat = 24
    static let iconSpacing: CGFloat = 7
    static let minimumBarWidth: CGFloat = 56
    static let percentageWidth: CGFloat = 36
    static let spacing: CGFloat = 8
    /// Room between each wing's content and the island's outer edge, and the notch.
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10
    static let minimumWing: CGFloat = 92

    struct LeadingInsets: ViewModifier {
        func body(content: Content) -> some View {
            content.padding(.leading, outerInset).padding(.trailing, innerInset)
        }
    }

    /// The width of each wing: whichever side needs more, used for both.
    static func wingWidth(name: String?, showsPercentage: Bool) -> CGFloat {
        let leading = iconAndNameWidth(name: name)
        let trailing = minimumBarWidth + (showsPercentage ? spacing + percentageWidth : 0)
        return max(max(leading, trailing) + outerInset + innerInset, minimumWing)
    }

    // MARK: Row

    /// The row's height under compact content: room for the icon, and a little over
    /// for the island's rounded bottom corners.
    static let rowHeight: CGFloat = 26
    /// The longest the row's bar gets, however wide the island it rides under.
    static let maximumRowBar: CGFloat = 150

    /// The row's icon and name with their insets, the part left of the bar.
    static func rowLeadingWidth(name: String?) -> CGFloat {
        outerInset + iconAndNameWidth(name: name) + innerInset
    }

    /// Room at the row's far end, after the bar or the percentage. The icon's glyph
    /// sits a little inside its box at the near end, so the far end keeps that much
    /// more than the outer inset, less what the "%" leaves inside its frame. Then what
    /// is drawn, not just the row, is centred on the notch, which in one line right
    /// under it shows a point either way.
    static func rowTrailingInset(for state: SystemHUDState, showsPercentage: Bool) -> CGFloat {
        trailingInset(glyphBearing: glyphBearing(SystemHUDIcon.symbol(for: state)), showsPercentage: showsPercentage)
    }

    /// The most room the far end keeps for `kind`, for its narrowest glyph. The row's
    /// width allows for it, so the island stays the same width when the glyph changes.
    static func widestRowTrailingInset(kind: SystemHUDModel.Kind, showsPercentage: Bool) -> CGFloat {
        let glyphs = kind == .volume
            ? [SystemHUDIcon.speaker, SystemHUDIcon.mutedSpeaker]
            : [SystemHUDIcon.dimSun, SystemHUDIcon.brightSun]
        return trailingInset(glyphBearing: glyphs.map(glyphBearing).max() ?? 0, showsPercentage: showsPercentage)
    }

    private static func trailingInset(glyphBearing: CGFloat, showsPercentage: Bool) -> CGFloat {
        outerInset + glyphBearing - (showsPercentage ? percentageBearing : 0)
    }

    /// How far a glyph sits inside the icon's 24-point box at the near end, centred
    /// in it, measured from the symbols at 14 points semibold. The speaker nearly
    /// fills the box; without its waves, the slashed speaker is much narrower. The two
    /// suns (4¼ and 5) share a figure, a quarter point from either, so the bar holds
    /// still as the sun changes at half brightness.
    private static func glyphBearing(_ symbol: String) -> CGFloat {
        switch symbol {
        case SystemHUDIcon.speaker: 2
        case SystemHUDIcon.mutedSpeaker: 5.5
        default: 4.5
        }
    }

    /// How far the percentage's "%" stops short of the end of its frame.
    static let percentageBearing: CGFloat = 1

    /// The least width of the row: the icon and name, the shortest bar, and the
    /// percentage if asked for, with their insets. In whole points, so the island's
    /// edges stay on the pixel grid when the row sets its width.
    static func rowWidth(name: String?, kind: SystemHUDModel.Kind, showsPercentage: Bool) -> CGFloat {
        ceil(
            rowLeadingWidth(name: name) + minimumBarWidth + (showsPercentage ? spacing + percentageWidth : 0)
                + widestRowTrailingInset(kind: kind, showsPercentage: showsPercentage)
        )
    }

    /// The most room the row gives the bar and the percentage.
    static func maximumRowBarWidth(showsPercentage: Bool) -> CGFloat {
        maximumRowBar + (showsPercentage ? spacing + percentageWidth : 0)
    }

    /// The icon, and the name beside it if there is one.
    private static func iconAndNameWidth(name: String?) -> CGFloat {
        // Two points of slack: SwiftUI sets text a hair wider than AppKit measures it,
        // which would otherwise truncate a name that just fits.
        let nameWidth = name.map {
            min(ceil(($0 as NSString).size(withAttributes: [.font: nameFont]).width) + 2, maximumNameWidth)
        }
        return iconWidth + (nameWidth.map { iconSpacing + $0 } ?? 0)
    }
}

/// A capsule track with a white fill from the left. The fill is clipped by the
/// track rather than rounded itself, so a low level reads as a sliver, not a dot.
private struct LevelBar: View {
    let level: Double
    let isDimmed: Bool

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.white.opacity(isDimmed ? 0.35 : 1))
                .frame(width: geo.size.width * min(max(level, 0), 1))
        }
        .background(Color.white.opacity(0.2))
        .clipShape(Capsule())
    }
}

/// Under the feature's toggle: the permission it needs, and which keys it takes.
struct SystemHUDSettings: View {
    let access: AccessibilityAccess
    @AppStorage(SystemHUDFeature.Key.volume) private var volume = true
    @AppStorage(SystemHUDFeature.Key.brightness) private var brightness = true
    @AppStorage(SystemHUDFeature.Key.showPercentage) private var showsPercentage = false
    @AppStorage(SystemHUDFeature.Key.showName) private var showsName = true

    var body: some View {
        LabeledContent {
            if access.isGranted {
                Label {
                    Text("Allowed")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
            } else {
                Button("Grant Access…") { access.request() }
            }
        } label: {
            Text(AccessibilityAccess.paneName)
            Text(access.isGranted
                 ? "Islet sees the volume and brightness keys before macOS does."
                 : "Needed to catch the volume and brightness keys. Until then, macOS shows its own overlay.")
            if !access.isGranted {
                // The usual trap: macOS keeps the permission for the exact copy of the
                // app it was given to, and still shows it switched on for a newer one.
                Text("Already switched on in System Settings? That permission belongs to an earlier copy of Islet. Select Islet in the \(AccessibilityAccess.paneName) list, remove it with −, then click Grant Access again.")
            }
        }
        .onAppear { access.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access.refresh()
        }

        Toggle("Volume", isOn: $volume)
        Toggle("Brightness", isOn: $brightness)
        Toggle("Show percentage", isOn: $showsPercentage)
        Toggle("Show the device's name", isOn: $showsName)
    }
}
