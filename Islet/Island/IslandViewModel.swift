import AppKit
import SwiftUI
import Observation

/// What one island window is showing and how big it is. There is one of these per
/// window; they all render the same `ActivityCenter`, but each has its own pointer,
/// hover and expanded state.
@MainActor
@Observable
final class IslandViewModel {
    enum Mode: Equatable {
        /// Nothing to see (a plain display with nothing to show, or a full-screen
        /// app on this display). Usually nothing is drawn at all; see
        /// `IslandLayout.isDrawn` for the exception.
        case hidden
        /// The resting notch.
        case idle
        /// An activity either side of the notch.
        case compact(id: String)
        /// A transient alert, in the island's place: a card, or a compact banner with
        /// no live activity to ride under (`ActivityCenter.bannerRidesUnder`).
        case banner(id: String)
        /// Opened, showing the home page, an activity, the drop zone or a feature's page.
        case expanded(focus: String)
    }

    static let homeFocus = "home"
    static let dropFocus = "drop"
    /// Posted as an island opens, with its model as the object; not as one already open
    /// turns to another page. For a feature that looks something up only for the opened
    /// island (which menu bar icons the notch hides) and would otherwise have to keep
    /// looking.
    static let didOpenNotification = Notification.Name("IslandViewModel.didOpen")

    var metrics: NotchMetrics
    /// Set by the controller from preferences and the full-screen watcher.
    var showsIdlePill = false
    var isSuppressed = false
    /// While the island is hidden for a full-screen app, the notch still opens it (on
    /// a display without one, a strip along the middle of the top edge). Set by the
    /// manager from preferences.
    var opensFromNotchInFullScreen = false
    /// How far right of the notch's centre the menu bar's first status item begins:
    /// infinity when none does, and 0 when nothing can tell where the items are
    /// (macOS 27 without Accessibility), so the second activity folds. Set by the
    /// controller; decides whether the second activity's bubble fits beside the
    /// island or folds into it.
    var menuBarRoomRight = CGFloat.infinity

    private(set) var isExpanded = false
    private(set) var isHovering = false
    /// The pointer is over the second activity: the detached bubble, or its icon
    /// folded into the island.
    private(set) var isHoveringSecondary = false
    /// A file drag is in progress anywhere on screen.
    private(set) var isDraggingFile = false
    /// The tab picked in the expanded island; `nil` follows the primary activity.
    var focus: String?
    /// Which page of home tiles is showing, when they need more than one.
    var homePage = 0
    /// The indicator card open in the opened island, if any (`IndicatorDetail`).
    private(set) var indicatorCard: OpenIndicatorCard?
    /// How tall each card is as drawn, by its id, as the card reports it, so the island
    /// can grow to hold one taller than its page leaves room for. Kept while the card
    /// is closed: one opened again while it is still fading out is the same view, come
    /// back, and reports no new height. Forgotten as the island closes.
    private(set) var indicatorCardHeights: [String: CGFloat] = [:]
    /// The opened island's size as last laid out while the pointer is over it: the room
    /// it keeps when what it shows asks for less, for as long as the pointer rests in
    /// the part given up (`keepingRoom(for:)`), and all of it through the grace after
    /// the pointer leaves, for it to come back to. Zero once nothing waits for the
    /// pointer, and while the island is closed.
    private var roomUnderPointer = CGSize.zero
    /// Where the pointer last was, in global coordinates, as the controller reports it.
    /// Not observed: the layout reads it only while the pointer is over the opened
    /// island, and every report of it there that could change the answer updates
    /// `roomUnderPointer` (`followPointer()`).
    @ObservationIgnored private var pointerLocation: CGPoint?

    /// The current press began on the island, so a drag it starts is outgoing (a file
    /// dragged off the shelf) and the island must not treat it as one arriving.
    @ObservationIgnored var dragStartedOnIsland = false

    #if DEBUG
    /// Keeps the island open whatever the pointer does, for screenshots
    /// (`islet://open?pin=1`; `islet://close` releases it).
    var isPinnedOpen = false
    #endif

    let center = ActivityCenter.shared

    @ObservationIgnored private var expandWork: DispatchWorkItem?
    @ObservationIgnored private var collapseWork: DispatchWorkItem?

    /// How the pointer on the notch is getting on towards opening the island while it
    /// is hidden for a full-screen app (see `peek(at:buttonsDown:)`).
    private enum PeekWait: Equatable {
        /// Not waiting: the pointer is elsewhere, or a click or a change of Space
        /// ended the wait, and it has to come back to the notch to wait again.
        case none
        /// On the notch with a button held: a drag, which waits for the release.
        case held
        /// Resting on the notch since it came to a stop at this point.
        case resting(at: CGPoint)
    }
    @ObservationIgnored private var peekWait = PeekWait.none

    /// The island was open over a full-screen app when the Space changed, and whether
    /// it closes waits on the full-screen watcher's next look (`spaceDidSettle`).
    @ObservationIgnored private var openAcrossSpaceChange = false
    /// The app in front when the island last opened.
    @ObservationIgnored private var appInFrontAtOpen: pid_t?
    /// Which app is in front. Only a test replaces it.
    @ObservationIgnored var appInFront: () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    init(metrics: NotchMetrics) {
        self.metrics = metrics
    }

    // MARK: Mode

    var mode: Mode {
        if isExpanded { return .expanded(focus: resolvedFocus) }
        if isSuppressed { return .hidden }
        // A compact banner over a live activity leaves it be, and rides under it.
        if let banner = center.banner, !center.bannerRidesUnder { return .banner(id: banner.id) }
        if let primary = center.primary { return .compact(id: primary.id) }
        // Camera and microphone dots need somewhere to sit, notch or not; a
        // long-lived indicator such as a Focus's waits for the island to be up.
        return metrics.hasNotch || showsIdlePill || center.indicators.contains(where: \.keepsIslandShown) ? .idle : .hidden
    }

    var resolvedFocus: String {
        if let focus {
            if focus == Self.homeFocus { return focus }
            if focus == Self.dropFocus, center.dropTarget != nil { return focus }
            if center.activity(id: focus) != nil || center.pages[focus] != nil { return focus }
        }
        return center.primary?.id ?? Self.homeFocus
    }

    /// Identity for the content layer, so a change of what is shown cross-fades
    /// rather than morphing one view's contents into another's.
    var contentKey: String {
        switch mode {
        case .hidden: "hidden"
        case .idle: "idle"
        case .compact(let id): "compact.\(id)"
        case .banner(let id): "banner.\(id)"
        case .expanded: "expanded"
        }
    }

    /// The activity a sideways swipe goes to: the one the compact island shows, or
    /// the page the opened island is on.
    var swipeTarget: (any IslandActivity)? {
        switch mode {
        case .compact(let id), .expanded(focus: let id): center.activity(id: id)
        default: nil
        }
    }

    /// The activity in the detached bubble: the runner-up, while the island is
    /// compact and the bubble fits beside it. A banner in the island's place, and the
    /// opened island, absorb it; a banner riding under the activity leaves it be, unless
    /// its row widens the island too far for the bubble (`IslandLayout.takesInBubble`).
    var bubbleActivity: (any IslandActivity)? {
        guard case .compact = mode else { return nil }
        let layout = self.layout
        guard !layout.foldsSecondary, !layout.takesInBubble else { return nil }
        return center.secondary
    }

    /// The runner-up folded into the island's leading wing, because the menu bar has
    /// no room for its bubble.
    var foldedActivity: (any IslandActivity)? {
        guard case .compact = mode, layout.foldsSecondary else { return nil }
        return center.secondary
    }

    /// The row under this island's compact content, if any. One shows at a time, the
    /// first of:
    ///
    /// - the attachment presented (the volume, while a key is held), while there is
    ///   compact content here to ride under — an activity, or a compact banner;
    /// - a compact banner riding under the activity (`ActivityCenter.bannerRidesUnder`),
    ///   which waits behind a presented row, its time held, and comes back once that
    ///   has gone;
    /// - the standing row, while its own activity holds the compact island, which waits
    ///   behind both and comes back once they have gone.
    ///
    /// None while the island is open (its header shows the attachment's banner, or the
    /// banner, instead), a card is up, or the island is hidden.
    ///
    /// A presented row and a banner's pass in seconds; the standing row stays as long as
    /// its activity (`rowIsPassing`).
    var attachment: IslandAttachment? {
        switch mode {
        case .compact(let id):
            if let attachment = center.attachment { return attachment }
            // In compact mode, a banner on screen is one riding under the activity.
            if let row = center.banner?.row { return row }
            guard let standing = center.standingAttachment, standing.activityID == id else { return nil }
            return standing.attachment
        case .banner:
            guard let attachment = center.attachment, case .compact? = center.banner?.style else { return nil }
            return attachment
        case .hidden, .idle, .expanded:
            return nil
        }
    }

    /// Whether the row under the compact island is one that passes in seconds: a
    /// presented one (the volume) or a banner's, rather than the standing one.
    var rowIsPassing: Bool {
        guard case .compact = mode else { return false }
        return center.attachment != nil || center.bannerRidesUnder
    }

    /// Whether the row under the compact island is a banner's, riding under the
    /// activity. Hanging below the menu bar, over the top of the window beneath (a
    /// browser's tabs), for as long as a banner lasts, and banners come often, it does
    /// not open the island on hover: a pointer resting there is on its way to that
    /// window. The notch row still does, and a click on the row, as on the island.
    var showsBannerRow: Bool {
        guard case .compact = mode else { return false }
        return center.attachment == nil && center.bannerRidesUnder
    }

    // MARK: Layout

    var layout: IslandLayout {
        IslandLayout.make(for: self)
    }

    // MARK: Hidden for full screen

    /// Hidden for a full-screen app, yet still opened from the notch.
    var opensWhileSuppressed: Bool { isSuppressed && opensFromNotchInFullScreen }

    /// The least time the pointer must rest to open the island while it is hidden for
    /// a full-screen app. The top edge is also the way to the app's hidden menu bar,
    /// and a pointer brushing past on its way there must not open the island; with
    /// the hover delay set to nothing, this still asks for a moment's rest.
    static let fullScreenDwell: TimeInterval = 0.25

    /// How far the pointer may drift on the notch and still be resting there, while the
    /// island is hidden for a full-screen app. Further, and it is moving on, and the
    /// wait to open starts again from where it stops.
    static let restTolerance: CGFloat = 3

    /// How tall the strip is that stands in for the island at the top of a display
    /// without a notch while it is hidden for a full-screen app. Thin, so the app's own
    /// top edge (a browser's tabs, a video's controls) stays the app's.
    static let edgeTargetHeight: CGFloat = 4

    /// Where the pointer finds the island while there is nothing to see
    /// (`mode == .hidden`), in global coordinates; null where there is nothing to find.
    ///
    /// Hidden for a full-screen app, the island is found — when the person has not
    /// turned that off — on the notch, where nothing of a full-screen app can be
    /// clicked (its content starts below the camera housing), or on a display without
    /// a notch in a strip `edgeTargetHeight` tall at the very top, as wide as the
    /// resting pill. The strip reaches a point above the screen: the pointer's highest
    /// position is the top edge itself, where mouse coordinates end. Otherwise a
    /// notched screen's notch stays a target, and a plain display with nothing to show
    /// has none.
    var hiddenTarget: CGRect {
        if isSuppressed, !opensFromNotchInFullScreen { return .null }
        if metrics.hasNotch { return metrics.notchRect.insetBy(dx: -2, dy: -2) }
        guard isSuppressed else { return .null }
        let width = metrics.notchSize.width + IslandLayout.pillWidening
        return CGRect(
            x: metrics.notchMidX - width / 2,
            y: metrics.screenFrame.maxY - Self.edgeTargetHeight,
            width: width,
            height: Self.edgeTargetHeight + 1
        )
    }

    /// Hidden for a full-screen app on a display without a notch, where the strip at
    /// the top edge stands in for the island.
    var standsInOnEdge: Bool {
        mode == .hidden && opensWhileSuppressed && !metrics.hasNotch
    }

    /// The active Space changed, and `isSuppressed` still describes the Space that
    /// went. While hidden for a full-screen app, a wait on the notch to open the
    /// island ends: the pointer has to come back to it on the new Space, rather than
    /// the island opening over whatever arrives. An island open over the full-screen
    /// app is left for `spaceDidSettle` to decide on, once it is known where the
    /// display has gone.
    func spaceDidChange() {
        guard isSuppressed else { return }
        cancelExpand()
        if isExpanded { openAcrossSpaceChange = true }
    }

    /// The full-screen watcher has looked again after a change of Space, so
    /// `isSuppressed` is up to date. An island that was open over a full-screen app
    /// when the Space changed closes, as what it was opened over has gone — unless the
    /// app simply left full screen under it (Esc, say, which changes Space too): the
    /// display is no longer full screen and the app it opened over is still in front.
    /// Then it stays open, now the normal island.
    func spaceDidSettle() {
        guard openAcrossSpaceChange else { return }
        openAcrossSpaceChange = false
        #if DEBUG
        if isPinnedOpen { return }
        #endif
        if isSuppressed || appInFront() != appInFrontAtOpen { collapse("Space changed under a full-screen peek") }
    }

    // MARK: Pointer

    /// Called by the window controller as the pointer moves, with whether it is over
    /// the island and whether it is over the second activity (its bubble, or its icon
    /// folded into the island).
    ///
    /// The second activity is a target of its own: resting on it makes only it react,
    /// and it opens on a click. Were it part of the island's hover, the island would
    /// swell and open by itself as the pointer arrived, swallowing it before it could
    /// be clicked.
    ///
    /// `point` is where the pointer is, in global coordinates, and `buttonsDown` whether
    /// a mouse button is held; only the notch of an island hidden for a full-screen app
    /// looks at them.
    func pointer(inside: Bool, overSecondary: Bool = false, at point: CGPoint? = nil, buttonsDown: Bool = false) {
        if let point { pointerLocation = point }
        if overSecondary != isHoveringSecondary {
            withAnimation(.islandHover) { isHoveringSecondary = overSecondary }
        }
        guard inside != isHovering else {
            if inside { followPointer() }
            if inside, peekWait != .none, mode == .hidden { peek(at: point, buttonsDown: buttonsDown) }
            return
        }
        withAnimation(.islandHover) { isHovering = inside }

        if inside {
            followPointer()
            cancelCollapse()
            if !isExpanded, Prefs.expandOnHover, !isShowingCard {
                if mode != .hidden {
                    scheduleExpand(after: Prefs.hoverDelay)
                } else if opensWhileSuppressed {
                    peek(at: point, buttonsDown: buttonsDown)
                }
            }
        } else {
            cancelExpand()
            if isExpanded { scheduleCollapse(after: 0.28) }
        }
    }

    /// The pointer is on the notch (or the strip standing in for it) while the island
    /// is hidden for a full-screen app. It opens once the pointer has come to rest there
    /// for the hover delay (never less than `fullScreenDwell`), counted from where it
    /// stopped rather than from where it arrived: a pointer sliding along the top edge,
    /// crossing the full-screen menu bar or pushing a game's view north, is passing
    /// however slowly it goes, and every move beyond `restTolerance` starts the wait
    /// again. A drag that reaches the top (selecting upwards so the app scrolls, or
    /// dragging a scrubber) is the app's, and the wait starts only once the button is
    /// let go.
    private func peek(at point: CGPoint?, buttonsDown: Bool) {
        if buttonsDown {
            expandWork?.cancel()
            expandWork = nil
            peekWait = .held
            return
        }
        if case .resting(let rest) = peekWait,
           point.map({ hypot($0.x - rest.x, $0.y - rest.y) <= Self.restTolerance }) ?? true {
            return
        }
        scheduleExpand(after: max(Prefs.hoverDelay, Self.fullScreenDwell))
        peekWait = .resting(at: point ?? .zero)
    }

    /// A click on the island that nothing in it took. Opened, that is a click beside
    /// an indicator's card, which closes it.
    func tap() {
        guard !isExpanded else {
            closeIndicatorCard()
            return
        }
        cancelExpand()
        expand()
    }

    /// A click somewhere other than the island. `onEdgeStrip` says it landed on the
    /// strip that stands in for the island on a display without a notch
    /// (`standsInOnEdge`). For someone who opens the island by clicking, the strip is
    /// drawn to take that click itself, too faint to see (`IslandRootView`); should it
    /// come through to the app all the same, it still opens the island. Opening on
    /// hover, the strip is not drawn and a click there is the app's, which ends the
    /// wait to open like any other click.
    func clickOutside(onEdgeStrip: Bool = false) {
        if onEdgeStrip, !Prefs.expandOnHover, standsInOnEdge {
            tap()
            return
        }
        cancelExpand()
        #if DEBUG
        if isPinnedOpen { return }
        #endif
        if isExpanded { collapse("click outside") }
    }

    func expand(focus: String? = nil) {
        cancelExpand()
        cancelCollapse()
        // Already open, this is a change of page, which a card does not outlast.
        closeIndicatorCard()
        let wasExpanded = isExpanded
        if !wasExpanded { appInFrontAtOpen = appInFront() }
        withAnimation(.islandOpen) {
            self.focus = focus
            isExpanded = true
            // Opened onto a page while the pointer is away, the close it left behind is
            // called off, and nothing waits for it to come back to the room it had.
            if !isHovering { roomUnderPointer = .zero }
        }
        if !wasExpanded {
            Haptics.tap(.alignment)
            NotificationCenter.default.post(name: Self.didOpenNotification, object: self)
        }
    }

    /// `reason` and the caller's place are logged, so an island that seems to close
    /// by itself can be traced to what closed it.
    func collapse(_ reason: StaticString = "requested", file: StaticString = #fileID, line: UInt = #line) {
        cancelExpand()
        cancelCollapse()
        openAcrossSpaceChange = false
        guard isExpanded else { return }
        IslandLog.island.notice("Closed: \(reason, privacy: .public) (\(file, privacy: .public):\(line, privacy: .public))")
        withAnimation(.islandClose) {
            isExpanded = false
            focus = nil
            indicatorCard = nil
            indicatorCardHeights = [:]
            roomUnderPointer = .zero
        }
        homePage = 0
    }

    func select(focus: String) {
        closeIndicatorCard()
        withAnimation(.islandMorph) { self.focus = focus }
    }

    // MARK: Room under the pointer

    /// The opened island's size for content that asks for `size`: never smaller than
    /// the room the pointer is resting in.
    ///
    /// What the opened island shows can get smaller by itself — Now Playing turning
    /// from a song to a video, or closing Up Next as another player takes over; a
    /// meeting or a timer taking the page; a card closing — as well as at a click.
    /// Were the island to shrink with it while the pointer rests in the part given up,
    /// the pointer would be left outside without having moved, and the island would
    /// close as though it had been left. So in whichever direction the pointer is
    /// beyond what the content asks for, the island keeps the size it had, the content
    /// at its top and the rest plain island, until the pointer moves up out of that
    /// room or the island closes; then it springs to the size asked for. A change that
    /// leaves the pointer within what the content asks for (a tab chosen, a panel
    /// closed from its own button) shrinks the island at once. The island hangs centred
    /// on the notch, so width it keeps is kept evenly either side.
    ///
    /// A pointer that moves off the island has the leave grace to come back, and it
    /// must find the island where it left it: were the room to go at once, a brush just
    /// past the edge of the part given up would come back to nothing and the island
    /// would close, where one that is simply that size stays open. So through the grace
    /// all the room is kept, and an island that is not come back to closes from it in
    /// one movement (`scheduleCollapse(after:)`).
    fileprivate func keepingRoom(for size: CGSize) -> CGSize {
        guard isExpanded, roomUnderPointer != .zero else { return size }
        var kept = size
        guard isHovering, let pointer = pointerLocation else {
            kept.height = max(size.height, roomUnderPointer.height)
            kept.width = max(size.width, roomUnderPointer.width)
            return kept
        }
        let bottom = metrics.screenFrame.maxY - metrics.topInset - size.height
        if pointer.y < bottom {
            kept.height = max(size.height, roomUnderPointer.height)
        }
        if abs(pointer.x - metrics.notchMidX) > size.width / 2 {
            kept.width = max(size.width, roomUnderPointer.width)
        }
        return kept
    }

    /// The pointer is over the island, or has just moved off the opened island and the
    /// leave grace is running, the room it rested in kept for it to come back to. The
    /// controller asks, so that an opened island coming to lie under a pointer at rest
    /// has it over it only when the pointer was there to begin with: not when a command
    /// opened the island over a pointer that never came to it.
    var hasPointer: Bool {
        isHovering || roomUnderPointer != .zero
    }

    /// The pointer is over the opened island: keeps `roomUnderPointer` to the island's
    /// size as laid out with the pointer where it is now. A pointer that has moved up
    /// out of room the content no longer asks for gives that room up, and the island
    /// springs to the size its content asks for.
    private func followPointer() {
        guard isExpanded else { return }
        let room = layout.size
        guard room != roomUnderPointer else { return }
        withAnimation(.islandMorph) { roomUnderPointer = room }
    }

    /// Nothing waits for a pointer that has left any more: the island springs to the
    /// size its content asks for.
    private func releaseRoom() {
        guard !isHovering, roomUnderPointer != .zero else { return }
        withAnimation(.islandMorph) { roomUnderPointer = .zero }
    }

    // MARK: Indicator cards

    /// The indicator the open card hangs from: the one it was opened from while that
    /// is shown, or else another showing the same card (the location arrow, once the
    /// camera's dot has gone). `nil` once none is, when the card says so for a moment
    /// and closes (`IndicatorCardOverlay`), or while the island is closed.
    var indicatorCardAnchor: String? {
        guard isExpanded, let card = indicatorCard else { return nil }
        let showing = center.indicators.filter { $0.detail?.id == card.detail.id }
        return showing.first { $0.id == card.indicatorID }?.id ?? showing.first?.id
    }

    /// A click on an indicator in the opened island: opens its card, or closes it if it
    /// is already open under that indicator. Opening one closes any other; one showing
    /// the same card as the open one just moves the card to it.
    func toggleIndicatorCard(id: String) {
        if indicatorCardAnchor == id {
            closeIndicatorCard()
            return
        }
        guard isExpanded, let detail = center.indicators.first(where: { $0.id == id })?.detail else { return }
        withAnimation(.indicatorCard) { indicatorCard = OpenIndicatorCard(indicatorID: id, detail: detail) }
    }

    /// Closes the open card. An island the card lengthened keeps that length while the
    /// pointer rests in it — on the strip beside the card, clicked to close it, or on
    /// its last lines as it goes — as it does whatever else it shows gets shorter
    /// (`keepingRoom(for:)`).
    func closeIndicatorCard() {
        guard indicatorCard != nil else { return }
        withAnimation(.indicatorCard) { indicatorCard = nil }
    }

    /// The card `id` is drawn `height` tall.
    func indicatorCardMeasured(id: String, height: CGFloat) {
        guard indicatorCardHeights[id] != height else { return }
        indicatorCardHeights[id] = height
    }

    /// How tall a card the opened island makes room for under its header: the open
    /// card's height, or zero (`IslandLayout`).
    var indicatorCardRoom: CGFloat {
        indicatorCard.flatMap { indicatorCardHeights[$0.detail.id] } ?? 0
    }

    /// A click on an indicator in the resting or compact island: it opens with that
    /// indicator's card already showing.
    func expand(showingCardOf id: String) {
        expand()
        toggleIndicatorCard(id: id)
    }

    // MARK: File drags

    func fileDrag(began: Bool) {
        isDraggingFile = began
        if !began, focus == Self.dropFocus, !isHovering {
            scheduleCollapse(after: 0.6)
        }
    }

    /// The pointer, mid-drag, came close to the island.
    func fileDragApproached() {
        guard center.dropTarget != nil else { return }
        cancelCollapse()
        if !isExpanded || focus != Self.dropFocus {
            expand(focus: Self.dropFocus)
        } else {
            releaseRoom()
        }
    }

    // MARK: Timers

    /// A card banner is up. Cards can hold buttons (restart a timer, say), so resting
    /// on one must not replace it with the opened island; a click still opens it.
    var isShowingCard: Bool {
        guard case .banner = mode, case .card? = center.banner?.style else { return false }
        return true
    }

    private func scheduleExpand(after delay: TimeInterval) {
        cancelExpand()
        let work = DispatchWorkItem { [weak self] in
            // A card may have arrived while waiting.
            guard let self, self.isHovering, !self.isShowingCard else { return }
            self.expand()
        }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelExpand() {
        expandWork?.cancel()
        expandWork = nil
        peekWait = .none
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        cancelCollapse()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering else { return }
            #if DEBUG
            if self.isPinnedOpen {
                self.releaseRoom()
                return
            }
            #endif
            // The room kept for the pointer goes as the island closes, in the one
            // movement.
            self.collapse("pointer left the island")
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }
}

/// Every size and radius the island needs for its current mode, worked out in one
/// place so the view, the hit-testing and the window agree.
struct IslandLayout: Equatable {
    /// The window's fixed size. The island hangs from its top edge.
    static let canvas = CGSize(width: 680, height: 330)
    static let expandedWidth: CGFloat = 520
    static let homeHeight: CGFloat = 116
    static let expandedInset = EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20)
    static let bubbleGap: CGFloat = 7
    /// How much wider than its notch-sized core the resting pill on a display without a
    /// notch is.
    static let pillWidening: CGFloat = 36
    /// Hidden for a full-screen app on a notched display, the island is tucked this far
    /// inside the camera housing's sides and bottom, with bottom corners at least as
    /// round as the housing's, so no edge of it can show beside the housing.
    static let tuckInset: CGFloat = 2
    static let tuckedRadius: CGFloat = 14
    /// The second activity folded into the island: its circle, inset from the island's
    /// end so it sits concentric with the rounded corner (with room to swell under the
    /// pointer), and the gap between it and the primary's leading content.
    static let foldedDiameter: CGFloat = 20
    static let foldedInset: CGFloat = 4
    static let foldedSpacing: CGFloat = 6
    /// Width of one indicator dot and the gap after it.
    static let indicatorPitch: CGFloat = 11
    /// An indicator dot's diameter; the rest of the pitch is the gap after it, which
    /// a symbol indicator keeps too.
    static let indicatorDot: CGFloat = 7
    static var indicatorGap: CGFloat { indicatorPitch - indicatorDot }
    /// The box an indicator drawn as a symbol (a Focus's) is fitted into: as tall as
    /// a line of small text, and wide enough for a wide symbol (a bed, a car) at that
    /// height, so every symbol takes the same room whatever its shape.
    static let indicatorSymbol = CGSize(width: 14, height: 11)
    /// The bottom corners while an attachment rides under the compact row: rounder
    /// than the compact island's, for an island nearly twice as tall, and still clear
    /// of the row's content.
    static let attachedRadius: CGFloat = 16

    var size: CGSize
    /// Gap above the island: zero when it hangs from a notch, a few points when it
    /// floats on a display without one.
    var topInset: CGFloat = 0
    var earRadius: CGFloat
    var bottomRadius: CGFloat
    /// Convex top corners, for the floating pill. Zero under a notch.
    var topRadius: CGFloat = 0
    /// The camera's gap. Under a notch it is drawn a point wider on each side than
    /// the hardware so no sliver of menu bar shows between the two.
    var notch: CGSize
    /// Compact / banner wing widths either side of the notch. Always equal, so the
    /// island stays centred on the notch — the iPhone's does around its camera. The
    /// trailing wing includes the indicator strip.
    var leadingWidth: CGFloat = 0
    var trailingWidth: CGFloat = 0
    /// The width each side's content asked for, placed at its wing's outer edge;
    /// the difference from the wing is black space next to the notch.
    var leadingContentWidth: CGFloat = 0
    var trailingContentWidth: CGFloat = 0
    /// Width at the right edge given to indicator dots.
    var indicatorWidth: CGFloat = 0
    /// Width at the leading wing's outer end given to the folded second activity (its
    /// circle, and the inset and gap either side), part of `leadingContentWidth`. Zero
    /// unless the bubble has no room beside the island.
    var foldedWidth: CGFloat = 0
    /// A passing row (`IslandViewModel.rowIsPassing`) widens the island too far for
    /// the bubble beside it, and the island takes the runner-up in until the row has
    /// gone, rather than fold it in (see `make(for:)`).
    var takesInBubble = false
    /// Expanded body height below the notch row.
    var bodyHeight: CGFloat = 0
    /// Height of the attachment's row below the notch row; zero without one.
    var attachmentHeight: CGFloat = 0
    /// Width of the attachment's row: the island's body between its ears, as it is at
    /// rest. The pointer's growth leaves it be, so the row does not stretch and settle
    /// again every time the pointer arrives.
    var attachmentWidth: CGFloat = 0
    var bubbleDiameter: CGFloat = 0
    var showsShadow = false
    /// Whether the island is drawn. When it is not, it is fully transparent, and the
    /// window passes clicks where it would be straight through.
    var isDrawn = true

    /// Default width either side of the notch for compact content.
    static func defaultSide(for notch: CGSize) -> CGFloat { notch.height + 12 }

    /// Width at the right edge given to `indicators`: each one's own width and the
    /// gap after it, plus room before the island's rounded end. A row of dots comes
    /// to `indicatorPitch` apiece; a symbol takes its wider box.
    static func indicatorWidth(for indicators: [StatusIndicator]) -> CGFloat {
        guard !indicators.isEmpty else { return 0 }
        return indicators.reduce(6) { width, indicator in
            width + (indicator.symbol == nil ? indicatorDot : indicatorSymbol.width) + indicatorGap
        }
    }

    var foldsSecondary: Bool { foldedWidth > 0 }

    /// Where the folded second activity takes the pointer, in the island's own
    /// coordinates (origin at its top left): the notch row from the island's leading
    /// end to halfway across the gap after the circle. The end beyond the circle counts
    /// as the circle's, so the island's hover growth, which moves the circle outwards,
    /// cannot bounce the pointer between the two.
    var foldedTarget: CGRect {
        guard foldsSecondary else { return .null }
        return CGRect(
            x: 0,
            y: 0,
            width: earRadius + Self.foldedInset + Self.foldedDiameter + Self.foldedSpacing / 2,
            height: notch.height
        )
    }

    /// Where the bubble's centre sits relative to the notch's top centre.
    var bubbleCenterOffset: CGSize {
        CGSize(
            width: size.width / 2 + Self.bubbleGap + bubbleDiameter / 2,
            height: topInset + notch.height / 2
        )
    }

    @MainActor
    static func make(for model: IslandViewModel) -> IslandLayout {
        let metrics = model.metrics
        let floating = !metrics.hasNotch
        var notch = metrics.notchSize
        if !floating { notch.width += 2 }
        let ear: CGFloat = floating ? 0 : 6
        let side = defaultSide(for: notch)
        let hover: CGFloat = model.isHovering ? 1 : 0
        let center = model.center
        // Touch the revision so re-published activity sizes invalidate the layout.
        _ = center.revision
        let dots = indicatorWidth(for: center.indicators)

        var layout = IslandLayout(
            size: CGSize(width: notch.width + 2 * ear, height: notch.height),
            topInset: metrics.topInset,
            earRadius: ear,
            bottomRadius: floating ? notch.height / 2 : 11,
            topRadius: floating ? notch.height / 2 : 0,
            notch: notch,
            bubbleDiameter: notch.height - 4
        )

        /// Rounds the corners; the floating pill rounds its top to match.
        func corners(_ bottom: CGFloat, top: CGFloat? = nil) {
            layout.bottomRadius = bottom
            layout.topRadius = floating ? (top ?? bottom) : 0
        }

        // An attachment rides in a row under compact content. The row spans the
        // island's body, so each wing is at least wide enough for the body to hold it:
        // both alike, keeping the island centred on the notch however wide the row asks
        // to be.
        let attachment = model.attachment
        /// How far either side of the notch a row asks the island's body to reach.
        func wing(for row: IslandAttachment?) -> CGFloat {
            row.map { max(0, ($0.width - notch.width) / 2) } ?? 0
        }
        let attachmentWing = wing(for: attachment)

        /// Lays out content either side of the notch at notch height, both wings as
        /// wide as the wider side asks (or the attachment below them), and makes room
        /// for the attachment's row underneath.
        func wings(leading: CGFloat, trailing: CGFloat, grow: CGFloat) {
            let wing = max(leading, trailing, attachmentWing)
            layout.leadingContentWidth = leading
            layout.trailingContentWidth = trailing
            layout.leadingWidth = wing
            layout.trailingWidth = wing
            layout.attachmentHeight = attachment?.height ?? 0
            layout.attachmentWidth = attachment == nil ? 0 : notch.width + 2 * wing
            layout.size = CGSize(
                width: notch.width + 2 * wing + 2 * ear + 2 * grow,
                height: notch.height + grow / 5 + layout.attachmentHeight
            )
            if attachment != nil {
                // The top keeps the compact island's corners (a floating pill's round
                // ends); only the bottom, now further down, rounds more.
                corners(attachedRadius + grow / 10, top: notch.height / 2)
            } else {
                corners(floating ? layout.size.height / 2 : min(notch.height / 2 - 2, 14) + grow / 10)
            }
        }

        switch model.mode {
        case .hidden:
            if model.opensWhileSuppressed, !floating {
                // Hidden for a full-screen app, yet still opened from the notch: tucked
                // just inside the camera housing, where it cannot be seen, rather than
                // not drawn at all. So the notch takes a click or a swipe as the resting
                // island does, and the island opens out of the notch, and closes back
                // into it, exactly as it does outside full screen.
                layout.size = CGSize(
                    width: metrics.notchSize.width - 2 * tuckInset,
                    height: metrics.notchSize.height - tuckInset
                )
                layout.earRadius = 0
                corners(tuckedRadius)
            } else if model.opensWhileSuppressed {
                // Without a notch there is nowhere to tuck it: not drawn, but kept at
                // the resting pill's size, so it opens from where the pill would be.
                layout.size.width += pillWidening
                layout.isDrawn = false
            } else {
                layout.size = CGSize(width: notch.width * 0.6, height: 0)
                layout.isDrawn = false
            }

        case .idle:
            if dots > 0 {
                layout.indicatorWidth = dots
                wings(leading: 0, trailing: dots, grow: 5 * hover)
            } else if floating {
                // The resting pill, where the user asked for one.
                layout.size.width += pillWidening + 10 * hover
            } else {
                // A little growth under the pointer says "this opens".
                layout.size.width += 14 * hover
                layout.size.height += 3 * hover
                corners(11 + 2 * hover)
            }

        case .compact(let id):
            let activity = center.activity(id: id)
            let leading = activity?.compactLeadingWidth ?? side
            let trailing = (activity?.compactTrailingWidth ?? side) + dots
            layout.indicatorWidth = dots
            if center.secondary != nil {
                // Where the bubble would end with the island at rest, so neither the
                // pointer's hover growth nor the fold's own widening can flip the choice.
                // A row wider than the compact row widens the island, and moves the
                // bubble out with it. The standing row, there as long as its activity,
                // counts; a passing one (the volume, a banner's) does not. Gone in
                // seconds, it would fold the runner-up into the activity's compact
                // content only to take it out again, reshuffling what the row was meant
                // to leave be. Where it pushes the bubble into the status items instead,
                // the island takes the bubble in until the row has gone, as a banner in
                // the island's place does.
                func bubbleEnd(row: IslandAttachment?) -> CGFloat {
                    notch.width / 2 + max(leading, trailing, wing(for: row)) + ear + bubbleGap + layout.bubbleDiameter
                }
                let standing = center.standingAttachment.flatMap { $0.activityID == id ? $0.attachment : nil }
                let passing = model.rowIsPassing
                if bubbleEnd(row: passing ? standing : attachment) > model.menuBarRoomRight - 2 {
                    layout.foldedWidth = foldedInset + foldedDiameter + foldedSpacing
                } else if passing, bubbleEnd(row: attachment) > model.menuBarRoomRight - 2 {
                    layout.takesInBubble = true
                }
            }
            wings(leading: leading + layout.foldedWidth, trailing: trailing, grow: 5 * hover)

        case .banner:
            switch center.banner?.style {
            case .compact(let leading, let trailing):
                wings(leading: leading, trailing: trailing, grow: 0)
            case .card(let width, let height):
                if !floating { layout.earRadius = 9 }
                layout.bodyHeight = height
                layout.size = CGSize(
                    width: (width ?? 400) + 2 * layout.earRadius,
                    height: notch.height + height + expandedInset.bottom
                )
                corners(26, top: 22)
                layout.showsShadow = true
            case nil:
                break
            }

        case .expanded(let focus):
            if !floating { layout.earRadius = 10 }
            let body: CGFloat
            if focus == IslandViewModel.homeFocus {
                body = homeHeight
            } else if focus == IslandViewModel.dropFocus {
                body = center.dropTarget?.expandedHeight ?? homeHeight
            } else if let activity = center.activity(id: focus) {
                body = activity.expandedHeight
            } else {
                body = center.pages[focus]?.height ?? homeHeight
            }
            layout.bodyHeight = body
            // A card taller than the page leaves room for lengthens the island below
            // the page, which keeps its own height.
            let card = IndicatorCardLayout.growth(
                cardHeight: model.indicatorCardRoom, pageHeight: body, notchHeight: notch.height
            )
            // Any room the pointer rests in beyond that is kept, the page keeping its
            // own height at the top.
            layout.size = model.keepingRoom(for: CGSize(
                width: max(expandedWidth, notch.width + 300) + 2 * layout.earRadius,
                height: notch.height + body + expandedInset.bottom + card
            ))
            corners(30, top: 24)
            layout.showsShadow = true
        }

        // Never ask for more than the window can hold.
        layout.size.width = min(layout.size.width, canvas.width - 40)
        layout.size.height = min(layout.size.height, canvas.height - 30)
        return layout
    }
}
