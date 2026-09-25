import SwiftUI
import Observation

/// The single source of truth for what the island is showing. Features push
/// activities, banners and home widgets in; every island window renders from here.
@MainActor
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    /// Ongoing activities, highest priority first, newest first within a priority.
    private(set) var activities: [any IslandActivity] = []
    /// The transient alert on screen, if any.
    private(set) var banner: IslandBanner?
    /// Home page tiles, in display order.
    private(set) var homeWidgets: [HomeWidget] = []
    /// Where files dragged onto the island go. `nil` leaves drags alone.
    var dropTarget: (any DropTarget)?
    /// Dots beside the notch, in display order.
    private(set) var indicators: [StatusIndicator] = []

    /// Bumped whenever an activity re-publishes itself, so views that depend on its
    /// sizes are invalidated even though the array's identity did not change.
    private(set) var revision = 0

    @ObservationIgnored private var startedAt: [String: Date] = [:]
    @ObservationIgnored private var bannerTimer: Task<Void, Never>?

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
        }
    }

    func isShowing(id: String) -> Bool { activities.contains { $0.id == id } }

    // MARK: Banners

    /// Shows a banner for its duration. A banner with the same id as the current one
    /// updates in place; a different one replaces it.
    func present(_ banner: IslandBanner) {
        let isUpdate = self.banner?.id == banner.id
        if isUpdate {
            self.banner = banner
        } else {
            if banner.haptic { Haptics.tap(.levelChange) }
            withAnimation(.islandMorph) { self.banner = banner }
        }

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
}
