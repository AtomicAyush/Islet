import SwiftUI

/// The island's outline: flush with the top of the screen, with small concave "ears"
/// at the top corners that flare out into the menu bar the way the camera housing's
/// own corners do, and rounded bottom corners that grow as the island opens.
///
/// The frame includes the ears, so the body between them is `width - 2 * earRadius`
/// wide. Both radii animate, so the island can morph from the notch's tight corners
/// to the opened card's soft ones in one spring.
struct IslandShape: Shape {
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(earRadius, bottomRadius) }
        set {
            earRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        guard w > 0, h > 0 else { return Path() }

        let ear = max(0, min(earRadius, h / 2, w / 4))
        let bodyWidth = w - 2 * ear
        let r = max(0, min(bottomRadius, h - ear, bodyWidth / 2))
        // Control-point factor for a quarter circle drawn as one cubic.
        let k: CGFloat = 0.5523

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Left ear: concave, from the top edge down into the body's side.
        p.addCurve(
            to: CGPoint(x: rect.minX + ear, y: rect.minY + ear),
            control1: CGPoint(x: rect.minX + ear * k, y: rect.minY),
            control2: CGPoint(x: rect.minX + ear, y: rect.minY + ear * (1 - k))
        )
        p.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - r))

        // Bottom-left corner.
        p.addCurve(
            to: CGPoint(x: rect.minX + ear + r, y: rect.maxY),
            control1: CGPoint(x: rect.minX + ear, y: rect.maxY - r * (1 - k)),
            control2: CGPoint(x: rect.minX + ear + r * (1 - k), y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - ear - r, y: rect.maxY))

        // Bottom-right corner.
        p.addCurve(
            to: CGPoint(x: rect.maxX - ear, y: rect.maxY - r),
            control1: CGPoint(x: rect.maxX - ear - r * (1 - k), y: rect.maxY),
            control2: CGPoint(x: rect.maxX - ear, y: rect.maxY - r * (1 - k))
        )
        p.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))

        // Right ear.
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - ear, y: rect.minY + ear * (1 - k)),
            control2: CGPoint(x: rect.maxX - ear * k, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}
