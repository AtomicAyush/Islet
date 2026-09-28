import SwiftUI
import Observation

/// A live activity as its feature describes it, whether or not it is running: its name
/// and symbol, for arranging the island's order in Settings, and where it goes in that
/// list until the person arranges it themselves.
struct IslandActivityInfo: Identifiable, Equatable {
    /// The id its `IslandActivity` is published under.
    var id: String
    var title: String
    var symbol: String
    /// Lower goes first in Settings' list, until the person arranges it. The island
    /// itself goes by priority, rank and age until then (`ActivityCenter.activities`),
    /// so features give their activities' usual priority here: a timer's high first,
    /// then the normal ones (a meeting, music, a download, a Pomodoro session, which
    /// ranks below the others), then the background ones. Settings then lists them as
    /// the island would take them, and arranging it changes no more than what is moved.
    var order: Int
}

extension IslandActivityInfo {
    /// `feature`'s live activity, under the feature's own id, name and symbol.
    @MainActor
    init(_ feature: any Feature, order: Int) {
        self.init(id: feature.id, title: feature.title, symbol: feature.symbol, order: order)
    }
}

/// The island's order is kept by the home page's rules (`HomeTileOrder`), with
/// nothing hidden: an activity is placed as a tile is.
extension IslandActivityInfo: HomeTilePlace {}

/// The person's order of live activities, which decides which one holds the island when
/// several are going on at once, and the order of the bubbles beside it
/// (`ActivityCenter.activities`). Kept in the defaults, with the activities the running
/// features have. There is one, `ActivityCenter`'s.
///
/// Until the person first moves one, nothing is written down and the island goes by
/// each activity's priority, rank and age, as it always has. Settings lists the
/// features' own order meanwhile (`IslandActivityInfo.order`), with those running now
/// in the order the island has them, so the list says what the island is doing. The
/// first move writes down every activity listed then, in the order Settings had them,
/// so it changes nothing but the place of the one moved; from then on that order wins. An activity never placed (a feature turned on since, or one new in
/// an update) is written down as it first turns up, beside its neighbours by the
/// features' orders, as a home tile is (`HomeTileOrder`), and stays there. One whose
/// feature is turned off keeps its place, and comes back to it.
@MainActor
@Observable
final class IslandArrangement {
    /// Every activity placed, in the person's order, including ones not running now.
    /// Empty until they first arrange it.
    private(set) var placed: [String]
    /// The live activities of the running features (`Feature.islandActivity`), in the
    /// registry's order; the feature registry keeps it current as features start and
    /// stop. Settings lists these to arrange. Once the order is arranged, one new here
    /// is written down at once.
    var activities: [IslandActivityInfo] = [] {
        didSet {
            guard activities != oldValue, !placed.isEmpty else { return }
            update(HomeTileOrder(placed: placed).current(activities))
        }
    }
    /// Told whenever the order changes, so the island can take its activities in the
    /// new one. `ActivityCenter` sets it.
    @ObservationIgnored var changed: () -> Void = {}
    /// The ids of the activities running now, in the order priority, rank and age give
    /// them, whatever the person chose to hold the island: the island's own order until
    /// this one is arranged. `ActivityCenter` sets it.
    @ObservationIgnored var automaticOrder: () -> [String] = { [] }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        placed = HomeTileOrder(placed: defaults.stringArray(forKey: Prefs.Key.islandOrder) ?? []).placed
    }

    /// Whether the person has arranged the order, so that it decides the island.
    var isArranged: Bool { !placed.isEmpty }

    /// Where activity `id` goes in the person's order, lower first; `nil` for one not
    /// placed, and for every one until the order is arranged.
    func place(of id: String) -> Int? {
        placed.firstIndex(of: id)
    }

    /// The running features' live activities in the order Settings lists them: the
    /// person's, or until they arrange it, the features' own with those running now in
    /// the island's order (`listedIDs`).
    var arrangedActivities: [IslandActivityInfo] {
        let byID = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return listedIDs.compactMap { byID[$0] }
    }

    /// The ids Settings lists, in its order. Until the person arranges it, the features'
    /// own order, but with the activities running now taking the places their kinds have
    /// in it in the order the island has them (`automaticOrder`): two of the same
    /// priority go newest first, and a meeting about to start, or a Claude Code session
    /// that needs an answer, goes up as it does in the island.
    private var listedIDs: [String] {
        let listed = HomeTileOrder(placed: placed).current(activities)
        guard placed.isEmpty else { return listed }
        let running = automaticOrder().filter(listed.contains)
        let slots = listed.indices.filter { running.contains(listed[$0]) }
        var ids = listed
        for (slot, id) in zip(slots, running) { ids[slot] = id }
        return ids
    }

    /// Moves `id` to `destination` in `list`, the activities in the order Settings lists
    /// them, counted without `id` itself: 0 puts it first. The first move writes down
    /// every activity listed, in the order Settings lists them (`listedIDs`), with only
    /// `id` moved.
    func move(_ id: String, to destination: Int, in list: [String]) {
        var next = HomeTileOrder(placed: placed.isEmpty ? listedIDs : placed)
        next.move(id, to: destination, in: list, tiles: activities)
        update(next.placed)
    }

    /// A list's move, as SwiftUI's `onMove` reports it: the rows at `offsets` go before
    /// the row that was at `destination`.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int, in list: [String]) {
        guard let from = offsets.first, list.indices.contains(from) else { return }
        move(list[from], to: destination > from ? destination - 1 : destination, in: list)
    }

    /// Back to priority, rank and age.
    func reset() {
        update([])
    }

    private func update(_ next: [String]) {
        guard next != placed else { return }
        placed = next
        if next.isEmpty {
            defaults.removeObject(forKey: Prefs.Key.islandOrder)
        } else {
            defaults.set(next, forKey: Prefs.Key.islandOrder)
        }
        changed()
    }
}
