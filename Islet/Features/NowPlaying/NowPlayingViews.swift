import SwiftUI

// MARK: - Pieces

/// The cover, or a music note on a dark tile until one arrives.
struct NowPlayingArtworkView: View {
    let artwork: NowPlayingArtwork?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if let artwork {
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
        .animation(.easeInOut(duration: 0.3), value: artwork?.id)
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

    var body: some View {
        WaveformBars(
            playing: model.isPlaying,
            colour: NSColor(model.tint(tinted)),
            bars: bars,
            barWidth: barWidth,
            spacing: spacing
        )
        .frame(width: CGFloat(bars) * barWidth + CGFloat(bars - 1) * spacing, height: height)
    }
}

/// The bars as Core Animation layers. Each runs a looping keyframe animation that the
/// render server plays on its own, so a song playing for an hour costs the app nothing
/// per frame — drawn from SwiftUI, the same motion re-rendered the island thirty times a
/// second and kept a core a tenth busy.
struct WaveformBars: NSViewRepresentable {
    let playing: Bool
    let colour: NSColor
    let bars: Int
    let barWidth: CGFloat
    let spacing: CGFloat

    func makeNSView(context: Context) -> WaveformBarsView {
        WaveformBarsView(bars: bars, barWidth: barWidth, spacing: spacing)
    }

    func updateNSView(_ view: WaveformBarsView, context: Context) {
        view.setColour(colour)
        view.setPlaying(playing)
    }
}

final class WaveformBarsView: NSView {
    /// Height of a settled bar, as a fraction of the full height.
    private static let rest: CGFloat = 0.28
    /// Every bar's motion repeats after this long; its frequencies are whole multiples
    /// of it, so the loop has no seam.
    private static let period: CFTimeInterval = 4
    /// Per bar: two frequencies (cycles per period) and their phases.
    private static let shapes: [(Double, Double, Double, Double)] = [
        (4, 0.0, 9, 1.7), (7, 2.1, 4, 0.4), (3, 4.2, 11, 2.6), (6, 1.3, 8, 5.1), (8, 3.3, 5, 0.8),
    ]

    private let barLayers: [CALayer]
    private let barWidth: CGFloat
    private let spacing: CGFloat
    private var isPlaying: Bool?

    init(bars: Int, barWidth: CGFloat, spacing: CGFloat) {
        self.barWidth = barWidth
        self.spacing = spacing
        barLayers = (0..<bars).map { _ in
            let bar = CALayer()
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = NSColor.white.cgColor
            return bar
        }
        super.init(frame: .zero)
        wantsLayer = true
        barLayers.forEach { layer?.addSublayer($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            let x = CGFloat(index) * (barWidth + spacing)
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: bounds.height)
            bar.position = CGPoint(x: x + barWidth / 2, y: bounds.midY)
        }
        CATransaction.commit()
    }

    func setColour(_ colour: NSColor) {
        let cg = colour.cgColor
        guard barLayers.first?.backgroundColor != cg else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        barLayers.forEach { $0.backgroundColor = cg }
        CATransaction.commit()
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        let first = isPlaying == nil
        isPlaying = playing
        for (index, bar) in barLayers.enumerated() {
            let current = bar.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat ?? Self.rest
            bar.removeAllAnimations()
            if playing {
                Self.startMotion(on: bar, index: index, from: first ? Self.rest : current)
            } else {
                // Settle to short bars rather than freezing mid-motion.
                bar.transform = CATransform3DMakeScale(1, Self.rest, 1)
                let settle = CASpringAnimation(keyPath: "transform.scale.y")
                settle.fromValue = current
                settle.toValue = Self.rest
                settle.damping = 14
                settle.duration = settle.settlingDuration
                bar.add(settle, forKey: "settle")
            }
        }
    }

    /// A short rise out of `start`, then the bar's loop, forever. The loop is its own
    /// animation, begun at an absolute time: wrapped in a group of infinite duration,
    /// Core Animation never applies it.
    private static func startMotion(on bar: CALayer, index: Int, from start: CGFloat) {
        let (f1, p1, f2, p2) = shapes[index % shapes.count]
        let samples = 48
        let values: [CGFloat] = (0...samples).map { i in
            let t = Double(i) / Double(samples)
            let value = 0.56 + 0.26 * sin(2 * .pi * f1 * t + p1) + 0.18 * sin(2 * .pi * f2 * t + p2)
            return CGFloat(min(1, max(0.18, value)))
        }
        let riseDuration: CFTimeInterval = 0.3

        let rise = CABasicAnimation(keyPath: "transform.scale.y")
        rise.fromValue = start
        rise.toValue = values[0]
        rise.duration = riseDuration
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        rise.fillMode = .forwards
        rise.isRemovedOnCompletion = false

        let loop = CAKeyframeAnimation(keyPath: "transform.scale.y")
        loop.values = values
        loop.calculationMode = .cubic
        loop.duration = period
        loop.repeatCount = .infinity
        loop.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) + riseDuration

        bar.add(rise, forKey: "rise")
        bar.add(loop, forKey: "wave")
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

extension NowPlayingModel {
    var title: String { track?.title ?? "Not playing" }

    /// The artist, or the album for media that names no artist. For a web video
    /// this is usually the channel.
    var subtitle: String {
        guard let track else { return "" }
        return track.artist.isEmpty ? track.album : track.artist
    }

    /// The artwork's colour where the settings ask for it, else white.
    func tint(_ tinted: Bool) -> Color {
        tinted ? (artwork?.tint ?? .white) : .white
    }
}

/// The artist, or a video's channel, and at the end of the line the switcher when
/// more than one player has something loaded. The line keeps the icons' height
/// either way, so the player does not shift as a second player comes and goes.
struct NowPlayingSubtitleRow: View {
    let model: NowPlayingModel
    let fontSize: CGFloat
    let iconSize: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            Text(model.subtitle)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            NowPlayingSwitcher(model: model, iconSize: iconSize)
        }
        .frame(height: iconSize)
    }
}

/// The icon of the app playing, tucked over the artwork's corner.
struct NowPlayingAppBadge: View {
    let model: NowPlayingModel
    let size: CGFloat

    var body: some View {
        if let icon = model.appIcon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .offset(x: size * 0.27, y: size * 0.27)
        }
    }
}

struct NowPlayingPlayButton: View {
    let model: NowPlayingModel
    var diameter: CGFloat = 38

    var body: some View {
        RoundButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", tint: .white, diameter: diameter) {
            model.togglePlayPause()
        }
        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
    }
}

/// Previous, play and next; for a video, 15 seconds back, play and 15 on.
struct NowPlayingTransport: View {
    let model: NowPlayingModel
    let spacing: CGFloat
    /// Diameter of the buttons either side of play.
    let small: CGFloat
    /// Diameter of play.
    let large: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            if model.isVideo {
                jump(forward: false)
            } else {
                RoundButton(symbol: "backward.fill", tint: .white, diameter: small) { model.previous() }
                    .accessibilityLabel("Previous")
            }
            NowPlayingPlayButton(model: model, diameter: large)
            if model.isVideo {
                jump(forward: true)
            } else {
                RoundButton(symbol: "forward.fill", tint: .white, diameter: small) { model.next() }
                    .accessibilityLabel("Next")
            }
        }
    }

    private func jump(forward: Bool) -> some View {
        let enabled = model.canJump(forward: forward)
        return RoundButton(symbol: forward ? "goforward.15" : "gobackward.15", tint: .white, diameter: small) {
            model.jump(forward: forward)
        }
        .opacity(enabled ? 1 : 0.35)
        .allowsHitTesting(enabled)
        .accessibilityLabel(forward ? "Forward 15 seconds" : "Back 15 seconds")
    }
}

/// Shuffle or repeat: dim when off, lit in the tint colour when on.
private struct ModeToggle: View {
    let symbol: String
    let isOn: Bool
    let tint: Color
    let label: String
    let action: () -> Void

    var body: some View {
        RoundButton(symbol: symbol, tint: isOn ? tint : .white.opacity(0.45), diameter: 26, action: action)
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? "On" : "Off")
            .animation(.easeOut(duration: 0.2), value: isOn)
    }
}

// MARK: - Presentations

/// The cover left of the notch. Moving to another player slides it the way the
/// fingers went: the last player's cover out, the new one's in from the other side.
/// Only for the moment of the move; at rest nothing animates.
struct NowPlayingCompactLeading: View {
    let model: NowPlayingModel

    var body: some View {
        let last = model.lastSwitch
        // How far a cover travels on its way in or out.
        let travel: CGFloat = 16
        let way: CGFloat = last.forward ? -1 : 1
        ZStack {
            // A new cover for each move, so the new artwork does not cross-fade over
            // the old one as it slides in. Inside the stack, because the animator
            // starts over, without sliding, when the view it wraps is replaced.
            CompactCover(artwork: model.artwork, isVideo: model.isVideo)
                .id(last.count)
        }
        .keyframeAnimator(initialValue: 1.0, trigger: last.count) { cover, value in
            // The animator stops at its last frame, a hair short of 1; were that not
            // counted as done, the last cover would stay behind, all but invisible.
            let progress = value > 0.99 ? 1 : max(value, 0)
            ZStack {
                if progress < 1 {
                    CompactCover(artwork: last.previousArtwork, isVideo: last.previousWasVideo)
                        // A swipe during a slide starts another with the cover it
                        // leaves, rather than cross-fading the one on its way out.
                        .id(last.count)
                        .modifier(CompactSlide(offset: way * travel * progress, gone: progress))
                }
                cover
                    .modifier(CompactSlide(offset: -way * travel * (1 - progress), gone: 1 - progress))
            }
        } keyframes: { _ in
            MoveKeyframe(0)
            // A spring quicker than its segment, so it has all but settled by the end.
            SpringKeyframe(1, duration: 0.45, spring: .smooth(duration: 0.3))
        }
    }
}

/// A song's artwork, a video's thumbnail, or a play glyph for a video without one.
private struct CompactCover: View {
    let artwork: NowPlayingArtwork?
    let isVideo: Bool

    var body: some View {
        if !isVideo {
            NowPlayingArtworkView(artwork: artwork, size: 20, radius: 5)
        } else if artwork != nil {
            NowPlayingThumbnail(artwork: artwork, width: 30, radius: 4)
        } else {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// A cover on its way in or out: `gone` is 0 in place and 1 out of sight.
private struct CompactSlide: ViewModifier {
    let offset: CGFloat
    let gone: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: 3 * gone)
            .opacity(1 - gone)
            .offset(x: offset)
    }
}

/// The waveform for music; for a video, a ring that fills as it plays. Moving
/// between the two cross-fades.
struct NowPlayingCompactTrailing: View {
    let model: NowPlayingModel

    var body: some View {
        ZStack {
            if model.isVideo {
                NowPlayingProgressRing(model: model, lineWidth: 2.5)
                    .frame(width: 16, height: 16)
            } else {
                NowPlayingWaveform(model: model, bars: 5, barWidth: 2, spacing: 2, height: 14)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.isVideo)
    }
}

/// The detached bubble: the cover or thumbnail as a disc; without one, the waveform,
/// or the ring for a video.
struct NowPlayingMinimal: View {
    let model: NowPlayingModel

    var body: some View {
        if model.artwork != nil {
            NowPlayingArtworkView(artwork: model.artwork, size: 22, radius: 11)
        } else if model.isVideo {
            NowPlayingProgressRing(model: model, lineWidth: 2)
                .frame(width: 15, height: 15)
        } else {
            NowPlayingWaveform(model: model, bars: 4, barWidth: 2, spacing: 1.5, height: 11)
        }
    }
}

/// The opened island: the player, a row of buttons for the playing app's library
/// when it has one, and the library's panel below them when one is open. While the
/// panel is open the player folds down to a single row, so the list has the room.
struct NowPlayingExpanded: View {
    let model: NowPlayingModel
    let library: NowPlayingLibraryModel

    /// The card's height for what it is showing. The island body can be about 250 pt
    /// at most (the island's window is 330 pt tall); the open panel takes it all.
    static func height(isVideo: Bool, hasButtons: Bool, isPanelOpen: Bool) -> CGFloat {
        if isPanelOpen { return 244 }
        // 4 above the player; the artwork, then 10 + 14 of scrubber and 6 + 38 of
        // controls; 8 + 24 for the library's buttons.
        let player: CGFloat = 4 + (isVideo ? 62 : 60) + 24 + 44
        return player + (hasButtons ? 32 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            if library.panel != nil {
                NowPlayingMiniPlayer(model: model)
                    .transition(.opacity)
            } else if model.isVideo {
                NowPlayingVideoPlayer(model: model)
                    .transition(.opacity)
            } else {
                NowPlayingMusicPlayer(model: model)
                    .transition(.opacity)
            }

            if library.hasButtons {
                NowPlayingLibraryButtons(model: model, library: library)
                    .padding(.top, library.panel == nil ? 8 : 12)
            }

            if library.panel != nil {
                NowPlayingLibraryPanel(model: model, library: library)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .frame(maxHeight: .infinity, alignment: .top)
        // Closing the island, or turning to another tab, closes the panel.
        .onDisappear { library.close() }
    }
}

private struct NowPlayingMusicPlayer: View {
    let model: NowPlayingModel
    @AppStorage(NowPlayingPrefs.tintWaveform) private var tinted = NowPlayingPrefs.tintWaveformDefault

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
                    NowPlayingSubtitleRow(model: model, fontSize: 13, iconSize: 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 60)

            NowPlayingProgress(model: model)
                .padding(.top, 10)

            controls
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
    }

    /// Shuffle and repeat either side of the transport, where the player reports
    /// them. When it reports only one, the other's place is kept so play stays in
    /// the middle.
    private var controls: some View {
        HStack(spacing: 22) {
            let showsModes = model.shuffle != nil || model.repeatMode != nil
            if showsModes {
                if let shuffle = model.shuffle {
                    ModeToggle(
                        symbol: "shuffle", isOn: shuffle != .off, tint: model.tint(tinted), label: "Shuffle"
                    ) { model.toggleShuffle() }
                } else {
                    Color.clear.frame(width: 26, height: 26)
                }
            }
            NowPlayingTransport(model: model, spacing: 26, small: 30, large: 38)
            if showsModes {
                if let repeatMode = model.repeatMode {
                    ModeToggle(
                        symbol: repeatMode == .one ? "repeat.1" : "repeat", isOn: repeatMode != .off,
                        tint: model.tint(tinted), label: "Repeat"
                    ) { model.cycleRepeat() }
                } else {
                    Color.clear.frame(width: 26, height: 26)
                }
            }
        }
    }

    /// The cover, badged with the app playing it; clicking it brings that app forward.
    private var artwork: some View {
        Button {
            model.openSourceApp()
        } label: {
            NowPlayingArtworkView(artwork: model.artwork, size: 60, radius: 12)
                .overlay(alignment: .bottomTrailing) { NowPlayingAppBadge(model: model, size: 22) }
        }
        .buttonStyle(.plain)
    }
}

/// The player in one row, above an open library panel: the artwork, what is
/// playing, and the transport.
private struct NowPlayingMiniPlayer: View {
    let model: NowPlayingModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.openSourceApp()
            } label: {
                if model.isVideo {
                    NowPlayingThumbnail(artwork: model.artwork, width: 78, radius: 8)
                } else {
                    NowPlayingArtworkView(artwork: model.artwork, size: 44, radius: 10)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                NowPlayingMarquee(text: model.title, font: .system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                NowPlayingSubtitleRow(model: model, fontSize: 12, iconSize: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NowPlayingTransport(model: model, spacing: 10, small: 28, large: 32)
        }
        .frame(height: 44)
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
                NowPlayingTransport(model: model, spacing: 10, small: 26, large: 30)
                NowPlayingTransport(model: model, spacing: 3, small: 24, large: 28)
                NowPlayingPlayButton(model: model, diameter: 28)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var artwork: some View {
        Button {
            model.openSourceApp()
        } label: {
            if model.isVideo {
                NowPlayingThumbnail(artwork: model.artwork, width: 64, radius: 8)
            } else {
                NowPlayingArtworkView(artwork: model.artwork, size: 44, radius: 9)
            }
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
}

// MARK: - Song banner

/// Left of the notch while a new song is announced: the cover and the artist (for a
/// video, the thumbnail and the channel). Where there is no room for the artist —
/// the opened island's header gives this side 24 points — just the cover.
struct NowPlayingSongBannerLeading: View {
    let model: NowPlayingModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NowPlayingSongBannerLayout.spacing) {
                cover(width: NowPlayingSongBannerLayout.coverWidth(isVideo: model.isVideo))
                if !model.subtitle.isEmpty {
                    Text(model.subtitle)
                        .font(Font(NowPlayingSongBannerLayout.artistFont))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        // Asks for no width of its own, so the row fits whenever the
                        // cover does and the artist takes what the wing has left: a
                        // thumbnail that arrives after the banner (a browser's video)
                        // trims the name rather than hiding it.
                        .frame(idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, NowPlayingSongBannerLayout.outerInset)
            .padding(.trailing, NowPlayingSongBannerLayout.innerInset)

            cover(width: 24)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cover(width: CGFloat) -> some View {
        if model.isVideo {
            NowPlayingThumbnail(artwork: model.artwork, width: width, radius: 4)
        } else {
            NowPlayingArtworkView(artwork: model.artwork, size: 20, radius: 5)
        }
    }
}

/// Right of the notch: the title, then the waveform (for a video, the ring) where
/// the compact activity has it. The title stays on this side in the opened island's
/// header too, where the left side is down to the cover.
struct NowPlayingSongBannerTrailing: View {
    let model: NowPlayingModel

    var body: some View {
        HStack(spacing: NowPlayingSongBannerLayout.spacing) {
            Text(model.title)
                .font(Font(NowPlayingSongBannerLayout.titleFont))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            NowPlayingCompactTrailing(model: model)
                .frame(width: NowPlayingSongBannerLayout.indicatorWidth)
        }
        .padding(.leading, NowPlayingSongBannerLayout.innerInset)
        .padding(.trailing, NowPlayingSongBannerLayout.outerInset)
    }
}

/// The song banner's measurements. Both wings are always the same width, whichever
/// side needs more, so the island stays centred on the notch; each side's content
/// keeps to its outer edge, and any difference is black beside the notch.
enum NowPlayingSongBannerLayout {
    static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let artistFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let spacing: CGFloat = 8
    /// Room between each wing's content and the island's outer edge, and the notch.
    /// Twelve points in, a song's cover and the waveform sit where the compact
    /// activity centres them in its 44-point wings.
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10
    /// The waveform or ring, in a slot as wide as a song's cover.
    static let indicatorWidth: CGFloat = 20
    /// Wide enough for most titles and artists whole; anything longer truncates
    /// rather than push the island over half the menu bar.
    static let maximumWing: CGFloat = 170

    /// The compact activity's cover: a square for music, a 16:9 thumbnail for video.
    static func coverWidth(isVideo: Bool) -> CGFloat { isVideo ? 30 : 20 }

    /// The width of each wing: whichever side needs more, used for both.
    static func wingWidth(title: String, artist: String, isVideo: Bool) -> CGFloat {
        let leading = outerInset + coverWidth(isVideo: isVideo)
            + (artist.isEmpty ? 0 : spacing + textWidth(artist, font: artistFont)) + innerInset
        let trailing = innerInset + textWidth(title, font: titleFont) + spacing + indicatorWidth + outerInset
        return min(max(leading, trailing), maximumWing)
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it,
    /// which would otherwise truncate a name that just fits.
    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
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

        // What each music app's library needs: a sign-in, a permission.
        Section("Spotify") {
            SpotifySettingsView()
        }
        Section("Music") {
            AppleMusicSettingsView()
        }
    }
}
