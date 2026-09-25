import SwiftUI

/// The island's motion. The iPhone's island never eases linearly: it stretches past
/// its target and settles, and its content arrives a beat after the shape does, out
/// of a blur. These are tuned to read the same at the size of a Mac notch.
extension Animation {
    /// Opening into the expanded view: quick, with a visible overshoot.
    static let islandOpen = Animation.spring(response: 0.42, dampingFraction: 0.72)
    /// Closing back to the notch: slightly faster and almost critically damped, so
    /// it does not bounce against the top of the screen.
    static let islandClose = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// Activities arriving, leaving or trading places.
    static let islandMorph = Animation.spring(response: 0.46, dampingFraction: 0.7)
    /// The small growth under the pointer.
    static let islandHover = Animation.spring(response: 0.28, dampingFraction: 0.62)
}

/// Content fades in from a blur and a slight shrink, and leaves faster than it came.
struct IslandContentTransition: ViewModifier {
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: 9 * progress)
            .scaleEffect(1 - 0.14 * progress, anchor: .top)
            .opacity(Double(1 - progress))
    }
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: IslandContentTransition(progress: 1),
                identity: IslandContentTransition(progress: 0)
            ).animation(.easeOut(duration: 0.28).delay(0.07)),
            removal: .modifier(
                active: IslandContentTransition(progress: 1),
                identity: IslandContentTransition(progress: 0)
            ).animation(.easeIn(duration: 0.14))
        )
    }
}
