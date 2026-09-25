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
        }
        guard event.phase == .changed || event.phase == .began, !swipeHandled else { return }

        let inverted = event.isDirectionInvertedFromDevice
        swipeTravel += inverted ? event.scrollingDeltaY : -event.scrollingDeltaY
        swipeTravelX += inverted ? event.scrollingDeltaX : -event.scrollingDeltaX

        // Sideways on the open home page turns its pages: fingers left, next page.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            guard model.isExpanded, model.resolvedFocus == IslandViewModel.homeFocus,
                  abs(swipeTravelX) > 30 else { return }
            swipeHandled = true
            model.homePage = max(0, model.homePage + (swipeTravelX < 0 ? 1 : -1))
            return
        }

        if swipeTravel > 24, !model.isExpanded {
            swipeHandled = true
            model.expand()
        } else if swipeTravel < -24, model.isExpanded {
            swipeHandled = true
            model.collapse()
        }
    }

    private func handle(_ event: NSEvent, isLocal: Bool) {
        switch event.type {
        case .leftMouseDown where isLocal:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            pressBeganInside = true
        case .leftMouseDown, .rightMouseDown:
            // A global press: this click was not on the island.
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            pressBeganInside = false
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
        let inside = islandRect(for: layout).contains(point) || bubbleRect(for: layout)?.contains(point) == true
        if pointerMoved || !inside {
            model.pointer(inside: inside)
        }
    }

    private func islandRect(for layout: IslandLayout) -> CGRect {
        let metrics = model.metrics
        var rect = CGRect(
            x: metrics.notchMidX + layout.centerOffset - layout.size.width / 2,
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
