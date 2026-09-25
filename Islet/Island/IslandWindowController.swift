import AppKit
import SwiftUI

/// One island on one screen: the panel, its model, and the pointer tracking that
/// decides when the island catches clicks and when it opens.
@MainActor
final class IslandWindowController {
    let model: IslandViewModel
    private let panel: IslandPanel
    private(set) var screen: NSScreen

    private var layout: IslandLayout?
    private var monitors: [Any] = []
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var fileDragActive = false
    /// The current press began on the island — dragging a file out of the shelf,
    /// say — so the drag it starts is outgoing and must not open the drop page.
    private var pressBeganInside = false
    /// Vertical travel of the current two-finger swipe over the island, in the
    /// direction the fingers moved (positive = down).
    private var swipeTravel: CGFloat = 0
    /// Sideways travel of the same swipe (positive = right), for turning home pages.
    private var swipeTravelX: CGFloat = 0
    private var swipeHandled = false
    /// Each swipe is either sideways or up-and-down, decided from its first few points
    /// of travel, so drift in the other direction cannot trigger the other gesture.
    private enum SwipeAxis { case undecided, horizontal, vertical }
    private var swipeAxis = SwipeAxis.undecided
    /// The swipe began over a list that scrolls up and down (Up Next, the mixer), so
    /// up-and-down swipes are the list's, not the island's.
    private var swipeOverList = false

    init(screen: NSScreen) {
        self.screen = screen
        let metrics = NotchMetrics.measure(screen)
        model = IslandViewModel(metrics: metrics)
        panel = IslandPanel(frame: Self.frame(for: metrics))

        let root = IslandRootView(model: model) { [weak self] layout in
            self?.layout = layout
            self?.updateHitTesting(pointerMoved: false)
        }
        let host = IslandHostingView(rootView: root)
        // The canvas is a fixed size; don't let SwiftUI's content resize the panel.
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()
        installMonitors()
    }

    func invalidate() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
        panel.close()
    }

    /// The screen's geometry changed (resolution, arrangement, notch appeared), or
    /// the Mac woke. Waking changes no geometry, but after a long sleep the window
    /// server can drop the panel from the screen, so it is always put back.
    func update(screen: NSScreen) {
        self.screen = screen
        let metrics = NotchMetrics.measure(screen)
        if metrics != model.metrics {
            model.metrics = metrics
        }
        panel.setFrame(Self.frame(for: metrics), display: true)
        panel.orderFrontRegardless()
    }

    private static func frame(for metrics: NotchMetrics) -> CGRect {
        let size = IslandLayout.canvas
        // Snap to whole pixels, not whole points: the notch's centre is often on a
        // half point, and rounding that to a point would shift the island a pixel.
        let scale = max(metrics.backingScale, 1)
        return CGRect(
            x: ((metrics.notchMidX - size.width / 2) * scale).rounded() / scale,
            y: metrics.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: Pointer

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let downs: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves.union(downs).union(.leftMouseUp), handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, isLocal: false) }
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves.union([.leftMouseUp, .leftMouseDown]), handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, isLocal: true) }
            return event
        }) {
            monitors.append(m)
        }
        // Scrolls only reach the panel while the pointer is over the island.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleSwipe(event) }
            return event
        }) {
            monitors.append(m)
        }
    }

    /// Two fingers pulled down over the island open it; pushed up, close it. The
    /// direction follows the fingers, whichever way natural scrolling is set.
    private func handleSwipe(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.window === panel else { return }
        if event.phase == .began {
            swipeTravel = 0
            swipeTravelX = 0
            swipeHandled = false
            swipeAxis = .undecided
            swipeOverList = model.isExpanded && isOverVerticalList(event)
        }
        guard event.phase == .changed || event.phase == .began, !swipeHandled else { return }

        let inverted = event.isDirectionInvertedFromDevice
        swipeTravel += inverted ? event.scrollingDeltaY : -event.scrollingDeltaY
        swipeTravelX += inverted ? event.scrollingDeltaX : -event.scrollingDeltaX

        if swipeAxis == .undecided, max(abs(swipeTravel), abs(swipeTravelX)) > 8 {
            swipeAxis = abs(swipeTravelX) > abs(swipeTravel) ? .horizontal : .vertical
        }
        switch swipeAxis {
        case .undecided:
            return
        case .horizontal:
            guard abs(swipeTravelX) > 30 else { return }
            // Fingers left means "next", as when paging on a trackpad.
            let direction: ActivitySwipe = swipeTravelX < 0 ? .next : .previous
            if model.isExpanded, model.resolvedFocus == IslandViewModel.homeFocus {
                // The open home page turns its pages; in the scrolling layout the row
                // takes the swipe itself.
                guard Prefs.homeLayout == .pages else { return }
                swipeHandled = true
                model.homePage = max(0, model.homePage + (direction == .next ? 1 : -1))
            } else if let activity = model.swipeTarget, activity.swipe(direction) {
                // The activity shown takes it (Now Playing switches player).
                swipeHandled = true
                Haptics.tap(.alignment)
            }
            return
        case .vertical:
            if swipeOverList { return }
        }

        if swipeTravel > 24, !model.isExpanded {
            swipeHandled = true
            model.expand()
        } else if swipeTravel < -24, model.isExpanded {
            swipeHandled = true
            model.collapse()
        }
    }

    /// Whether the pointer is over a scroll view with more content than it shows, top
    /// to bottom. SwiftUI's ScrollView is an NSScrollView underneath, so a hit test
    /// finds it.
    private func isOverVerticalList(_ event: NSEvent) -> Bool {
        guard let content = panel.contentView,
              let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        else { return false }
        var scroll = hit as? NSScrollView ?? hit.enclosingScrollView
        while let current = scroll {
            if let document = current.documentView,
               document.frame.height > current.contentView.bounds.height + 1 {
                return true
            }
            scroll = current.enclosingScrollView
        }
        return false
    }

    private func handle(_ event: NSEvent, isLocal: Bool) {
        switch event.type {
        case .leftMouseDown where isLocal:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            // Local events include Islet's other windows (Settings); only the panel counts.
            pressBeganInside = event.window === panel
            model.dragStartedOnIsland = pressBeganInside
        case .leftMouseDown, .rightMouseDown:
            // A global press: this click was not on the island.
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            pressBeganInside = false
            model.dragStartedOnIsland = false
            model.clickOutside()
        case .leftMouseUp:
            pressBeganInside = false
            if fileDragActive {
                fileDragActive = false
                model.fileDrag(began: false)
            }
            updateHitTesting()
        case .leftMouseDragged:
            trackFileDrag()
            updateHitTesting()
        default:
            updateHitTesting()
        }
    }

    /// A drag that put files on the drag pasteboard, with the pointer approaching the
    /// top of this screen, opens the island onto the drop target.
    private func trackFileDrag() {
        let pasteboard = NSPasteboard(name: .drag)
        if !fileDragActive, !pressBeganInside, pasteboard.changeCount != dragChangeCount,
           pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            fileDragActive = true
            model.fileDrag(began: true)
        }
        guard fileDragActive else { return }

        let point = NSEvent.mouseLocation
        let catchZone = model.metrics.notchRect.insetBy(dx: -70, dy: -50)
        if catchZone.contains(point) {
            model.fileDragApproached()
        }
    }

    /// Works out whether the pointer is over the island (and its bubble), for hover.
    /// Clicks need no help: the panel only catches them on pixels it has drawn.
    ///
    /// When the island changes shape on its own (a banner arriving, say) the pointer
    /// may now be over it without having moved. That does not count as hovering —
    /// otherwise a pointer resting near the top of the screen would open the island
    /// every time something happened.
    private func updateHitTesting(pointerMoved: Bool = true) {
        guard let layout else { return }
        let point = NSEvent.mouseLocation
        let overIsland = islandRect(for: layout).contains(point)
        let overBubble = !overIsland && bubbleRect(for: layout)?.contains(point) == true
        let inside = overIsland || overBubble
        // A press that began on the island (dragging the scrubber, say) holds it open
        // until release, wherever the pointer wanders; mouse-up clears the press and
        // comes back through here. Outgoing file drags change the drag pasteboard and
        // are left alone.
        if !inside, pressBeganInside, NSEvent.pressedMouseButtons & 1 != 0,
           NSPasteboard(name: .drag).changeCount == dragChangeCount {
            return
        }
        if pointerMoved || !inside {
            model.pointer(inside: overIsland, overBubble: overBubble)
        }
    }

    private func islandRect(for layout: IslandLayout) -> CGRect {
        let metrics = model.metrics
        var rect = CGRect(
            x: metrics.notchMidX - layout.size.width / 2,
            y: metrics.screenFrame.maxY - layout.topInset - layout.size.height,
            width: layout.size.width,
            height: layout.size.height
        )
        if model.mode == .hidden {
            // Nothing drawn, so nothing to hover — except on a notched screen, where
            // the notch itself stays a target. Not while an app is full screen,
            // though: there the top edge belongs to the app's own title bar.
            guard metrics.hasNotch, !model.isSuppressed else { return .null }
            rect = metrics.notchRect
        }
        // Once open, be forgiving about brushing past the edge.
        let slop: CGFloat = model.isExpanded ? 10 : 2
        return rect.insetBy(dx: -slop, dy: -slop)
    }

    private func bubbleRect(for layout: IslandLayout) -> CGRect? {
        guard model.bubbleActivity != nil else { return nil }
        let metrics = model.metrics
        let center = CGPoint(
            x: metrics.notchMidX + layout.bubbleCenterOffset.width,
            y: metrics.screenFrame.maxY - layout.bubbleCenterOffset.height
        )
        let r = layout.bubbleDiameter / 2 + 2
        return CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    }
}
