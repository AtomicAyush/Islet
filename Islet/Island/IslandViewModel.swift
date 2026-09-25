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
    /// The window's fixed size. The island is centred at its top edge.
    static let canvas = CGSize(width: 680, height: 330)
    static let expandedWidth: CGFloat = 520
    static let homeHeight: CGFloat = 116
    static let expandedInset = EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20)
    static let bubbleGap: CGFloat = 7

    var size: CGSize
    var earRadius: CGFloat
    var bottomRadius: CGFloat
    var notch: CGSize
    /// Compact / banner content widths either side of the notch.
    var leadingWidth: CGFloat = 0
    var trailingWidth: CGFloat = 0
    /// Expanded body height below the notch row.
    var bodyHeight: CGFloat = 0
    var bubbleDiameter: CGFloat = 0
    var showsShadow = false

    /// Default width either side of the notch for compact content.
    static func defaultSide(for notch: CGSize) -> CGFloat { notch.height + 12 }

    /// Where the bubble's centre sits relative to the canvas's top centre.
    var bubbleCenterOffset: CGSize {
        CGSize(width: size.width / 2 + Self.bubbleGap + bubbleDiameter / 2, height: notch.height / 2)
    }

    @MainActor
    static func make(for model: IslandViewModel) -> IslandLayout {
        let notch = model.metrics.notchSize
        let ear: CGFloat = 6
        let side = defaultSide(for: notch)
        let hover: CGFloat = model.isHovering ? 1 : 0
        let center = model.center
        // Touch the revision so re-published activity sizes invalidate the layout.
        _ = center.revision

        var layout = IslandLayout(
            size: CGSize(width: notch.width + 2 * ear, height: notch.height),
            earRadius: ear,
            bottomRadius: 11,
            notch: notch,
            bubbleDiameter: notch.height - 4
        )

        switch model.mode {
        case .hidden:
            layout.size = CGSize(width: notch.width * 0.6, height: 0)

        case .idle:
            // A little growth under the pointer says "this opens".
            layout.size.width += 14 * hover
            layout.size.height += 3 * hover
            layout.bottomRadius = 11 + 2 * hover

        case .compact(let id):
            let activity = center.activity(id: id)
            layout.leadingWidth = activity?.compactLeadingWidth ?? side
            layout.trailingWidth = activity?.compactTrailingWidth ?? side
            layout.size = CGSize(
                width: notch.width + layout.leadingWidth + layout.trailingWidth + 2 * ear + 10 * hover,
                height: notch.height + 2 * hover
            )
            layout.bottomRadius = notch.height / 2 - 2 + hover

        case .banner:
            switch center.banner?.style {
            case .compact(let leading, let trailing):
                layout.leadingWidth = leading
                layout.trailingWidth = trailing
                layout.size = CGSize(
                    width: notch.width + leading + trailing + 2 * ear,
                    height: notch.height
                )
                layout.bottomRadius = notch.height / 2 - 2
            case .card(let width, let height):
                layout.earRadius = 9
                layout.bodyHeight = height
                layout.size = CGSize(
                    width: (width ?? 400) + 2 * layout.earRadius,
                    height: notch.height + height + expandedInset.bottom
                )
                layout.bottomRadius = 26
                layout.showsShadow = true
            case nil:
                break
            }

        case .expanded(let focus):
            layout.earRadius = 10
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
            layout.bottomRadius = 30
            layout.showsShadow = true
        }

        // Never ask for more than the window can hold.
        layout.size.width = min(layout.size.width, canvas.width - 40)
        layout.size.height = min(layout.size.height, canvas.height - 30)
        return layout
    }
}
