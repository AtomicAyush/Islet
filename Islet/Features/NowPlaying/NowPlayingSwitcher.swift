import SwiftUI

/// The players with something loaded, as a row of their app icons: the one on show
/// lit and ringed, the others dimmed. Clicking one shows it. One that is playing
/// carries a few bars, which Core Animation moves, so they cost nothing per frame.
/// Nothing at all while there is only one player.
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

    var body: some View {
        let name = NowPlayingModel.appName(for: bundleID) ?? "Player"
        Button(action: action) {
            icon
                .frame(width: size, height: size)
                .opacity(isShown ? 1 : isHovering ? 0.85 : 0.5)
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(isShown ? 0.85 : 0), lineWidth: 1.25)
                        .padding(-3)
                }
                .overlay(alignment: .bottomTrailing) {
                    if isPlaying {
                        PlayingBars(size: size)
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
                .foregroundStyle(.white)
        }
    }
}

/// Three small bars on a black disc, tucked over an icon's corner.
private struct PlayingBars: View {
    let size: CGFloat

    var body: some View {
        WaveformBars(playing: true, colour: .white, bars: 3, barWidth: 1.5, spacing: 1)
            .frame(width: 6.5, height: size * 0.36)
            .frame(width: size * 0.62, height: size * 0.62)
            .background(Circle().fill(.black))
    }
}
