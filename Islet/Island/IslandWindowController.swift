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

    init(screen: NSScreen) {
        self.screen = screen
        let metrics = NotchMetrics.measure(screen)
        model = IslandViewModel(metrics: metrics)
        panel = IslandPanel(frame: Self.frame(for: metrics))

        let root = IslandRootView(model: model) { [weak self] layout in
            self?.layout = layout
            self?.updateHitTesting()
        }
        panel.contentView = IslandHostingView(rootView: root)
        panel.orderFrontRegardless()
        installMonitors()
    }

    func invalidate() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
        panel.close()
    }

    /// The screen's geometry changed (resolution, arrangement, notch appeared).
    func update(screen: NSScreen) {
        self.screen = screen
        let metrics = NotchMetrics.measure(screen)
        guard metrics != model.metrics else { return }
        model.metrics = metrics
        panel.setFrame(Self.frame(for: metrics), display: true)
    }

    private static func frame(for metrics: NotchMetrics) -> CGRect {
        let size = IslandLayout.canvas
        return CGRect(
            x: (metrics.notchMidX - size.width / 2).rounded(),
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
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves.union(.leftMouseUp), handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, isLocal: true) }
            return event
        }) {
            monitors.append(m)
        }
    }

    private func handle(_ event: NSEvent, isLocal: Bool) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            // Only global downs arrive here, so this click was not on the island.
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            model.clickOutside()
        case .leftMouseUp:
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
        if !fileDragActive, pasteboard.changeCount != dragChangeCount,
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

    /// Catch clicks only over the island (and its bubble); let everything else
    /// through to the menu bar and windows below.
    private func updateHitTesting() {
        guard let layout else { return }
        let point = NSEvent.mouseLocation
        let inside = islandRect(for: layout).contains(point) || bubbleRect(for: layout)?.contains(point) == true
        let catchesDrops = fileDragActive && model.isExpanded
        panel.ignoresMouseEvents = !(inside || catchesDrops)
        model.pointer(inside: inside)
    }

    private func islandRect(for layout: IslandLayout) -> CGRect {
        let metrics = model.metrics
        var rect = CGRect(
            x: metrics.notchMidX - layout.size.width / 2,
            y: metrics.screenFrame.maxY - layout.size.height,
            width: layout.size.width,
            height: layout.size.height
        )
        if model.mode == .hidden {
            // Nothing drawn, so nothing to hover — except on a notched screen, where
            // the notch itself stays a target.
            guard metrics.hasNotch else { return .null }
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
