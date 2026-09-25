import SwiftUI

/// The island's outline.
///
/// Under a notch it hangs from the top of the screen: flush with the top edge, with
/// small concave "ears" at the top corners that flare out into the menu bar the way
/// the camera housing's own corners do, and rounded bottom corners that grow as the
/// island opens. On a display without a notch it floats instead, like the iPhone's
/// pill: no ears, and convex top corners (`topRadius`).
///
/// The frame includes the ears, so the body between them is `width - 2 * earRadius`
/// wide. All three radii animate, so the island can morph from the notch's tight
/// corners to the opened card's soft ones in one spring.
struct IslandShape: Shape {
    var earRadius: CGFloat
    var bottomRadius: CGFloat
    var topRadius: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(earRadius, AnimatablePair(bottomRadius, topRadius)) }
        set {
            earRadius = newValue.first
            bottomRadius = newValue.second.first
            topRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        guard w > 0, h > 0 else { return Path() }

        let ear = max(0, min(earRadius, h / 2, w / 4))
        let bodyWidth = w - 2 * ear
        let top = ear > 0 ? 0 : max(0, min(topRadius, h / 2, bodyWidth / 2))
        let r = max(0, min(bottomRadius, h - ear - top, bodyWidth / 2))
        // Control-point factor for a quarter circle drawn as one cubic.
        let k: CGFloat = 0.5523

        let left = rect.minX + ear
        let right = rect.maxX - ear

        var p = Path()
        if ear > 0 {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            // Left ear: concave, from the top edge down into the body's side.
            p.addCurve(
                to: CGPoint(x: left, y: rect.minY + ear),
                control1: CGPoint(x: rect.minX + ear * k, y: rect.minY),
                control2: CGPoint(x: left, y: rect.minY + ear * (1 - k))
            )
        } else {
            p.move(to: CGPoint(x: left + top, y: rect.minY))
            // Convex top-left corner.
            p.addCurve(
                to: CGPoint(x: left, y: rect.minY + top),
                control1: CGPoint(x: left + top * (1 - k), y: rect.minY),
                control2: CGPoint(x: left, y: rect.minY + top * (1 - k))
            )
        }
        p.addLine(to: CGPoint(x: left, y: rect.maxY - r))

        // Bottom-left corner.
        p.addCurve(
            to: CGPoint(x: left + r, y: rect.maxY),
            control1: CGPoint(x: left, y: rect.maxY - r * (1 - k)),
            control2: CGPoint(x: left + r * (1 - k), y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: right - r, y: rect.maxY))

        // Bottom-right corner.
        p.addCurve(
            to: CGPoint(x: right, y: rect.maxY - r),
            control1: CGPoint(x: right - r * (1 - k), y: rect.maxY),
            control2: CGPoint(x: right, y: rect.maxY - r * (1 - k))
        )

        if ear > 0 {
            p.addLine(to: CGPoint(x: right, y: rect.minY + ear))
            // Right ear.
            p.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control1: CGPoint(x: right, y: rect.minY + ear * (1 - k)),
                control2: CGPoint(x: rect.maxX - ear * k, y: rect.minY)
            )
        } else {
            p.addLine(to: CGPoint(x: right, y: rect.minY + top))
            // Convex top-right corner.
            p.addCurve(
                to: CGPoint(x: right - top, y: rect.minY),
                control1: CGPoint(x: right, y: rect.minY + top * (1 - k)),
                control2: CGPoint(x: right - top * (1 - k), y: rect.minY)
            )
        }
        p.closeSubpath()
        return p
    }
}
