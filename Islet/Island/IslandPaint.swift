import AppKit
import SwiftUI

/// The island's fill as drawn, filling its frame: one colour, a still gradient, or
/// colours fading one into the next on the render server (`IslandFillPaint`).
struct IslandPaint: View {
    let style: IslandPaintStyle
    /// Whether it is shown at all: a fill that is not holds still.
    var isShown = true

    var body: some View {
        switch style {
        case .solid(let colour):
            Rectangle().fill(colour.color)
        case .gradient(let stops, let direction):
            LinearGradient(colors: stops.map(\.color), startPoint: direction.start, endPoint: direction.end)
        case .rotating(let stops, let period):
            IslandFillPaint(stops: stops, period: period, isShown: isShown)
        }
    }
}

extension IslandGradientDirection {
    var start: UnitPoint {
        switch self {
        case .down: .top
        case .across: .leading
        case .diagonal: .topLeading
        }
    }

    var end: UnitPoint {
        switch self {
        case .down: .bottom
        case .across: .trailing
        case .diagonal: .bottomTrailing
        }
    }
}

/// Colours fading one into the next, round and round: one layer whose background colour
/// Core Animation moves through the stops, so Islet draws nothing as it changes.
struct IslandFillPaint: NSViewRepresentable {
    let stops: [RGB]
    let period: Double
    var isShown = true

    func makeNSView(context: Context) -> FillView { FillView() }

    func updateNSView(_ view: FillView, context: Context) {
        view.update(stops: stops, period: period, isShown: isShown)
    }

    final class FillView: IslandMotionView {
        private let paint = CALayer()
        private var stops: [RGB] = []
        private var cycle: Double = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer?.addSublayer(paint)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(stops: [RGB], period: Double, isShown: Bool) {
            #if DEBUG
            IslandMotion.shared.updates += 1
            #endif
            guard stops != self.stops || period != cycle || isShown != self.isShown else { return }
            self.stops = stops
            cycle = period
            // Setting it tells the clock when it changes; set the rest first.
            if isShown != self.isShown { self.isShown = isShown } else { animationChanged() }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            paint.frame = bounds
            CATransaction.commit()
        }

        override var animatedLayer: CALayer? { stops.isEmpty ? nil : paint }
        override var period: CFTimeInterval { cycle }

        override func makeAnimation() -> CAAnimation? {
            guard stops.count > 1 else { return nil }
            let animation = CAKeyframeAnimation(keyPath: "backgroundColor")
            animation.values = (stops + [stops[0]]).map(\.cgColor)
            animation.keyTimes = (0...stops.count).map { NSNumber(value: Double($0) / Double(stops.count)) }
            animation.calculationMode = .linear
            animation.duration = cycle
            // A fade of seconds per colour needs few frames; each is well under one step
            // of 8-bit colour from the last.
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
            return animation
        }

        override func pose(at phase: Double) {
            paint.backgroundColor = Self.colour(of: stops, at: phase)?.cgColor
        }

        /// The colour `phase` of the way round `stops`, from the last back to the first.
        static func colour(of stops: [RGB], at phase: Double) -> RGB? {
            guard let first = stops.first else { return nil }
            let position = phase * Double(stops.count)
            let index = min(Int(position), stops.count - 1)
            let next = index + 1 < stops.count ? stops[index + 1] : first
            return stops[index].mixed(toward: next, position - Double(index))
        }
    }
}

/// A ring's colours travelling round: a conic gradient Core Animation turns on the render
/// server. The gradient is stretched to the shape it runs round, so its colours travel
/// along a long island's straight sides about as fast as round its ends, rather than
/// racing round the ends and crawling along the bottom.
struct IslandRingPaint: NSViewRepresentable {
    let colours: [RGB]
    let period: Double
    var isShown = true

    func makeNSView(context: Context) -> RingView { RingView() }

    func updateNSView(_ view: RingView, context: Context) {
        view.update(colours: colours, period: period, isShown: isShown)
    }

    final class RingView: IslandMotionView {
        /// Stretched to the view's shape.
        private let stretch = CALayer()
        /// Square, turning about its centre.
        private let conic = CAGradientLayer()
        private var colours: [RGB] = []
        private var cycle: Double = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            conic.type = .conic
            conic.startPoint = CGPoint(x: 0.5, y: 0.5)
            conic.endPoint = CGPoint(x: 0.5, y: 0)
            stretch.addSublayer(conic)
            layer?.addSublayer(stretch)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(colours: [RGB], period: Double, isShown: Bool) {
            #if DEBUG
            IslandMotion.shared.updates += 1
            #endif
            guard colours != self.colours || period != cycle || isShown != self.isShown else { return }
            if colours != self.colours {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                conic.colors = (colours + colours.prefix(1)).map(\.cgColor)
                CATransaction.commit()
            }
            self.colours = colours
            cycle = period
            if isShown != self.isShown { self.isShown = isShown } else { animationChanged() }
        }

        override func layout() {
            super.layout()
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let side = size.height
            stretch.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            stretch.position = CGPoint(x: bounds.midX, y: bounds.midY)
            stretch.transform = CATransform3DMakeScale(size.width / side, 1, 1)
            // Large enough to cover the square at any angle.
            let reach = side * 2.squareRoot() + 2
            conic.bounds = CGRect(x: 0, y: 0, width: reach, height: reach)
            conic.position = CGPoint(x: side / 2, y: side / 2)
            CATransaction.commit()
        }

        override var animatedLayer: CALayer? { colours.isEmpty ? nil : conic }
        override var period: CFTimeInterval { colours.count > 1 ? cycle : 0 }

        override func makeAnimation() -> CAAnimation? {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0
            animation.toValue = -2 * Double.pi
            animation.duration = cycle
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
            return animation
        }

        override func pose(at phase: Double) {
            conic.transform = CATransform3DMakeRotation(-2 * .pi * phase, 0, 0, 1)
        }
    }
}

/// The ring round the island, a bubble or the count: a band of `thickness` inside the
/// edge, and the glow falling inward from it, in the ring's colours at its brightness.
///
/// The colours are masked by the edge stroked twice as wide as the band, and the shape's
/// own clip leaves only the inner half, as the island's hairline is drawn: so nothing is
/// drawn outside the shape, and where clicks are caught never changes. The glow is a few
/// wider, fainter strokes of the same edge, so nothing is blurred as the colours move.
struct IslandRingView<Edge: Shape>: View {
    let ring: IslandRing
    let edge: Edge
    /// The most room the band and its glow may take, clear of what the shape shows.
    let room: IslandRingRoom
    var isShown = true
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let colours = ring.colours(on: theme)
        let band = min(ring.thickness.width, room.band)
        let reach = min(6 * ring.glow, room.glow)
        let glow = min(ring.glow * 0.6, theme.glowCap(for: colours))
        IslandRingColours(ring: ring, isShown: isShown)
            .mask {
                ZStack {
                    if reach > 0.25, glow > 0 {
                        ForEach(1...Self.glowSteps, id: \.self) { step in
                            edge.stroke(lineWidth: 2 * (band + reach * Double(step) / Double(Self.glowSteps)))
                                .opacity(glow / Double(Self.glowSteps))
                        }
                    }
                    edge.stroke(lineWidth: 2 * band)
                }
            }
            .opacity(ring.brightness)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Strokes the glow is built of, each a little wider and all as faint.
    private static var glowSteps: Int { 5 }
}

/// A ring's colours over the whole of the view, for a mask to shape: its one colour, or
/// its colours turning round the view's centre.
struct IslandRingColours: View {
    let ring: IslandRing
    var isShown = true
    @Environment(\.islandTheme) private var theme

    var body: some View {
        switch ring.colouring {
        case .steady(let colour):
            Rectangle().fill(colour.color)
        case .rotating:
            IslandRingPaint(colours: ring.colours(on: theme), period: ring.speed.secondsPerLap, isShown: isShown)
        }
    }
}

extension IslandRing {
    /// How far in from the edge a ring reaches within `room`, its glow included.
    func depth(within room: IslandRingRoom) -> CGFloat {
        min(thickness.width, room.band) + min(6 * glow, room.glow)
    }
}

/// How much room a ring has inside an edge before it would reach what the shape shows.
struct IslandRingRoom: Equatable {
    /// The band itself.
    var band: CGFloat
    /// The glow inward from it.
    var glow: CGFloat

    /// A bubble's or the count's: a thin band, and a little glow.
    static let small = IslandRingRoom(band: 1.5, glow: 1.5)
}
