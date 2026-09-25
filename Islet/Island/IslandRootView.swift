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
            BubbleLayer(model: model, layout: layout)

            IslandSurface(model: model, layout: layout)
                .offset(x: layout.centerOffset, y: layout.topInset)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = IslandShape(
            earRadius: layout.earRadius,
            bottomRadius: layout.bottomRadius,
            topRadius: layout.topRadius
        )

        ZStack(alignment: .top) {
            shape.fill(Color.black)

            content
                .id(model.contentKey)
                .transition(.islandContent)
                .padding(.horizontal, layout.earRadius)
        }
        // Width and height spring separately — width a little livelier — so the
        // island stretches sideways a beat before it drops, rather than scaling
        // like a rectangle.
        .animation(.islandWidth) { $0.frame(width: layout.size.width, alignment: .top) }
        .animation(.islandHeight) { $0.frame(height: layout.size.height, alignment: .top) }
        .clipShape(shape)
        .contentShape(shape)
        .keyframeAnimator(initialValue: Squash(), trigger: model.contentKey) { [reduceMotion] view, squash in
            view.scaleEffect(x: reduceMotion ? 1 : squash.x, y: reduceMotion ? 1 : squash.y, anchor: .top)
        } keyframes: { _ in
            // A brief squash and rebound on every change of shape, like the iPhone's
            // island absorbing the impact of new content.
            KeyframeTrack(\.x) {
                SpringKeyframe(1.035, duration: 0.14, spring: .snappy)
                SpringKeyframe(0.994, duration: 0.16, spring: .snappy)
                SpringKeyframe(1, duration: 0.2, spring: .smooth)
            }
            KeyframeTrack(\.y) {
                SpringKeyframe(0.95, duration: 0.14, spring: .snappy)
                SpringKeyframe(1.012, duration: 0.16, spring: .snappy)
                SpringKeyframe(1, duration: 0.2, spring: .smooth)
            }
        }
        .shadow(color: .black.opacity(layout.showsShadow ? 0.5 : 0), radius: 18, y: 8)
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

private struct Squash {
    var x: CGFloat = 1
    var y: CGFloat = 1
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

/// The detached bubble the iPhone uses for a second live activity. It keeps the
/// activity it last showed so it can merge back into the island after that
/// activity has already gone.
private struct BubbleLayer: View {
    let model: IslandViewModel
    let layout: IslandLayout
    @State private var shown: (any IslandActivity)?
    @State private var progress: CGFloat = 0

    var body: some View {
        BubbleDroplet(progress: progress, layout: layout, activity: shown) { id in
            model.expand(focus: id)
        }
        .onChange(of: model.bubbleActivity?.id, initial: true) { _, id in
            if let activity = model.bubbleActivity { shown = activity }
            withAnimation(id == nil ? .islandClose : .islandMorph) {
                progress = id == nil ? 0 : 1
            } completion: {
                if model.bubbleActivity == nil { shown = nil }
            }
        }
    }
}

/// The bubble budding off the island like a droplet. Both are drawn as black
/// circles through a blur and an alpha threshold, so while they are close a neck
/// of "liquid" joins them, stretches, and snaps — the way the iPhone's island
/// splits in two. Once the bubble has settled it is drawn plainly.
private struct BubbleDroplet: View, Animatable {
    var progress: CGFloat
    let layout: IslandLayout
    let activity: (any IslandActivity)?
    let onTap: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let d = layout.bubbleDiameter
        let h = layout.notch.height
        let target = layout.bubbleCenterOffset
        // The island's rounded right end, relative to the notch's centre.
        let islandRight = layout.centerOffset + layout.size.width / 2 - layout.earRadius
        let tucked = islandRight - d / 2
        let x = reduceMotion ? target.width : tucked + (target.width - tucked) * progress
        let scale = reduceMotion ? 1 : 0.55 + 0.45 * min(progress, 1.2)
        // With Reduce Motion on, the bubble just fades in place: no neck, no travel.
        let isMoving = !reduceMotion && progress > 0.001 && abs(progress - 1) > 0.001

        ZStack(alignment: .top) {
            if isMoving {
                Canvas { context, size in
                    context.addFilter(.alphaThreshold(min: 0.5, color: .black))
                    context.addFilter(.blur(radius: 4))
                    context.drawLayer { layer in
                        let mid = size.width / 2
                        let cap = h / 2 - 1
                        layer.fill(
                            Path(ellipseIn: CGRect(x: mid + islandRight - 2 * cap, y: target.height - cap, width: 2 * cap, height: 2 * cap)),
                            with: .color(.black)
                        )
                        let r = d / 2 * scale
                        layer.fill(
                            Path(ellipseIn: CGRect(x: mid + x - r, y: target.height - r, width: 2 * r, height: 2 * r)),
                            with: .color(.black)
                        )
                    }
                }
                .frame(width: IslandLayout.canvas.width, height: layout.topInset + h + 12)
                .allowsHitTesting(false)
            }

            if let activity, progress > 0.001 {
                activity.minimal()
                    .frame(width: d, height: d)
                    .background(Circle().fill(Color.black))
                    .clipShape(Circle())
                    .opacity(Double(min(1, max(0, (progress - 0.35) / 0.5))))
                    .background(Circle().fill(Color.black))
                    .scaleEffect(scale)
                    .contentShape(Circle())
                    .onTapGesture { onTap(activity.id) }
                    .offset(x: x, y: target.height - d / 2)
            }
        }
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
                banner.leading.frame(width: 24)
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
