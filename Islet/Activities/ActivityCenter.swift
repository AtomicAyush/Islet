import SwiftUI
import Observation

/// The single source of truth for what the island is showing. Features push
/// activities, banners, attachments and home widgets in; every island window renders
/// from here.
@MainActor
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    /// Ongoing activities, highest priority first, newest first within a priority.
    private(set) var activities: [any IslandActivity] = []
    /// The transient alert on screen, if any.
    private(set) var banner: IslandBanner?
    /// Brief content riding under the compact island, if any.
    private(set) var attachment: IslandAttachment?
    /// A row that stays under one activity while its feature keeps it there. A
    /// presented `attachment` goes in front of it for as long as that is up.
    private(set) var standingAttachment: StandingAttachment?
    /// Home page tiles, in display order.
    private(set) var homeWidgets: [HomeWidget] = []
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
            return (startedAt[a.id] ?? .distantPast) > (startedAt[b.id] ?? .distantPast)
        }
        withAnimation(.islandMorph) {
            activities = next
            revision &+= 1
        }
    }

    func end(id: String) {
        guard activities.contains(where: { $0.id == id }) else { return }
        startedAt[id] = nil
        withAnimation(.islandMorph) {
            activities.removeAll { $0.id == id }
            // A standing row goes with its activity rather than wait to come back
            // under it.
            if standingAttachment?.activityID == id { standingAttachment = nil }
        }
        attachmentLostCarrier()
    }

    func isShowing(id: String) -> Bool { activities.contains { $0.id == id } }

    // MARK: Banners

    /// Shows a banner for its duration. A banner with the same id as the current one
    /// updates in place; a different one replaces it. A passive banner is dropped
    /// while passive banners are silenced.
    func present(_ banner: IslandBanner) {
        if banner.interruption == .passive, silencesPassiveBanners { return }
        let isUpdate = self.banner?.id == banner.id
        if isUpdate {
            self.banner = banner
        } else {
            if banner.haptic { Haptics.tap(.levelChange) }
            withAnimation(.islandMorph) { self.banner = banner }
        }
        // A card takes the island over from an attachment as it would from any other
        // banner; a compact banner has a row for it to go on riding under.
        if !hasCompactContent { dismissAttachment() }

        bannerTimer?.cancel()
        let id = banner.id
        let duration = banner.duration
        bannerTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismissBanner(id: id)
        }
    }

    func dismissBanner(id: String? = nil) {
        guard let current = banner, id == nil || current.id == id else { return }
        bannerTimer?.cancel()
        withAnimation(.islandMorph) { banner = nil }
        attachmentLostCarrier()
    }

    // MARK: Attachments

    /// Whether the island has compact content for an attachment to ride under: a
    /// compact banner, or a live activity with no banner over it. A card hides what is
    /// under it and has no compact row of its own.
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
    /// under turns into its banner (`attachmentLostCarrier`).
    func present(_ attachment: IslandAttachment) {
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
    }

    func removeHomeWidget(id: String) {
        homeWidgets.removeAll { $0.id == id }
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
