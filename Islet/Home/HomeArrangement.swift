import SwiftUI
import Observation

/// A home tile as its feature describes it, whether or not it is showing: its name and
/// symbol, for arranging the home page in Settings and in the island, and where it goes
/// until the person puts it somewhere else (`HomeWidget.order`).
struct HomeTileInfo: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String
    /// Lower sorts first (leftmost), as `HomeWidget.order`.
    var order: Int
}

/// A tile on the home page now and the order it asks for, which may not be the one its
/// feature describes (`HomeTileInfo`): Hidden Menu Bar Icons asks to go earlier while
/// icons are out of sight.
struct HomeTilePosition: Equatable {
    var id: String
    var order: Int
}

/// A tile's id and the place its feature gives it: a tile on the home page, or a
/// feature's description of one.
protocol HomeTilePlace {
    var id: String { get }
    var order: Int { get }
}

extension HomeWidget: HomeTilePlace {}
extension HomeTileInfo: HomeTilePlace {}
extension HomeTilePosition: HomeTilePlace {}

/// How the person arranged the home page: the order they put the tiles in, and the ones
/// they hid. A plain value, so the rules can be tried apart from where it is kept
/// (`HomeArrangement`).
///
/// Until the person first moves a tile, tiles go by the orders they ask for, as they
/// always have, including a feature moving its tile while it matters more (Hidden Menu
/// Bar Icons goes before the timer while icons are out of sight). The first move writes
/// down every tile known then, in the order the page had them, and from then on that
/// order wins: a feature asking for another order no longer moves a tile, and a tile that
/// goes away (its feature off, or nothing for it to say) keeps its place and comes back
/// to it. A tile never placed (a feature turned on since, or one new in an update) is
/// written down as it first turns up, just after the tile that comes before it by its
/// feature's order, or failing that just before the one after it, and stays there. Ids of
/// tiles that no longer exist stay in the list, ignored.
///
/// Hiding is apart from the order: a hidden tile keeps its place, and comes back to it.
struct HomeTileOrder: Equatable {
    /// Every tile placed, in the person's order, including ones not showing now. Empty
    /// until they first arrange the page.
    var placed: [String]
    var hidden: Set<String>

    /// A list read back with an id twice in it (edited by hand, say) keeps the first.
    init(placed: [String] = [], hidden: Set<String> = []) {
        var seen = Set<String>()
        self.placed = placed.filter { seen.insert($0).inserted }
        self.hidden = hidden
    }

    /// Whether the page differs at all from the features' own arrangement.
    var isCustomised: Bool { !placed.isEmpty || !hidden.isEmpty }

    /// `tiles` in the person's order, hidden ones included. `known` are the features'
    /// descriptions of their tiles (`HomeTileInfo`): a tile not placed yet goes by its
    /// feature's order rather than the one it asks for now, so it does not move about.
    func arranged<T: HomeTilePlace>(_ tiles: [T], known: [HomeTileInfo] = []) -> [T] {
        guard !placed.isEmpty else { return Self.byOrder(tiles) }
        var byID: [String: T] = [:]
        for tile in tiles where byID[tile.id] == nil { byID[tile.id] = tile }
        return adopting(tiles, known: known).compactMap { byID.removeValue(forKey: $0) }
    }

    /// `tiles` as the home page shows them: arranged, without the hidden ones, except
    /// any in `shownAnyway` (a preview of a hidden tile).
    func shown<T: HomeTilePlace>(_ tiles: [T], known: [HomeTileInfo] = [], shownAnyway: Set<String> = []) -> [T] {
        arranged(tiles, known: known).filter { !hidden.contains($0.id) || shownAnyway.contains($0.id) }
    }

    /// Every tile of `tiles` (on the page now) and `known` in the order the page has them:
    /// the person's, or before they first move a tile, by the orders the tiles on the page
    /// ask for and their features' for the rest. What a first move writes down, and what
    /// Settings lists.
    func current<T: HomeTilePlace>(_ tiles: [T], known: [HomeTileInfo] = []) -> [String] {
        guard placed.isEmpty else { return adopting(tiles, known: known) }
        var seen = Set<String>()
        let all = tiles.map { HomeTilePosition(id: $0.id, order: $0.order) }
            + known.map { HomeTilePosition(id: $0.id, order: $0.order) }
        return Self.byOrder(all.filter { seen.insert($0.id).inserted }).map(\.id)
    }

    /// Moves `id` to `destination` in `list`, the tiles in the order the person sees them,
    /// counted without `id` itself: 0 puts it first, `list.count - 1` last. Tiles not in
    /// `list` (hidden, or not showing) keep their places among the rest. The first move
    /// writes down the order of every tile in `tiles` and `known` (`current`).
    mutating func move<T: HomeTilePlace>(
        _ id: String, to destination: Int, in list: [String], tiles: [T], known: [HomeTileInfo] = []
    ) {
        placed = current(tiles, known: known)
        guard list.contains(id) else { return }
        let others = list.filter { $0 != id }
        let destination = min(max(destination, 0), others.count)
        guard let from = placed.firstIndex(of: id) else { return }
        placed.remove(at: from)
        if destination < others.count, let next = placed.firstIndex(of: others[destination]) {
            placed.insert(id, at: next)
        } else if let last = others.last, let previous = placed.firstIndex(of: last) {
            placed.insert(id, at: previous + 1)
        } else {
            placed.insert(id, at: from)
        }
    }

    /// Writes down every tile of `known` not placed yet, beside its default neighbours
    /// (`adopting`). Nothing to do until the person has arranged the page.
    mutating func adopt(_ known: [HomeTileInfo]) {
        guard !placed.isEmpty else { return }
        placed = adopting([HomeTilePosition](), known: known)
    }

    mutating func setHidden(_ isHidden: Bool, _ id: String) {
        if isHidden { hidden.insert(id) } else { hidden.remove(id) }
    }

    /// Back to the features' own arrangement, every tile showing.
    mutating func reset() {
        placed = []
        hidden = []
    }

    /// `placed`, with every tile of `known` and `tiles` it does not have yet slotted in
    /// beside its default neighbours: just after the placed tile with the greatest order
    /// no greater than its own, or failing that just before the one with the least order
    /// above it. The orders are the features' (`known`), whatever a tile on the page asks
    /// for now, so a tile raising itself moves neither itself nor another; only a tile no
    /// feature describes goes by its own. Tiles are slotted in by their order, so two new
    /// ones keep theirs.
    private func adopting<T: HomeTilePlace>(_ tiles: [T], known: [HomeTileInfo]) -> [String] {
        var orders: [String: Int] = [:]
        for tile in tiles { orders[tile.id] = tile.order }
        for tile in known { orders[tile.id] = tile.order }

        var list = placed
        var seen = Set(placed)
        var newcomers: [HomeTilePosition] = []
        for id in known.map(\.id) + tiles.map(\.id) where seen.insert(id).inserted {
            newcomers.append(HomeTilePosition(id: id, order: orders[id] ?? 0))
        }
        for tile in Self.byOrder(newcomers) {
            var after: (index: Int, order: Int)?
            var before: (index: Int, order: Int)?
            for (index, id) in list.enumerated() {
                guard let order = orders[id] else { continue }
                if order <= tile.order {
                    if after.map({ order >= $0.order }) ?? true { after = (index, order) }
                } else if before.map({ order < $0.order }) ?? true {
                    before = (index, order)
                }
            }
            if let after {
                list.insert(tile.id, at: after.index + 1)
            } else if let before {
                list.insert(tile.id, at: before.index)
            } else {
                list.append(tile.id)
            }
        }
        return list
    }

    /// Sorted by order, keeping the given order among equals.
    private static func byOrder<T: HomeTilePlace>(_ tiles: [T]) -> [T] {
        tiles.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
    }
}

/// The person's arrangement of the home page (`HomeTileOrder`), kept in the defaults,
/// with the tiles the running features have and the ones on the page now. There is one,
/// `ActivityCenter`'s: every island and Settings arrange the same page.
@MainActor
@Observable
final class HomeArrangement {
    private(set) var order: HomeTileOrder
    /// The tiles the running features can put on the home page (`Feature.homeTile`), in
    /// the registry's order; the feature registry keeps it current as features start and
    /// stop. Settings lists these to arrange, the island offers the hidden ones back, and
    /// they place a tile never placed beside its default neighbours whether or not those
    /// are showing. Once the page is arranged, a tile new here is written down at once.
    var tiles: [HomeTileInfo] = [] {
        didSet {
            var next = order
            next.adopt(tiles)
            update(next)
        }
    }
    /// The tiles on the home page now, hidden ones included, at the orders they ask for
    /// (`ActivityCenter.homeWidgets`, which keeps this current): Settings lists them, and
    /// a first move writes them down, as the page has them.
    var showing: [HomeTilePosition] = []

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = HomeTileOrder(
            placed: defaults.stringArray(forKey: Prefs.Key.homeTileOrder) ?? [],
            hidden: Set(defaults.stringArray(forKey: Prefs.Key.hiddenHomeTiles) ?? [])
        )
    }

    var isCustomised: Bool { order.isCustomised }

    func isHidden(_ id: String) -> Bool { order.hidden.contains(id) }

    /// `widgets` in the person's order, hidden ones included.
    func arranged<T: HomeTilePlace>(_ widgets: [T]) -> [T] {
        order.arranged(widgets, known: tiles)
    }

    /// `widgets` as the home page shows them: in the person's order, without the hidden
    /// ones but for any in `shownAnyway`.
    func shown<T: HomeTilePlace>(_ widgets: [T], shownAnyway: Set<String> = []) -> [T] {
        order.shown(widgets, known: tiles, shownAnyway: shownAnyway)
    }

    /// The running features' tiles in the order the page has them, hidden ones included:
    /// the list Settings shows, the same as the island's whether or not the person has
    /// arranged it yet.
    var arrangedTiles: [HomeTileInfo] {
        let byID = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.current(showing, known: tiles).compactMap { byID[$0] }
    }

    /// The running features' tiles the person hid, in their order.
    var hiddenTiles: [HomeTileInfo] { arrangedTiles.filter { order.hidden.contains($0.id) } }

    /// The name of tile `id`, as its feature gives it.
    func title(of id: String) -> String {
        tiles.first { $0.id == id }?.title ?? id
    }

    /// Moves `id` to `destination` in `list` (`HomeTileOrder.move`): the tiles in the
    /// order they are shown where it was moved, the home page's or Settings' list.
    func move(_ id: String, to destination: Int, in list: [String]) {
        var next = order
        next.move(id, to: destination, in: list, tiles: showing, known: tiles)
        update(next)
    }

    /// A list's move, as SwiftUI's `onMove` reports it: the rows at `offsets` go before
    /// the row that was at `destination`.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int, in list: [String]) {
        guard let from = offsets.first, list.indices.contains(from) else { return }
        move(list[from], to: destination > from ? destination - 1 : destination, in: list)
    }

    func setHidden(_ isHidden: Bool, _ id: String) {
        var next = order
        next.setHidden(isHidden, id)
        update(next)
    }

    func showAll() {
        var next = order
        next.hidden = []
        update(next)
    }

    func reset() {
        var next = order
        next.reset()
        update(next)
    }

    private func update(_ next: HomeTileOrder) {
        guard next != order else { return }
        order = next
        if next.placed.isEmpty {
            defaults.removeObject(forKey: Prefs.Key.homeTileOrder)
        } else {
            defaults.set(next.placed, forKey: Prefs.Key.homeTileOrder)
        }
        if next.hidden.isEmpty {
            defaults.removeObject(forKey: Prefs.Key.hiddenHomeTiles)
        } else {
            defaults.set(next.hidden.sorted(), forKey: Prefs.Key.hiddenHomeTiles)
        }
    }
}
