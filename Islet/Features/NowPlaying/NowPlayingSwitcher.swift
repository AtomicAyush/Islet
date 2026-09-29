import SwiftUI

/// The players with something loaded, as a row of their app icons: the one on show
/// lit and ringed, the others dimmed. Clicking one shows it. One that is playing
/// carries a few bars, which Core Animation moves, so they cost nothing per frame;
/// the one on show's follow its music, as the island's other waveforms do. Nothing
/// at all while there is only one player.
struct NowPlayingSwitcher: View {
    let model: NowPlayingModel
    let iconSize: CGFloat

    var body: some View {
        if model.sessions.count > 1 {
            HStack(spacing: iconSize / 3) {
                ForEach(model.sessions) { session in
                    let isShown = session.id == model.shownSession
                    SessionButton(
                        bundleID: session.bundleID,
                        isShown: isShown,
                        // The one on show follows the island's own controls at once.
                        isPlaying: isShown ? model.isPlaying : session.isPlaying,
                        size: iconSize
                    ) {
                        model.pick(session.id)
                    }
                }
            }
            .animation(.snappy(duration: 0.25), value: model.shownSession)
        }
    }
}

private struct SessionButton: View {
    let bundleID: String?
    let isShown: Bool
    let isPlaying: Bool
    let size: CGFloat
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let name = NowPlayingModel.appName(for: bundleID) ?? "Player"
        // The ring round the player on show, softened on the black island as it always
        // was; elsewhere at full strength, so it stands out as a mark.
        let ring = isShown ? (theme.isDefault ? 0.85 : 1) : 0
        Button(action: action) {
            icon
                .frame(width: size, height: size)
                .opacity(isShown ? 1 : isHovering ? 0.85 : 0.5)
                .overlay {
                    Circle()
                        .strokeBorder(.islandAccent(.nowPlaying).opacity(ring), lineWidth: 1.25)
                        .padding(-3)
                }
                .overlay(alignment: .bottomTrailing) {
                    if isPlaying {
                        PlayingBars(size: size, follows: isShown)
                            .offset(x: size * 0.22, y: size * 0.22)
                            .transition(.opacity)
                    }
                }
                .contentShape(Circle().inset(by: -3))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(name)
        .accessibilityLabel(name)
        .accessibilityValue(isPlaying ? "Playing" : "Paused")
        .accessibilityAddTraits(isShown ? .isSelected : [])
    }

    @ViewBuilder
    private var icon: some View {
        if let image = NowPlayingModel.appIcon(for: bundleID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "play.circle.fill")
                .resizable()
                .foregroundStyle(.islandGraphic())
        }
    }
}

/// Three small bars on a disc of the island's colour, tucked over an icon's corner.
private struct PlayingBars: View {
    let size: CGFloat
    /// The player on show: its bars follow its music when they can.
    let follows: Bool
    @Environment(\.islandTheme) private var theme

    var body: some View {
        WaveformBars(playing: true, tint: .accent(.nowPlaying), bars: 3, barWidth: 1.5, spacing: 1, follows: follows)
            .frame(width: 6.5, height: size * 0.36)
            .frame(width: size * 0.62, height: size * 0.62)
            .background {
                if theme.isMulticolour {
                    IslandPaint(style: theme.paintStyle).clipShape(Circle())
                } else {
                    Circle().fill(.islandBackground)
                }
            }
    }
}
