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

/// A transient alert, the way plugging in a charger or connecting AirPods is on the
/// iPhone. A card drops down and takes the island over for a moment, then gives it
/// back. A compact one does the same while the island has nothing else to show, or
/// when it is news of the activity showing (a new song); over any other live activity
/// it leaves that activity where it is and rides in a row beneath it, as the volume
/// does, so the music or the timer stays in sight (`ActivityCenter.bannerRidesUnder`).
/// The opened island shows a compact banner in its header.
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
    /// Whether the banner may break through while a Focus asks for quiet.
    var interruption: BannerInterruption = .active
    /// The activity this banner is news from, if any: Now Playing, for its song
    /// changing. While that activity holds the compact island, a compact banner takes
    /// its place there, the new song over the old, rather than riding in a row under
    /// it: a row naming the song under the song would say it twice.
    var activityID: String? = nil
    /// Compact style, in the row under an activity (`row`): how wide each side's
    /// content is, where the banner evens its two sides up beside the notch, so the
    /// island stays centred on it. `nil` when each side already asks for just what its
    /// content takes. Side by side in a row, a side evened up would leave its slack in
    /// the middle of the line, each side's content being against its outer edge.
    var rowWidths: (leading: CGFloat, trailing: CGFloat)? = nil
    /// Compact style: left of the notch.
    var leading: AnyView = AnyView(EmptyView())
    /// Compact style: right of the notch.
    var trailing: AnyView = AnyView(EmptyView())
    /// Card style: the card's body below the notch row.
    var content: AnyView = AnyView(EmptyView())
}

/// Something brief that rides under the compact island instead of taking it over: the
/// volume changing while music plays, say. What the island was showing stays exactly
/// as it was, and a slim row grows beneath it for a moment, then folds away again.
///
/// It needs compact content to ride under: a live activity, or a compact banner. With
/// none (the island at rest, or a card up), it shows as `banner` instead, taking the
/// island over as any banner does. `ActivityCenter.present(_:)` chooses between the
/// two when it goes up, and it keeps that form while it is presented again in place;
/// a row whose activity or banner goes before it does becomes its banner for the time
/// it has left. The opened island has no compact row either, so its header shows the
/// banner, as it shows any compact banner.
///
/// A compact banner over a live activity takes the same row, as `IslandBanner.row`
/// (see `ActivityCenter.bannerRidesUnder`). One row shows at a time: a presented
/// attachment first, since a held key wants its answer now; then a banner riding
/// under the activity, which comes back once the attachment has gone, its time held
/// while it waited.
///
/// A row can also stand under one activity for as long as its feature keeps it there,
/// rather than for a moment: the line of a song being sung, under Now Playing (see
/// `ActivityCenter.setStandingAttachment(_:under:)`). It shows only while that activity
/// holds the compact island, and gives way to a presented row or a banner's, coming
/// back once they have gone. It has no banner and no timer.
struct IslandAttachment {
    /// The rows' height: the volume's, a banner's and the line being sung alike, so the
    /// island keeps its height as one gives way to another.
    static let standardHeight: CGFloat = 26

    /// Presenting an attachment with the id of the one on screen updates it in place
    /// (and restarts its timer) instead of animating a new one in, as with banners.
    var id: String
    /// The row's height, below the notch row.
    var height: CGFloat = IslandAttachment.standardHeight
    /// The least width the row's content needs. The row spans the island's body at
    /// rest, centred on the notch; an island narrower than this widens for it, on both
    /// sides alike.
    var width: CGFloat
    /// How long a presented row stays. A standing row stays until it is removed.
    var duration: TimeInterval = 2.6
    /// The row. It takes no clicks: a click there is on the island.
    var content: AnyView
    /// The same thing as a banner of its own, for when there is nothing compact to
    /// ride under. `nil` shows it only under compact content. A standing row has none.
    var banner: IslandBanner?
}

/// A row standing under an activity: the row, and the activity it belongs under.
struct StandingAttachment {
    var activityID: String
    var attachment: IslandAttachment
}

/// How much a banner may interrupt, after the iPhone's notification interruption
/// levels. A Focus quiets passive banners the way it quiets passive notifications.
/// A preview is there to be looked at, so a feature previewing a passive banner
/// presents it as active.
enum BannerInterruption {
    /// Nice to see, never needed now: a song changing. Dropped while a Focus is on,
    /// if Settings asks for quiet.
    case passive
    /// Worth the interruption: something the person did (plugging in, connecting
    /// headphones, a Focus changing) or something they asked to hear about (a timer).
    case active
}

/// A small coloured dot beside the notch, like the iPhone's camera and microphone
/// indicators, or a small symbol where the state needs naming. Indicators sit at the
/// island's right edge whether it is resting or showing an activity, and never take
/// the island over.
struct StatusIndicator: Identifiable, Equatable {
    var id: String
    var color: Color
    /// Lower sorts first (closest to the notch).
    var order: Int = 0
    /// An SF Symbol drawn in `color` in place of the dot, for a state that needs
    /// naming rather than flagging (which Focus is on). `nil` draws the dot.
    var symbol: String? = nil
    /// Whether the indicator alone brings up the island where it would otherwise
    /// hide: on a display without a notch, with no resting island asked for. The
    /// camera and microphone dots do, since they must be seen wherever they are. A
    /// Focus, on for hours at a time, does not: it is shown wherever the island is
    /// up anyway, and never overrules that setting.
    var keepsIslandShown = true
    /// What the indicator says, in words, to VoiceOver: "Location in use — Find My".
    var label: String? = nil
    /// What the indicator means, in full. With one, clicking the indicator shows it in
    /// a card under the indicator; without, the indicator is only a mark.
    var detail: IndicatorDetail? = nil
}

/// The card an indicator opens: which apps are behind a privacy dot, which Focus is
/// on and until when. It shows under the indicator in the opened island, one card at
/// a time, and closes with a click anywhere else in the island.
///
/// Its view observes the feature's model, as an activity's views do, so it stays
/// current while open without the indicator being re-published.
struct IndicatorDetail: Equatable {
    /// Which card this is. Indicators that show the same card give it the same id —
    /// the privacy dots and the location arrow all list what is in use — so it stays
    /// open while any of them is lit, and a click on another of them moves it there
    /// rather than closing it. Once none is lit, the card stays a moment, to say so,
    /// then closes.
    var id: String
    /// What the card is about, in a word, for VoiceOver: "Privacy", "Focus".
    var title: String
    /// The widest the card grows. It is as wide as its content asks, and no narrower
    /// than it takes to reach its indicator; a line longer than this truncates. Its
    /// height is whatever the content needs: the opened island grows to hold a card
    /// taller than its page leaves room for.
    var maxWidth: CGFloat
    var content: @MainActor () -> AnyView

    /// Two details are the same card when all but their views match. The view is
    /// built afresh each time an indicator is published, and draws the same card
    /// from the same model, so a new one is no reason to update the island.
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.title == b.title && a.maxWidth == b.maxWidth
    }
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

/// A page of the opened island that a feature owns rather than an activity, opened
/// by selecting its id as the island's focus: from a home tile, or with
/// `islet://open?focus=<id>`. While it is open the header shows its tab beside the
/// home tab, which is the way back; it has no tab otherwise, since nothing is going on
/// there to be told about.
struct IslandPage: Identifiable {
    var id: String
    /// SF Symbol for the page's tab while it is open.
    var symbol: String
    /// Height of the page below the notch row.
    var height: CGFloat
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
