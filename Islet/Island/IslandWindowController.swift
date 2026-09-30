import AppKit
import Carbon.HIToolbox
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
    /// Told as a menu comes up in Islet or goes (`IslandViewModel.menu(isUp:)`).
    private var menuObservers: [NSObjectProtocol] = []
    /// Listening for Escape, while the home page is being arranged or a page is kept
    /// open.
    private var escapeMonitors: [Any] = []
    /// Gives the panel the keyboard while something in the island is typed in.
    private let keyboard: IslandKeyboard
    /// Watches for the panel losing the keyboard while typing: ⌘Tab, a click elsewhere.
    private var resignKeyObserver: NSObjectProtocol?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    /// A drag of files, or of a picture from a web page, is under way.
    private var fileDragActive = false
    /// The current press began on the island — dragging a file out of the shelf,
    /// say — so the drag it starts is outgoing and must not open the drop page.
    private var pressBeganInside = false
    /// Looks at the mouse button while a press that began on the island lasts
    /// (`watchPress()`).
    private var pressTimer: Timer?
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
    /// What was last found of each app's menus on this display, and which app's the
    /// room either side of the island was last set from (`measureMenus`).
    private var menus = MenuBarRoom.MenusMemory()
    /// Looks at the menus while something is left of the island (`watchMenus`).
    private var menusTimer: Timer?

    init(screen: NSScreen) {
        self.screen = screen
        let metrics = NotchMetrics.measure(screen)
        model = IslandViewModel(metrics: metrics)
        panel = IslandPanel(frame: Self.frame(for: metrics))
        keyboard = IslandKeyboard(window: panel)

        let root = IslandRootView(model: model) { [weak self] layout in
            self?.layout = layout
            self?.watchMenus()
            self?.updateHitTesting(pointerMoved: false)
        }
        let host = IslandHostingView(rootView: root)
        host.islandActions = { [weak model] in model?.compactAccessibilityActions ?? [] }
        // The canvas is a fixed size; don't let SwiftUI's content resize the panel.
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()
        installMonitors()
        model.editingHomeChanged = { [weak self] _ in self?.listenForEscapeIfHeld() }
        model.keepingOpenChanged = { [weak self] _ in self?.listenForEscapeIfHeld() }
        model.typingChanged = { [weak self] typing in self?.typingChanged(typing) }
        panel.keyAction = { [weak model] action in model?.keyAction(action) }
        measureMenuBarRoom()
    }

    func invalidate() {
        model.endTyping(.invalidated)
        menusTimer?.invalidate()
        menusTimer = nil
        pressTimer?.invalidate()
        pressTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        menuObservers.removeAll()
        listenForEscape(false)
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
    /// decide how many further activities' bubbles fit there. Read off the main
    /// thread: the first read of the window list takes tens of milliseconds, and
    /// asking every app through Accessibility, when it comes to that, longer. When
    /// nothing can tell where the items are, there is no room, and the first further
    /// activity folds into the island. The moment it was asked for goes along, so an
    /// Accessibility read from before whatever prompted it is not reused. The front
    /// app's menus are looked at alongside (`measureMenus`), and each look is taken as
    /// it comes in, so a slow app holds up neither.
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
        measureMenus()
    }

    private func apply(menuBarRoom room: CGFloat, generation: Int) {
        guard generation == roomGeneration, room != model.menuBarRoomRight else { return }
        withAnimation(.islandMorph) { model.menuBarRoomRight = room }
    }

    // MARK: The front app's menus

    /// Looks at the front app's menus on this display, while the bubbles may go on both
    /// sides of the island: those left of it stop short of the menus, and those right of
    /// it short of any menus that reach past the notch. Read off the main thread, as the
    /// status items are. Should the menu bar show another app's menus by now, those last
    /// found of that app's are kept clear of meanwhile (`followMenuBarOwner`).
    ///
    /// The menus are left be while the island is hidden for a full-screen app: the menu
    /// bar is tucked away then. With bubbles right of the island only, they are not
    /// looked at, and what was found of them is forgotten, so going back to both sides
    /// waits for a fresh look.
    func measureMenus() {
        guard model.bubblePlacement == .bothSides else {
            menus.forget()
            show(.unknown)
            return
        }
        followMenuBarOwner()
        guard !model.isSuppressed, let display = screen.displayID else { return }
        let owner = menus.owner
        let look = menus.begin()
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = MenuBarRoom.findMenus(on: display, owner: owner)
            await self?.apply(menus: found, of: owner, look: look)
        }
    }

    /// Keeps clear of the menus of the app whose menus the menu bar shows now, as last
    /// found, should that be another app than before: at once, rather than after the
    /// next look, so a bubble never sits on an app's menus for as long as a look takes.
    /// For an app not looked at yet, no bubble goes left of the island until it has
    /// been. Called as the menu bar changes hands, and as the island comes back from
    /// hiding for a full-screen app.
    func followMenuBarOwner() {
        guard model.bubblePlacement == .bothSides,
              let meanwhile = menus.follow(MenuBarRoom.menuBarOwner())
        else { return }
        show(meanwhile)
    }

    private func apply(menus found: MenuBarRoom.Menus, of owner: pid_t?, look: Int) {
        guard let taken = menus.take(found, of: owner, look: look) else { return }
        show(taken)
    }

    /// Hands the model the room either side of the island that `found` leaves.
    private func show(_ found: MenuBarRoom.Menus) {
        let center = model.metrics.notchMidX
        let left = model.bubblePlacement == .bothSides ? found.roomLeft(of: center) : 0
        let right = model.bubblePlacement == .bothSides ? found.roomRight(of: center) : .infinity
        guard left != model.menuBarRoomLeft || right != model.menusRoomRight else { return }
        withAnimation(.islandMorph) {
            model.menuBarRoomLeft = left
            model.menusRoomRight = right
        }
    }

    /// Looks at the menus again every few seconds while something is left of the
    /// island: an app can change its menus without telling anyone, and a bubble must
    /// not stay on them for long. Called with each new layout.
    private func watchMenus() {
        let left = layout.map { $0.leftBubbleCount > 0 || ($0.showsOverflowBubble && $0.overflowOnLeft) } ?? false
        if !left {
            menusTimer?.invalidate()
            menusTimer = nil
        } else if menusTimer == nil {
            menusTimer = Timer.scheduledTimer(withTimeInterval: Self.menusInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.measureMenus() }
            }
            menusTimer?.tolerance = 1
        }
    }

    /// How often the menus are looked at while something is left of the island. A look
    /// asks one app, and takes a few milliseconds.
    static let menusInterval: TimeInterval = 4

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
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves.union(downs).union(.leftMouseUp), handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, isLocal: true) }
            return event
        }) {
            monitors.append(m)
        }
        // While a menu is up, the pointer's moves are its own and reach no monitor; one
        // from the island holds it open meanwhile. Told on the posting thread, the main
        // one, as the menu comes up, not after.
        for (name, isUp) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.menu(isUp: isUp) }
            })
        }
        // Scrolls only reach the panel while the pointer is over the island.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleSwipe(event) }
            return event
        }) {
            monitors.append(m)
        }
    }

    /// Listens for Escape while the home page is being arranged or a page is kept open,
    /// and not otherwise.
    private func listenForEscapeIfHeld() {
        listenForEscape(model.isEditingHome || model.keptOpenPage != nil)
    }

    /// While the home page is being arranged, or a page is kept open, Escape ends it.
    /// The panel is key only while something in it is typed in, so neither has the
    /// keyboard: it listens for the key wherever it is pressed, only meanwhile, and the
    /// key still reaches the app in front. macOS passes on keys pressed in other apps
    /// only to an app with Accessibility access; without it, Done or a click outside
    /// ends arranging instead, and Keep Open or a click on the notch lets a page go.
    private func listenForEscape(_ on: Bool) {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors.removeAll()
        guard on else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.keyDown(event) }
        }) {
            escapeMonitors.append(m)
        }
        // Keys pressed in Islet's own windows (Settings) come this way instead.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.keyDown(event) }
            return event
        }) {
            escapeMonitors.append(m)
        }
    }

    // MARK: Typing

    /// Typing began or ended in the island (`IslandViewModel.beginTyping`): the panel
    /// takes the keyboard, or hands it back. The keyboard going elsewhere meanwhile, to
    /// another app or window, ends typing.
    private func typingChanged(_ typing: Bool) {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        keyboard.typingChanged(typing)
        guard typing else { return }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.endTyping(.resignedKey) }
        }
    }

    private func keyDown(_ event: NSEvent) {
        guard Self.endsEditing(event) else { return }
        model.endEditingHome()
        model.endKeepingOpen()
    }

    /// Whether a key press ends arranging the home page, or lets go of a page kept
    /// open: Escape, with no modifier held.
    static func endsEditing(_ event: NSEvent) -> Bool {
        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return event.keyCode == UInt16(kVK_Escape) && held.isEmpty
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

        // Swiping down opens the island. Swiping up does not close it: a two-finger
        // scroll over a part of the opened island that doesn't scroll read as that
        // gesture and closed the island mid-use. It closes when the pointer leaves
        // or on a click outside.
        if swipeTravel > 24, !model.isExpanded {
            swipeHandled = true
            model.expand()
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
            if pressBeganInside { watchPress() }
        case .rightMouseDown where isLocal:
            // A right-click on the compact island's row brings up its menu
            // (`IslandChoice`), which the island opening under it would take away.
            // Settings' are not the island's, and a row riding under it has no menu.
            if event.window === panel, let layout,
               Self.compactRowRect(for: layout, model: model).contains(NSEvent.mouseLocation) {
                model.menuOpened()
            }
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

    /// Watches a press that began on the island until the button is let go. A drag it
    /// starts out of the island (a clipboard item, a file off the shelf) holds the
    /// island open until it is let go (`IslandViewModel.dragOut(began:)`); the drag
    /// takes the mouse's moves and its release for itself, so neither may come here,
    /// and the button is looked at instead, a few times a second while the press lasts.
    private func watchPress() {
        pressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPress() }
        }
        // Common modes, so it runs while a drag is tracked.
        RunLoop.main.add(timer, forMode: .common)
        pressTimer = timer
    }

    private func checkPress() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            pressTimer?.invalidate()
            pressTimer = nil
            pressBeganInside = false
            guard model.isDraggingOut else { return }
            model.dragOut(began: false)
            // Where the drag was let go is where the pointer is now, on the island or off.
            updateHitTesting()
            return
        }
        if !model.isDraggingOut, NSPasteboard(name: .drag).changeCount != dragChangeCount {
            model.dragOut(began: true)
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

    /// Works out whether the pointer is over the island or one of its further
    /// activities (a bubble, the icon folded into the island, or the count of those
    /// left over), for hover. Clicks need no help:
    /// the panel only catches them on pixels it has drawn.
    ///
    /// When the island changes shape on its own (a banner arriving, say) the pointer
    /// may now be over it without having moved. That does not count as hovering —
    /// otherwise a pointer resting near the top of the screen would open the island
    /// every time something happened. Opened, it is the other way about. Only the
    /// pointer's own moving takes it off the island, never the island changing shape
    /// around it while it rests: the model keeps the room the pointer rests in
    /// (`IslandViewModel.keepingRoom(for:)`), and anything else that leaves it outside
    /// must not close the island as though it had been left. An opened island that
    /// grows under the pointer it already has, or has just been left by, has it over
    /// it, which keeps that room up to date as the island grows; one opened by a
    /// command over a pointer that never came to it does not, and stays open when the
    /// pointer goes on its way.
    private func updateHitTesting(pointerMoved: Bool = true) {
        guard let layout else { return }
        let point = NSEvent.mouseLocation
        let (overIsland, overSecondary) = Self.hitTest(point, layout: layout, model: model)
        let inside = overIsland || overSecondary != nil
        // A press that began on the island (dragging the scrubber, say) holds it open
        // until release, wherever the pointer wanders; mouse-up clears the press and
        // comes back through here. Outgoing drags change the drag pasteboard and are
        // left alone, closing the island as they leave it unless it is kept open;
        // `watchPress()` tells the model when one ends.
        if !inside, pressBeganInside, NSEvent.pressedMouseButtons & 1 != 0,
           NSPasteboard(name: .drag).changeCount == dragChangeCount {
            return
        }
        if pointerMoved || (model.isExpanded ? inside && model.hasPointer : !inside) {
            model.pointer(
                inside: overIsland, overSecondary: overSecondary,
                at: point, buttonsDown: NSEvent.pressedMouseButtons != 0
            )
        } else if model.hoveredSecondary != nil, overSecondary != model.hoveredSecondary {
            // The bubble under the resting pointer slid away, or ended: it is no longer
            // hovered, and what came under the pointer instead waits for it to move.
            model.secondaryMovedFromPointer()
        }
    }

    /// Whether `point`, in global coordinates, is over the island, or which further
    /// activity it is over (a bubble, the icon folded into the island, or the count of
    /// those left over), for `model` laid out as `layout`. The folded icon's patch of
    /// the island counts as that activity's only, and the count riding on the folded
    /// icon or the last bubble as the count's, over the circle it rides on.
    static func hitTest(
        _ point: CGPoint, layout: IslandLayout, model: IslandViewModel
    ) -> (island: Bool, secondary: IslandViewModel.SecondaryTarget?) {
        let others = model.otherActivities
        if badgeRects(for: layout, model: model).contains(where: { $0.contains(point) }) {
            return (false, .overflow)
        }
        if foldedRect(for: layout, model: model).contains(point) {
            // The folded one follows the bubbles, as `IslandViewModel.foldedActivity`.
            let folded = others.dropFirst(layout.bubbleCount).first
            return (false, folded.map { .activity($0.id) })
        }
        if islandRect(for: layout, model: model).contains(point) { return (true, nil) }
        for (index, activity) in others.prefix(layout.bubbleCount).enumerated() where layout.isBubbleShown(at: index) {
            let place = layout.bubblePlace(at: index)
            let center = layout.bubbleCenterOffset(at: CGFloat(place.slot), side: place.side)
            if circle(at: center, diameter: layout.bubbleDiameter, model: model).contains(point) {
                return (false, .activity(activity.id))
            }
        }
        let count = layout.overflowPlace
        if model.showsOverflowBubble,
           circle(at: layout.overflowCenterOffset(at: CGFloat(count.slot), side: count.side), diameter: layout.overflowDiameter, model: model)
            .contains(point) {
            return (false, .overflow)
        }
        return (false, nil)
    }

    /// The island's top-left corner on screen, which its own coordinates start from.
    private static func islandOrigin(for layout: IslandLayout, model: IslandViewModel) -> CGPoint {
        let metrics = model.metrics
        return CGPoint(x: metrics.notchMidX - layout.size.width / 2, y: metrics.screenFrame.maxY - layout.topInset)
    }

    /// The compact island's own row, on screen, without any row riding under it: where
    /// a right-click brings up the compact island's menu.
    static func compactRowRect(for layout: IslandLayout, model: IslandViewModel) -> CGRect {
        guard case .compact = model.mode else { return .null }
        let origin = islandOrigin(for: layout, model: model)
        return CGRect(x: origin.x, y: origin.y - layout.notch.height, width: layout.size.width, height: layout.notch.height)
    }

    private static func islandRect(for layout: IslandLayout, model: IslandViewModel) -> CGRect {
        // Nothing to see, so nothing of the island to hover: the notch, or the strip
        // that stands in for it, instead (`IslandViewModel.hiddenTarget`).
        if model.mode == .hidden { return model.hiddenTarget }
        let origin = islandOrigin(for: layout, model: model)
        // A banner's row is not hovered (`IslandViewModel.showsBannerRow`).
        let height = layout.size.height - (model.showsBannerRow ? layout.attachmentHeight : 0)
        let rect = CGRect(
            x: origin.x,
            y: origin.y - height,
            width: layout.size.width,
            height: height
        )
        // Once open, be forgiving about brushing past the edge.
        let slop: CGFloat = model.isExpanded ? 10 : 2
        return rect.insetBy(dx: -slop, dy: -slop)
    }

    /// The folded activity's patch of the island (`IslandLayout.foldedTarget`)
    /// on screen, with the island's resting slop on its outer sides only: its inner
    /// edge is where a click stops opening the folded activity, so hovering stops
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

    /// Where the count riding on the folded icon, or on the last bubble, is on screen,
    /// a point larger all round; empty when it has a bubble of its own or there is none.
    private static func badgeRects(for layout: IslandLayout, model: IslandViewModel) -> [CGRect] {
        var rects: [CGRect] = []
        let folded = layout.foldedBadgeRect
        if !folded.isNull {
            let origin = islandOrigin(for: layout, model: model)
            rects.append(CGRect(x: origin.x + folded.minX, y: origin.y - folded.maxY, width: folded.width, height: folded.height))
        }
        let last = layout.bubbleBadgeRect
        if !last.isNull, model.bubbleActivities.count == layout.bubblesShown {
            let metrics = model.metrics
            rects.append(CGRect(
                x: metrics.notchMidX + last.minX, y: metrics.screenFrame.maxY - last.maxY,
                width: last.width, height: last.height
            ))
        }
        return rects.map { $0.insetBy(dx: -1, dy: -1) }
    }

    /// A bubble's square on screen, a little larger than its circle, from where its
    /// centre sits relative to the notch's top centre.
    private static func circle(at offset: CGSize, diameter: CGFloat, model: IslandViewModel) -> CGRect {
        let metrics = model.metrics
        let center = CGPoint(
            x: metrics.notchMidX + offset.width,
            y: metrics.screenFrame.maxY - offset.height
        )
        let r = diameter / 2 + 2
        return CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    }
}
