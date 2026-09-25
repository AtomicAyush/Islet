import SwiftUI

/// The whole canvas: the island hanging from the top centre, and the detached bubble
/// beside it when two activities are running.
struct IslandRootView: View {
    let model: IslandViewModel
    /// Told whenever the island's footprint changes, so the controller can update
    /// where clicks are caught.
    var onLayoutChange: (IslandLayout) -> Void = { _ in }

    var body: some View {
        let layout = model.layout

        ZStack(alignment: .top) {
            if let bubble = model.bubbleActivity {
                MinimalBubble(activity: bubble, diameter: layout.bubbleDiameter) {
                    model.expand(focus: bubble.id)
                }
                .offset(
                    x: layout.bubbleCenterOffset.width,
                    y: layout.bubbleCenterOffset.height - layout.bubbleDiameter / 2
                )
                .transition(.bubbleDetach(distance: layout.bubbleCenterOffset.width))
            }

            IslandSurface(model: model, layout: layout)
                .offset(x: layout.centerOffset)
        }
        .frame(width: IslandLayout.canvas.width, height: IslandLayout.canvas.height, alignment: .top)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: layout, initial: true) { _, new in onLayoutChange(new) }
    }
}

/// The black island itself, with whatever the current mode puts inside it.
private struct IslandSurface: View {
    let model: IslandViewModel
    let layout: IslandLayout

    var body: some View {
        let shape = IslandShape(earRadius: layout.earRadius, bottomRadius: layout.bottomRadius)

        ZStack(alignment: .top) {
            shape.fill(Color.black)

            content
                .id(model.contentKey)
                .transition(.islandContent)
                .padding(.horizontal, layout.earRadius)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .shadow(color: .black.opacity(layout.showsShadow ? 0.5 : 0), radius: 20, y: 10)
        .onTapGesture { model.tap() }
        .opacity(model.mode == .hidden ? 0 : 1)
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .hidden:
            Color.clear.frame(height: layout.notch.height)

        case .idle:
            if model.center.indicators.isEmpty {
                Color.clear.frame(height: layout.notch.height)
            } else {
                CompactRow(
                    leading: AnyView(EmptyView()),
                    trailing: AnyView(EmptyView()),
                    indicators: model.center.indicators,
                    layout: layout
                )
            }

        case .compact(let id):
            if let activity = model.center.activity(id: id) {
                CompactRow(
                    leading: activity.compactLeading(),
                    trailing: activity.compactTrailing(),
                    indicators: model.center.indicators,
                    layout: layout
                )
            }

        case .banner:
            if let banner = model.center.banner {
                switch banner.style {
                case .compact:
                    CompactRow(leading: banner.leading, trailing: banner.trailing, indicators: [], layout: layout)
                case .card:
                    VStack(spacing: 0) {
                        Color.clear.frame(height: layout.notch.height)
                        banner.content
                            .frame(height: layout.bodyHeight)
                            .padding(.horizontal, IslandLayout.expandedInset.leading)
                    }
                }
            }

        case .expanded(let focus):
            ExpandedIsland(model: model, focus: focus, layout: layout)
        }
    }
}

/// Compact content: one view left of the notch, one right, and the camera between.
/// Indicator dots, if any, sit at the far right.
private struct CompactRow: View {
    let leading: AnyView
    let trailing: AnyView
    let indicators: [StatusIndicator]
    let layout: IslandLayout

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: layout.leadingWidth, height: layout.notch.height)
            Spacer(minLength: layout.notch.width)
            trailing
                .frame(width: max(0, layout.trailingWidth - layout.indicatorWidth), height: layout.notch.height)
            if layout.indicatorWidth > 0 {
                IndicatorDots(indicators: indicators)
                    .frame(width: layout.indicatorWidth, height: layout.notch.height, alignment: .leading)
            }
        }
        .frame(height: layout.notch.height)
    }
}

struct IndicatorDots: View {
    let indicators: [StatusIndicator]

    var body: some View {
        HStack(spacing: IslandLayout.indicatorPitch - 7) {
            ForEach(indicators) { indicator in
                Circle()
                    .fill(indicator.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: indicator.color.opacity(0.6), radius: 3)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 2)
    }
}

/// The detached circle the iPhone uses for a second live activity.
private struct MinimalBubble: View {
    let activity: any IslandActivity
    let diameter: CGFloat
    let onTap: () -> Void

    var body: some View {
        activity.minimal()
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color.black))
            .clipShape(Circle())
            .contentShape(Circle())
            .onTapGesture(perform: onTap)
    }
}

private struct BubbleDetach: ViewModifier {
    var progress: CGFloat
    var distance: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.6 * progress)
            .offset(x: -distance * 0.35 * progress)
            .opacity(Double(1 - progress))
            .blur(radius: 3 * progress)
    }
}

extension AnyTransition {
    /// The bubble buds off the island's right edge and springs out to its place.
    static func bubbleDetach(distance: CGFloat) -> AnyTransition {
        .modifier(
            active: BubbleDetach(progress: 1, distance: distance),
            identity: BubbleDetach(progress: 0, distance: distance)
        )
    }
}

// MARK: - Expanded

private struct ExpandedIsland: View {
    let model: IslandViewModel
    let focus: String
    let layout: IslandLayout

    var body: some View {
        VStack(spacing: 0) {
            ExpandedHeader(model: model, focus: focus, layout: layout)
                .frame(height: layout.notch.height)

            page
                .id(focus)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                .frame(height: layout.bodyHeight, alignment: .top)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, IslandLayout.expandedInset.leading - 6)
    }

    @ViewBuilder
    private var page: some View {
        if focus == IslandViewModel.dropFocus, let target = model.center.dropTarget {
            target.view()
        } else if focus == IslandViewModel.homeFocus {
            HomeView(widgets: model.center.homeWidgets)
        } else if let activity = model.center.activity(id: focus) {
            activity.expanded()
        }
    }
}

/// The row beside the notch: tabs on the left, a compact banner or settings on the
/// right.
private struct ExpandedHeader: View {
    let model: IslandViewModel
    let focus: String
    let layout: IslandLayout

    var body: some View {
        let sideWidth = max(0, (layout.size.width - 2 * layout.earRadius - layout.notch.width) / 2 - 16)

        HStack(spacing: 0) {
            tabs
                .frame(width: sideWidth, alignment: .leading)
            Spacer(minLength: layout.notch.width)
            trailing
                .frame(width: sideWidth, alignment: .trailing)
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            if !model.center.activities.isEmpty {
                TabButton(symbol: "house.fill", isSelected: focus == IslandViewModel.homeFocus) {
                    model.select(focus: IslandViewModel.homeFocus)
                }
                ForEach(model.center.activities, id: \.id) { activity in
                    TabButton(symbol: activity.symbol, isSelected: focus == activity.id) {
                        model.select(focus: activity.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let banner = model.center.banner, case .compact = banner.style {
            HStack(spacing: 6) {
                banner.leading.frame(width: 22)
                banner.trailing
            }
            .frame(height: layout.notch.height)
            .transition(.opacity)
        } else {
            HStack(spacing: 8) {
                if !model.center.indicators.isEmpty {
                    IndicatorDots(indicators: model.center.indicators)
                }
                TabButton(symbol: "gearshape.fill", isSelected: false) {
                    model.collapse()
                    SettingsWindowController.shared.show()
                }
            }
        }
    }
}

private struct TabButton: View {
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? .white : .white.opacity(isHovering ? 0.75 : 0.45))
                .frame(width: 24, height: 20)
                .background(
                    Capsule().fill(.white.opacity(isSelected ? 0.16 : (isHovering ? 0.08 : 0)))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
