import SwiftUI

/// A filled circular button in the iPhone Live Activity style.
struct RoundButton: View {
    let symbol: String
    let tint: Color
    var diameter: CGFloat = 38
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.38, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(tint.opacity(isHovering ? 0.3 : 0.2)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// How far something has come, as a ring that fills in `tint` over a faint track of
/// it, eased from one look to the next: a download's, a copy's.
struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// The island's wings for things under way, a download's or a copy's: the icon of the
/// newest left of the camera, and its ring right of it, with a count beside the ring
/// while several go at once.
enum ProgressWingLayout {
    static let compactIcon: CGFloat = 20
    static let compactMark: CGFloat = 16
    /// Room for the count beside the ring while several are under way.
    static let countedTrailingWidth: CGFloat = 60
    static let expandedHeight: CGFloat = 76

    /// Between the ring and the island's outer end, in a row `rowHeight` tall: the icon
    /// on the left is centred in the default wing, so the ring is centred in the same
    /// width at the right, whatever the notch's height, and stays there when the count
    /// widens its wing.
    static func trailingInset(rowHeight: CGFloat) -> CGFloat {
        max(0, (IslandLayout.defaultSide(for: CGSize(width: 0, height: rowHeight)) - compactMark) / 2)
    }
}

/// Left of the notch: the newest one's icon, `ProgressWingLayout.compactIcon` across,
/// springing in when another takes its place.
struct ProgressWingLeading<Icon: View>: View {
    /// Which one the icon is for; `nil` for none.
    let id: String?
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        ZStack {
            if let id {
                icon()
                    .id(id)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: id)
    }
}

/// Right of the notch: the newest one's ring (`mark`), with how many are under way
/// when there are several.
struct ProgressWingTrailing<Mark: View>: View {
    let count: Int
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 5) {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize()
                        .transition(.opacity)
                }
                mark()
                    .frame(width: ProgressWingLayout.compactMark, height: ProgressWingLayout.compactMark)
            }
            .padding(.trailing, ProgressWingLayout.trailingInset(rowHeight: proxy.size.height))
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
    }
}
