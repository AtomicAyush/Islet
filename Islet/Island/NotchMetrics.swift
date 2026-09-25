import AppKit

/// The measurements of one screen's notch, or of the pill Islet floats on a display
/// without one. Everything the island draws is sized from these.
struct NotchMetrics: Equatable {
    /// The screen's frame in global AppKit coordinates (bottom-left origin).
    var screenFrame: CGRect
    /// Whether the screen has a real camera housing.
    var hasNotch: Bool
    /// The closed island: the hardware notch exactly, or the resting pill on a
    /// display without one.
    var notchSize: CGSize
    /// The notch's horizontal centre in global coordinates.
    var notchMidX: CGFloat
    /// Gap between the top of the screen and the island. Zero under a notch, where
    /// the island hangs from the edge; a few points on other displays, where it
    /// floats like the iPhone's.
    var topInset: CGFloat
    /// Points per pixel on this screen, for snapping the window to whole pixels.
    var backingScale: CGFloat

    static func measure(_ screen: NSScreen) -> NotchMetrics {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The notch is whatever the two unobscured corners leave between them.
            // On a 14-inch MacBook Pro that is 185 × 32, centred half a point left
            // of the screen's middle.
            let minX = frame.minX + left.width
            let maxX = frame.maxX - right.width
            return NotchMetrics(
                screenFrame: frame,
                hasNotch: true,
                notchSize: CGSize(width: maxX - minX, height: screen.safeAreaInsets.top),
                notchMidX: (minX + maxX) / 2,
                topInset: 0,
                backingScale: screen.backingScaleFactor
            )
        }

        // No notch: a pill that fits inside the menu bar (24–30 points tall,
        // depending on the display), floating just below the top edge. There is no
        // camera to leave room for, so the gap between compact wings is small.
        let menuBar = frame.maxY - screen.visibleFrame.maxY
        let height = menuBar > 0 ? min(max(menuBar - 6, 20), 28) : 24
        return NotchMetrics(
            screenFrame: frame,
            hasNotch: false,
            notchSize: CGSize(width: 64, height: height),
            notchMidX: frame.midX,
            topInset: 3,
            backingScale: screen.backingScaleFactor
        )
    }

    /// The notch rectangle in global coordinates.
    var notchRect: CGRect {
        CGRect(
            x: notchMidX - notchSize.width / 2,
            y: screenFrame.maxY - topInset - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var hasNotch: Bool { safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil }
}
