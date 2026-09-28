import SwiftUI

extension FeatureTint {
    /// Now Playing's highlights (the scrubber, the volume, what is lit or picked), and
    /// its waveform when the cover lends it no colour: white on the black island.
    static let nowPlaying = FeatureTint.neutral
}

extension IslandBackdrop {
    /// The tile a cover or a thumbnail stands on until it arrives.
    static let artworkPlaceholder = IslandBackdrop.surface(0.17)
    /// A row of a panel's list, under the pointer: what its words are measured
    /// against, so they read whether or not it is lit.
    static let panelRow = IslandBackdrop.surface(0.08)
}

/// The colour the waveform borrows from a cover (see `NowPlayingArtwork`).
struct ArtworkTint: Equatable, Sendable {
    /// Lifted to a brightness that stands out on black: what the black island draws.
    let dark: RGB
    /// The cover's own colour, its saturation capped as `dark`'s is but not lifted:
    /// what a light island starts from, fitting it darker only as far as it needs.
    let raw: RGB
}

enum NowPlayingTint {
    /// What the waveform, a video's ring, a lit shuffle or repeat, the heart, the
    /// playing playlist's mark and the output checkmark are drawn in: the cover's
    /// colour while the accent is Feature colours and Settings ask for it, and
    /// otherwise Now Playing's own highlight, which is the island's ink or the accent.
    /// A cover's colour is someone else's, so it is only fitted for contrast.
    static func ink(_ artwork: ArtworkTint?, tinted: Bool, in theme: IslandTheme) -> IslandInk {
        guard tinted, theme.accent == .featureColours, let artwork else { return .accent(.nowPlaying) }
        return .fitted(theme.isLight ? artwork.raw : artwork.dark)
    }
}

extension NowPlayingModel {
    /// See `NowPlayingTint.ink`.
    func tint(_ tinted: Bool, in theme: IslandTheme) -> IslandInk {
        NowPlayingTint.ink(artwork?.tint, tinted: tinted, in: theme)
    }
}

extension IslandTheme {
    /// Now Playing's highlight as one opaque colour, for what is filled with it and
    /// carries words or a symbol: a picked chip or choice, the output in use, a call
    /// to action. Draw it with `.islandFill` and what is on it with `.islandOnFill`.
    var nowPlayingFill: RGB {
        let source = accentSource(.nowPlaying)
        return source == ink ? ink : fitted(source)
    }

    /// A cover's or thumbnail's tile until it arrives: opaque, so it hides what is
    /// under it wherever it is drawn.
    var artworkPlaceholder: Color {
        colour(of: .artworkPlaceholder).color
    }
}
