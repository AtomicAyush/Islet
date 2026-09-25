import AppKit
import SwiftUI

/// A borderless, transparent panel pinned over the notch, above the menu bar.
///
/// It is always the size of the largest island it might show; the island is drawn
/// inside it and everything else is clear, and clicks on the clear part fall through
/// to whatever is below.
final class IslandPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above the menu bar (24) and status items (25), below pop-up menus (101) so
        // an open menu still draws over the island.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [
            .canJoinAllSpaces, .canJoinAllApplications, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Left at its default, a transparent window catches clicks only on pixels it
        // has drawn: the island takes clicks, the clear canvas around it passes them
        // through. Writing `ignoresMouseEvents` at all — even `false` — switches that
        // off and makes the whole canvas opaque to clicks, so it is never set.
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // AppKit keeps ordinary windows below the menu bar; this one belongs on it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view that takes the first click. The panel never becomes key, so without
/// this the first click on a button in the island would only focus the window.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        // The notch is a safe-area inset at the top of the screen; the island is
        // meant to cover it, not be pushed below it.
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
