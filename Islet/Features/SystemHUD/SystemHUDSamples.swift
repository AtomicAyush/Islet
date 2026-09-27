import SwiftUI

/// A made-up song for the "Volume while music plays" preview to change the volume
/// over. It is an activity of its own, drawn with Now Playing's cover and waveform,
/// so whatever is really playing is left alone: it only steps aside into the bubble
/// for the few seconds the preview lasts.
@MainActor
final class SystemHUDSampleSong: IslandActivity {
    let id = "systemHUD.sampleSong"
    let name = "Now Playing"
    let symbol = "music.note"
    /// Above everything real, for the moment it is up: the preview is there to be
    /// looked at.
    var priority: ActivityPriority { .urgent }
    var expandedHeight: CGFloat { 64 }

    private let artwork = NowPlayingArtwork.sampleSunset
    @AppStorage(NowPlayingPrefs.tintWaveform) private var tinted = NowPlayingPrefs.tintWaveformDefault

    func compactLeading() -> AnyView {
        AnyView(NowPlayingArtworkView(artwork: artwork, size: 20, radius: 5))
    }

    func compactTrailing() -> AnyView {
        // Looping on the render server, as Now Playing's own does before it hears
        // the music, so the preview costs nothing per frame either.
        AnyView(
            WaveformBars(
                playing: true,
                colour: NSColor(tinted ? (artwork?.tint ?? .white) : .white),
                bars: 5, barWidth: 2, spacing: 2
            )
            .frame(width: 18, height: 14)
        )
    }

    func minimal() -> AnyView {
        AnyView(NowPlayingArtworkView(artwork: artwork, size: 22, radius: 11))
    }

    func expanded() -> AnyView {
        AnyView(
            HStack(spacing: 12) {
                NowPlayingArtworkView(artwork: artwork, size: 44, radius: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Midnight Drive")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Neon Harbour")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
        )
    }
}
