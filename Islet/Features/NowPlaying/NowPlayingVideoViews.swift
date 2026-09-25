import SwiftUI

/// A video's thumbnail at 16:9, or a play glyph on a dark tile until one arrives.
struct NowPlayingThumbnail: View {
    let artwork: NowPlayingArtwork?
    let width: CGFloat
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let height = (width * 9 / 16).rounded()
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
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: height * 0.4, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .animation(.easeInOut(duration: 0.3), value: artwork?.id)
    }
}

/// A thin ring that fills as the video plays, in the tint colour.
struct NowPlayingProgressRing: View {
    let model: NowPlayingModel
    var lineWidth: CGFloat = 2.5
    @AppStorage(NowPlayingPrefs.tintWaveform) private var tinted = NowPlayingPrefs.tintWaveformDefault

    var body: some View {
        ProgressRingLayers(timing: model.timing, colour: NSColor(model.tint(tinted)), lineWidth: lineWidth)
    }
}

private struct ProgressRingLayers: NSViewRepresentable {
    let timing: NowPlayingTiming
    let colour: NSColor
    let lineWidth: CGFloat

    func makeNSView(context: Context) -> ProgressRingView {
        ProgressRingView(lineWidth: lineWidth)
    }

    func updateNSView(_ view: ProgressRingView, context: Context) {
        view.setColour(colour)
        view.setTiming(timing)
    }
}

/// The ring as shape layers. Core Animation runs the fill from where playback is to
/// the end at playback's own pace, asking only for the few frames a second a ring
/// this small needs to move a pixel, so an hour of video costs the app nothing per
/// frame. It is restarted only when the player reports a new position or rate.
final class ProgressRingView: NSView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let lineWidth: CGFloat
    private var timing: NowPlayingTiming?
    private var laidOutSize: CGSize = .zero

    init(lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
        for ring in [track, fill] {
            ring.fillColor = nil
            ring.lineWidth = lineWidth
            ring.lineCap = .round
            layer?.addSublayer(ring)
        }
        fill.strokeEnd = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        let side = max(0, min(bounds.width, bounds.height) - lineWidth)
        // From twelve o'clock, clockwise; the layers' y axis points up.
        let path = CGMutablePath()
        path.addArc(
            center: CGPoint(x: bounds.midX, y: bounds.midY), radius: side / 2,
            startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for ring in [track, fill] {
            ring.frame = bounds
            ring.path = path
        }
        CATransaction.commit()
        // The ring's size sets how many frames a second its motion needs.
        restart()
    }

    func setColour(_ colour: NSColor) {
        let cg = colour.cgColor
        guard fill.strokeColor != cg else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        fill.strokeColor = cg
        track.strokeColor = colour.withAlphaComponent(0.25).cgColor
        CATransaction.commit()
    }

    func setTiming(_ timing: NowPlayingTiming) {
        guard timing != self.timing else { return }
        self.timing = timing
        restart()
    }

    private func restart() {
        fill.removeAnimation(forKey: "progress")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let timing, timing.duration > 0 else {
            // A live stream has no end to measure against: the whole ring, still.
            fill.strokeEnd = timing == nil ? 0 : 1
            return
        }
        let now = Date()
        let position = timing.position(at: now)
        let fraction = position / timing.duration
        guard timing.rate > 0, fraction < 1 else {
            fill.strokeEnd = fraction
            return
        }
        fill.strokeEnd = 1
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = fraction
        animation.toValue = 1
        animation.duration = (timing.duration - position) / timing.rate
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        // About one frame per pixel the ring's end moves, and never more than 10: a
        // clip a few seconds long moves a couple of pixels a frame, which a ring
        // this small hides.
        let circumference = Double.pi * min(bounds.width, bounds.height) * (window?.backingScaleFactor ?? 2)
        let pixelsPerSecond = circumference * timing.rate / timing.duration
        let frames = Float(min(10, max(1, pixelsPerSecond.rounded(.up))))
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: frames, preferred: frames)
        fill.add(animation, forKey: "progress")
    }
}

/// The opened island for a video: the thumbnail, what is playing and on which
/// channel, the scrubber, and 15-second jumps either side of play.
struct NowPlayingVideoPlayer: View {
    let model: NowPlayingModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    model.openSourceApp()
                } label: {
                    NowPlayingThumbnail(artwork: model.artwork, width: 110, radius: 10)
                        .overlay(alignment: .bottomTrailing) { NowPlayingAppBadge(model: model, size: 22) }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    NowPlayingMarquee(text: model.title, font: .system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    NowPlayingSubtitleRow(model: model, fontSize: 13, iconSize: 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 62)

            NowPlayingProgress(model: model)
                .padding(.top, 10)

            NowPlayingTransport(model: model, spacing: 26, small: 30, large: 38)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
    }
}
