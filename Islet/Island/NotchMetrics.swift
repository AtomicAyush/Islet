import AppKit

/// The measurements of one screen's notch, or of the notch Islet pretends a plain
/// display has. Everything the island draws is sized from these.
struct NotchMetrics: Equatable {
    /// The screen's frame in global AppKit coordinates (bottom-left origin).
    var screenFrame: CGRect
    /// Whether the screen has a real camera housing.
    var hasNotch: Bool
    /// The closed island: the hardware notch exactly, or a menu-bar-high stand-in.
    var notchSize: CGSize
    /// The notch's horizontal centre in global coordinates.
    var notchMidX: CGFloat

    /// A 14" MacBook Pro reports 185 × 32. Plain displays borrow that width so the
    /// island keeps the same proportions everywhere.
    static let standInWidth: CGFloat = 185

    static func measure(_ screen: NSScreen) -> NotchMetrics {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The notch is whatever the two unobscured corners leave between them.
            let minX = frame.minX + left.width
            let maxX = frame.maxX - right.width
            return NotchMetrics(
                screenFrame: frame,
                hasNotch: true,
                notchSize: CGSize(width: maxX - minX, height: screen.safeAreaInsets.top),
                notchMidX: (minX + maxX) / 2
            )
        }

        // No notch: match the menu bar, which is 24–30 points depending on the display.
        let menuBar = frame.maxY - screen.visibleFrame.maxY
        let height = menuBar > 0 ? min(max(menuBar - 1, 24), 32) : 24
        return NotchMetrics(
            screenFrame: frame,
            hasNotch: false,
            notchSize: CGSize(width: standInWidth, height: height),
            notchMidX: frame.midX
        )
    }

    /// The notch rectangle in global coordinates.
    var notchRect: CGRect {
        CGRect(
            x: notchMidX - notchSize.width / 2,
            y: screenFrame.maxY - notchSize.height,
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
