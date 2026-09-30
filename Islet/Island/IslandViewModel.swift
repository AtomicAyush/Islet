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
    /// Posted as an island closes, with its model as the object: for what is kept only
    /// while the island is open (the input box's conversation).
    static let didCloseNotification = Notification.Name("IslandViewModel.didClose")

    var metrics: NotchMetrics
    /// Set by the controller from preferences and the full-screen watcher.
    var showsIdlePill = false
    var isSuppressed = false {
        // Typing ends as a full-screen app takes the display: the app it was typed
        // over is not the one in front any more. Opened over one, it carries on.
        didSet { if isSuppressed, !oldValue { endTyping(.suppressed) } }
    }
    /// While the island is hidden for a full-screen app, the notch still opens it (on
    /// a display without one, a strip along the middle of the top edge). Set by the
    /// manager from preferences.
    var opensFromNotchInFullScreen = false
    /// How far right of the notch's centre the menu bar's first status item begins:
    /// infinity when none does, and 0 when nothing can tell where the items are
    /// (macOS 27 without Accessibility), so the first further activity folds. Set by the
    /// controller; decides how many further activities have bubbles beside the island,
    /// and whether one folds into it.
    var menuBarRoomRight = CGFloat.infinity
    /// How far left of the notch's centre the front app's menus end: infinity on a
    /// display with no menu bar, and 0 until measured, or when nothing can tell (no
    /// Accessibility, or the menus on another display). Set by the controller; decides
    /// how many bubbles fit left of the island.
    var menuBarRoomLeft: CGFloat = 0
    /// How far right of the notch's centre the first of the front app's menus that
    /// reach past it begins (`MenuBarRoom.Menus.roomRight`): infinity when none do, as
    /// usually, or while the bubbles go right of the island only, when the menus are
    /// not looked at. Set by the controller; the bubbles right of the island stop short
    /// of such menus as they do of the status items.
    var menusRoomRight = CGFloat.infinity
    /// Which sides of the island the bubbles go on. Set by the manager from preferences.
    var bubblePlacement = BubblePlacement.bothSides

    /// Something beside the island's own content that takes a click of its own: a
    /// further activity, in its bubble or folded into the island, or the bubble that
    /// counts those with no room.
    enum SecondaryTarget: Hashable {
        case activity(String)
        case overflow
    }

    private(set) var isExpanded = false
    private(set) var isHovering = false
    /// Which further activity the pointer is over, if any: a bubble, the icon folded
    /// into the island, or the count of those left over.
    private(set) var hoveredSecondary: SecondaryTarget?
    /// The pointer is over a further activity rather than the island itself.
    var isHoveringSecondary: Bool { hoveredSecondary != nil }
    /// A file drag is in progress anywhere on screen.
    private(set) var isDraggingFile = false
    /// The tab picked in the expanded island; `nil` follows the primary activity.
    var focus: String?
    /// Which page of home tiles is showing, when they need more than one.
    var homePage = 0
    /// The home page is being arranged (`editHome()`): its tiles wiggle, and drag to new
    /// places or hide rather than do what they usually do, and the island stays open
    /// whatever the pointer does, until Done, Escape, a click outside or a long while
    /// with the pointer away.
    private(set) var isEditingHome = false
    /// Told as arranging the home page begins and ends, so the controller listens for
    /// Escape only meanwhile.
    @ObservationIgnored var editingHomeChanged: (Bool) -> Void = { _ in }
    /// How long the pointer may stay away from an island arranging the home page before
    /// arranging ends and it closes: one opened to arrange by a script, or walked away
    /// from, does not stay open for ever. Tests shorten it.
    @ObservationIgnored var editingIdleTimeout: TimeInterval = 60
    @ObservationIgnored private var editingIdleWork: DispatchWorkItem?
    /// Where something in the island is being typed in, while it is
    /// (`beginTyping(in:client:)`). The island's window has the keyboard meanwhile, and
    /// the island stays open whatever the pointer does, with no time limit, until
    /// typing ends.
    private(set) var typingPlace: TypingPlace?
    var isTyping: Bool { typingPlace != nil }
    /// Goes up each time the field being typed in should take the caret: as typing
    /// begins, and again should it begin again in the same place.
    private(set) var focusRequest = 0
    /// Told as typing begins and ends, so the controller gives the window the keyboard
    /// and hands it back (`IslandKeyboard`).
    @ObservationIgnored var typingChanged: (Bool) -> Void = { _ in }
    @ObservationIgnored private var typingClient: TypingClient?
    /// The page the island was on when typing took it to another, to go back to.
    @ObservationIgnored private var focusBeforeTyping: String?
    /// A menu opened from the opened island is up: one of the header's lists of what it
    /// has no room for, or a right click's. The island stays open meanwhile, whatever
    /// the pointer does (`menu(isUp:)`).
    private(set) var isShowingMenu = false
    /// A menu from the island has gone, and the pointer, left where it went, has not
    /// been back on the island since.
    @ObservationIgnored private var menuLeftPointer = false
    /// How long an island stays open once the pointer is found off it after one of its
    /// menus, for it to come back from where the chosen item was.
    static let menuGrace: TimeInterval = 1.2
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

    /// The page kept open with its Keep Open button (the clipboard's, to drag one item
    /// after another out of it), if any. While the island shows it, the island stays
    /// open whatever the pointer does, dragging out to another app and back or going
    /// off to work in one, until Keep Open is clicked again, Escape, a click on the
    /// notch, another page, the island closing any other way, the Mac sleeping or
    /// locking, or `keepOpenIdleTimeout` with the pointer away. Nothing but the button
    /// sets it, so no link can hold the island open.
    private(set) var keptOpenPage: String?
    /// Told as a page is kept open and let go, so the controller listens for Escape
    /// only meanwhile.
    @ObservationIgnored var keepingOpenChanged: (Bool) -> Void = { _ in }
    /// How long the pointer may stay away from a page kept open, with nothing dragged
    /// from it, before it is let go and the island closes: long enough to drop one
    /// item and work with it before fetching the next, short enough that an island
    /// walked away from does not hang over the screen. Tests shorten it.
    @ObservationIgnored var keepOpenIdleTimeout: TimeInterval = 5 * 60
    @ObservationIgnored private var keepOpenIdleWork: DispatchWorkItem?
    /// A drag that began on the island is under way (a clipboard item, a file off the
    /// shelf, a tile being arranged). The island closes as it leaves, as it always
    /// has, so what it covered can take the drop; kept open, it stays, and its time
    /// away does not start until the drag is let go (`dragOut(began:)`).
    private(set) var isDraggingOut = false

    /// Whether the island stays open whatever the pointer does: kept open on the page
    /// it shows, or, in a debug build, `islet://open?pin=1`.
    var isHeldOpen: Bool {
        #if DEBUG
        if isPinnedOpen { return true }
        #endif
        guard let keptOpenPage else { return false }
        return isExpanded && resolvedFocus == keptOpenPage
    }

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

    /// How the pointer is getting on with a button in the compact row that acts on a
    /// click of its own, like Calendar's Join (see `pointer(onCompactButton:)`).
    private enum CompactButton: Equatable {
        case none
        /// Resting on one, which keeps the island from opening.
        case resting
        /// One was clicked, and the island stays shut until the pointer leaves it: what
        /// the click started (a call's app coming forward) is what was wanted.
        case clicked
    }
    @ObservationIgnored private var compactButton = CompactButton.none

    /// The island was open over a full-screen app when the Space changed, and whether
    /// it closes waits on the full-screen watcher's next look (`spaceDidSettle`).
    @ObservationIgnored private var openAcrossSpaceChange = false
    /// The app in front when the island last opened.
    @ObservationIgnored private var appInFrontAtOpen: pid_t?
    /// Which app is in front. Only a test replaces it.
    @ObservationIgnored var appInFront: () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    /// Opens Settings on one of General's rows, for the island's menus
    /// (`IslandChoice.arrange`). Only a test replaces it.
    @ObservationIgnored var openSettings: @MainActor (GeneralRow) -> Void = { SettingsWindowController.shared.show($0) }

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
        // Opened on nothing in particular, it starts on the activity in front, unless
        // Presentation Mode holds back what that activity's page shows.
        guard let primary = center.primary, !center.holdsBack(primary.personal) else { return Self.homeFocus }
        return primary.id
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

    /// Every ongoing activity after the one the compact island shows, in
    /// `ActivityCenter`'s order; none in any other mode. `IslandLayout` decides where
    /// each goes: a bubble of its own, folded into the island, or counted.
    var otherActivities: [any IslandActivity] {
        guard case .compact = mode else { return [] }
        return Array(center.activities.dropFirst())
    }

    /// The activities in detached bubbles beside the island, in order, while it is
    /// compact and they fit beside it. A banner in the island's place, and the opened
    /// island, absorb them; a banner riding under the activity leaves them be, but for
    /// those its row pushes too far (`IslandLayout.takesInBubble`).
    var bubbleActivities: [any IslandActivity] {
        bubbles.map(\.activity)
    }

    /// Each activity in a detached bubble, in order, with where its bubble is: which
    /// side of the island, and its place in the row on that side, from 0 beside it.
    var bubbles: [(activity: any IslandActivity, place: IslandLayout.BubblePlace)] {
        let layout = self.layout
        return otherActivities.prefix(layout.bubbleCount).enumerated().compactMap { index, activity in
            layout.isBubbleShown(at: index) ? (activity, layout.bubblePlace(at: index)) : nil
        }
    }

    /// The first activity with no bubble, folded into the island's leading wing,
    /// because the menu bar has no room for its bubble, or the bubbles are at their
    /// most.
    var foldedActivity: (any IslandActivity)? {
        let layout = self.layout
        guard layout.foldsSecondary else { return nil }
        return otherActivities.dropFirst(layout.bubbleCount).first
    }

    /// The activities with neither a bubble nor the fold, which the count
    /// (`IslandLayout.overflowCount`) stands for, in order.
    var countedActivities: [any IslandActivity] {
        let layout = self.layout
        return Array(otherActivities.dropFirst(layout.bubbleCount + (layout.foldsSecondary ? 1 : 0)))
    }

    /// Whether the bubble counting the activities with neither a bubble nor the fold
    /// (`IslandLayout.overflowCount`) is beside the island. Without room for it, the
    /// count rides on the folded icon or the last bubble instead.
    var showsOverflowBubble: Bool {
        guard case .compact = mode else { return false }
        let layout = self.layout
        return layout.showsOverflowBubble && !layout.takesInBubble
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
            guard let standing = center.shownStandingAttachment, standing.activityID == id else { return nil }
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
        if isHeldOpen { return }
        if isSuppressed || appInFront() != appInFrontAtOpen { collapse("Space changed under a full-screen peek") }
    }

    // MARK: Pointer

    /// Called by the window controller as the pointer moves, with whether it is over
    /// the island and which further activity it is over, if any (a bubble, the icon
    /// folded into the island, or the count of those left over).
    ///
    /// Each further activity is a target of its own: resting on it makes only it
    /// react, and it opens on a click. Were it part of the island's hover, the island
    /// would swell and open by itself as the pointer arrived, swallowing it before it
    /// could be clicked.
    ///
    /// `point` is where the pointer is, in global coordinates, and `buttonsDown` whether
    /// a mouse button is held; only the notch of an island hidden for a full-screen app
    /// looks at them.
    func pointer(
        inside: Bool, overSecondary: SecondaryTarget? = nil, at point: CGPoint? = nil, buttonsDown: Bool = false
    ) {
        if let point { pointerLocation = point }
        // Back on the island after a menu, or never off it.
        if inside { menuLeftPointer = false }
        if overSecondary != hoveredSecondary {
            withAnimation(.islandHover) { hoveredSecondary = overSecondary }
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
            cancelEditingIdle()
            cancelKeepOpenIdle()
            if !isExpanded, Prefs.expandOnHover, !isShowingCard {
                if mode != .hidden {
                    if compactButton == .none { scheduleExpand(after: Prefs.hoverDelay) }
                } else if opensWhileSuppressed {
                    peek(at: point, buttonsDown: buttonsDown)
                }
            }
        } else {
            compactButton = .none
            cancelExpand()
            // Arranging the home page holds the island open: tiles are dragged about, and
            // a drag that strays past the edge must not close it. Only a long while away
            // ends it.
            if isEditingHome {
                scheduleEditingIdle()
            } else if isTyping {
                // Typing holds it open too, with no time limit: the pointer is often
                // moved out of the way to type.
            } else if isExpanded, !isShowingMenu {
                // One of its menus holds it open while up, and gives the pointer longer
                // to come back as it goes (`menu(isUp:)`).
                scheduleCollapse(after: menuLeftPointer ? Self.menuGrace : 0.28)
            }
        }
    }

    /// What the pointer rests on beside the island moved away, or something else came
    /// under it, without the pointer moving: nothing there is hovered any more, and
    /// whatever is under it now waits for the pointer to move, as anything arriving
    /// under a resting pointer does. The island's own hover is left be.
    func secondaryMovedFromPointer() {
        guard hoveredSecondary != nil else { return }
        withAnimation(.islandHover) { hoveredSecondary = nil }
    }

    /// The pointer came onto a button in the compact row that acts on a click of its
    /// own (Calendar's Join), or left it. Resting there does not open the island, as
    /// resting anywhere else on it does: that would take the button away before it
    /// could be clicked. Moving on to the rest of the island starts the wait to open,
    /// as arriving would. The button says so as it goes, too, since a view taken away
    /// under the pointer may never hear it leave.
    func pointer(onCompactButton isOn: Bool) {
        if isOn {
            if compactButton == .none { compactButton = .resting }
            cancelExpand()
        } else if compactButton == .resting {
            compactButton = .none
            if isHovering, !isExpanded, Prefs.expandOnHover, !isShowingCard, mode != .hidden {
                scheduleExpand(after: Prefs.hoverDelay)
            }
        }
    }

    /// A button in the compact row did what it is for. The island stays shut until the
    /// pointer has left it.
    func compactButtonClicked() {
        compactButton = .clicked
        cancelExpand()
    }

    /// A right-click on the compact island's own row brought up its menu. Shut, it
    /// stays shut until the pointer has left it, as after a click on a button in the
    /// compact row: the menu is what was wanted, and resting on the island meanwhile
    /// must not open it. Only when there is a menu: a right-click on the idle notch or
    /// a banner brings none up, and leaves hover to open the island as ever. A bubble's
    /// menu leaves the island be, since resting on a bubble never opens it. The window
    /// controller tells it only of right-clicks on the row, not a row riding under it.
    func menuOpened() {
        guard !isExpanded, isHovering, !compactChoices.isEmpty else { return }
        compactButtonClicked()
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
    /// an indicator's card, which closes it; on the notch (`onNotch`), it also lets go
    /// of a page kept open.
    func tap(onNotch: Bool = false) {
        guard !isExpanded else {
            closeIndicatorCard()
            if onNotch { endKeepingOpen() }
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
        endTyping(.clickOutside)
        if isHeldOpen || isDraggingOut { return }
        if isExpanded { collapse("click outside") }
    }

    func expand(focus: String? = nil) {
        cancelExpand()
        cancelCollapse()
        endTyping(leaving: focus)
        // Another page takes the island away from the home page being arranged, or
        // from a page kept open.
        if focus != Self.homeFocus { stopEditingHome() }
        if focus != keptOpenPage { stopKeepingOpen() }
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
        if case .page = typingPlace { endTyping(.collapse) }
        IslandLog.island.notice("Closed: \(reason, privacy: .public) (\(file, privacy: .public):\(line, privacy: .public))")
        let wasEditing = isEditingHome
        let wasKeepingOpen = keptOpenPage != nil
        withAnimation(.islandClose) {
            isExpanded = false
            focus = nil
            indicatorCard = nil
            indicatorCardHeights = [:]
            roomUnderPointer = .zero
            isEditingHome = false
            keptOpenPage = nil
        }
        homePage = 0
        cancelEditingIdle()
        cancelKeepOpenIdle()
        menuLeftPointer = false
        if wasEditing { editingHomeChanged(false) }
        if wasKeepingOpen { keepingOpenChanged(false) }
        NotificationCenter.default.post(name: Self.didCloseNotification, object: self)
    }

    /// A menu came up in Islet, or went. One that comes up with the pointer on the
    /// opened island is the island's: the header's lists of what it has no room for,
    /// or a right click's. It can reach well below the island, and while it is up the
    /// pointer's moves are the menu's and never seen here, so the island stays open
    /// meanwhile. As it goes, the pointer is left where the chosen item was, likely
    /// off the island: leaving from there closes the island only after `menuGrace`,
    /// time enough to come back to what was chosen, rather than at once.
    func menu(isUp: Bool) {
        if isUp {
            guard isExpanded, isHovering, !isShowingMenu else { return }
            cancelCollapse()
            isShowingMenu = true
        } else {
            guard isShowingMenu else { return }
            isShowingMenu = false
            menuLeftPointer = true
            if isExpanded, !isHovering, !isEditingHome { scheduleCollapse(after: Self.menuGrace) }
        }
    }

    func select(focus: String) {
        endTyping(leaving: focus)
        closeIndicatorCard()
        if focus != Self.homeFocus { stopEditingHome() }
        if focus != keptOpenPage { stopKeepingOpen() }
        withAnimation(.islandMorph) { self.focus = focus }
    }

    // MARK: Keeping a page open

    /// Keep Open, clicked on `page`, which the island is showing: keeps the island open
    /// on it, or, kept open already, lets it go, and the island closes as the pointer
    /// next leaves it, as any open island does.
    func toggleKeepingOpen(_ page: String) {
        if keptOpenPage == page {
            stopKeepingOpen()
            return
        }
        guard isExpanded, resolvedFocus == page else { return }
        cancelCollapse()
        // Held on the page, so an activity starting does not take it over.
        focus = page
        keptOpenPage = page
        if !isHovering { scheduleKeepOpenIdle() }
        keepingOpenChanged(true)
    }

    /// Lets go of the page kept open, for Escape, a click on the notch, the Mac sleeping
    /// or locking, or a long while away. An island the pointer has left closes now,
    /// after the grace it would have had.
    func endKeepingOpen() {
        guard keptOpenPage != nil else { return }
        stopKeepingOpen()
        if isExpanded, !isHovering, !isDraggingOut { scheduleCollapse(after: 0.28) }
    }

    /// Lets go of the page kept open, leaving the island open as it would be without it.
    private func stopKeepingOpen() {
        guard keptOpenPage != nil else { return }
        cancelKeepOpenIdle()
        keptOpenPage = nil
        keepingOpenChanged(false)
    }

    /// Lets go of the page kept open, and so closes the island, once the pointer has
    /// been away for `keepOpenIdleTimeout` with nothing dragged from it.
    private func scheduleKeepOpenIdle() {
        cancelKeepOpenIdle()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.keptOpenPage != nil, !self.isHovering, !self.isDraggingOut else { return }
            self.keepOpenIdleWork = nil
            self.endKeepingOpen()
        }
        keepOpenIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + keepOpenIdleTimeout, execute: work)
    }

    private func cancelKeepOpenIdle() {
        keepOpenIdleWork?.cancel()
        keepOpenIdleWork = nil
    }

    // MARK: Arranging the home page

    /// Opens the island on the home page, if it is not open there already, to arrange
    /// its tiles: from the home page's menu, or `islet://open?edit=1`. Until Done,
    /// Escape or a click outside, the island stays open wherever the pointer goes, but
    /// for a long while away (`editingIdleTimeout`).
    func editHome() {
        cancelCollapse()
        closeIndicatorCard()
        if !isExpanded {
            expand(focus: Self.homeFocus)
        } else if resolvedFocus != Self.homeFocus {
            select(focus: Self.homeFocus)
        } else {
            // Pinned on the home page, so an activity starting does not take it over.
            focus = Self.homeFocus
        }
        guard !isEditingHome else { return }
        withAnimation(.islandMorph) { isEditingHome = true }
        if !isHovering { scheduleEditingIdle() }
        editingHomeChanged(true)
    }

    /// Done arranging the home page, with Done or Escape. An island the pointer left
    /// meanwhile closes now, after the grace it would have had.
    func endEditingHome() {
        guard isEditingHome else { return }
        stopEditingHome()
        if isExpanded, !isHovering { scheduleCollapse(after: 0.28) }
    }

    /// Stops arranging the home page as another page takes the island, which stays open
    /// as it would for that page.
    private func stopEditingHome() {
        guard isEditingHome else { return }
        cancelEditingIdle()
        withAnimation(.islandMorph) { isEditingHome = false }
        editingHomeChanged(false)
    }

    /// Ends arranging, and so closes the island, once the pointer has been away for
    /// `editingIdleTimeout`.
    private func scheduleEditingIdle() {
        cancelEditingIdle()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isEditingHome, !self.isHovering else { return }
            self.editingIdleWork = nil
            self.endEditingHome()
        }
        editingIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + editingIdleTimeout, execute: work)
    }

    private func cancelEditingIdle() {
        editingIdleWork?.cancel()
        editingIdleWork = nil
    }

    // MARK: Typing

    /// The person asked to type in this island — pressed the shortcut, clicked a field,
    /// or a tile that opens one — so its window takes the keyboard, and a page to type
    /// in is opened. Nothing else begins typing: not the pointer resting on the island,
    /// a banner, an `islet://` URL (which any app or web page can open) or an activity.
    /// The client is told of the island's own key equivalents and of typing ending.
    func beginTyping(in place: TypingPlace, client: TypingClient) {
        if let typingPlace, typingPlace != place { endTyping(.otherPage) }
        if case .page(let id) = place {
            if !isExpanded {
                focusBeforeTyping = nil
                expand(focus: id)
            } else if resolvedFocus != id {
                focusBeforeTyping = resolvedFocus
                select(focus: id)
            }
        }
        cancelCollapse()
        closeIndicatorCard()
        let begins = typingPlace == nil
        typingPlace = place
        typingClient = client
        if begins { typingChanged(true) }
        focusRequest &+= 1
    }

    /// Typing ends, the window hands the keyboard back, and the client forgets what was
    /// typed. Unless the island is already going elsewhere, it leaves the page typed in:
    /// back to the page it was on, or home, with the pointer on it, and closed without.
    func endTyping(_ reason: TypingEnd) {
        guard let place = typingPlace else { return }
        typingPlace = nil
        let client = typingClient
        typingClient = nil
        let back = focusBeforeTyping
        focusBeforeTyping = nil
        IslandLog.island.notice("Typing ended: \(reason.rawValue, privacy: .public)")
        typingChanged(false)
        client?.ended(reason)

        guard case .page(let id) = place, client?.leavesPage ?? true, isExpanded, resolvedFocus == id else { return }
        switch reason {
        case .otherPage, .collapse, .clickOutside, .invalidated:
            return
        default:
            break
        }
        if isHovering {
            select(focus: back ?? Self.homeFocus)
        } else {
            collapse("typing ended")
        }
    }

    /// One of the island's own key equivalents, pressed while it has the keyboard.
    func keyAction(_ action: IslandKeyAction) {
        typingClient?.key(action)
    }

    /// The island is going to another page (`nil`: whatever it would show), which ends
    /// typing in the page it leaves.
    private func endTyping(leaving focus: String?) {
        guard case .page(let id) = typingPlace, focus != id else { return }
        endTyping(.otherPage)
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

    /// A drag that began on the island started (`began`) or was let go, wherever it
    /// went. Kept open, the island stays under it and its time away waits for the
    /// drop; otherwise it closes as the drag leaves it, and let go with the pointer
    /// away, it closes if it has not already.
    func dragOut(began: Bool) {
        guard began != isDraggingOut else { return }
        isDraggingOut = began
        if began {
            cancelKeepOpenIdle()
        } else if isExpanded, !isHovering, !isEditingHome, !isShowingMenu {
            scheduleCollapse(after: 0.28)
        }
    }

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
            // A card may have arrived while waiting, or the pointer moved on to a button
            // that keeps the island shut.
            guard let self, self.isHovering, !self.isShowingCard, self.compactButton == .none else { return }
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
        guard !isTyping else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering, !self.isEditingHome, !self.isShowingMenu, !self.isTyping else { return }
            if self.isHeldOpen {
                self.releaseRoom()
                // Held open where it would have closed: a long while away lets it go.
                if self.keptOpenPage != nil { self.scheduleKeepOpenIdle() }
                return
            }
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
    /// The most further activities beside the island in bubbles of their own. One more
    /// folds into the island, and any beyond that are counted.
    static let maxBubbles = 4
    /// How far short of the window's edge the bubbles stop at rest: the island's hover
    /// growth moves them out by 5, and a hovered bubble swells by 2 more, and neither
    /// may be cut off.
    static let windowEdgeClearance: CGFloat = 7
    /// How far short of the front app's menus the bubbles stop at rest: the 2 they keep
    /// from the status items, and the 5 the island's hover growth moves them out by, so
    /// they stay clear of the menu titles with the island hovered too.
    static let menusClearance: CGFloat = 7
    /// The count of the activities with no room, where it rides on the folded icon or
    /// the last bubble: a small capsule at the circle's bottom trailing corner.
    static let badgeSize = CGSize(width: 15, height: 10)
    /// How much wider than its notch-sized core the resting pill on a display without a
    /// notch is.
    static let pillWidening: CGFloat = 36
    /// Hidden for a full-screen app on a notched display, the island is tucked this far
    /// inside the camera housing's sides and bottom, with bottom corners at least as
    /// round as the housing's, so no edge of it can show beside the housing.
    static let tuckInset: CGFloat = 2
    static let tuckedRadius: CGFloat = 14
    /// A further activity folded into the island: its circle, inset from the island's
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
    /// The resting island under a notch: its ears, and its bottom corners. At rest it
    /// stands in for the camera housing, and a coloured island keeps a black shape of
    /// exactly this size at its top (`IslandRootView`'s notch plate).
    static let restingEar: CGFloat = 6
    static let restingRadius: CGFloat = 11
    /// How long a coloured island keeps its colour once it has nothing to show: long
    /// enough for it to shrink back to the notch's size, where the plate covers it,
    /// before it turns black again.
    static let colourHold: Duration = .milliseconds(600)

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
    /// Width at the leading wing's outer end given to the folded further activity (its
    /// circle, and the inset and gap either side), part of `leadingContentWidth`. Zero
    /// unless one has no room for its bubble beside the island.
    var foldedWidth: CGFloat = 0
    /// How many further activities have bubbles beside the island, in order, as the
    /// island is at rest (see `make(for:)`). The one folded in, if any, is the next.
    var bubbleCount = 0
    /// How many of those bubbles are beside the island now: fewer than `bubbleCount`
    /// while a passing row takes the outermost of them in.
    var bubblesShown = 0
    /// How many of the bubbles are left of the island, the rest being right of it
    /// (`bubblePlace(at:)`): none unless there is room there and both sides are wanted.
    var leftBubbleCount = 0
    /// How many of those are beside the island now.
    var leftBubblesShown = 0
    var rightBubbleCount: Int { bubbleCount - leftBubbleCount }
    /// How many further activities have neither a bubble nor the fold, which a small
    /// bubble after the others counts, or, with no room for it, the folded icon.
    var overflowCount = 0
    /// Whether the count of those left over has a bubble of its own. Without one, it
    /// rides on the folded icon, or, with nothing folded, on the last bubble.
    var showsOverflowBubble = false
    /// The count's own bubble is left of the island, after the bubbles there, rather
    /// than right of it (`overflowPlace`).
    var overflowOnLeft = false
    /// The count rides on the folded icon.
    var badgesFolded: Bool { overflowCount > 0 && !showsOverflowBubble && foldsSecondary }
    /// The count rides on the last bubble, while that bubble is beside the island.
    var badgesLastBubble: Bool {
        overflowCount > 0 && !showsOverflowBubble && !foldsSecondary && bubbleCount > 0 && isBubbleShown(at: bubbleCount - 1)
    }
    /// A passing row (`IslandViewModel.rowIsPassing`) widens the island too far for
    /// some of the bubbles beside it, and the island takes them in until the row has
    /// gone, rather than fold one in (see `make(for:)`).
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
    /// The bubble counting the activities left over is a little smaller than theirs.
    var overflowDiameter: CGFloat { max(16, bubbleDiameter - 6) }
    var showsShadow = false
    /// Whether the island is drawn. When it is not, it is fully transparent, and the
    /// window passes clicks where it would be straight through.
    var isDrawn = true
    /// Whether the island is painted in the chosen colour. Under a notch the resting
    /// island (hidden, idle, with indicators or under the pointer) is the notch, and
    /// stays black; whenever it shows something it takes the colour. Without a notch it
    /// always does, the resting pill included.
    var wearsColour = true

    /// How much room a ring round the island has inside its edge before it would reach
    /// what the island shows. Opened, and in a card banner, content keeps 16 points or
    /// more from the edge; in a row beside the notch, it comes within a few.
    var ringRoom: IslandRingRoom {
        bodyHeight > 0 ? IslandRingRoom(band: 3.5, glow: 6) : IslandRingRoom(band: 2, glow: 2)
    }

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

    /// The notch's gap in the island's own coordinates (origin at its top left),
    /// where a click lets go of a page kept open (`IslandViewModel.tap(onNotch:)`).
    var notchTarget: CGRect {
        CGRect(x: (size.width - notch.width) / 2, y: 0, width: notch.width, height: notch.height)
    }

    /// Where the folded activity takes the pointer, in the island's own coordinates
    /// (origin at its top left): the notch row from the island's leading end to halfway
    /// across the gap after the circle. The end beyond the circle counts as the
    /// circle's, so the island's hover growth, which moves the circle outwards, cannot
    /// bounce the pointer between the two. The count riding on it, if any, is a target
    /// of its own (`foldedBadgeRect`).
    var foldedTarget: CGRect {
        guard foldsSecondary else { return .null }
        return CGRect(
            x: 0,
            y: 0,
            width: earRadius + Self.foldedInset + Self.foldedDiameter + Self.foldedSpacing / 2,
            height: notch.height
        )
    }

    /// How far past the folded circle's bottom trailing corner the count riding on it
    /// sits: out beyond the circle, and inside the island's bottom edge, however low
    /// the island is.
    var foldedBadgeOffset: CGSize {
        CGSize(width: 5, height: min(4, (notch.height - Self.foldedDiameter) / 2 - 1))
    }

    /// Where the count riding on the folded icon is, in the island's own coordinates;
    /// null when it rides elsewhere or there is none.
    var foldedBadgeRect: CGRect {
        guard badgesFolded else { return .null }
        let corner = CGPoint(
            x: earRadius + Self.foldedInset + Self.foldedDiameter + foldedBadgeOffset.width,
            y: (notch.height + Self.foldedDiameter) / 2 + foldedBadgeOffset.height
        )
        return CGRect(
            x: corner.x - Self.badgeSize.width, y: corner.y - Self.badgeSize.height,
            width: Self.badgeSize.width, height: Self.badgeSize.height
        )
    }

    /// How far past the last bubble's bottom outer corner the count riding on it sits:
    /// no further out than the bubble, which may end just short of the status items (or,
    /// left of the island, the menus), and a point below it.
    static let bubbleBadgeOffset = CGSize(width: 0, height: 1)

    /// Where the count riding on the last bubble is, relative to the notch's top
    /// centre (x rightwards, y downwards); null when it rides elsewhere or there is none.
    /// It sits at the bubble's bottom corner away from the island: the trailing one
    /// right of it, the leading one left of it.
    var bubbleBadgeRect: CGRect {
        guard badgesLastBubble else { return .null }
        let last = bubblePlace(at: bubbleCount - 1)
        let center = bubbleCenterOffset(at: CGFloat(last.slot), side: last.side)
        let outer = bubbleDiameter / 2 + Self.bubbleBadgeOffset.width
        return CGRect(
            x: last.side == .left ? center.width - outer : center.width + outer - Self.badgeSize.width,
            y: center.height + bubbleDiameter / 2 + Self.bubbleBadgeOffset.height - Self.badgeSize.height,
            width: Self.badgeSize.width, height: Self.badgeSize.height
        )
    }

    /// Which side of the island a bubble is on.
    enum Side: Hashable {
        case right, left
    }

    /// Where a bubble is: which side of the island, and its place in the row there,
    /// from 0 beside the island.
    struct BubblePlace: Equatable {
        var side: Side
        var slot: Int
    }

    /// The side each of `count` bubbles goes on, in order, with room for `right` of them
    /// right of the island and `left` left of it: right, then left, then right again,
    /// and once one side is full, the rest on the other. So the first always has the
    /// place right of the island it has on its own, wherever there is room for it.
    static func sides(count: Int, right: Int, left: Int) -> [Side] {
        var onRight = 0, onLeft = 0
        return (0..<count).map { index in
            let goesRight = index.isMultiple(of: 2) ? onRight < right : onLeft >= left
            if goesRight { onRight += 1 } else { onLeft += 1 }
            return goesRight ? .right : .left
        }
    }

    /// Where the bubble of the further activity at `index` (in order, from 0) is.
    func bubblePlace(at index: Int) -> BubblePlace {
        let sides = Self.sides(count: bubbleCount, right: rightBubbleCount, left: leftBubbleCount)
        guard sides.indices.contains(index) else { return BubblePlace(side: .right, slot: index) }
        let side = sides[index]
        return BubblePlace(side: side, slot: sides[..<index].filter { $0 == side }.count)
    }

    /// Whether the bubble of the further activity at `index` is beside the island now:
    /// a passing row takes in the outermost on each side first.
    func isBubbleShown(at index: Int) -> Bool {
        guard index >= 0, index < bubbleCount else { return false }
        let place = bubblePlace(at: index)
        return place.slot < (place.side == .left ? leftBubblesShown : bubblesShown - leftBubblesShown)
    }

    /// Where the bubble counting the activities left over is: after the bubbles on its side.
    var overflowPlace: BubblePlace {
        overflowOnLeft
            ? BubblePlace(side: .left, slot: leftBubbleCount)
            : BubblePlace(side: .right, slot: rightBubbleCount)
    }

    /// Where the centre of the bubble in `slot` on `side` sits relative to the notch's
    /// top centre: the first beside the island, each next one a bubble and a gap further
    /// out. A fractional slot is on its way between two.
    func bubbleCenterOffset(at slot: CGFloat, side: Side = .right) -> CGSize {
        let out = size.width / 2 + Self.bubbleGap + bubbleDiameter / 2 + slot * (bubbleDiameter + Self.bubbleGap)
        return CGSize(width: side == .left ? -out : out, height: topInset + notch.height / 2)
    }

    /// Where the centre of the bubble counting the activities left over sits relative
    /// to the notch's top centre: in the slot after the last of the others on its side,
    /// its smaller circle a gap from theirs.
    func overflowCenterOffset(at slot: CGFloat, side: Side = .right) -> CGSize {
        let out = size.width / 2 + Self.bubbleGap + overflowDiameter / 2 + slot * (bubbleDiameter + Self.bubbleGap)
        return CGSize(width: side == .left ? -out : out, height: topInset + notch.height / 2)
    }

    /// Where the further activities go, given how far right of the island at rest the
    /// bubbles may reach (`room`) and how far with one folded in, which can widen it
    /// (`roomFolded`), and the same left of it (`leftRoom`, `leftRoomFolded`; none
    /// unless both sides are wanted). Every one of them has a bubble when there are no
    /// more than `maxBubbles` and they all fit, right, left, right and so on
    /// (`sides(count:right:left:)`). Otherwise as many as fit on both sides together
    /// (no more than `maxBubbles`) have bubbles, and the first to miss out folds into
    /// the island, so long as that costs none of those bubbles, nor moves one to the
    /// other side: the fold widens the island, and moves them all out. Any left over
    /// are counted, in a bubble of their own after the others on the side whose turn is
    /// next, or the other if it fits only there, or else on the folded icon, or, with
    /// nothing folded, on the last bubble.
    ///
    /// So the fold never takes a bubble away: the activity after the island has the
    /// bubble right of it that it would have were only the two of them running,
    /// whenever there is room. Where something on the menu bar leaves no room for it
    /// there (a status item, or the pill macOS shows while the screen is shared), it
    /// goes left of the island if that side has room, and folds in only if neither
    /// has, as with bubbles right of the island only.
    struct Bubbles: Equatable {
        var count = 0
        var folds = false
        var overflow = 0
        var overflowBubble = false
        /// How many of the bubbles are left of the island.
        var left = 0
        /// The count's bubble is left of the island.
        var overflowLeft = false
    }

    static func arrangeBubbles(
        others: Int, room: CGFloat, roomFolded: CGFloat, leftRoom: CGFloat = 0, leftRoomFolded: CGFloat = 0,
        diameter: CGFloat, overflowDiameter: CGFloat
    ) -> Bubbles {
        let pitch = diameter + bubbleGap
        guard others > 0 else { return Bubbles() }
        func capacity(_ room: CGFloat) -> Int {
            var count = maxBubbles
            while count > 0, CGFloat(count) * pitch > room { count -= 1 }
            return count
        }
        /// How many of `most` have bubbles, and how many of those go left.
        func fitting(_ most: Int, right: CGFloat, left: CGFloat) -> (count: Int, left: Int) {
            let onRight = capacity(right), onLeft = capacity(left)
            let count = min(maxBubbles, most, onRight + onLeft)
            return (count, sides(count: count, right: onRight, left: onLeft).filter { $0 == .left }.count)
        }
        /// Which side the count's bubble goes on after `placed`, if either has room for it.
        func countSide(after placed: (count: Int, left: Int), right: CGFloat, left: CGFloat) -> Side? {
            func fits(after count: Int, in room: CGFloat) -> Bool {
                CGFloat(count) * pitch + bubbleGap + overflowDiameter <= room
            }
            let fitsRight = fits(after: placed.count - placed.left, in: right)
            let fitsLeft = fits(after: placed.left, in: left)
            // The side whose turn it is, right after an even number of bubbles.
            if placed.count.isMultiple(of: 2) { return fitsRight ? .right : fitsLeft ? .left : nil }
            return fitsLeft ? .left : fitsRight ? .right : nil
        }
        let unfolded = fitting(others, right: room, left: leftRoom)
        if unfolded.count == others { return Bubbles(count: others, left: unfolded.left) }
        let folded = fitting(others - 1, right: roomFolded, left: leftRoomFolded)
        if folded.count >= unfolded.count, folded.left == unfolded.left {
            let overflow = others - 1 - folded.count
            let side = overflow > 0 ? countSide(after: folded, right: roomFolded, left: leftRoomFolded) : nil
            return Bubbles(
                count: folded.count, folds: true, overflow: overflow, overflowBubble: side != nil,
                left: folded.left, overflowLeft: side == .left
            )
        }
        let side = countSide(after: unfolded, right: room, left: leftRoom)
        return Bubbles(
            count: unfolded.count, folds: false, overflow: others - unfolded.count, overflowBubble: side != nil,
            left: unfolded.left, overflowLeft: side == .left
        )
    }

    @MainActor
    static func make(for model: IslandViewModel) -> IslandLayout {
        let metrics = model.metrics
        let floating = !metrics.hasNotch
        var notch = metrics.notchSize
        if !floating { notch.width += 2 }
        let ear: CGFloat = floating ? 0 : restingEar
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
            bottomRadius: floating ? notch.height / 2 : restingRadius,
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
                corners(restingRadius + 2 * hover)
            }

        case .compact(let id):
            let activity = center.activity(id: id)
            let leading = activity?.compactLeadingWidth ?? side
            let trailing = (activity?.compactTrailingWidth ?? side) + dots
            layout.indicatorWidth = dots
            let others = center.activities.count - 1
            if others > 0 {
                // Where the bubbles would end with the island at rest, so neither the
                // pointer's hover growth nor the fold's own widening can flip the choice.
                // A row wider than the compact row widens the island, and moves the
                // bubbles out with it. The standing row, there as long as its activity,
                // counts; a passing one (the volume, a banner's) does not. Gone in
                // seconds, it would fold a further activity into the activity's compact
                // content only to take it out again, reshuffling what the row was meant
                // to leave be. Where it pushes bubbles into the status items instead,
                // the island takes those in until the row has gone, as a banner in the
                // island's place does. Nor do the bubbles reach so near the window's edge
                // that the island's hover growth could push one past it.
                // Left of the island, the bubbles stop short of the front app's menus, as
                // right of it they stop short of the status items, and of any menus that
                // reach past the notch.
                let fold = foldedInset + foldedDiameter + foldedSpacing
                let edge = canvas.width / 2 - windowEdgeClearance
                let limit = min(model.menuBarRoomRight - 2, model.menusRoomRight - menusClearance, edge)
                let leftLimit = model.bubblePlacement == .bothSides ? min(model.menuBarRoomLeft - menusClearance, edge) : 0
                func islandEnd(row: IslandAttachment?, folded: Bool) -> CGFloat {
                    notch.width / 2 + max(leading + (folded ? fold : 0), trailing, wing(for: row)) + ear
                }
                let standing = center.shownStandingAttachment.flatMap { $0.activityID == id ? $0.attachment : nil }
                let passing = model.rowIsPassing
                let resting = passing ? standing : attachment
                let bubbles = arrangeBubbles(
                    others: others,
                    room: limit - islandEnd(row: resting, folded: false),
                    roomFolded: limit - islandEnd(row: resting, folded: true),
                    leftRoom: leftLimit - islandEnd(row: resting, folded: false),
                    leftRoomFolded: leftLimit - islandEnd(row: resting, folded: true),
                    diameter: layout.bubbleDiameter,
                    overflowDiameter: layout.overflowDiameter
                )
                if bubbles.folds { layout.foldedWidth = fold }
                layout.bubbleCount = bubbles.count
                layout.bubblesShown = bubbles.count
                layout.leftBubbleCount = bubbles.left
                layout.leftBubblesShown = bubbles.left
                layout.overflowCount = bubbles.overflow
                layout.showsOverflowBubble = bubbles.overflowBubble
                layout.overflowOnLeft = bubbles.overflowLeft
                if passing {
                    // On each side, the outermost bubbles the row pushes too far.
                    let end = islandEnd(row: attachment, folded: bubbles.folds)
                    let room = limit - end, leftRoom = leftLimit - end
                    let pitch = layout.bubbleDiameter + bubbleGap
                    var right = layout.rightBubbleCount, left = layout.leftBubbleCount
                    while right > 0, CGFloat(right) * pitch > room { right -= 1 }
                    while left > 0, CGFloat(left) * pitch > leftRoom { left -= 1 }
                    layout.bubblesShown = right + left
                    layout.leftBubblesShown = left
                    let count = layout.overflowPlace
                    let overflowEnd = CGFloat(count.slot) * pitch + bubbleGap + layout.overflowDiameter
                    layout.takesInBubble = layout.bubblesShown < bubbles.count
                        || (bubbles.overflowBubble && overflowEnd > (count.side == .left ? leftRoom : room))
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

        switch model.mode {
        case .hidden, .idle: layout.wearsColour = floating
        case .compact, .banner, .expanded: break
        }

        // Never ask for more than the window can hold.
        layout.size.width = min(layout.size.width, canvas.width - 40)
        layout.size.height = min(layout.size.height, canvas.height - 30)
        return layout
    }
}
