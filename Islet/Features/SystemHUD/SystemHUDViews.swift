import SwiftUI

/// Left of the notch: a speaker or a sun, drawn to match the level.
struct SystemHUDIcon: View {
    let model: SystemHUDModel

    var body: some View {
        Image(systemName: symbol, variableValue: symbol == Self.speaker ? model.level : nil)
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
    private static let speaker = "speaker.wave.3.fill"

    private var symbol: String {
        switch model.kind {
        case .volume: model.isMuted || model.level == 0 ? "speaker.slash.fill" : Self.speaker
        case .brightness: model.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }
}

/// Left of the notch: the speaker or sun, and — like the macOS overlay — what is
/// being changed: the output device, or the display. Where there is no room for the
/// name, or even the insets (the opened island's header gives it 24 points), just
/// the icon.
struct SystemHUDLeading: View {
    let model: SystemHUDModel
    var showsName = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if showsName, let name = model.deviceName {
                HStack(spacing: SystemHUDLayout.iconSpacing) {
                    SystemHUDIcon(model: model)
                    Text(name)
                        .font(Font(SystemHUDLayout.nameFont))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: SystemHUDLayout.maximumNameWidth, alignment: .leading)
                }
                .modifier(SystemHUDLayout.LeadingInsets())
            }
            SystemHUDIcon(model: model)
                .modifier(SystemHUDLayout.LeadingInsets())
            SystemHUDIcon(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Right of the notch: the level as a slim bar that fills the wing, greyed while
/// muted, with the percentage beside it if asked for.
struct SystemHUDLevel: View {
    let model: SystemHUDModel
    let showsPercentage: Bool

    var body: some View {
        HStack(spacing: SystemHUDLayout.spacing) {
            LevelBar(level: model.level, isDimmed: model.isMuted)
                .frame(minWidth: SystemHUDLayout.minimumBarWidth, maxWidth: .infinity)
                .frame(height: 5)
            if showsPercentage {
                Text(percentage)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(model.isMuted ? 0.55 : 1))
                    .contentTransition(.numericText(value: model.level))
                    .frame(width: SystemHUDLayout.percentageWidth, alignment: .trailing)
            }
        }
        .animation(.smooth(duration: 0.2), value: model.level)
        .animation(.smooth(duration: 0.2), value: model.isMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.kind == .volume ? "Volume" : "Brightness")
        .accessibilityValue(model.isMuted ? "Muted" : percentage)
    }

    private var percentage: String {
        "\(Int((model.level * 100).rounded()))%"
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
        // Two points of slack: SwiftUI sets text a hair wider than AppKit measures it,
        // which would otherwise truncate a name that just fits.
        let nameWidth = name.map {
            min(ceil(($0 as NSString).size(withAttributes: [.font: nameFont]).width) + 2, maximumNameWidth)
        }
        let leading = iconWidth + (nameWidth.map { iconSpacing + $0 } ?? 0)
        let trailing = minimumBarWidth + (showsPercentage ? spacing + percentageWidth : 0)
        return max(max(leading, trailing) + outerInset + innerInset, minimumWing)
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
