import SwiftUI

/// How strongly an activity claims the island. The highest one is shown compact
/// around the notch; the runner-up gets the detached bubble beside it.
enum ActivityPriority: Int, Comparable {
    case background = 0
    case normal = 1
    case high = 2
    case urgent = 3

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Something ongoing that lives in the island until it ends — music playing, a timer
/// running, a meeting about to start. Mirrors the iPhone's Live Activity: a compact
/// presentation either side of the camera, a minimal one for the detached bubble,
/// and an expanded one when the island is opened.
///
/// Implementations are classes that own (or reference) an observable model; the
/// views they return observe that model, so the activity itself is only re-published
/// to `ActivityCenter` when its identity, priority or sizes change.
@MainActor
protocol IslandActivity: AnyObject {
    /// Stable identifier. Showing an activity with an id already on screen replaces it.
    var id: String { get }
    var priority: ActivityPriority { get }
    /// SF Symbol for this activity's tab in the expanded island.
    var symbol: String { get }

    /// Width of the compact content left of the notch. `nil` uses the default.
    var compactLeadingWidth: CGFloat? { get }
    /// Width of the compact content right of the notch. `nil` uses the default.
    var compactTrailingWidth: CGFloat? { get }
    /// Height of the expanded content below the notch row.
    var expandedHeight: CGFloat { get }

    /// Left of the notch. Given the notch height; vertically centred.
    func compactLeading() -> AnyView
    /// Right of the notch.
    func compactTrailing() -> AnyView
    /// Inside the detached circular bubble, when another activity holds the island.
    func minimal() -> AnyView
    /// The opened island's body, below the notch row, at `expandedHeight`.
    func expanded() -> AnyView
    /// The app this activity is about, when it is about one (the player Now Playing
    /// shows), so other activities can avoid showing the same app twice.
    var appBundleIdentifier: String? { get }
    /// A two-finger swipe sideways over the island while it shows this activity.
    /// Returns whether the activity did something with it.
    func swipe(_ direction: ActivitySwipe) -> Bool
}

enum ActivitySwipe {
    /// Fingers moved left.
    case next
    /// Fingers moved right.
    case previous
}

extension IslandActivity {
    var priority: ActivityPriority { .normal }
    var compactLeadingWidth: CGFloat? { nil }
    var compactTrailingWidth: CGFloat? { nil }
    var expandedHeight: CGFloat { 110 }
    func minimal() -> AnyView { compactLeading() }
    var appBundleIdentifier: String? { nil }
    func swipe(_ direction: ActivitySwipe) -> Bool { false }
}

/// A transient alert that takes over the island for a moment, the way plugging in a
/// charger or connecting AirPods does on the iPhone, then gives it back.
struct IslandBanner {
    enum Style: Equatable {
        /// Stays at notch height and widens: content either side of the notch.
        case compact(leading: CGFloat, trailing: CGFloat)
        /// Drops down into a card below the notch row.
        case card(width: CGFloat? = nil, height: CGFloat)
    }

    /// Presenting a banner with the id of the one on screen updates it in place
    /// (and restarts its timer) instead of animating a new one in. The volume HUD
    /// relies on this while a key is held.
    var id: String
    var style: Style
    var duration: TimeInterval = 2.6
    var haptic: Bool = true
    /// Compact style: left of the notch.
    var leading: AnyView = AnyView(EmptyView())
    /// Compact style: right of the notch.
    var trailing: AnyView = AnyView(EmptyView())
    /// Card style: the card's body below the notch row.
    var content: AnyView = AnyView(EmptyView())
}

/// A small coloured dot beside the notch, like the iPhone's camera and microphone
/// indicators. Indicators sit at the island's right edge whether it is resting or
/// showing an activity, and never take the island over.
struct StatusIndicator: Identifiable, Equatable {
    var id: String
    var color: Color
    /// Lower sorts first (closest to the notch).
    var order: Int = 0
}

/// A tile on the home page — what the expanded island shows when nothing is
/// running, or when its home tab is picked.
struct HomeWidget: Identifiable {
    var id: String
    /// Lower sorts first (leftmost).
    var order: Int
    /// Relative share of the row's width.
    var weight: CGFloat = 1
    var view: AnyView
}

/// Receives files dragged onto the island. While a file drag nears the notch, the
/// island opens onto this target's page.
///
/// The island handles the drag itself and reports where it is over the page, so the
/// page only draws. (A drop handler inside the page would appear only once the drag
/// was under way, and AppKit does not offer a drag to a window that had nowhere to
/// drop when it began — so the first drag would slide back every time.)
@MainActor
protocol DropTarget: AnyObject {
    /// Height of the drop page below the notch row.
    var expandedHeight: CGFloat { get }
    /// The drop page. It shows where a drop would land; it takes no drops itself.
    func view() -> AnyView
    /// A file drag is over the page at `point` (top-left origin, in a page of
    /// `size`), or has left it (`nil`).
    func dragMoved(to point: CGPoint?, in size: CGSize)
    /// Whether files dropped at `point` would be taken.
    func canDrop(at point: CGPoint, in size: CGSize) -> Bool
    /// Files were dropped at `point`.
    func drop(_ urls: [URL], at point: CGPoint, in size: CGSize)
}
