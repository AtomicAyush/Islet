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
                    let totalWeight = widgets.reduce(0) { $0 + $1.weight }
                    let spacing = CGFloat(widgets.count - 1) * 10
                    HStack(spacing: 10) {
                        ForEach(widgets) { widget in
                            HomeTile { widget.view }
                                .frame(width: (geo.size.width - spacing) * widget.weight / totalWeight)
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
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
