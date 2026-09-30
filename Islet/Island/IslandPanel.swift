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
        // A second guard while it takes keys: a click on a button in the island leaves
        // the keyboard where it is; only a field, or `makeKey()`, takes it.
        becomesKeyOnlyIfNeeded = true
    }

    /// Whether the panel may take the keyboard: only while something in the island is
    /// being typed in (`IslandKeyboard`). Otherwise it never does, and every key goes to
    /// the app in front.
    var takesKeys = false
    /// Told of a key equivalent that is the island's own while it takes keys.
    var keyAction: (IslandKeyAction) -> Void = { _ in }

    override var canBecomeKey: Bool { takesKeys }
    override var canBecomeMain: Bool { false }

    /// While the panel takes keys, a key equivalent would otherwise go on to Islet's own
    /// menu, where ⌘Q quits it: only the Edit menu's pass (`KeyEquivalentRule`).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard takesKeys, isKeyWindow else { return super.performKeyEquivalent(with: event) }
        switch KeyEquivalentRule.rule(for: event) {
        case .pass:
            if super.performKeyEquivalent(with: event) { return true }
            // Islet is not the active app, so its Edit menu may not be asked: the field
            // is sent the menu item's action itself.
            guard let action = KeyEquivalentRule.editAction(for: event) else { return false }
            return NSApp.sendAction(action, to: nil, from: self)
        case .handle(let action):
            keyAction(action)
            return true
        case .swallow:
            return true
        }
    }

    // AppKit keeps ordinary windows below the menu bar; this one belongs on it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view that takes the first click. The panel is key only while something in
/// it is being typed in, so without this the first click on a button in the island
/// would only focus the window.
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

    /// VoiceOver's actions on the island as a whole, asked for afresh each time
    /// (`IslandViewModel.compactAccessibilityActions`). The window controller sets it.
    var islandActions: () -> [NSAccessibilityCustomAction] = { [] }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        (super.accessibilityCustomActions() ?? []) + islandActions()
    }
}

extension IslandPanel: KeyTakingWindow {
    /// Out and straight back in, in the one turn: the window server hands the keyboard
    /// back to the app in front, which never stopped being in front, and nothing is
    /// drawn between (`animationBehavior` is `.none`).
    func returnKey() {
        orderOut(nil)
        orderFrontRegardless()
    }
}
