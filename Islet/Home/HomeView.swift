import SwiftUI

/// The opened island when nothing is running, or when its house tab is picked:
/// the date on the left and each feature's tile beside it.
///
/// When the tiles would be squeezed below a readable width they keep that width,
/// and either scroll sideways in one row or are split into pages, each filling the
/// row exactly — whichever Settings asks for. With pages, dots under the date say
/// which is showing; clicking one, or a two-finger swipe sideways, turns the page.
///
/// The page's menu arranges it (`HomeEditing`): the tiles wiggle, drag to new places
/// and hide. A tile dragged over a page's dot turns to that page, and one held at
/// either end of a scrolling row scrolls it along.
struct HomeView: View {
    let widgets: [HomeWidget]
    @Binding var page: Int
    /// Arranging the page where it is shown; `nil` where it cannot be.
    var editing: HomeEditing? = nil
    @AppStorage(Prefs.Key.homeLayout) private var layout = HomeLayout.scroll.rawValue

    /// The narrowest a weight-1 tile gets before the row scrolls or pages.
    static let minimumUnit: CGFloat = 112
    static let spacing: CGFloat = 10

    @State private var pageCount = 1
    /// The tile being dragged to another place, while the page is arranged.
    @State private var dragging: String?
    /// The pages as they were when the drag began, by tile, kept until it is let go
    /// (`pages(of:width:holding:dragging:showing:)`).
    @State private var heldPages: [[String]]?

    private var usesPages: Bool { layout == HomeLayout.pages.rawValue }
    private var isArranging: Bool { editing?.isOn == true }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DateTile()
                .frame(width: 104)
                .accessibilityElement(children: .combine)
                // The page's menu, for VoiceOver, which may not reach a menu on the page.
                .accessibilityActions {
                    if let editing {
                        if editing.isOn {
                            Button("Done Editing Home Page") { editing.end() }
                        } else {
                            Button("Edit Home Page") { editing.begin() }
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) { pageDots }

            if widgets.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if usesPages {
                GeometryReader { geo in
                    let pages = Self.pages(
                        of: widgets, width: geo.size.width, holding: heldPages, dragging: dragging, showing: page
                    )
                    let current = min(max(page, 0), pages.count - 1)
                    TileRow(widgets: pages[current], width: geo.size.width, slot: slot)
                        // A new page, or tiles arriving or leaving, fade in afresh; tiles
                        // only changing places on it slide to their new ones. While the
                        // page is arranged, tiles coming and going slide in and out too,
                        // rather than the page under the pointer going.
                        .id(PageIdentity(index: current, tiles: isArranging ? nil : Set(pages[current].map(\.id))))
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 24)),
                            removal: .opacity.combined(with: .offset(x: -24))
                        ))
                        .onChange(of: pages.count, initial: true) { _, count in
                            pageCount = count
                            if page > count - 1 { page = count - 1 }
                        }
                        .onChange(of: page) { _, value in
                            // A swipe past the last page stays on it.
                            if value > pages.count - 1 { page = pages.count - 1 }
                        }
                        .onChange(of: dragging) { old, new in
                            if new == nil {
                                heldPages = nil
                            } else if old == nil {
                                heldPages = Self.pages(of: widgets, width: geo.size.width).map { $0.map(\.id) }
                            }
                        }
                }
            } else {
                GeometryReader { geo in
                    ScrollingTileRow(
                        widgets: widgets, width: geo.size.width,
                        overhang: isArranging ? HomeTileSlot.badgeOverhang : 0,
                        dragging: $dragging, slot: slot
                    )
                }
            }
        }
        .padding(.top, 6)
        .animation(.islandMorph, value: page)
        .animation(.easeOut(duration: 0.2), value: isArranging)
        // Anywhere on the page, the gaps and the empty page included.
        .contentShape(Rectangle())
        .contextMenu { pageMenu }
        .environment(\.editHomePage, isArranging ? nil : editing.map { EditHomePageAction(run: $0.begin) })
        // Let go between tiles, or over the date, a tile stays where the drag has put it
        // rather than sliding back as though it had been refused.
        .onDrop(of: [.homeTile], isTargeted: nil) { _ in
            guard dragging != nil else { return false }
            dragging = nil
            return true
        }
        // A drag let go outside the island is dropped nowhere here: the button coming up
        // says it is over.
        .task(id: dragging) {
            guard dragging != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    dragging = nil
                    return
                }
            }
        }
        .onChange(of: isArranging) { dragging = nil }
    }

    /// What an empty page says: when tiles are hidden, how to get them back.
    private var emptyText: String {
        let hidden = editing?.hiddenCount ?? 0
        if isArranging { return "No tiles showing" }
        if hidden > 0 { return "\(hidden) \(hidden == 1 ? "tile" : "tiles") hidden — right-click to edit" }
        return "Nothing going on"
    }

    /// Each tile in its slot, which arranges it while the page is arranged.
    private func slot(_ widget: HomeWidget) -> HomeTileSlot {
        HomeTileSlot(
            widget: widget,
            shown: widgets.map(\.id),
            editing: editing,
            dragging: $dragging
        )
    }

    @ViewBuilder
    private var pageMenu: some View {
        if let editing {
            if editing.isOn {
                Button("Done") { editing.end() }
            } else {
                Button("Edit Home Page") { editing.begin() }
            }
        }
    }

    @ViewBuilder
    private var pageDots: some View {
        if usesPages, pageCount > 1 {
            HStack(spacing: 5) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Button {
                        page = index
                    } label: {
                        Capsule()
                            .fill(.white.opacity(index == min(page, pageCount - 1) ? 0.9 : 0.3))
                            .frame(width: index == min(page, pageCount - 1) ? 14 : 6, height: 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // A tile dragged over a dot turns to that page, to be dropped there;
                    // let go on the dot, it stays where the drag has put it.
                    .onDrop(of: [.homeTile], isTargeted: Binding(
                        get: { false },
                        set: { if $0, isArranging { page = index } }
                    )) { _ in
                        guard dragging != nil else { return false }
                        dragging = nil
                        return true
                    }
                }
            }
            .padding(.leading, 4)
            .padding(.bottom, 2)
        }
    }

    /// Splits the tiles into pages, in order, each holding as many as fit at the
    /// minimum width.
    static func pages(of widgets: [HomeWidget], width: CGFloat) -> [[HomeWidget]] {
        var pages: [[HomeWidget]] = []
        var current: [HomeWidget] = []
        var weight: CGFloat = 0
        for widget in widgets {
            let needed = (weight + widget.weight) * minimumUnit + CGFloat(current.count) * spacing
            if !current.isEmpty, needed > width {
                pages.append(current)
                current = []
                weight = 0
            }
            current.append(widget)
            weight += widget.weight
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    /// The tiles on the pages `held` had them when a drag began, in their order now, so
    /// a tile dragged about does not push others onto another page, and the page under
    /// the pointer reflow, until it is let go. Once it has moved, the tile being dragged
    /// (and any not held) goes on the page of a tile beside it: the one showing, if
    /// either is on it. A page may be fuller than usual meanwhile, its tiles a little
    /// narrower.
    static func pages(
        of widgets: [HomeWidget], width: CGFloat, holding held: [[String]]?, dragging: String?, showing: Int
    ) -> [[HomeWidget]] {
        guard let held, !held.isEmpty else { return pages(of: widgets, width: width) }
        var pageOf: [String: Int] = [:]
        for (index, ids) in held.enumerated() {
            for id in ids { pageOf[id] = index }
        }
        // Not moved yet (turning to another page to drop it there, say), it stays put.
        let present = Set(widgets.map(\.id))
        let hasMoved = widgets.map(\.id).filter { pageOf[$0] != nil } != held.joined().filter(present.contains)
        var places: [Int?] = widgets.map { $0.id == dragging && hasMoved ? nil : pageOf[$0.id] }
        for index in places.indices where places[index] == nil {
            let before = places[..<index].last { $0 != nil } ?? nil
            let after = places[(index + 1)...].first { $0 != nil } ?? nil
            places[index] = [before, after].contains(showing) ? showing : before ?? after ?? 0
        }
        var pages = Array(repeating: [HomeWidget](), count: held.count)
        for (widget, place) in zip(widgets, places) {
            pages[min(place ?? 0, held.count - 1)].append(widget)
        }
        return pages
    }

    /// The tile to bring into view, scrolling a row of tiles one tile toward `edge`: the
    /// last that starts before the visible part, going back, or the first that ends past
    /// it, going on. `widths` are the tiles', `offset` how far the row has scrolled, and
    /// `width` how much of it shows.
    static func scrollTarget(toward edge: HorizontalEdge, widths: [CGFloat], offset: CGFloat, width: CGFloat) -> Int? {
        var start: CGFloat = 0
        var frames: [(start: CGFloat, end: CGFloat)] = []
        for tileWidth in widths {
            frames.append((start, start + tileWidth))
            start += tileWidth + HomeView.spacing
        }
        switch edge {
        case .leading:
            return frames.lastIndex { $0.start < offset - 1 }
        case .trailing:
            return frames.firstIndex { $0.end > offset + width + 1 }
        }
    }
}

/// What a page of tiles is, for its transition: which page, and which tiles are on it
/// (`nil` while the page is arranged).
private struct PageIdentity: Hashable {
    var index: Int
    var tiles: Set<String>?
}

/// One page of tiles, each getting its weight's share of the row.
private struct TileRow: View {
    let widgets: [HomeWidget]
    let width: CGFloat
    let slot: (HomeWidget) -> HomeTileSlot

    var body: some View {
        let totalWeight = widgets.reduce(0) { $0 + $1.weight }
        let spacing = CGFloat(widgets.count - 1) * HomeView.spacing
        let unit = (width - spacing) / max(totalWeight, 1)

        HStack(spacing: HomeView.spacing) {
            ForEach(widgets) { widget in
                slot(widget)
                    .frame(width: unit * widget.weight)
            }
        }
    }
}

/// Every tile in one row, sharing it by weight while they fit; past that they keep
/// the minimum width and the row scrolls, snapping to tile edges. An edge fades only
/// while there is more to scroll to on that side, so the last tile, once scrolled
/// to, is shown whole. A tile dragged to either end, while there is more that way,
/// scrolls the row along a tile at a time.
private struct ScrollingTileRow: View {
    let widgets: [HomeWidget]
    let width: CGFloat
    /// Room kept past the top and leading edges, inside the scrolling, for the hide
    /// badges while the page is arranged (`HomeTileSlot.badgeOverhang`). Elsewhere the
    /// badges have the page's top margin and the gap beside the date.
    var overhang: CGFloat = 0
    @Binding var dragging: String?
    let slot: (HomeWidget) -> HomeTileSlot

    static let fade: CGFloat = 22
    /// How wide the ends are that scroll the row while a tile is dragged over them, and
    /// how often they move it on.
    static let scrollEdge: CGFloat = 28
    static let scrollInterval: Duration = .milliseconds(450)

    /// How far the row has scrolled from its start, in points.
    @State private var offset: CGFloat = 0
    /// The end a dragged tile is held over, scrolling the row that way.
    @State private var scrollingToward: HorizontalEdge?

    var body: some View {
        let totalWeight = widgets.reduce(0) { $0 + $1.weight }
        let spacing = CGFloat(widgets.count - 1) * HomeView.spacing
        let share = (width - spacing) / max(totalWeight, 1)
        let unit = max(share, HomeView.minimumUnit)
        let contentWidth = unit * totalWeight + spacing
        let more = (leading: offset > 1, trailing: offset + width < contentWidth - 1)

        let row = HStack(spacing: HomeView.spacing) {
            ForEach(widgets) { widget in
                slot(widget)
                    .frame(width: unit * widget.weight)
            }
        }

        if contentWidth <= width + 0.5 {
            row
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    row.scrollTargetLayout()
                        .background {
                            // Where the row sits, for macOS 14, which has no scroll geometry.
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: RowOffsetKey.self,
                                    value: overhang - geo.frame(in: .named(RowOffsetKey.space)).minX
                                )
                            }
                        }
                }
                .contentMargins(.leading, overhang, for: .scrollContent)
                .contentMargins(.top, overhang, for: .scrollContent)
                .coordinateSpace(name: RowOffsetKey.space)
                .scrollTargetBehavior(.viewAligned)
                .modifier(ScrollOffsetReader(offset: $offset))
                .mask(edgeFades(leading: more.leading, trailing: more.trailing))
                .overlay {
                    if dragging != nil {
                        HStack(spacing: 0) {
                            scrollEdge(.leading, isOn: more.leading)
                            Spacer(minLength: 0)
                            scrollEdge(.trailing, isOn: more.trailing)
                        }
                    }
                }
                .task(id: scrollingToward) {
                    guard let edge = scrollingToward else { return }
                    while !Task.isCancelled {
                        let target = HomeView.scrollTarget(
                            toward: edge, widths: widgets.map { unit * $0.weight }, offset: offset, width: width
                        )
                        guard let target else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(widgets[target].id, anchor: edge == .leading ? .leading : .trailing)
                        }
                        try? await Task.sleep(for: Self.scrollInterval)
                    }
                }
                .onChange(of: dragging == nil) { scrollingToward = nil }
                // Out over the room kept for the badges, the tiles staying where they were.
                .padding(.leading, -overhang)
                .padding(.top, -overhang)
            }
        }
    }

    /// One end of the row, which scrolls it while a dragged tile is held over it; let
    /// go there, the tile stays where the drag has put it.
    @ViewBuilder
    private func scrollEdge(_ edge: HorizontalEdge, isOn: Bool) -> some View {
        if isOn {
            Color.clear
                .frame(width: Self.scrollEdge)
                .contentShape(Rectangle())
                .onDrop(of: [.homeTile], isTargeted: Binding(
                    get: { scrollingToward == edge },
                    set: { targeted in
                        if targeted { scrollingToward = edge } else if scrollingToward == edge { scrollingToward = nil }
                    }
                )) { _ in
                    scrollingToward = nil
                    guard dragging != nil else { return false }
                    dragging = nil
                    return true
                }
        }
    }

    private func edgeFades(leading: Bool, trailing: Bool) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: leading ? Self.fade : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: trailing ? Self.fade : 0)
        }
        .animation(.easeOut(duration: 0.18), value: leading)
        .animation(.easeOut(duration: 0.18), value: trailing)
    }
}

/// Reports a horizontal scroll view's offset. macOS 15 says so directly; macOS 14
/// infers it from where the row sits in the scroll view's coordinate space.
private struct ScrollOffsetReader: ViewModifier {
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x + geometry.contentInsets.leading
            } action: { _, new in
                offset = new
            }
        } else {
            content.onPreferenceChange(RowOffsetKey.self) { offset = $0 }
        }
    }
}

private struct RowOffsetKey: PreferenceKey {
    static let space = "homeTileRow"
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A rounded, faintly lit card for a home widget.
struct HomeTile<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
    }
}

private struct DateTile: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text(context.date.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.9))
                Text(context.date.formatted(.dateTime.day()))
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(context.date.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 4)
        }
    }
}
