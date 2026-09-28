import CoreGraphics

/// How the opened island's tabs share the room left of the notch: at their usual size
/// while they fit, a little narrower and closer together while that is enough, and
/// past that home, as many activities as fit, and a More button in the last slot whose
/// menu holds the rest. The activity the island shows always keeps its tab: if its
/// place is in the menu, it takes the last slot, and the activity that had that slot
/// goes to the menu instead. An open feature page's tab always shows, after the rest.
///
/// It is worked out from the tabs' fixed sizes, so the row is built once, as it shows.
struct HeaderTabFit: Equatable {
    static let tabWidth: CGFloat = 24
    static let spacing: CGFloat = 4
    static let tightTabWidth: CGFloat = 22
    static let tightSpacing: CGFloat = 2

    /// How wide each tab is, the More button too, and the gap between them.
    var tabWidth = Self.tabWidth
    var spacing = Self.spacing
    /// The activities with a tab, and those in the More menu, each in the centre's order.
    var shown: [String]
    var overflow: [String] = []

    /// `activities` are the activities' ids in the centre's order; `selected`, what the
    /// island shows; `hasPage`, whether a feature's page is open, with its own tab.
    init(activities: [String], selected: String?, hasPage: Bool, room: CGFloat) {
        shown = activities
        // Home, and the open page's tab.
        let fixed = hasPage ? 2 : 1
        let tabs = fixed + activities.count
        guard tabs > Self.slots(in: room, width: Self.tabWidth, spacing: Self.spacing) else { return }
        tabWidth = Self.tightTabWidth
        spacing = Self.tightSpacing
        let slots = Self.slots(in: room, width: tabWidth, spacing: spacing)
        guard tabs > slots else { return }
        // The More button takes a slot of its own.
        var kept = Array(activities.prefix(max(1, slots - fixed - 1)))
        if let selected, activities.contains(selected), !kept.contains(selected) {
            kept[kept.count - 1] = selected
        }
        shown = kept
        overflow = activities.filter { !kept.contains($0) }
    }

    /// The tabs for the header of an island showing `focus`, in `room`.
    @MainActor
    init(center: ActivityCenter, focus: String, room: CGFloat) {
        self.init(
            activities: center.activities.map(\.id), selected: focus, hasPage: center.pages[focus] != nil, room: room
        )
    }

    /// What the More menu lists: the activities in it, each by its name and symbol, in
    /// the centre's order.
    @MainActor
    func menuItems(_ activities: [any IslandActivity]) -> [HeaderMenuItem] {
        activities.filter { overflow.contains($0.id) }.map { HeaderMenuItem(id: $0.id, title: $0.name, symbol: $0.symbol) }
    }

    /// How many tabs `width` wide and `spacing` apart fit in `room`.
    static func slots(in room: CGFloat, width: CGFloat, spacing: CGFloat) -> Int {
        max(0, Int(((room + spacing) / (width + spacing) + 1e-9).rounded(.down)))
    }
}

/// Which indicators the opened island's header has room for, beside the settings
/// button or Done. While all of them fit, all show. Otherwise a button at the end of
/// the strip counts the rest ("+2") and lists them. Those that must be seen wherever
/// the island is (`StatusIndicator.keepsIslandShown`: the camera and microphone) have
/// the first claim on the room, each while there is room left for it. Once all of
/// those are in, the others follow in their order, up to the first there is no room
/// for, so a small one further on never shows while one before it is counted. The
/// strip shows the ones kept in their order.
struct HeaderIndicatorFit: Equatable {
    /// The width of the button counting the rest, as a symbol indicator's.
    static let moreWidth = IndicatorCardLayout.symbolButtonWidth

    /// The indicators in the strip, and those behind the count, each in their order.
    var shown: [String]
    var overflow: [String] = []

    init(_ indicators: [StatusIndicator], room: CGFloat) {
        shown = indicators.map(\.id)
        let widths = indicators.map(Self.width(of:))
        guard widths.reduce(0, +) > room + 1e-9 else { return }
        let first = indicators.indices.filter { indicators[$0].keepsIslandShown }
        var used = Self.moreWidth
        var kept = Set<Int>()
        for index in first where used + widths[index] <= room + 1e-9 {
            used += widths[index]
            kept.insert(index)
        }
        if kept.count == first.count {
            for index in indicators.indices where !indicators[index].keepsIslandShown {
                guard used + widths[index] <= room + 1e-9 else { break }
                used += widths[index]
                kept.insert(index)
            }
        }
        shown = indicators.indices.filter { kept.contains($0) }.map { indicators[$0].id }
        overflow = indicators.indices.filter { !kept.contains($0) }.map { indicators[$0].id }
    }

    /// What the count's menu lists: the indicators behind it, in their order, each by
    /// what it says to VoiceOver or else its card's title. One with a card opens it; the
    /// rest are only named.
    func menuItems(_ indicators: [StatusIndicator]) -> [HeaderMenuItem] {
        indicators.filter { overflow.contains($0.id) }.map {
            HeaderMenuItem(
                id: $0.id, title: $0.label ?? $0.detail?.title ?? "Indicator", symbol: $0.symbol ?? "circle.fill",
                isEnabled: $0.detail != nil
            )
        }
    }

    /// How wide an indicator is in the header: a button, for one with a card, or its
    /// mark and the gap either side, as `HeaderIndicators` draws it.
    static func width(of indicator: StatusIndicator) -> CGFloat {
        if indicator.detail != nil {
            indicator.symbol == nil ? IndicatorCardLayout.dotButtonWidth : IndicatorCardLayout.symbolButtonWidth
        } else {
            (indicator.symbol == nil ? IslandLayout.indicatorDot : IslandLayout.indicatorSymbol.width) + IslandLayout.indicatorGap
        }
    }
}

/// An entry in one of the header's menus of what it has no room for.
struct HeaderMenuItem: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    var isEnabled = true
}

extension IslandLayout {
    /// The room either side of the notch in the opened island's header.
    var headerSideWidth: CGFloat {
        max(0, (size.width - 2 * earRadius - notch.width) / 2 - 16)
    }
}
