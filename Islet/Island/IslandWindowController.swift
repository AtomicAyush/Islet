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
    /// A drag of files, or of a picture from a web page, is under way.
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
    /// Counts menu bar measurements, so one that finishes late cannot overwrite a newer one.
    private var roomGeneration = 0

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
        measureMenuBarRoom()
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
        measureMenuBarRoom()
    }

    /// Finds where the status items begin right of this island, for the model to
    /// decide whether the second activity's bubble fits there. Read off the main
    /// thread: the first read of the window list takes tens of milliseconds, and
    /// asking every app through Accessibility, when it comes to that, longer. When
    /// nothing can tell where the items are, there is no room, and the second
    /// activity folds into the island. The moment it was asked for goes along, so an
    /// Accessibility read from before whatever prompted it is not reused.
    func measureMenuBarRoom() {
        guard let display = screen.displayID else { return }
        let metrics = model.metrics
        roomGeneration &+= 1
        let generation = roomGeneration
        let asked = ContinuousClock.now
        Task.detached(priority: .userInitiated) { [weak self] in
            let finding = MenuBarRoom.find(rightOf: metrics.notchRect.maxX, on: display, askedAt: asked)
            await self?.apply(menuBarRoom: finding.roomRight(of: metrics.notchMidX), generation: generation)
        }
    }

    private func apply(menuBarRoom room: CGFloat, generation: Int) {
        guard generation == roomGeneration, room != model.menuBarRoomRight else { return }
        withAnimation(.islandMorph) { model.menuBarRoomRight = room }
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
            // A card can scroll too (a shortcut's result): its text takes the swipe,
            // not the island, which would open over it mid-read.
            swipeOverList = (model.isExpanded || model.isShowingCard)
                && Self.isOverVerticalList(in: panel, at: event.locationInWindow)
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

    /// Whether a point in `window` is over a scroll view with more content than it
    /// shows, top to bottom. SwiftUI's ScrollView is an NSScrollView underneath, so a
    /// hit test finds it.
    static func isOverVerticalList(in window: NSWindow, at locationInWindow: NSPoint) -> Bool {
        // A hit test takes its point in the view's superview's coordinates. The hosting
        // view is flipped and the window's frame view is not, so the view's own
        // coordinates would mirror the point top to bottom and miss the island.
        guard let content = window.contentView, let frame = content.superview,
              let hit = content.hitTest(frame.convert(locationInWindow, from: nil))
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
            // A global press: this click was not on the island, though it may have
            // landed on the strip standing in for a hidden one.
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            pressBeganInside = false
            model.dragStartedOnIsland = false
            model.clickOutside(onEdgeStrip: event.type == .leftMouseDown && model.standsInOnEdge
                && model.hiddenTarget.contains(NSEvent.mouseLocation))
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

    /// A drag that put files on the drag pasteboard, or a picture from a web page,
    /// with the pointer approaching the top of this screen, opens the island onto
    /// the drop target.
    private func trackFileDrag() {
        let pasteboard = NSPasteboard(name: .drag)
        if !fileDragActive, !pressBeganInside, pasteboard.changeCount != dragChangeCount,
           Self.opensDropZone(for: pasteboard) {
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

    /// Whether a drag carrying this pasteboard is one the drop zone takes: files, or a
    /// picture dragged out of a web page. A link or a text selection is not; the
    /// island stays shut for those.
    static func opensDropZone(for pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || PictureDrag.isPictureDrag(pasteboard)
    }

    /// Works out whether the pointer is over the island or its second activity (the
    /// bubble, or the icon folded into the island), for hover. Clicks need no help:
    /// the panel only catches them on pixels it has drawn.
    ///
    /// When the island changes shape on its own (a banner arriving, say) the pointer
    /// may now be over it without having moved. That does not count as hovering —
    /// otherwise a pointer resting near the top of the screen would open the island
    /// every time something happened.
    private func updateHitTesting(pointerMoved: Bool = true) {
        guard let layout else { return }
        let point = NSEvent.mouseLocation
        let (overIsland, overSecondary) = Self.hitTest(point, layout: layout, model: model)
        let inside = overIsland || overSecondary
        // A press that began on the island (dragging the scrubber, say) holds it open
        // until release, wherever the pointer wanders; mouse-up clears the press and
        // comes back through here. Outgoing file drags change the drag pasteboard and
        // are left alone.
        if !inside, pressBeganInside, NSEvent.pressedMouseButtons & 1 != 0,
           NSPasteboard(name: .drag).changeCount == dragChangeCount {
            return
        }
        if pointerMoved || !inside {
            model.pointer(
                inside: overIsland, overSecondary: overSecondary,
                at: point, buttonsDown: NSEvent.pressedMouseButtons != 0
            )
        }
    }

    /// Whether `point`, in global coordinates, is over the island or over its second
    /// activity (the bubble, or the icon folded into the island), for `model` laid out
    /// as `layout`. The folded icon's patch of the island counts as the second
    /// activity's only.
    static func hitTest(_ point: CGPoint, layout: IslandLayout, model: IslandViewModel) -> (island: Bool, secondary: Bool) {
        let overFolded = foldedRect(for: layout, model: model).contains(point)
        let overIsland = !overFolded && islandRect(for: layout, model: model).contains(point)
        let overBubble = !overFolded && !overIsland && bubbleRect(for: layout, model: model)?.contains(point) == true
        return (overIsland, overFolded || overBubble)
    }

    /// The island's top-left corner on screen, which its own coordinates start from.
    private static func islandOrigin(for layout: IslandLayout, model: IslandViewModel) -> CGPoint {
        let metrics = model.metrics
        return CGPoint(x: metrics.notchMidX - layout.size.width / 2, y: metrics.screenFrame.maxY - layout.topInset)
    }

    private static func islandRect(for layout: IslandLayout, model: IslandViewModel) -> CGRect {
        // Nothing to see, so nothing of the island to hover: the notch, or the strip
        // that stands in for it, instead (`IslandViewModel.hiddenTarget`).
        if model.mode == .hidden { return model.hiddenTarget }
        let origin = islandOrigin(for: layout, model: model)
        let rect = CGRect(
            x: origin.x,
            y: origin.y - layout.size.height,
            width: layout.size.width,
            height: layout.size.height
        )
        // Once open, be forgiving about brushing past the edge.
        let slop: CGFloat = model.isExpanded ? 10 : 2
        return rect.insetBy(dx: -slop, dy: -slop)
    }

    /// The folded second activity's patch of the island (`IslandLayout.foldedTarget`)
    /// on screen, with the island's resting slop on its outer sides only: its inner
    /// edge is where a click stops opening the second activity, so hovering stops
    /// there too.
    private static func foldedRect(for layout: IslandLayout, model: IslandViewModel) -> CGRect {
        let target = layout.foldedTarget
        guard !target.isNull else { return .null }
        let origin = islandOrigin(for: layout, model: model)
        let slop: CGFloat = 2
        return CGRect(
            x: origin.x + target.minX - slop,
            y: origin.y - target.maxY - slop,
            width: target.width + slop,
            height: target.height + 2 * slop
        )
    }

    private static func bubbleRect(for layout: IslandLayout, model: IslandViewModel) -> CGRect? {
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
