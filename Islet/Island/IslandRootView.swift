import SwiftUI

/// The whole canvas: the island hanging from the top centre, and a detached bubble
/// beside it for each further activity running, as many as the menu bar has room for.
///
/// The island is painted in the chosen colour (`IslandTheme`) whenever it shows
/// something. Under a notch it is black at rest, where it stands in for the camera
/// housing: it takes the colour at once as it starts to open, and keeps it until it
/// has shrunk back to the notch's size, then turns black again, so no frame shows the
/// fill somewhere between the two. Everything inside reads the paint of the moment
/// from the environment.
struct IslandRootView: View {
    let model: IslandViewModel
    /// Told whenever the island's footprint changes, so the controller can update
    /// where clicks are caught.
    var onLayoutChange: (IslandLayout) -> Void = { _ in }
    @AppStorage(Prefs.Key.expandOnHover) private var expandOnHover = true
    @AppStorage(Prefs.Key.islandColour) private var islandColour = IslandTheme.standardIslandPref
    @AppStorage(Prefs.Key.accentColour) private var accentColour = IslandTheme.standardAccentPref
    /// The island has had nothing to show for `IslandLayout.colourHold`: back at the
    /// notch's size, it is black again.
    @State private var isSettled = true
    /// Counts down the hold once the island has nothing to show.
    @State private var hold: Task<Void, Never>?

    var body: some View {
        let layout = model.layout
        // Worked out here, once per change of preference; everything inside reads it
        // from the environment rather than from UserDefaults.
        let theme = IslandTheme.cached(islandPref: islandColour, accentPref: accentColour)
        let isColoured = layout.wearsColour || !isSettled
        let paint = isColoured ? theme : theme.resting

        ZStack(alignment: .top) {
            BubbleLayer(model: model, layout: layout)

            IslandSurface(
                model: model,
                layout: layout,
                isBlack: theme.island == .black,
                // Into the colour at once; back to black, once settled, gently.
                paintAnimation: isColoured ? nil : .easeOut(duration: 0.2)
            )
            .offset(y: layout.topInset)

            if model.standsInOnEdge, !expandOnHover {
                EdgeStrip(model: model)
            }
        }
        .frame(width: IslandLayout.canvas.width, height: IslandLayout.canvas.height, alignment: .top)
        .ignoresSafeArea()
        .environment(\.islandTheme, paint)
        .environment(\.island, model)
        // Controls the system draws (a spinner, a text selection) follow the ink of
        // what they are drawn on; the window's own, such as a menu, the chosen colour's.
        .environment(\.colorScheme, paint.colorScheme)
        .preferredColorScheme(theme.colorScheme)
        .onChange(of: layout.wearsColour, initial: true) { _, wears in
            hold?.cancel()
            guard !wears else {
                isSettled = false
                return
            }
            hold = Task {
                try? await Task.sleep(for: IslandLayout.colourHold)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { isSettled = true }
            }
        }
        .onChange(of: layout, initial: true) { _, new in onLayoutChange(new) }
    }
}

extension EnvironmentValues {
    /// The island a view is drawn in, for the odd control in an activity's content that
    /// needs a word with it: Calendar's Join beside the notch, which keeps the island
    /// from opening under it.
    @Entry var island: IslandViewModel? = nil
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

/// The island itself, with whatever the current mode puts inside it.
private struct IslandSurface: View {
    let model: IslandViewModel
    let layout: IslandLayout
    /// The island's chosen colour is black. Any other has the black notch plate at its
    /// top, under a notch, and casts its shadow as a whole.
    let isBlack: Bool
    /// How the fill moves to a new colour: at once, or not at all with the island's
    /// springs, which would take it through every shade between black and the colour.
    let paintAnimation: Animation?
    @Environment(\.islandTheme) private var paint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = IslandShape(
            earRadius: layout.earRadius,
            bottomRadius: layout.bottomRadius,
            topRadius: layout.topRadius
        )

        ZStack(alignment: .top) {
            if isBlack {
                shape.fill(paint.background)
            } else {
                // A plain rectangle under the island's clip, so the colour can take
                // `paintAnimation` while the corners keep the island's springs.
                Rectangle()
                    .fill(paint.background)
                    .animation(paintAnimation, value: paint.background)
            }

            content
                .id(model.contentKey)
                .transition(.islandContent)
                .padding(.horizontal, layout.earRadius)

            // Its own layer under the compact row, so arriving and leaving it never
            // touches the content above: the island grows down to it, and it comes out
            // of a blur the way content does.
            AttachmentLayer(attachment: model.attachment, layout: layout, isOpen: model.isExpanded)

            // A light island has no edge of its own over a light menu bar or wallpaper:
            // a hairline of the ink gives it one. Stroked on the island's outline and
            // clipped by it, so only its inner half shows.
            if paint.isLight {
                shape.stroke(.islandDecorative(0.16), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // Width and height spring separately — width a little livelier — so the
        // island stretches sideways a beat before it drops, rather than scaling
        // like a rectangle.
        .animation(.islandWidth) { $0.frame(width: layout.size.width, alignment: .top) }
        .animation(.islandHeight) { $0.frame(height: layout.size.height, alignment: .top) }
        .clipShape(shape)
        .contentShape(shape)
        .onDrop(of: IslandDropDelegate.offeredTypes, delegate: IslandDropDelegate(model: model, layout: layout))
        // A coloured island's shadow, cast by a black shape of its outline behind it, so
        // it is one shadow for the whole island rather than one per layer. Always there
        // and only faded in and out, so choosing a colour never rebuilds what the island
        // shows. Before the squash, so it bounces with the island.
        .background {
            shape.fill(Color.black)
                .shadow(color: .black.opacity(layout.showsShadow ? 0.5 : 0), radius: 18, y: 8)
                .opacity(isBlack ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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
        // Over the squash, so it stays put over the camera housing while the island
        // bounces around it, and clipped to the island, so it never shows beyond it
        // (tucked into the housing in full screen, the island is smaller than it). It
        // hangs from a clear view the island's size, since a frame round the plate
        // itself would grow to the plate and clip nothing.
        .overlay(alignment: .top) {
            if !isBlack, model.metrics.hasNotch {
                Color.clear
                    .overlay(alignment: .top) { NotchPlate(notch: layout.notch) }
                    .clipShape(shape)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .modifier(IslandShadow(isShown: layout.showsShadow, isWhole: !isBlack))
        .onTapGesture { location in
            // The count riding on the folded icon opens the home page, where every
            // activity has its tab. The folded activity's end of the island opens that
            // activity: the same patch the controller treats as hovering it, not just
            // its circle.
            if layout.foldedBadgeRect.contains(location) {
                model.expand(focus: IslandViewModel.homeFocus)
            } else if let folded = model.foldedActivity, layout.foldedTarget.contains(location) {
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
                    counted: layout.badgesFolded ? model.countedActivities.map(\.name) : [],
                    isFoldedHovered: model.foldedActivity.map { model.hoveredSecondary == .activity($0.id) } ?? false,
                    isCountHovered: model.hoveredSecondary == .overflow,
                    open: { model.expand(focus: $0) }
                )
                .compactIslandChoices()
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

/// The shadow the opened island and a card cast on what is under them, on a black
/// island.
///
/// Every layer in the island casts its own, so each word and tile shades the fill under
/// it. On a black island that shows only outside it, where it always has. A coloured
/// island would show it, so it casts none here and one as a whole from the shape behind
/// it instead (`IslandSurface`). Only the shadow's opacity changes with the colour, never
/// the views, so what the island shows keeps its state.
private struct IslandShadow: ViewModifier {
    let isShown: Bool
    let isWhole: Bool

    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(isShown && !isWhole ? 0.5 : 0), radius: 18, y: 8)
    }
}

/// The camera housing, over a coloured island: a black shape exactly the size of the
/// resting island, ears and all, at the top centre. The resting island stays as it
/// was, and the colour grows out around it. Always drawn over a coloured island under
/// a notch; while the island is black it is black on black.
private struct NotchPlate: View {
    /// The island's notch gap (`IslandLayout.notch`).
    let notch: CGSize

    var body: some View {
        IslandShape(earRadius: IslandLayout.restingEar, bottomRadius: IslandLayout.restingRadius)
            // The housing is black whatever the island's colour.
            .fill(Color.black)
            .frame(width: notch.width + 2 * IslandLayout.restingEar, height: notch.height)
    }
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
/// if any, sit at the far right, and a further activity with no room for its bubble
/// sits at the far left, with a count of any others with no room either.
private struct CompactRow: View {
    let leading: AnyView
    let trailing: AnyView
    let indicators: [StatusIndicator]
    let layout: IslandLayout
    var folded: (any IslandActivity)? = nil
    /// The names of the activities with neither a bubble nor the fold, when their
    /// count rides on the folded icon (`IslandLayout.badgesFolded`).
    var counted: [String] = []
    var isFoldedHovered = false
    var isCountHovered = false
    /// Opens the island on the activity with this id, or on the home page.
    var open: (String) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                if let folded {
                    folded.minimal()
                        .frame(width: IslandLayout.foldedDiameter, height: IslandLayout.foldedDiameter)
                        .clipShape(Circle())
                        .secondaryHover(isFoldedHovered)
                        .accessibilityElement(children: .ignore)
                        .activityAccessibility(folded) { open(folded.id) }
                        .islandChoices(forActivity: folded.id, menu: false)
                        .overlay(alignment: .bottomTrailing) {
                            if layout.badgesFolded {
                                OverflowBadge(count: layout.overflowCount, counted: counted, isHovered: isCountHovered) {
                                    open(IslandViewModel.homeFocus)
                                }
                                .offset(layout.foldedBadgeOffset)
                                .transition(.opacity)
                            }
                        }
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

/// The count of activities with no room beside the island, where it rides on the
/// folded icon or the last bubble: small and dim, a note rather than a label. It
/// opens the home page, where each has its tab, and brightens with the pointer on it.
///
/// Its pill is a wash of the ink laid opaque over the island, since it lies over the
/// icon it rides on, and a ring of the island's colour parts it from that icon.
private struct OverflowBadge: View {
    let count: Int
    /// The names of those it counts, for VoiceOver.
    let counted: [String]
    var isHovered = false
    /// It rides on a bubble and reaches past it over the menu bar, so on a light island
    /// it takes the island's hairline, as the bubble does.
    var isOutside = false
    let open: () -> Void
    @Environment(\.islandTheme) private var paint

    var body: some View {
        let pill = IslandBackdrop.surface(isHovered ? 0.27 : 0.16)
        Text("+\(count)")
            .font(.system(size: 7.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.islandText(isHovered ? 0.95 : 0.7, on: pill))
            .padding(.horizontal, 2.5)
            .frame(minWidth: IslandLayout.badgeSize.width)
            .frame(height: IslandLayout.badgeSize.height)
            .background(Capsule().fill(paint.colour(of: pill).color))
            .background(Capsule().stroke(paint.background, lineWidth: 1.5))
            // The hairline on the ring's outer edge: see `IslandSurface`.
            .overlay {
                if isOutside, paint.isLight {
                    Capsule().inset(by: -0.75).strokeBorder(.islandDecorative(0.16), lineWidth: 0.5)
                }
            }
            .fixedSize()
            .animation(.islandHover, value: isHovered)
            .accessibilityElement(children: .ignore)
            .countAccessibility(count, counted: counted, open: open)
    }
}

extension View {
    /// A further activity's circle, in its bubble or folded into the island, for
    /// VoiceOver: a button named for the activity, with what it is doing now, if it
    /// says, that opens the island on it.
    fileprivate func activityAccessibility(_ activity: any IslandActivity, open: @escaping () -> Void) -> some View {
        accessibilityLabel(activity.name)
            .accessibilityValue(activity.spokenStatus ?? "")
            .accessibilityHint("Opens it in the island")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, open)
    }

    /// The count of activities with no room beside the island, for VoiceOver: a button
    /// saying how many and which, that opens the home page.
    fileprivate func countAccessibility(_ count: Int, counted: [String], open: @escaping () -> Void) -> some View {
        accessibilityLabel("\(count) more \(count == 1 ? "activity" : "activities")")
            .accessibilityValue(ListFormatter.localizedString(byJoining: counted))
            .accessibilityHint("Opens the island's home page")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, open)
    }

    /// A further activity's circle, in its bubble or folded into the island, with the
    /// pointer on it: it swells a little and gains a faint ring, to say a click opens it.
    fileprivate func secondaryHover(_ isHovered: Bool, scale: CGFloat = 1) -> some View {
        overlay(Circle().strokeBorder(.islandDecorative(isHovered ? 0.22 : 0), lineWidth: 1))
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

/// The detached bubbles the iPhone uses for further live activities, side by side
/// right of the island and, where there is room, left of it too, and after them the
/// count of any with no room. Each keeps what it last showed, so it can merge back
/// into its neighbour or the island after its activity has already gone, and keeps its
/// place while it does, so the others slide into theirs rather than jump.
private struct BubbleLayer: View {
    let model: IslandViewModel
    let layout: IslandLayout
    @State private var bubbles: [ShownBubble] = []
    /// The island the bubbles were last brought in line with.
    @State private var drawnBeside: IslandLayout?

    var body: some View {
        let wanted = self.wanted
        let keys = Set(wanted.map(\.key))
        /// The island each bubble sits beside. One no longer wanted keeps to the island
        /// it was drawn beside, from the moment it is no longer wanted: before it is
        /// marked as leaving, the island may already have opened, and an opened island
        /// has no room for bubbles at all.
        func beside(_ bubble: ShownBubble) -> IslandLayout {
            bubble.leftFrom ?? (keys.contains(bubble.id) ? layout : drawnBeside ?? layout)
        }
        return ZStack(alignment: .top) {
            // Every bubble's neck under every bubble, so one budding off its neighbour
            // never draws over that neighbour's content.
            ForEach(bubbles) { bubble in
                BubbleNeck(progress: bubble.progress, slot: bubble.slot, layout: beside(bubble), bubble: bubble)
            }
            ForEach(bubbles) { bubble in
                BubbleDroplet(
                    progress: bubble.progress, slot: bubble.slot, layout: beside(bubble), bubble: bubble,
                    isHovered: model.hoveredSecondary == bubble.target,
                    isCountHovered: model.hoveredSecondary == .overflow
                ) { target in
                    switch target {
                    case .activity(let id): model.expand(focus: id)
                    case .overflow: model.expand(focus: IslandViewModel.homeFocus)
                    }
                }
            }
        }
        .onChange(of: Snapshot(wanted: wanted, layout: layout), initial: true) { old, new in
            drawnBeside = new.layout
            guard old.wanted != new.wanted || bubbles.isEmpty && !new.wanted.isEmpty else { return }
            update(to: new.wanted, from: old.layout, to: new.layout)
        }
    }

    /// What the bubbles were drawn beside, as the layer last saw it.
    private struct Snapshot: Equatable {
        let wanted: [Wanted]
        let layout: IslandLayout
    }

    /// What goes beside the island now, in order: each activity's bubble, the last
    /// carrying the count of those left over when that rides on it, then the count's
    /// own bubble, if it has one.
    private var wanted: [Wanted] {
        let bubbles = model.bubbles
        let counted = layout.overflowCount > 0 ? model.countedActivities.map(\.name) : []
        var wanted = bubbles.enumerated().map { index, bubble in
            let badged = layout.badgesLastBubble && index == bubbles.count - 1
            return Wanted(
                target: .activity(bubble.activity.id), activity: bubble.activity, place: bubble.place,
                count: badged ? layout.overflowCount : 0, counted: badged ? counted : []
            )
        }
        if model.showsOverflowBubble {
            wanted.append(Wanted(
                target: .overflow, activity: nil, place: layout.overflowPlace, count: layout.overflowCount, counted: counted
            ))
        }
        return wanted
    }

    /// Brings the bubbles drawn in line with `wanted`, as the island goes from
    /// `previous` to `current`. A bubble already drawn springs to its new place, or
    /// back out if it was merging away; a new one is put in place inside what it buds
    /// from, and sets off a moment later, so there is a first frame to spring from; one
    /// no longer wanted merges back and is let go once it has.
    ///
    /// The first bubble on each side buds off the island and merges back into it. Any
    /// other buds off the bubble before it on its side, or merges back into that one,
    /// when that one stays where it is; when it is on its way somewhere else, or the
    /// island's width changes and moves them all, its old place would be left behind as
    /// a blob of nothing, and the island is too far off to reach without crossing the
    /// others. So there the bubble grows or shrinks where it stands instead, and a
    /// neighbour sliding over it as it shrinks takes it in.
    ///
    /// A bubble is drawn on one side only: one whose activity moves to the other side
    /// merges back there, and buds off afresh on its new side.
    ///
    /// Those merging back keep to their places beside the island as it was, not as it
    /// is now: opened, it is far wider, and they would be flung out to its new edge.
    private func update(to wanted: [Wanted], from previous: IslandLayout, to current: IslandLayout) {
        let places = Dictionary(wanted.map { ($0.key, $0.place.slot) }, uniquingKeysWith: { first, _ in first })
        // Budding off the island, or merging into it, is from and to its rounded end
        // as the narrower of the two islands has it, which stays inside the island
        // whether it grows or shrinks meanwhile.
        let island = previous.size.width <= current.size.width ? previous : current
        let steady = previous.size.width == current.size.width
        var next = bubbles
        var isNew = false
        for want in wanted {
            let slot = want.place.slot
            if let i = next.firstIndex(where: { $0.id == want.key }) {
                if let activity = want.activity { next[i].activity = activity }
                next[i].count = want.count
                next[i].counted = want.counted
                if next[i].isLeaving { next[i].island = island }
                next[i].isLeaving = false
                next[i].leftFrom = nil
            } else {
                // Out of the island, as the first always is; out of the bubble before
                // it, when that one is settled in its place; otherwise where it stands.
                let before = slot > 0 ? next.first { $0.side == want.place.side && places[$0.id] == slot - 1 } : nil
                let settled = steady && before.map {
                    !$0.isLeaving && $0.progress == 1 && $0.slot == CGFloat(slot - 1)
                } ?? false
                next.append(ShownBubble(
                    target: want.target, side: want.place.side, activity: want.activity, count: want.count,
                    counted: want.counted, slot: CGFloat(slot), progress: 0, isLeaving: false,
                    origin: slot == 0 ? .island : settled ? .neighbour : .place, island: island
                ))
                isNew = true
            }
        }
        // One let go again before it set off has nothing to merge back.
        next.removeAll { places[$0.id] == nil && !$0.hasSetOff }
        for i in next.indices where places[next[i].id] == nil && !next[i].isLeaving {
            // Back into the island, as the first always goes; into the bubble before
            // it, when that one stays where it is; otherwise where it stands.
            let slot = next[i].slot
            let side = next[i].side
            let stays = steady && next.contains {
                !$0.isOverflow && $0.side == side && $0.slot == slot - 1 && places[$0.id].map(CGFloat.init) == slot - 1
            }
            next[i].origin = slot < 0.5 ? .island : stays ? .neighbour : .place
            next[i].isLeaving = true
            next[i].leftFrom = previous
            next[i].island = island
            next[i].departure &+= 1
        }
        // Bottom to top: those merging away under all the rest, then the others from
        // the last to the first, so one budding off its neighbour, or merging back into
        // it, passes under it rather than over its content.
        func place(_ bubble: ShownBubble) -> CGFloat {
            places[bubble.id].map(CGFloat.init) ?? bubble.slot
        }
        bubbles = next.sorted { a, b in
            a.isLeaving != b.isLeaving ? a.isLeaving : place(a) > place(b)
        }
        if isNew {
            DispatchQueue.main.async { settle(wanted: places) }
        } else {
            settle(wanted: places)
        }
    }

    /// Springs each bubble wanted to its place and out to its full size, and merges the
    /// others back, letting each go once it has, unless it was wanted again meanwhile.
    private func settle(wanted places: [ShownBubble.Key: Int]) {
        withAnimation(.islandMorph) {
            for i in bubbles.indices {
                guard let slot = places[bubbles[i].id], !bubbles[i].isLeaving else { continue }
                bubbles[i].slot = CGFloat(slot)
                bubbles[i].progress = 1
                bubbles[i].hasSetOff = true
            }
        }
        // One changing sides goes back in at the pace its new bubble comes out on the
        // other side, so that it is never gone from both meanwhile.
        let wantedAgain = Set(places.keys.map(\.target))
        for changesSides in [false, true] {
            let departures = bubbles
                .filter { $0.isLeaving && wantedAgain.contains($0.target) == changesSides }
                .map { ($0.id, $0.departure) }
            guard !departures.isEmpty else { continue }
            withAnimation(changesSides ? .islandMorph : .islandClose) {
                for i in bubbles.indices where departures.contains(where: { $0.0 == bubbles[i].id }) {
                    bubbles[i].progress = 0
                }
            } completion: {
                bubbles.removeAll { bubble in
                    bubble.isLeaving && departures.contains { $0.0 == bubble.id && $0.1 == bubble.departure }
                }
            }
        }
    }

    private struct Wanted: Equatable {
        let target: IslandViewModel.SecondaryTarget
        let activity: (any IslandActivity)?
        let place: IslandLayout.BubblePlace
        let count: Int
        let counted: [String]

        var key: ShownBubble.Key { ShownBubble.Key(target: target, side: place.side) }

        static func == (a: Wanted, b: Wanted) -> Bool {
            a.target == b.target && a.place == b.place && a.count == b.count && a.counted == b.counted
        }
    }
}

/// One bubble as drawn: the activity it shows (or last showed), or the count, where
/// it sits, and how far it has budded off.
private struct ShownBubble: Identifiable {
    let target: IslandViewModel.SecondaryTarget
    /// The side of the island it is on, for as long as it is drawn.
    let side: IslandLayout.Side
    var activity: (any IslandActivity)?
    /// The number the count's bubble shows; on an activity's bubble, the count of those
    /// left over riding on it, or 0.
    var count: Int
    /// The names of the activities that count stands for, for VoiceOver.
    var counted: [String]
    /// Its place in the row on its side of the island, from 0 beside it.
    var slot: CGFloat
    /// 0 inside what it buds from, 1 settled in its place.
    var progress: CGFloat
    var isLeaving: Bool
    /// What it buds off, or merges back into.
    var origin: Origin
    /// The island whose rounded end on its side it buds off or merges into, when it does.
    var island: IslandLayout?
    /// Counts its merges back, so letting go after one cannot take it from a later one.
    var departure = 0
    /// It has begun to bud off, so going it merges back rather than vanishing.
    var hasSetOff = false
    /// Merging back, the island it keeps its place beside, as it was when it began to.
    var leftFrom: IslandLayout?

    /// A target has one bubble on each side at most: one merging back where it was
    /// while another buds off on its new side.
    struct Key: Hashable {
        let target: IslandViewModel.SecondaryTarget
        let side: IslandLayout.Side
    }

    var id: Key { Key(target: target, side: side) }
    var isOverflow: Bool { target == .overflow }

    enum Origin {
        /// The island's rounded end on its side.
        case island
        /// The bubble before it.
        case neighbour
        /// Nothing: it grows from, or shrinks to, half its size where it stands.
        case place
    }
}

/// Where a bubble is drawn at a point in its budding off, and what it buds from: the
/// island's rounded end on its side, or the bubble before it.
private struct BubbleGeometry {
    let d: CGFloat
    let target: CGSize
    /// The centre and radius of what it buds from, relative to the notch's centre.
    let anchorX: CGFloat
    let anchorRadius: CGFloat
    let x: CGFloat
    let scale: CGFloat
    /// How much of the whole bubble shows: all of it, but for one growing or
    /// shrinking where it stands, which fades as it gets small.
    let presence: Double
    let isMoving: Bool

    init(progress: CGFloat, slot: CGFloat, layout: IslandLayout, bubble: ShownBubble, reduceMotion: Bool) {
        let side = bubble.side
        d = bubble.isOverflow ? layout.overflowDiameter : layout.bubbleDiameter
        target = bubble.isOverflow
            ? layout.overflowCenterOffset(at: slot, side: side) : layout.bubbleCenterOffset(at: slot, side: side)
        // Away from the island: rightwards on its right, leftwards on its left.
        let outwards: CGFloat = side == .left ? -1 : 1
        let tucked: CGFloat
        switch bubble.origin {
        case .neighbour:
            anchorX = layout.bubbleCenterOffset(at: slot - 1, side: side).width
            anchorRadius = layout.bubbleDiameter / 2
            tucked = anchorX
        case .island:
            // The island's rounded end on the bubble's side, relative to the notch's centre.
            let island = bubble.island ?? layout
            let islandEnd = island.size.width / 2 - island.earRadius
            let cap = island.notch.height / 2 - 1
            anchorX = outwards * (islandEnd - cap)
            anchorRadius = cap
            tucked = outwards * (islandEnd - d / 2)
        case .place:
            anchorX = target.width
            anchorRadius = 0
            tucked = target.width
        }
        let inPlace = bubble.origin == .place
        x = reduceMotion ? target.width : tucked + (target.width - tucked) * progress
        scale = reduceMotion ? 1 : inPlace ? 0.5 + 0.5 * min(progress, 1.2) : 0.55 + 0.45 * min(progress, 1.2)
        presence = reduceMotion || !inPlace ? 1 : Double(min(1, max(0, (progress - 0.15) / 0.45)))
        // With Reduce Motion on, the bubble just fades in place: no neck, no travel.
        // Nor has one growing where it stands anything to be joined to.
        isMoving = !reduceMotion && !inPlace && progress > 0.001 && abs(progress - 1) > 0.001
    }
}

/// The "liquid" joining a bubble to what it buds from while it moves. Both are drawn
/// as circles of the island's colour through a blur and an alpha threshold, so while
/// they are close a neck joins them, stretches, and snaps, the way the iPhone's island
/// splits in two.
private struct BubbleNeck: View, Animatable {
    var progress: CGFloat
    var slot: CGFloat
    let layout: IslandLayout
    let bubble: ShownBubble
    @Environment(\.islandTheme) private var paint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, slot) }
        set { (progress, slot) = (newValue.first, newValue.second) }
    }

    var body: some View {
        let g = BubbleGeometry(progress: progress, slot: slot, layout: layout, bubble: bubble, reduceMotion: reduceMotion)
        if g.isMoving {
            // Only as wide as the two circles and the blur's reach either side, rather
            // than the whole window: several bubbles can be on the move at once.
            let r = g.d / 2 * g.scale
            let lo = (min(g.anchorX - g.anchorRadius, g.x - r) - 12).rounded(.down)
            let hi = (max(g.anchorX + g.anchorRadius, g.x + r) + 12).rounded(.up)
            let fill = paint.background
            Canvas { context, _ in
                context.addFilter(.alphaThreshold(min: 0.5, color: fill))
                context.addFilter(.blur(radius: 4))
                context.drawLayer { layer in
                    let cap = g.anchorRadius
                    layer.fill(
                        Path(ellipseIn: CGRect(x: g.anchorX - lo - cap, y: g.target.height - cap, width: 2 * cap, height: 2 * cap)),
                        with: .color(fill)
                    )
                    layer.fill(
                        Path(ellipseIn: CGRect(x: g.x - lo - r, y: g.target.height - r, width: 2 * r, height: 2 * r)),
                        with: .color(fill)
                    )
                }
            }
            .frame(width: hi - lo, height: layout.topInset + layout.notch.height + 12)
            .offset(x: (lo + hi) / 2)
            .allowsHitTesting(false)
        }
    }
}

/// A bubble budding off the island, or off the bubble before it, like a droplet, over
/// its neck (`BubbleNeck`). Once it has settled it is drawn plainly, in the island's
/// colour, with the island's hairline on a light island.
private struct BubbleDroplet: View, Animatable {
    var progress: CGFloat
    var slot: CGFloat
    let layout: IslandLayout
    let bubble: ShownBubble
    /// The pointer is on the bubble: it swells a little and lifts, to say it opens.
    let isHovered: Bool
    /// The pointer is on the count, wherever it is.
    let isCountHovered: Bool
    let onTap: (IslandViewModel.SecondaryTarget) -> Void
    @Environment(\.islandTheme) private var paint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, slot) }
        set { (progress, slot) = (newValue.first, newValue.second) }
    }

    var body: some View {
        let g = BubbleGeometry(progress: progress, slot: slot, layout: layout, bubble: bubble, reduceMotion: reduceMotion)
        let d = g.d
        let fade = Double(min(1, max(0, (progress - 0.35) / 0.5)))
        let fill = paint.background
        if progress > 0.001 {
            content
                .frame(width: d, height: d)
                .background(Circle().fill(fill))
                .clipShape(Circle())
                .opacity(fade)
                .background(Circle().fill(fill))
                // The island's hairline, on a light island: see `IslandSurface`.
                .overlay {
                    if paint.isLight { Circle().strokeBorder(.islandDecorative(0.16), lineWidth: 0.5) }
                }
                .opacity(g.presence)
                .secondaryHover(isHovered, scale: g.scale)
                .contentShape(Circle())
                .onTapGesture { onTap(bubble.target) }
                .accessibilityElement(children: .ignore)
                .modifier(BubbleAccessibility(bubble: bubble) { onTap(bubble.target) })
                .islandChoices(forActivity: bubble.isLeaving ? nil : bubble.activity?.id)
                .overlay(alignment: bubble.side == .left ? .bottomLeading : .bottomTrailing) {
                    // Faded in and out as the count comes to this bubble and leaves it, at
                    // its bottom corner away from the island.
                    ZStack {
                        if !bubble.isOverflow, bubble.count > 0 {
                            OverflowBadge(
                                count: bubble.count, counted: bubble.counted, isHovered: isCountHovered, isOutside: true
                            ) {
                                onTap(.overflow)
                            }
                            .offset(
                                x: bubble.side == .left ? -IslandLayout.bubbleBadgeOffset.width : IslandLayout.bubbleBadgeOffset.width,
                                y: IslandLayout.bubbleBadgeOffset.height
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onTap(.overflow) }
                            .opacity(fade * g.presence)
                            .transition(.opacity)
                        }
                    }
                    .animation(.islandMorph, value: bubble.count > 0)
                }
                // One merging away is on its way out: VoiceOver has done with it.
                .accessibilityHidden(bubble.isLeaving)
                .offset(x: g.x, y: g.target.height - d / 2)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let activity = bubble.activity {
            activity.minimal()
        } else {
            Text("+\(bubble.count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.islandText(0.7))
        }
    }
}

/// A bubble for VoiceOver: its activity, or the count of those left over.
private struct BubbleAccessibility: ViewModifier {
    let bubble: ShownBubble
    let open: () -> Void

    func body(content: Content) -> some View {
        if let activity = bubble.activity {
            content.activityAccessibility(activity, open: open)
        } else {
            content.countAccessibility(bubble.count, counted: bubble.counted, open: open)
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
/// Done on the right beside the banner or indicators. Each side keeps to its room:
/// tabs that do not fit go into a menu (`HeaderTabFit`), and so do indicators
/// (`HeaderIndicatorFit`).
private struct ExpandedHeader: View {
    let model: IslandViewModel
    let focus: String
    let layout: IslandLayout

    /// The room either side of the notch.
    private var sideWidth: CGFloat { layout.headerSideWidth }

    var body: some View {
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
        let activities = model.center.activities
        let fit = HeaderTabFit(center: model.center, focus: focus, room: sideWidth)
        return HStack(spacing: fit.spacing) {
            if !model.center.activities.isEmpty || page != nil {
                TabButton(symbol: "house.fill", isSelected: focus == IslandViewModel.homeFocus) {
                    model.select(focus: IslandViewModel.homeFocus)
                }
                ForEach(activities.filter { fit.shown.contains($0.id) }, id: \.id) { activity in
                    TabButton(symbol: activity.symbol, isSelected: focus == activity.id) {
                        model.select(focus: activity.id)
                    }
                    .islandChoices(forActivity: activity.id)
                }
                if !fit.overflow.isEmpty {
                    MoreActivitiesMenu(model: model, fit: fit)
                }
                // A feature's page has a tab only while it is open; home is the way back.
                if let page {
                    TabButton(symbol: page.symbol, isSelected: true) {}
                }
            }
        }
        .environment(\.headerTabWidth, fit.tabWidth)
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
        let room = sideWidth - 8 - HomeDoneButton.width
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if let banner = compactBanner {
                    headerBanner(banner)
                } else if !model.center.indicators.isEmpty {
                    HeaderIndicators(model: model, room: room)
                }
                done
            }
            HStack(spacing: 8) {
                if !model.center.indicators.isEmpty {
                    HeaderIndicators(model: model, room: room)
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
                    HeaderIndicators(model: model, room: sideWidth - 8 - HeaderTabFit.tabWidth)
                }
                TabButton(symbol: "gearshape.fill", isSelected: false) {
                    model.collapse()
                    SettingsWindowController.shared.show()
                }
            }
        }
    }
}

/// A tab in the opened island's header. The picked one is a highlight, in the accent
/// on a wash of it (the ink, under Feature colours); the rest are in the ink, and lit
/// faintly under the pointer. The glyphs are small, so off the black island they are
/// held to the words' 4.5:1 rather than a symbol's 3:1, against the pill they sit on.
private struct TabButton: View {
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.islandTheme) private var theme
    @State private var isHovering = false
    @Environment(\.headerTabWidth) private var width

    var body: some View {
        let picked = theme.onWash(.accent(.shell, minimum: Contrast.text), wash: 0.16)
        let lit: IslandBackdrop = isHovering ? .surface(0.08) : .island
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? picked.mark : theme.text(isHovering ? 0.75 : 0.45, on: lit))
                .frame(width: 24, height: 20)
                // Narrower where the row is short of room (`HeaderTabFit`).
                .frame(width: width)
                .background(
                    Capsule().fill(isSelected ? picked.wash : theme.surface(isHovering ? 0.08 : 0))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The last of the tabs while more activities are running than there are tabs room
/// for: a menu of the rest, each by its symbol and name, that opens the one chosen.
/// It is coloured as a tab that is not picked is (`TabButton`), and lit as one is
/// under the pointer, and while its menu is up.
struct MoreActivitiesMenu: View {
    let model: IslandViewModel
    let items: [HeaderMenuItem]
    @State private var isHovering = false
    @State private var showsMenu = false
    @Environment(\.headerTabWidth) private var width
    @Environment(\.islandTheme) private var theme

    init(model: IslandViewModel, fit: HeaderTabFit) {
        self.model = model
        items = fit.menuItems(model.center.activities)
    }

    /// Opens the activity `id`, as its tab would.
    func choose(_ id: String) {
        model.select(focus: id)
    }

    /// The menu's items, then the same Show in Island choice a tab's right-click
    /// offers, for the activities that have no tab of their own to right-click.
    @ViewBuilder var entries: some View {
        ForEach(items) { item in
            Button {
                choose(item.id)
            } label: {
                Label(item.title, systemImage: item.symbol)
            }
        }
        Divider()
        Menu("Show in Island") {
            ForEach(items) { item in
                Button(item.title) { model.choose(.show(item.id)) }
            }
        }
    }

    var body: some View {
        let lit = isHovering || showsMenu
        let pill: IslandBackdrop = lit ? .surface(0.08) : .island
        Menu {
            entries
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text(lit ? 0.75 : 0.45, on: pill))
                .frame(width: width, height: 20)
                .background(Capsule().fill(theme.surface(lit ? 0.08 : 0)))
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .headerMenuState(isUp: model.isShowingMenu, isHovering: $isHovering, showsMenu: $showsMenu)
        .help("More activities")
        .accessibilityLabel("More activities")
        .accessibilityValue("\(items.count)")
    }
}

extension View {
    /// Keeps a header menu button's light true to its menu. A menu from the island came
    /// up with the pointer on the button, so it is the button's own, and the button
    /// stays lit while it is up. The pointer's comings and goings are not heard while a
    /// menu is up, so whatever the button last heard is forgotten as the menu goes: the
    /// pointer is most likely where the chosen item was.
    func headerMenuState(isUp: Bool, isHovering: Binding<Bool>, showsMenu: Binding<Bool>) -> some View {
        onChange(of: isUp) { _, up in
            showsMenu.wrappedValue = up && isHovering.wrappedValue
            if !up { isHovering.wrappedValue = false }
        }
    }
}

extension EnvironmentValues {
    /// How wide the opened island's tabs are: narrower while the header is short of
    /// room (`HeaderTabFit`).
    @Entry var headerTabWidth: CGFloat = HeaderTabFit.tabWidth
}
