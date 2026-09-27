import SwiftUI
import Observation

/// The single source of truth for what the island is showing. Features push
/// activities, banners, attachments and home widgets in; every island window renders
/// from here.
@MainActor
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    /// Ongoing activities, highest priority first; within a priority the highest rank
    /// first, then the newest.
    private(set) var activities: [any IslandActivity] = []
    /// The transient alert on screen, if any.
    private(set) var banner: IslandBanner?
    /// Brief content riding under the compact island, if any.
    private(set) var attachment: IslandAttachment?
    /// A row that stays under one activity while its feature keeps it there. A
    /// presented `attachment` goes in front of it for as long as that is up.
    private(set) var standingAttachment: StandingAttachment?
    /// Every tile features have put on the home page, by their `order`, hidden ones
    /// included. The page shows `shownHomeWidgets`.
    private(set) var homeWidgets: [HomeWidget] = []
    /// How the person arranged the home page. Only a test replaces it.
    @ObservationIgnored var homeArrangement = HomeArrangement() {
        didSet { syncHomeArrangement() }
    }
    /// Home tiles a preview has put up, shown even if the person hid them: the preview
    /// is what they asked to see (`setPreviewing`).
    private(set) var previewingHomeTiles: Set<String> = []
    /// Features' own pages of the opened island, by id (`IslandPage`).
    private(set) var pages: [String: IslandPage] = [:]
    /// Where files dragged onto the island go. `nil` leaves drags alone.
    var dropTarget: (any DropTarget)?
    /// Dots beside the notch, in display order.
    private(set) var indicators: [StatusIndicator] = []
    /// Set while a Focus is on and Settings asks for quiet: passive banners are then
    /// dropped rather than shown, the way a Focus holds back passive notifications.
    /// Active banners, live activities and indicators are unaffected.
    var silencesPassiveBanners = false

    /// Bumped whenever an activity re-publishes itself, so views that depend on its
    /// sizes are invalidated even though the array's identity did not change.
    private(set) var revision = 0

    @ObservationIgnored private var startedAt: [String: Date] = [:]
    @ObservationIgnored private var bannerTimer: Task<Void, Never>?
    /// When the banner on screen is due to go, while its clock runs.
    @ObservationIgnored private var bannerDeadline = Date.distantPast
    /// The time a riding banner still has to show, held while a presented row covers
    /// it (`settleBannerClock`); `nil` while its clock runs.
    @ObservationIgnored private var bannerTimeOwed: TimeInterval?
    /// Whether the banner on screen has had any of its time uncovered.
    @ObservationIgnored private var bannerHasShown = false
    @ObservationIgnored private var attachmentTimer: Task<Void, Never>?
    /// When the attachment on screen is due to go, for a banner taking over from it.
    @ObservationIgnored private var attachmentDeadline = Date.distantPast

    private init() {}

    var primary: (any IslandActivity)? { activities.first }
    var secondary: (any IslandActivity)? { activities.dropFirst().first }

    func activity(id: String) -> (any IslandActivity)? {
        activities.first { $0.id == id }
    }

    // MARK: Activities

    /// Starts an activity, or re-publishes it if one with its id is already showing
    /// (for a changed priority or size).
    func show(_ activity: any IslandActivity) {
        if startedAt[activity.id] == nil { startedAt[activity.id] = Date() }
        var next = activities.filter { $0.id != activity.id }
        next.append(activity)
        next.sort { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            if a.rank != b.rank { return a.rank > b.rank }
            return (startedAt[a.id] ?? .distantPast) > (startedAt[b.id] ?? .distantPast)
        }
        withAnimation(.islandMorph) {
            activities = next
            revision &+= 1
        }
        // An activity arriving under a banner may put it in the row, behind the volume.
        settleBannerClock()
    }

    func end(id: String) {
        guard activities.contains(where: { $0.id == id }) else { return }
        let bannerRode = bannerRidesUnder
        startedAt[id] = nil
        withAnimation(.islandMorph) {
            activities.removeAll { $0.id == id }
            // A standing row goes with its activity rather than wait to come back
            // under it.
            if standingAttachment?.activityID == id { standingAttachment = nil }
        }
        attachmentLostCarrier()
        if bannerRode { bannerLostCarrier() }
        settleBannerClock()
    }

    func isShowing(id: String) -> Bool { activities.contains { $0.id == id } }

    // MARK: Banners

    /// Shows a banner for its duration. A banner with the same id as the current one
    /// updates in place; a different one replaces it. A passive banner is dropped
    /// while passive banners are silenced. Over a live activity, a compact one rides in
    /// a row under it (`bannerRidesUnder`).
    func present(_ banner: IslandBanner) {
        if banner.interruption == .passive, silencesPassiveBanners { return }
        // Its clock starts afresh, whatever the one it replaces had left.
        bannerTimer?.cancel()
        bannerTimeOwed = nil
        let isUpdate = self.banner?.id == banner.id
        if isUpdate {
            self.banner = banner
        } else {
            if banner.haptic { Haptics.tap(.levelChange) }
            withAnimation(.islandMorph) { self.banner = banner }
            bannerHasShown = false
        }
        // A card takes the island over from an attachment as it would from any other
        // banner; a compact banner has a row for it to go on riding under.
        if !hasCompactContent { dismissAttachment() }
        startBannerClock(banner.duration)
    }

    func dismissBanner(id: String? = nil) {
        guard let current = banner, id == nil || current.id == id else { return }
        bannerTimer?.cancel()
        bannerTimeOwed = nil
        withAnimation(.islandMorph) { banner = nil }
        attachmentLostCarrier()
    }

    /// Gives the banner on screen `duration` more, from now or, while a presented row
    /// covers it, from when it is uncovered.
    private func startBannerClock(_ duration: TimeInterval) {
        bannerTimer?.cancel()
        bannerTimeOwed = nil
        guard let id = banner?.id else { return }
        if bannerIsCovered {
            bannerTimeOwed = duration
            return
        }
        bannerHasShown = true
        bannerDeadline = Date().addingTimeInterval(duration)
        bannerTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismissBanner(id: id)
        }
    }

    /// A banner riding under the activity, with a presented row (the volume, while a
    /// key is held) in front of it: out of sight, though still up.
    private var bannerIsCovered: Bool { attachment != nil && bannerRidesUnder }

    /// Stops the banner's clock while a presented row covers it, and starts it again
    /// once nothing does, for the time it had left. A banner waiting behind the volume
    /// is not seen, so it is not using up its time: held longer than the banner lasts,
    /// the volume would otherwise outlast it, and it would never be seen at all. One
    /// already seen, with less time left than the island takes to change shape, goes
    /// with the row in front of it instead, rather than come back only to go straight
    /// out again. Called after anything that can cover or uncover it: a row presented
    /// or gone, a banner presented, an activity arriving or ending.
    private func settleBannerClock() {
        guard banner != nil else {
            bannerTimeOwed = nil
            return
        }
        if bannerIsCovered {
            guard bannerTimeOwed == nil else { return }
            bannerTimer?.cancel()
            bannerTimeOwed = max(0, bannerDeadline.timeIntervalSinceNow)
        } else if let owed = bannerTimeOwed {
            if owed <= 0.5, bannerHasShown {
                dismissBanner()
            } else {
                startBannerClock(owed)
            }
        }
    }

    /// The time the banner on screen has left to show.
    private var bannerTimeLeft: TimeInterval {
        bannerTimeOwed ?? bannerDeadline.timeIntervalSinceNow
    }

    /// Whether the banner on screen rides in a row under the live activity holding the
    /// compact island, rather than take the island over: a compact banner, over an
    /// activity it is not news of (`IslandBanner.activityID`). The activity's compact
    /// content stays exactly as it was, and the banner's two sides go side by side in
    /// the row beneath it (`IslandBanner.row`), as the volume does while music plays:
    /// whatever the banner says, the music or the timer stays in sight. A card still
    /// takes the island over, as does a compact banner with no live activity to ride
    /// under, or one that is news of the activity showing.
    ///
    /// It follows the island, rather than being settled once as the banner goes up. A
    /// live activity arriving under a banner takes the island back, the banner riding
    /// under it; the last one it rode under ending gives it the island for the rest of
    /// its time (`bannerLostCarrier`). Either way the banner's timer runs on as it was,
    /// except while a presented row covers it (`settleBannerClock`).
    var bannerRidesUnder: Bool {
        guard let banner, case .compact = banner.style, let primary else { return false }
        return banner.activityID != primary.id
    }

    /// The last live activity a banner rode under ended, and the banner takes the
    /// island over for the rest of its time, as if it had gone up that way. With less
    /// time left than the island takes to change shape, it goes with the activity
    /// instead, rather than morph into a banner only to morph straight out again.
    private func bannerLostCarrier() {
        guard let banner, !bannerRidesUnder, bannerTimeLeft <= 0.5 else { return }
        dismissBanner(id: banner.id)
    }

    // MARK: Attachments

    /// Whether the island has compact content for an attachment to ride under: a
    /// compact banner, or a live activity with no card over it. A card hides what is
    /// under it and has no compact row of its own. Over a banner riding under an
    /// activity, the attachment takes the row, and the banner waits behind it.
    private var hasCompactContent: Bool {
        if let banner {
            if case .compact = banner.style { return true }
            return false
        }
        return primary != nil
    }

    /// Shows an attachment under the compact island for its duration or, with nothing
    /// compact to ride under, its banner instead. An attachment with the id of the one
    /// on screen updates in place and restarts its timer; a different one replaces it.
    ///
    /// Presented again and again (while a key is held), it keeps the form it took for
    /// as long as that form stays on screen: its banner is updated in place, rather than
    /// swapped for a row because something compact turned up beneath it, so the island
    /// changes shape once in a hold and not twice. Only a row that loses what it rides
    /// under turns into its banner (`attachmentLostCarrier`). A live activity turning up
    /// takes that banner into the row under it, as it does any compact banner; the next
    /// time it is presented, it goes back to being the row, which lays out its content
    /// for a row, where the banner's two sides were laid out for either side of the
    /// notch. The island has already changed shape for the activity, so the hold still
    /// changes it only the once.
    func present(_ attachment: IslandAttachment) {
        if let banner = attachment.banner, self.banner?.id == banner.id, bannerRidesUnder {
            dismissBanner(id: banner.id)
        }
        if let banner = attachment.banner, self.banner?.id == banner.id || !hasCompactContent {
            dismissAttachment(id: attachment.id)
            present(banner)
            return
        }
        guard hasCompactContent else {
            dismissAttachment(id: attachment.id)
            return
        }
        if let current = self.attachment, current.id == attachment.id,
           current.width == attachment.width, current.height == attachment.height {
            self.attachment = attachment
        } else {
            // Arriving, or a new size in place (another device's longer name): the
            // island springs to it, and the content and bubble either side of the notch
            // move out with its edges, as they do for any other change of shape.
            withAnimation(.islandMorph) { self.attachment = attachment }
        }

        attachmentTimer?.cancel()
        let id = attachment.id
        let duration = attachment.duration
        attachmentDeadline = Date().addingTimeInterval(duration)
        attachmentTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismissAttachment(id: id)
        }
        settleBannerClock()
    }

    /// Something the attachment rode under went: the activity ended, or the banner
    /// over it did. Whatever compact content is left (the activity that banner was
    /// over) carries it on. With none, it becomes its banner for the rest of its time,
    /// as if it had been one from the start, rather than vanish early, or wait out of
    /// sight to come back under whatever turns up next. With less time left than the
    /// island takes to change shape, it goes with what it rode under instead of
    /// morphing into a banner only to morph straight out again.
    private func attachmentLostCarrier() {
        guard let attachment, !hasCompactContent else { return }
        let remaining = attachmentDeadline.timeIntervalSinceNow
        dismissAttachment()
        guard var banner = attachment.banner, remaining > 0.5 else { return }
        banner.duration = remaining
        present(banner)
    }

    func dismissAttachment(id: String? = nil) {
        guard let current = attachment, id == nil || current.id == id else { return }
        attachmentTimer?.cancel()
        withAnimation(.islandMorph) { attachment = nil }
        // A banner that waited behind the row comes back for the time it had left.
        settleBannerClock()
    }

    /// Stands `attachment` under the activity `activityID` until it is removed. It shows
    /// while that activity holds the compact island, with no banner over it and no
    /// presented row in front of it; the rest of the time it waits, out of sight.
    /// Setting it again with the same id and size swaps its content in place, so a row
    /// whose view follows a model of its own is set once, not every time it changes.
    func setStandingAttachment(_ attachment: IslandAttachment, under activityID: String) {
        let standing = StandingAttachment(activityID: activityID, attachment: attachment)
        if let current = standingAttachment, current.activityID == activityID,
           current.attachment.id == attachment.id, current.attachment.width == attachment.width,
           current.attachment.height == attachment.height {
            standingAttachment = standing
        } else {
            withAnimation(.islandMorph) { standingAttachment = standing }
        }
    }

    func removeStandingAttachment(id: String? = nil) {
        guard let current = standingAttachment, id == nil || current.attachment.id == id else { return }
        withAnimation(.islandMorph) { standingAttachment = nil }
    }

    // MARK: Indicators

    func setIndicator(_ indicator: StatusIndicator) {
        guard indicators.first(where: { $0.id == indicator.id }) != indicator else { return }
        var next = indicators.filter { $0.id != indicator.id }
        next.append(indicator)
        next.sort { $0.order < $1.order }
        withAnimation(.islandMorph) { indicators = next }
    }

    func removeIndicator(id: String) {
        guard indicators.contains(where: { $0.id == id }) else { return }
        withAnimation(.islandMorph) { indicators.removeAll { $0.id == id } }
    }

    // MARK: Home

    func setHomeWidget(_ widget: HomeWidget) {
        var next = homeWidgets.filter { $0.id != widget.id }
        next.append(widget)
        next.sort { $0.order < $1.order }
        homeWidgets = next
        syncHomeArrangement()
    }

    func removeHomeWidget(id: String) {
        homeWidgets.removeAll { $0.id == id }
        syncHomeArrangement()
    }

    /// The home page's tiles as it shows them: in the person's order once they have
    /// arranged the page, by each tile's `order` until then, and without the ones they
    /// hid (`HomeTileOrder`) unless a preview has put one up.
    var shownHomeWidgets: [HomeWidget] {
        homeArrangement.shown(homeWidgets, shownAnyway: previewingHomeTiles)
    }

    /// Whether a preview has tile `id` up, to show on the home page even if it is hidden.
    /// The feature says when the preview ends.
    func setPreviewing(_ isPreviewing: Bool, homeTile id: String) {
        guard previewingHomeTiles.contains(id) != isPreviewing else { return }
        if isPreviewing { previewingHomeTiles.insert(id) } else { previewingHomeTiles.remove(id) }
    }

    /// Tells the arrangement which tiles are on the page and where they ask to go, when
    /// that changes: not for a tile only drawing something new.
    private func syncHomeArrangement() {
        let showing = homeWidgets.map { HomeTilePosition(id: $0.id, order: $0.order) }
        if homeArrangement.showing != showing { homeArrangement.showing = showing }
    }

    // MARK: Pages

    /// Makes a page available to open. An island open on it when it is removed goes
    /// back to what it would show anyway.
    func setPage(_ page: IslandPage) {
        pages[page.id] = page
    }

    func removePage(id: String) {
        guard pages[id] != nil else { return }
        withAnimation(.islandMorph) { pages[id] = nil }
    }
}
