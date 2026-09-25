import SwiftUI
import Observation

/// What one island window is showing and how big it is. There is one of these per
/// window; they all render the same `ActivityCenter`, but each has its own pointer,
/// hover and expanded state.
@MainActor
@Observable
final class IslandViewModel {
    enum Mode: Equatable {
        /// Nothing drawn at all (a plain display with nothing to show, or a
        /// full-screen app on this display).
        case hidden
        /// The resting notch.
        case idle
        /// An activity either side of the notch.
        case compact(id: String)
        /// A transient alert.
        case banner(id: String)
        /// Opened, showing the home page, an activity, or the drop zone.
        case expanded(focus: String)
    }

    static let homeFocus = "home"
    static let dropFocus = "drop"

    var metrics: NotchMetrics
    /// Set by the controller from preferences and the full-screen watcher.
    var showsIdlePill = false
    var isSuppressed = false

    private(set) var isExpanded = false
    private(set) var isHovering = false
    /// A file drag is in progress anywhere on screen.
    private(set) var isDraggingFile = false
    /// The tab picked in the expanded island; `nil` follows the primary activity.
    var focus: String?

    #if DEBUG
    /// Keeps the island open whatever the pointer does, for screenshots
    /// (`islet://open?pin=1`; `islet://close` releases it).
    var isPinnedOpen = false
    #endif

    let center = ActivityCenter.shared

    @ObservationIgnored private var expandWork: DispatchWorkItem?
    @ObservationIgnored private var collapseWork: DispatchWorkItem?

    init(metrics: NotchMetrics) {
        self.metrics = metrics
    }

    // MARK: Mode

    var mode: Mode {
        if isExpanded { return .expanded(focus: resolvedFocus) }
        if isSuppressed { return .hidden }
        if let banner = center.banner { return .banner(id: banner.id) }
        if let primary = center.primary { return .compact(id: primary.id) }
        return metrics.hasNotch || showsIdlePill ? .idle : .hidden
    }

    var resolvedFocus: String {
        if let focus {
            if focus == Self.homeFocus { return focus }
            if focus == Self.dropFocus, center.dropTarget != nil { return focus }
            if center.activity(id: focus) != nil { return focus }
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

    /// The activity in the detached bubble: the runner-up, while the island is
    /// compact. Banners and the opened island absorb it.
    var bubbleActivity: (any IslandActivity)? {
        guard case .compact = mode else { return nil }
        return center.secondary
    }

    // MARK: Layout

    var layout: IslandLayout {
        IslandLayout.make(for: self)
    }

    // MARK: Pointer

    /// Called by the window controller as the pointer crosses the island's edge.
    func pointer(inside: Bool) {
        guard inside != isHovering else { return }
        withAnimation(.islandHover) { isHovering = inside }

        if inside {
            cancelCollapse()
            if !isExpanded, Prefs.expandOnHover, mode != .hidden {
                scheduleExpand(after: Prefs.hoverDelay)
            }
        } else {
            cancelExpand()
            if isExpanded { scheduleCollapse(after: 0.28) }
        }
    }

    func tap() {
        guard !isExpanded else { return }
        cancelExpand()
        expand()
    }

    /// A click somewhere other than the island.
    func clickOutside() {
        cancelExpand()
        #if DEBUG
        if isPinnedOpen { return }
        #endif
        if isExpanded { collapse() }
    }

    func expand(focus: String? = nil) {
        cancelExpand()
        cancelCollapse()
        let wasExpanded = isExpanded
        withAnimation(.islandOpen) {
            self.focus = focus
            isExpanded = true
        }
        if !wasExpanded { Haptics.tap(.alignment) }
    }

    func collapse() {
        cancelExpand()
        cancelCollapse()
        guard isExpanded else { return }
        withAnimation(.islandClose) {
            isExpanded = false
            focus = nil
        }
    }

    func select(focus: String) {
        withAnimation(.islandMorph) { self.focus = focus }
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
        }
    }

    // MARK: Timers

    private func scheduleExpand(after delay: TimeInterval) {
        cancelExpand()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isHovering else { return }
            self.expand()
        }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelExpand() {
        expandWork?.cancel()
        expandWork = nil
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        cancelCollapse()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering else { return }
            #if DEBUG
            if self.isPinnedOpen { return }
            #endif
            self.collapse()
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
    /// Width of one indicator dot and the gap after it.
    static let indicatorPitch: CGFloat = 11

    var size: CGSize
    /// How far the island's centre sits right of the notch's centre. Non-zero when
    /// the two sides of compact content differ in width: the island shifts so the
    /// gap in the middle stays exactly over the camera.
    var centerOffset: CGFloat = 0
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
    /// Compact / banner content widths either side of the notch. The trailing
    /// width includes the indicator strip.
    var leadingWidth: CGFloat = 0
    var trailingWidth: CGFloat = 0
    /// Width at the right edge given to indicator dots.
    var indicatorWidth: CGFloat = 0
    /// Expanded body height below the notch row.
    var bodyHeight: CGFloat = 0
    var bubbleDiameter: CGFloat = 0
    var showsShadow = false

    /// Default width either side of the notch for compact content.
    static func defaultSide(for notch: CGSize) -> CGFloat { notch.height + 12 }

    /// Where the bubble's centre sits relative to the notch's top centre.
    var bubbleCenterOffset: CGSize {
        CGSize(
            width: centerOffset + size.width / 2 + Self.bubbleGap + bubbleDiameter / 2,
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
        let dots = center.indicators.isEmpty
            ? 0
            : CGFloat(center.indicators.count) * indicatorPitch + 6

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

        /// Lays out content either side of the notch at notch height.
        func wings(leading: CGFloat, trailing: CGFloat, grow: CGFloat) {
            layout.leadingWidth = leading
            layout.trailingWidth = trailing
            layout.size = CGSize(
                width: notch.width + leading + trailing + 2 * ear + 2 * grow,
                height: notch.height + grow / 5
            )
            layout.centerOffset = (trailing - leading) / 2
            corners(floating ? layout.size.height / 2 : min(notch.height / 2 - 2, 14) + grow / 10)
        }

        switch model.mode {
        case .hidden:
            layout.size = CGSize(width: notch.width * 0.6, height: 0)

        case .idle:
            if dots > 0 {
                layout.indicatorWidth = dots
                wings(leading: 0, trailing: dots, grow: 5 * hover)
            } else if floating {
                // The resting pill, where the user asked for one.
                layout.size.width += 36 + 10 * hover
            } else {
                // A little growth under the pointer says "this opens".
                layout.size.width += 14 * hover
                layout.size.height += 3 * hover
                corners(11 + 2 * hover)
            }

        case .compact(let id):
            let activity = center.activity(id: id)
            layout.indicatorWidth = dots
            wings(
                leading: activity?.compactLeadingWidth ?? side,
                trailing: (activity?.compactTrailingWidth ?? side) + dots,
                grow: 5 * hover
            )

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
            } else {
                body = center.activity(id: focus)?.expandedHeight ?? homeHeight
            }
            layout.bodyHeight = body
            layout.size = CGSize(
                width: max(expandedWidth, notch.width + 300) + 2 * layout.earRadius,
                height: notch.height + body + expandedInset.bottom
            )
            corners(30, top: 24)
            layout.showsShadow = true
        }

        // Never ask for more than the window can hold.
        layout.size.width = min(layout.size.width, canvas.width - 40 - 2 * abs(layout.centerOffset))
        layout.size.height = min(layout.size.height, canvas.height - 30)
        return layout
    }
}
