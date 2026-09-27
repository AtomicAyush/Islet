import SwiftUI

/// The whole canvas: the island hanging from the top centre, and the detached bubble
/// beside it when two activities are running and the menu bar has room for it.
struct IslandRootView: View {
    let model: IslandViewModel
    /// Told whenever the island's footprint changes, so the controller can update
    /// where clicks are caught.
    var onLayoutChange: (IslandLayout) -> Void = { _ in }
    @AppStorage(Prefs.Key.expandOnHover) private var expandOnHover = true

    var body: some View {
        let layout = model.layout

        ZStack(alignment: .top) {
            BubbleLayer(model: model, layout: layout)

            IslandSurface(model: model, layout: layout)
                .offset(y: layout.topInset)

            if model.standsInOnEdge, !expandOnHover {
                EdgeStrip(model: model)
            }
        }
        .frame(width: IslandLayout.canvas.width, height: IslandLayout.canvas.height, alignment: .top)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: layout, initial: true) { _, new in onLayoutChange(new) }
    }
}

/// The strip at the top edge that stands in for the island while it is hidden for a
/// full-screen app on a display without a notch (`IslandViewModel.hiddenTarget`), for
/// someone who opens the island by clicking. Nothing of the island is drawn there, and
/// the window lets a click on nothing through to the app below, which would take the
/// click as well as the island opening; so the strip is drawn, too faint to see, for the
/// window to take the click itself. Opening on hover, it is not drawn, and a click on
/// the app's top edge stays the app's.
private struct EdgeStrip: View {
    let model: IslandViewModel

    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.01))
            .frame(width: model.hiddenTarget.width, height: IslandViewModel.edgeTargetHeight)
            .contentShape(Rectangle())
            .onTapGesture { model.tap() }
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

            // Its own layer under the compact row, so arriving and leaving it never
            // touches the content above: the island grows down to it, and it comes out
            // of a blur the way content does.
            AttachmentLayer(attachment: model.attachment, layout: layout, isOpen: model.isExpanded)
        }
        // Width and height spring separately — width a little livelier — so the
        // island stretches sideways a beat before it drops, rather than scaling
        // like a rectangle.
        .animation(.islandWidth) { $0.frame(width: layout.size.width, alignment: .top) }
        .animation(.islandHeight) { $0.frame(height: layout.size.height, alignment: .top) }
        .clipShape(shape)
        .contentShape(shape)
        .onDrop(of: IslandDropDelegate.offeredTypes, delegate: IslandDropDelegate(model: model, layout: layout))
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
        .onTapGesture { location in
            // The folded second activity's end of the island opens that activity: the
            // same patch the controller treats as hovering it, not just its circle.
            if let folded = model.foldedActivity, layout.foldedTarget.contains(location) {
                model.expand(focus: folded.id)
            } else if let id = IndicatorCardLayout.compactIndicator(at: location, in: layout, indicators: model.center.indicators) {
                model.expand(showingCardOf: id)
            } else {
                model.tap()
            }
        }
        // Hidden for a full-screen app on a display without a notch, the island is not
        // drawn, so it comes and goes by its opacity. Opening, it is there at once, at
        // the resting pill's size, and grows as it does outside full screen rather than
        // fading in as a grey ghost; closing, it stays until it has all but shrunk back
        // to the pill, then goes.
        .transaction { transaction in
            guard model.opensWhileSuppressed else { return }
            transaction.animation = layout.isDrawn ? nil : .easeIn(duration: 0.1).delay(0.2)
        } body: {
            $0.opacity(layout.isDrawn ? 1 : 0)
        }
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
                    layout: layout,
                    folded: model.foldedActivity,
                    isFoldedHovered: model.isHoveringSecondary
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

/// The row an attachment rides in, under the notch row: across the island's body and
/// centred on the notch, whatever the compact content either side of the notch is
/// doing. It takes no clicks; a click there is on the island.
///
/// The layer is always there, and the row hangs from a point at the notch's centre
/// rather than from the island's edges. A view on its way out keeps the frame it last
/// had in its parent; with the island for a parent, whose edges move as it narrows or
/// opens, the row would slide sideways with the island's leading edge as it faded.
/// From a point that never moves, it comes and goes where it belongs, under the notch.
private struct AttachmentLayer: View {
    let attachment: IslandAttachment?
    let layout: IslandLayout
    /// The island is open, and its header shows the attachment as its banner. The row
    /// goes at once rather than fade out over the page coming in, a second level on
    /// screen beside the header's.
    let isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: .top) {
                if let attachment {
                    attachment.content
                        .frame(width: layout.attachmentWidth, height: attachment.height)
                        .padding(.top, layout.notch.height)
                        // A row laid out afresh at a new width (another device's longer
                        // name) cross-fades, the way the island's content does, while the
                        // island springs out to it: stretched in place, its content,
                        // already at its new layout, would sit off-centre, or run past
                        // the island's edges, until the spring settled.
                        .id(RowIdentity(id: attachment.id, width: layout.attachmentWidth))
                        .transition(reduceMotion ? .attachmentFade : .islandContent)
                }
            }
            // Its own geometry, so the row is placed from this point, which stays put,
            // rather than from the island's edges, which do not.
            .geometryGroup()
            .animation(nil) { $0.opacity(isOpen ? 0 : 1) }
            .allowsHitTesting(false)
    }

    private struct RowIdentity: Hashable {
        let id: String
        let width: CGFloat
    }
}

extension AnyTransition {
    /// An attachment's row with Reduce Motion: no blur or shrink, just the fade, on the
    /// island content's own timings rather than whichever spring moved the island.
    fileprivate static var attachmentFade: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.28).delay(0.07)),
            removal: .opacity.animation(.easeIn(duration: 0.14))
        )
    }
}

/// Compact content: one view left of the notch, one right, and the camera between.
/// Each view gets the width it asked for at its wing's outer edge; indicator dots,
/// if any, sit at the far right, and a second activity with no room for its bubble
/// sits at the far left.
private struct CompactRow: View {
    let leading: AnyView
    let trailing: AnyView
    let indicators: [StatusIndicator]
    let layout: IslandLayout
    var folded: (any IslandActivity)? = nil
    var isFoldedHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                if let folded {
                    folded.minimal()
                        .frame(width: IslandLayout.foldedDiameter, height: IslandLayout.foldedDiameter)
                        .clipShape(Circle())
                        .secondaryHover(isFoldedHovered)
                        .padding(.leading, IslandLayout.foldedInset)
                        .frame(width: layout.foldedWidth, alignment: .leading)
                        .id(folded.id)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                }
                leading
                    .frame(width: layout.leadingContentWidth - layout.foldedWidth, height: layout.notch.height)
            }
            .frame(width: layout.leadingWidth, alignment: .leading)
            Spacer(minLength: layout.notch.width)
            HStack(spacing: 0) {
                trailing
                    .frame(
                        width: max(0, layout.trailingContentWidth - layout.indicatorWidth),
                        height: layout.notch.height
                    )
                if layout.indicatorWidth > 0 {
                    IndicatorDots(indicators: indicators)
                        .frame(width: layout.indicatorWidth, height: layout.notch.height, alignment: .leading)
                }
            }
            .frame(width: layout.trailingWidth, alignment: .trailing)
        }
        .frame(height: layout.notch.height)
    }
}

extension View {
    /// The second activity's circle — the bubble, or its icon folded into the island —
    /// with the pointer on it: it swells a little and gains a faint ring, to say a
    /// click opens it.
    fileprivate func secondaryHover(_ isHovered: Bool, scale: CGFloat = 1) -> some View {
        overlay(Circle().strokeBorder(Color.white.opacity(isHovered ? 0.22 : 0), lineWidth: 1))
            .scaleEffect(scale * (isHovered ? 1.14 : 1))
            .animation(.islandHover, value: isHovered)
    }
}

struct IndicatorDots: View {
    let indicators: [StatusIndicator]

    /// Room before the first mark, within the strip `IslandLayout` gives the dots.
    static let leading: CGFloat = 2

    var body: some View {
        HStack(spacing: IslandLayout.indicatorGap) {
            ForEach(indicators) { indicator in
                IndicatorMark(indicator: indicator)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, Self.leading)
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
        BubbleDroplet(progress: progress, layout: layout, activity: shown, isHovered: model.isHoveringSecondary) { id in
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
    /// The pointer is on the bubble: it swells a little and lifts, to say it opens.
    let isHovered: Bool
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
        let islandRight = layout.size.width / 2 - layout.earRadius
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
                    .secondaryHover(isHovered, scale: scale)
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
                // Under an open card the page takes no clicks, and VoiceOver skips it.
                .accessibilityHidden(when: model.indicatorCard != nil)
        }
        .indicatorCard(model: model, layout: layout)
        .padding(.horizontal, IslandLayout.expandedInset.leading - 6)
    }

    @ViewBuilder
    private var page: some View {
        if focus == IslandViewModel.dropFocus, let target = model.center.dropTarget {
            target.view()
        } else if focus == IslandViewModel.homeFocus {
            HomeView(
                widgets: model.center.shownHomeWidgets,
                page: Binding(get: { model.homePage }, set: { model.homePage = $0 }),
                editing: homeEditing
            )
        } else if let activity = model.center.activity(id: focus) {
            activity.expanded()
        } else if let page = model.center.pages[focus] {
            page.view
        }
    }

    /// Arranging the home page from this island: its model says whether it is being
    /// arranged, and the moves go to the one arrangement every island shares.
    private var homeEditing: HomeEditing {
        let center = model.center
        let arrangement = center.homeArrangement
        return HomeEditing(
            isOn: model.isEditingHome,
            wiggles: model.isHovering,
            hiddenCount: center.homeWidgets.filter { arrangement.isHidden($0.id) }.count,
            begin: { model.editHome() },
            end: { model.endEditingHome() },
            move: { id, destination, shown in arrangement.move(id, to: destination, in: shown) },
            hide: { id in withAnimation(.islandMorph) { arrangement.setHidden(true, id) } },
            title: { arrangement.title(of: $0) }
        )
    }
}

/// The row beside the notch: tabs on the left, a compact banner or settings on the
/// right. While the home page is arranged, its hidden tiles on the left instead, and
/// Done on the right beside the banner or indicators.
private struct ExpandedHeader: View {
    let model: IslandViewModel
    let focus: String
    let layout: IslandLayout

    var body: some View {
        let sideWidth = max(0, (layout.size.width - 2 * layout.earRadius - layout.notch.width) / 2 - 16)
        let arranging = model.isEditingHome && focus == IslandViewModel.homeFocus

        HStack(spacing: 0) {
            Group {
                if arranging {
                    HiddenTilesMenu(arrangement: model.center.homeArrangement)
                } else {
                    tabs
                }
            }
            .frame(width: sideWidth, alignment: .leading)
            Spacer(minLength: layout.notch.width)
            Group {
                if arranging {
                    arrangingTrailing
                } else {
                    trailing
                }
            }
            .frame(width: sideWidth, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.2), value: arranging)
    }

    private var tabs: some View {
        let page = model.center.pages[focus]
        return HStack(spacing: 4) {
            if !model.center.activities.isEmpty || page != nil {
                TabButton(symbol: "house.fill", isSelected: focus == IslandViewModel.homeFocus) {
                    model.select(focus: IslandViewModel.homeFocus)
                }
                ForEach(model.center.activities, id: \.id) { activity in
                    TabButton(symbol: activity.symbol, isSelected: focus == activity.id) {
                        model.select(focus: activity.id)
                    }
                }
                // A feature's page has a tab only while it is open; home is the way back.
                if let page {
                    TabButton(symbol: page.symbol, isSelected: true) {}
                }
            }
        }
    }

    /// A compact banner, as the header shows it.
    private var compactBanner: IslandBanner? {
        // An attachment has no compact row to ride under here, so it shows as its
        // banner would, ahead of any other banner.
        guard let banner = model.center.attachment?.banner ?? model.center.banner,
              case .compact = banner.style else { return nil }
        return banner
    }

    private func headerBanner(_ banner: IslandBanner) -> some View {
        HStack(spacing: 6) {
            banner.leading.frame(width: 24)
            banner.trailing
        }
        .frame(height: layout.notch.height)
        .environment(\.isInIslandHeader, true)
        .transition(.opacity)
    }

    /// Done, with the banner or the indicators beside it where they fit: the camera and
    /// microphone lights stay in sight while the home page is arranged.
    private var arrangingTrailing: some View {
        let done = HomeDoneButton { model.endEditingHome() }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if let banner = compactBanner {
                    headerBanner(banner)
                } else if !model.center.indicators.isEmpty {
                    HeaderIndicators(model: model)
                }
                done
            }
            HStack(spacing: 8) {
                if !model.center.indicators.isEmpty {
                    HeaderIndicators(model: model)
                }
                done
            }
            done
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let banner = compactBanner {
            headerBanner(banner)
        } else {
            HStack(spacing: 8) {
                if !model.center.indicators.isEmpty {
                    HeaderIndicators(model: model)
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
