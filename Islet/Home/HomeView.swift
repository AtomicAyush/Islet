import SwiftUI

/// The opened island when nothing is running, or when its house tab is picked:
/// the date on the left and each feature's tile beside it.
struct HomeView: View {
    let widgets: [HomeWidget]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DateTile()
                .frame(width: 104)

            if widgets.isEmpty {
                Text("Nothing going on")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    TileRow(widgets: widgets, width: geo.size.width)
                }
            }
        }
        .padding(.top, 6)
    }
}

/// The widgets side by side, each getting its weight's share of the row. When the
/// shares would squeeze a tile below a readable width, the tiles keep that width
/// instead and the row scrolls sideways, fading at its trailing edge.
private struct TileRow: View {
    let widgets: [HomeWidget]
    let width: CGFloat

    /// The narrowest a weight-1 tile gets before the row starts scrolling.
    static let minimumUnit: CGFloat = 112
    static let spacing: CGFloat = 10

    var body: some View {
        let totalWeight = widgets.reduce(0) { $0 + $1.weight }
        let spacing = CGFloat(widgets.count - 1) * Self.spacing
        let share = (width - spacing) / max(totalWeight, 1)
        let unit = max(share, Self.minimumUnit)
        let scrolls = unit > share + 0.5

        let row = HStack(spacing: Self.spacing) {
            ForEach(widgets) { widget in
                HomeTile { widget.view }
                    .frame(width: unit * widget.weight)
            }
        }

        if scrolls {
            ScrollView(.horizontal, showsIndicators: false) { row }
                .mask(
                    LinearGradient(
                        stops: [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        } else {
            row
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
