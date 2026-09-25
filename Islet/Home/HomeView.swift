import SwiftUI

/// The opened island when nothing is running, or when its house tab is picked:
/// the date on the left and each feature's tile beside it.
///
/// When the tiles would be squeezed below a readable width they are split into
/// pages, each filling the row exactly — no tile is ever shown in part. Dots under the
/// date say which page is showing; clicking one, or a two-finger swipe sideways over
/// the island, turns the page.
struct HomeView: View {
    let widgets: [HomeWidget]
    @Binding var page: Int

    /// The narrowest a weight-1 tile gets before tiles move to another page.
    static let minimumUnit: CGFloat = 112
    static let spacing: CGFloat = 10

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DateTile()
                .frame(width: 104)
                .overlay(alignment: .bottomLeading) { pageDots }

            if widgets.isEmpty {
                Text("Nothing going on")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let pages = Self.pages(of: widgets, width: geo.size.width)
                    let current = min(max(page, 0), pages.count - 1)
                    TileRow(widgets: pages[current], width: geo.size.width)
                        .id(pages[current].map(\.id))
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 24)),
                            removal: .opacity.combined(with: .offset(x: -24))
                        ))
                        .onAppear { pageCount = pages.count }
                        .onChange(of: pages.count, initial: true) { _, count in
                            pageCount = count
                            if page > count - 1 { page = count - 1 }
                        }
                        .onChange(of: page) { _, value in
                            // A swipe past the last page stays on it.
                            if value > pages.count - 1 { page = pages.count - 1 }
                        }
                }
            }
        }
        .padding(.top, 6)
        .animation(.islandMorph, value: page)
    }

    @State private var pageCount = 1

    @ViewBuilder
    private var pageDots: some View {
        if pageCount > 1 {
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
}

/// One page of tiles, each getting its weight's share of the row.
private struct TileRow: View {
    let widgets: [HomeWidget]
    let width: CGFloat

    var body: some View {
        let totalWeight = widgets.reduce(0) { $0 + $1.weight }
        let spacing = CGFloat(widgets.count - 1) * HomeView.spacing
        let unit = (width - spacing) / max(totalWeight, 1)

        HStack(spacing: HomeView.spacing) {
            ForEach(widgets) { widget in
                HomeTile { widget.view }
                    .frame(width: unit * widget.weight)
            }
        }
    }
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
