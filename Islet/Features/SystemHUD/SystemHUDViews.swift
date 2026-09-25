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

/// Right of the notch: what is being changed, like the macOS overlay says (the
/// output device, or the display), over the level as a slim bar — greyed while
/// muted, with the percentage beside it if asked for.
struct SystemHUDLevel: View {
    let model: SystemHUDModel
    let showsPercentage: Bool
    var showsName = true

    static let barWidth: CGFloat = 64
    static let percentageWidth: CGFloat = 36
    static let spacing: CGFloat = 8
    /// Long names ("External Headphones", "LG UltraFine Display") truncate here
    /// rather than push the island over half the menu bar.
    static let maximumNameWidth: CGFloat = 132
    static let nameFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

    /// The right wing's width: the widest line with even room either side of it.
    static func wingWidth(showsPercentage: Bool, name: String?) -> CGFloat {
        let levelWidth = showsPercentage ? barWidth + spacing + percentageWidth : barWidth
        let nameWidth = name.map {
            min(ceil(($0 as NSString).size(withAttributes: [.font: nameFont]).width), maximumNameWidth)
        } ?? 0
        return max(levelWidth, nameWidth) + (showsPercentage && nameWidth <= levelWidth ? 20 : 32)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsName, let name = model.deviceName {
                Text(name)
                    .font(Font(Self.nameFont))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.maximumNameWidth, alignment: .leading)
            }
            HStack(spacing: Self.spacing) {
                LevelBar(level: model.level, isDimmed: model.isMuted)
                    .frame(width: Self.barWidth, height: 5)
                if showsPercentage {
                    Text(percentage)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(model.isMuted ? 0.55 : 1))
                        .contentTransition(.numericText(value: model.level))
                        .frame(width: Self.percentageWidth, alignment: .trailing)
                }
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
            Text("Accessibility")
            Text(access.isGranted
                 ? "Islet sees the volume and brightness keys before macOS does."
                 : "Needed to catch the volume and brightness keys. Until then, macOS shows its own overlay.")
            if !access.isGranted {
                // The usual trap: macOS keeps the permission for the exact copy of the
                // app it was given to, and still shows it switched on for a newer one.
                Text("Already switched on in System Settings? That permission belongs to an earlier copy of Islet. Select Islet in the Accessibility list, remove it with −, then click Grant Access again.")
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
