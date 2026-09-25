import SwiftUI

// MARK: - Pieces

/// The cover, or a music note on a dark tile until one arrives.
struct NowPlayingArtworkView: View {
    let model: NowPlayingModel
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if let artwork = model.artwork {
                Image(nsImage: artwork.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .id(artwork.id)
                    .transition(.opacity)
            } else {
                shape.fill(Color(white: 0.17))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .animation(.easeInOut(duration: 0.3), value: model.artwork?.id)
    }
}

/// Bars that dance while something plays and settle low when it stops.
///
/// Not real audio: each bar follows its own fixed sum of sines, so the motion is
/// smooth and never repeats visibly, and costs nothing to compute.
struct NowPlayingWaveform: View {
    let model: NowPlayingModel
    var bars = 5
    var barWidth: CGFloat = 2
    var spacing: CGFloat = 2
    var height: CGFloat = 14
    @AppStorage(NowPlayingPrefs.tintWaveform) private var tinted = NowPlayingPrefs.tintWaveformDefault

    /// Height of a settled bar, as a fraction of the full height.
    private static let rest = 0.28
    /// How long bars take to rise to full motion when playback resumes.
    private static let rampUp: TimeInterval = 0.35
    /// Per bar: two frequencies (Hz) and their phases.
    private static let shapes: [(Double, Double, Double, Double)] = [
        (1.1, 0.0, 2.3, 1.7), (1.7, 2.1, 0.9, 0.4), (0.8, 4.2, 2.9, 2.6), (1.4, 1.3, 2.1, 5.1), (2.0, 3.3, 1.2, 0.8),
    ]

    var body: some View {
        let playing = model.isPlaying
        let since = model.playStateChangedAt
        let colour = tinted ? (model.artwork?.tint ?? .white) : .white

        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Rises out of the settled bars instead of jumping to full height.
            let ramp = playing ? min(1, max(0, context.date.timeIntervalSince(since) / Self.rampUp)) : 0
            HStack(spacing: spacing) {
                ForEach(0..<bars, id: \.self) { bar in
                    let level = Self.rest + (Self.level(bar, at: t) - Self.rest) * ramp
                    Capsule()
                        .fill(colour)
                        .frame(width: barWidth, height: max(barWidth, height * level))
                }
            }
            .frame(height: height)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: playing)
        .animation(.easeInOut(duration: 0.4), value: colour)
    }

    private static func level(_ bar: Int, at t: Double) -> Double {
        let (f1, p1, f2, p2) = shapes[bar % shapes.count]
        let value = 0.56 + 0.26 * sin(2 * .pi * f1 * t + p1) + 0.18 * sin(2 * .pi * f2 * t + p2)
        return min(1, max(0.18, value))
    }
}

/// A single line that scrolls, marquee style, when it is too long to fit: still for
/// a moment, then one pass, then still again.
struct NowPlayingMarquee: View {
    let text: String
    let font: Font
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var startedAt = Date()

    private let gap: CGFloat = 36
    private let fade: CGFloat = 12
    /// Points per second.
    private let speed = 30.0
    /// Seconds still between passes.
    private let pause = 2.5

    var body: some View {
        let scrolls = boxWidth > 0 && textWidth > boxWidth + 0.5
        Text(text)
            .font(font)
            .lineLimit(1)
            .opacity(scrolls ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .background(alignment: .leading) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if scrolls {
                    TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                        let x = offset(at: context.date)
                        HStack(spacing: gap) {
                            Text(text)
                            Text(text)
                        }
                        .font(font)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: -x)
                        .frame(width: boxWidth, alignment: .leading)
                        .clipped()
                        .mask(edges(leading: min(fade, x)))
                    }
                }
            }
            .onChange(of: text) { startedAt = Date() }
    }

    private func offset(at date: Date) -> CGFloat {
        let distance = Double(textWidth + gap)
        let cycle = pause + distance / speed
        let phase = date.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: cycle)
        return phase < pause ? 0 : CGFloat((phase - pause) * speed)
    }

    /// Softens the edges text scrolls across; the leading one only once it moves.
    private func edges(leading: CGFloat) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: leading)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: fade)
        }
    }
}

/// Where playback is, ticking without a model timer, and dragged to seek.
struct NowPlayingProgress: View {
    let model: NowPlayingModel
    @State private var dragFraction: Double?

    var body: some View {
        let duration = model.timing.duration
        let isDragging = dragFraction != nil

        TimelineView(.animation(minimumInterval: 0.1, paused: !model.isPlaying || isDragging)) { context in
            let position = dragFraction.map { $0 * duration } ?? model.position(at: context.date)
            HStack(spacing: 10) {
                Text(NowPlayingClock.text(position))
                    .fixedSize()
                    .frame(minWidth: 34, alignment: .leading)
                bar(fraction: duration > 0 ? position / duration : 0, duration: duration)
                Text(duration > 0 ? "-" + NowPlayingClock.text(duration - position, roundingUp: true) : "--:--")
                    .fixedSize()
                    .frame(minWidth: 38, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func bar(fraction: Double, duration: TimeInterval) -> some View {
        let thickness: CGFloat = dragFraction == nil ? 5 : 8
        return GeometryReader { geo in
            let width = max(1, geo.size.width)
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.2))
                Rectangle().fill(.white).frame(width: width * min(1, max(0, fraction)))
            }
            .frame(height: thickness)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = min(1, max(0, value.location.x / width))
                    }
                    .onEnded { value in
                        model.seek(to: min(1, max(0, value.location.x / width)) * duration)
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 14)
        .allowsHitTesting(duration > 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragFraction == nil)
    }
}

enum NowPlayingClock {
    /// "3:07", or "1:02:03" past an hour.
    static func text(_ seconds: TimeInterval, roundingUp: Bool = false) -> String {
        let total = max(0, Int(roundingUp ? seconds.rounded(.up) : seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

private extension NowPlayingModel {
    var title: String { track?.title ?? "Not playing" }

    /// The artist, or the album for media that names no artist.
    var subtitle: String {
        guard let track else { return "" }
        return track.artist.isEmpty ? track.album : track.artist
    }
}

// MARK: - Presentations

struct NowPlayingCompactLeading: View {
    let model: NowPlayingModel

    var body: some View {
        NowPlayingArtworkView(model: model, size: 20, radius: 5)
    }
}

struct NowPlayingCompactTrailing: View {
    let model: NowPlayingModel

    var body: some View {
        NowPlayingWaveform(model: model, bars: 5, barWidth: 2, spacing: 2, height: 14)
    }
}

/// The detached bubble: the cover as a disc, or the waveform when there is none.
struct NowPlayingMinimal: View {
    let model: NowPlayingModel

    var body: some View {
        if model.artwork != nil {
            NowPlayingArtworkView(model: model, size: 22, radius: 11)
        } else {
            NowPlayingWaveform(model: model, bars: 4, barWidth: 2, spacing: 1.5, height: 11)
        }
    }
}

struct NowPlayingExpanded: View {
    let model: NowPlayingModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                artwork

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        NowPlayingMarquee(text: model.title, font: .system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        NowPlayingWaveform(model: model, bars: 5, barWidth: 2.5, spacing: 2, height: 16)
                    }
                    Text(model.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 60)

            NowPlayingProgress(model: model)
                .padding(.top, 10)

            HStack(spacing: 26) {
                RoundButton(symbol: "backward.fill", tint: .white, diameter: 30) { model.previous() }
                    .accessibilityLabel("Previous")
                RoundButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", tint: .white) {
                    model.togglePlayPause()
                }
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                RoundButton(symbol: "forward.fill", tint: .white, diameter: 30) { model.next() }
                    .accessibilityLabel("Next")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The cover, badged with the app playing it; clicking it brings that app forward.
    private var artwork: some View {
        Button {
            model.openSourceApp()
        } label: {
            NowPlayingArtworkView(model: model, size: 60, radius: 12)
                .overlay(alignment: .bottomTrailing) {
                    if let icon = model.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 22, height: 22)
                            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                            .offset(x: 6, y: 6)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// The home page's mini player, for the current session or the last one.
///
/// The tile shares the home row with every other feature's, so with a few of them up
/// it can be well under 100 pt wide. Rather than spill into its neighbours it lets
/// the cover go first, then tightens the controls, then keeps only play.
struct NowPlayingHomeTile: View {
    let model: NowPlayingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    artwork
                    labels.frame(idealWidth: 48, maxWidth: .infinity, alignment: .leading)
                }
                labels
            }
            // The last session, kept after its player went away, reads as past.
            .opacity(model.isLive ? 1 : 0.6)

            Spacer(minLength: 6)

            ViewThatFits(in: .horizontal) {
                controls(spacing: 10, small: 26, large: 30)
                controls(spacing: 3, small: 24, large: 28)
                playPause(diameter: 28)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var artwork: some View {
        Button {
            model.openSourceApp()
        } label: {
            NowPlayingArtworkView(model: model, size: 44, radius: 9)
        }
        .buttonStyle(.plain)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(model.subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .lineLimit(1)
    }

    private func controls(spacing: CGFloat, small: CGFloat, large: CGFloat) -> some View {
        HStack(spacing: spacing) {
            RoundButton(symbol: "backward.fill", tint: .white, diameter: small) { model.previous() }
                .accessibilityLabel("Previous")
            playPause(diameter: large)
            RoundButton(symbol: "forward.fill", tint: .white, diameter: small) { model.next() }
                .accessibilityLabel("Next")
        }
    }

    private func playPause(diameter: CGFloat) -> some View {
        RoundButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", tint: .white, diameter: diameter) {
            model.togglePlayPause()
        }
        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
    }
}

/// Right of the notch while a new song is announced: its title and artist. The
/// compact cover stays on the left.
struct NowPlayingSongBannerTrailing: View {
    let model: NowPlayingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(model.subtitle)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .lineLimit(1)
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NowPlayingSettings: View {
    /// Lets a paused island pick up the new hold straight away.
    let onHideAfterPauseChange: () -> Void
    @AppStorage(NowPlayingPrefs.hideAfterPause) private var hideAfterPause = NowPlayingPrefs.hideAfterPauseDefault
    @AppStorage(NowPlayingPrefs.tintWaveform) private var tinted = NowPlayingPrefs.tintWaveformDefault
    @AppStorage(NowPlayingPrefs.showSongChanges) private var songChanges = NowPlayingPrefs.showSongChangesDefault

    var body: some View {
        Picker("Hide after pausing", selection: $hideAfterPause) {
            Text("Immediately").tag(0)
            Text("After 30 seconds").tag(30)
            Text("After 5 minutes").tag(300)
            Text("Never").tag(NowPlayingPrefs.neverHide)
        }
        .onChange(of: hideAfterPause) { onHideAfterPauseChange() }
        Toggle("Tint the waveform with the artwork's colour", isOn: $tinted)
        Toggle("Show song changes", isOn: $songChanges)
    }
}
