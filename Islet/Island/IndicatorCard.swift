import SwiftUI

/// The indicator card open in the opened island: the indicator it was opened from,
/// and the card itself, kept so it can stay a moment after every indicator showing it
/// has gone, to say so.
struct OpenIndicatorCard: Equatable {
    var indicatorID: String
    var detail: IndicatorDetail
}

extension Animation {
    /// A card opening, closing, or moving to another indicator: quick and without the
    /// island's overshoot, as a popover's.
    static let indicatorCard = Animation.spring(response: 0.3, dampingFraction: 0.86)
}

/// The measurements of indicators as buttons, and of the cards they open.
enum IndicatorCardLayout {
    /// An indicator with a card is a button as tall as a tab. A symbol's is as wide as
    /// a tab too; a dot's a little narrower, so a row of them does not sprawl.
    static let buttonHeight: CGFloat = 20
    static let dotButtonWidth: CGFloat = 20
    static let symbolButtonWidth: CGFloat = 24
    /// The least room between the notch row and the card's top edge. The caret rises
    /// from the edge, through this gap, to just under the indicator's button.
    static let topGap: CGFloat = 2
    static let caret = CGSize(width: 14, height: 7)
    /// Kept clear between the card's bottom edge and the island's.
    static let bottomMargin: CGFloat = 10
    static let cornerRadius: CGFloat = 14
    static let padding = EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)
    /// How long a card stays, saying there is nothing left to show, once the last
    /// indicator showing it has gone.
    static let lingering: Duration = .milliseconds(1600)
    /// How far past the first and last marks in the resting or compact island a click
    /// still counts as on them.
    static let compactReach: CGFloat = 4

    /// Where the card's top edge is, down from the top of an opened island whose notch
    /// row is `notchHeight` tall: just under the row, or, where the row is barely taller
    /// than the buttons in it (a display without a notch), far enough below for the
    /// caret's tip to stop a point short of the button it points at, rather than cover
    /// the button's lower edge.
    static func cardTop(notchHeight: CGFloat) -> CGFloat {
        let buttonBottom = (notchHeight + buttonHeight) / 2
        return max(notchHeight + topGap, buttonBottom + 1 + caret.height)
    }

    /// How much longer the opened island must be to hold a card `cardHeight` tall over
    /// a page `pageHeight` tall, under a notch row `notchHeight` tall. Zero while the
    /// page and the island's bottom edge leave room enough.
    static func growth(cardHeight: CGFloat, pageHeight: CGFloat, notchHeight: CGFloat) -> CGFloat {
        let room = notchHeight + pageHeight + IslandLayout.expandedInset.bottom
            - cardTop(notchHeight: notchHeight) - bottomMargin
        return max(0, ceil(cardHeight - room))
    }

    /// The indicator with a card at `point` in the resting or compact island, in the
    /// island's own coordinates (origin at its top left), laid out as `layout`. Only the
    /// notch row counts, as for the folded activity (`IslandLayout.foldedTarget`),
    /// so a row the island grows beneath it is never an indicator's. Each indicator
    /// takes its mark and half the gap either side, the first from the start of the
    /// strip and the last `compactReach` past its mark, so a small dot is still easy to
    /// hit; a click on the rest of the island, its rounded end included, opens it as
    /// ever.
    static func compactIndicator(at point: CGPoint, in layout: IslandLayout, indicators: [StatusIndicator]) -> String? {
        guard layout.indicatorWidth > 0, point.y >= 0, point.y <= layout.notch.height else { return nil }
        // The strip of indicators ends at the island's rounded end, as `CompactRow`
        // places it.
        let stripStart = layout.size.width - layout.earRadius - layout.indicatorWidth
        var x = stripStart + IndicatorDots.leading
        for (index, indicator) in indicators.enumerated() {
            let width = indicator.symbol == nil ? IslandLayout.indicatorDot : IslandLayout.indicatorSymbol.width
            let start = index == 0 ? stripStart : x - IslandLayout.indicatorGap / 2
            let end = x + width + (index == indicators.count - 1 ? compactReach : IslandLayout.indicatorGap / 2)
            if point.x >= start, point.x < end { return indicator.detail == nil ? nil : indicator.id }
            x += width + IslandLayout.indicatorGap
        }
        return nil
    }
}

extension IslandBackdrop {
    /// What an indicator card's content lies on: a shade of the ink over the island,
    /// drawn opaque so the page under the card does not show through. Words and marks in
    /// a card are measured against it: `.islandText(0.55, on: .indicatorCard)`.
    static let indicatorCard = IslandBackdrop.surface(0.14)
}

// MARK: - Marks and buttons

/// An indicator's mark: a dot, or its symbol fitted into the box `IslandLayout` gives
/// it, with a softer glow than a dot's so its shape stays crisp. A light island has no
/// glow: there a halo of colour reads as a smudge.
struct IndicatorMark: View {
    let indicator: StatusIndicator
    /// What the mark is drawn on, for its contrast: the island, or a button's capsule.
    var backdrop: IslandBackdrop = .island
    @Environment(\.islandTheme) private var theme

    var body: some View {
        if let label = indicator.label {
            mark.accessibilityLabel(label)
        } else {
            mark
        }
    }

    @ViewBuilder
    private var mark: some View {
        let colour = indicator.color.on(backdrop).color(in: theme)
        if let symbol = indicator.symbol {
            Image(systemName: symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .fontWeight(.semibold)
                .foregroundStyle(colour)
                .frame(width: IslandLayout.indicatorSymbol.width, height: IslandLayout.indicatorSymbol.height)
                .shadow(color: colour.opacity(theme.isLight ? 0 : 0.45), radius: 2)
        } else {
            Circle()
                .fill(colour)
                .frame(width: IslandLayout.indicatorDot, height: IslandLayout.indicatorDot)
                .shadow(color: colour.opacity(theme.isLight ? 0 : 0.6), radius: 3)
        }
    }
}

/// The indicators in the opened island's header. One with a card is a button that
/// opens it; the rest are plain marks, spaced as in the compact row. Those there is no
/// room for are counted by a button at the end, which lists them (`HeaderIndicatorFit`).
struct HeaderIndicators: View {
    let model: IslandViewModel
    /// The room the strip has.
    var room: CGFloat = .infinity

    var body: some View {
        let open = model.indicatorCardAnchor
        let indicators = model.center.indicators
        let fit = HeaderIndicatorFit(indicators, room: room)
        HStack(spacing: 0) {
            ForEach(indicators.filter { fit.shown.contains($0.id) }) { indicator in
                Group {
                    if indicator.detail != nil {
                        IndicatorButton(indicator: indicator, isOpen: open == indicator.id) {
                            model.toggleIndicatorCard(id: indicator.id)
                        }
                        .anchorPreference(key: IndicatorAnchors.self, value: .bounds) { [indicator.id: $0] }
                    } else {
                        IndicatorMark(indicator: indicator)
                            .padding(.horizontal, IslandLayout.indicatorGap / 2)
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
            if !fit.overflow.isEmpty {
                MoreIndicatorsMenu(model: model, fit: fit, isOpen: open.map(fit.overflow.contains) ?? false)
                    // A card opened from the menu points at the count.
                    .anchorPreference(key: IndicatorAnchors.self, value: .bounds) { anchor in
                        Dictionary(uniqueKeysWithValues: indicators.filter {
                            fit.overflow.contains($0.id) && $0.detail != nil
                        }.map { ($0.id, anchor) })
                    }
                .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

/// The count of the indicators the header has no room for, at the end of its strip: a
/// menu of them, by what each says, where one with a card opens it, as a click on the
/// indicator would, under the count. It lights while such a card is open, as an
/// indicator's button does, and while its menu is up. It is coloured as an indicator's
/// button is (`IndicatorButton`).
struct MoreIndicatorsMenu: View {
    let model: IslandViewModel
    let items: [HeaderMenuItem]
    let isOpen: Bool
    @State private var isHovering = false
    @State private var showsMenu = false

    init(model: IslandViewModel, fit: HeaderIndicatorFit, isOpen: Bool) {
        self.model = model
        items = fit.menuItems(model.center.indicators)
        self.isOpen = isOpen
    }

    /// Opens the card of the indicator `id`, or closes it, as a click on the indicator
    /// would.
    func choose(_ id: String) {
        model.toggleIndicatorCard(id: id)
    }

    /// The menu's items.
    var entries: some View {
        ForEach(items) { item in
            Button {
                choose(item.id)
            } label: {
                Label(item.title, systemImage: item.symbol)
            }
            .disabled(!item.isEnabled)
        }
    }

    var body: some View {
        let open = isOpen || showsMenu
        let lit = open ? 0.16 : (isHovering ? 0.08 : 0)
        Menu {
            entries
        } label: {
            Text("+\(items.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.islandText(open || isHovering ? 0.75 : 0.45, on: .surface(lit)))
                .frame(width: HeaderIndicatorFit.moreWidth, height: IndicatorCardLayout.buttonHeight)
                .background(Capsule().fill(.islandSurface(lit)))
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .headerMenuState(isUp: model.isShowingMenu, isHovering: $isHovering, showsMenu: $showsMenu)
        .help("More indicators")
        .accessibilityLabel("More indicators")
        .accessibilityValue("\(items.count)")
    }
}

/// An indicator that opens a card: its mark on a capsule that lights under the
/// pointer and stays lit while the card is open, as a tab does while it is picked. The
/// capsule is always a shade of the ink, never the accent, which has no place among the
/// indicators.
private struct IndicatorButton: View {
    let indicator: StatusIndicator
    let isOpen: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let lit = isOpen ? 0.16 : (isHovering ? 0.08 : 0)
        Button(action: action) {
            IndicatorMark(indicator: indicator, backdrop: .surface(lit))
                .frame(
                    width: indicator.symbol == nil ? IndicatorCardLayout.dotButtonWidth : IndicatorCardLayout.symbolButtonWidth,
                    height: IndicatorCardLayout.buttonHeight
                )
                .background(Capsule().fill(.islandSurface(lit)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // No pointing hand: the panel never becomes key and Islet is seldom the active
        // app, so the cursor is never Islet's to set. The capsule says it is a button,
        // as a tab's does.
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityHint(isOpen ? "Hides the details" : "Shows the details")
    }
}

/// Where each indicator with a card is in the header, for its card to point at.
private struct IndicatorAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - The card

extension View {
    /// The open indicator card, over the opened island's header and page, which this
    /// is applied to.
    func indicatorCard(model: IslandViewModel, layout: IslandLayout) -> some View {
        modifier(IndicatorCardHost(model: model, layout: layout))
    }
}

private struct IndicatorCardHost: ViewModifier {
    let model: IslandViewModel
    let layout: IslandLayout

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                // A click on the page only closes the card, as a click beside a menu
                // closes the menu, so a control half hidden under the card is never
                // pressed by mistake. The header is left uncovered: its tabs, the
                // settings button and the other indicators work as ever and close the
                // card as they go, and a click on nothing there reaches the island,
                // which closes it too (`IslandViewModel.tap()`).
                if model.indicatorCard != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.closeIndicatorCard() }
                        .padding(.top, layout.notch.height)
                        .accessibilityHidden(true)
                }
            }
            .overlayPreferenceValue(IndicatorAnchors.self) { anchors in
                IndicatorCardOverlay(model: model, layout: layout, anchors: anchors)
            }
    }
}

/// The open card, under the header's trailing end: its right edge in line with the
/// settings button's, so it stays put as indicators come and go and moves only its
/// caret, which points up at the indicator it belongs to.
private struct IndicatorCardOverlay: View {
    let model: IslandViewModel
    let layout: IslandLayout
    let anchors: [String: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            if model.isExpanded, let card = model.indicatorCard {
                let anchor = model.indicatorCardAnchor
                // No caret while a banner holds the header's end in place of the
                // indicators, or once they have all gone.
                let caretInset = anchor.flatMap { anchors[$0] }.map { proxy.size.width - proxy[$0].midX }
                IndicatorCardView(detail: card.detail, caretInset: caretInset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [id = card.detail.id] height in
                        model.indicatorCardMeasured(id: id, height: height)
                    }
                    .frame(width: proxy.size.width, alignment: .trailing)
                    .offset(y: IndicatorCardLayout.cardTop(notchHeight: layout.notch.height))
                    .id(card.detail.id)
                    .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                    .task(id: anchor == nil) {
                        // Every indicator showing this card has gone. What it says now
                        // (nothing in use, the Focus off) stays long enough to read.
                        guard anchor == nil else { return }
                        try? await Task.sleep(for: IndicatorCardLayout.lingering)
                        guard !Task.isCancelled else { return }
                        model.closeIndicatorCard()
                    }
            }
        }
    }
}

/// The card itself: the feature's content on a panel a shade of the ink away from the
/// island (lighter on a dark island, darker on a light one), so it reads as lying over
/// the page, with a caret up to its indicator `caretInset` in from its right edge.
/// Clicks inside it stay inside it; the caret takes none, so it never keeps a click from
/// the button it points at.
private struct IndicatorCardView: View {
    let detail: IndicatorDetail
    let caretInset: CGFloat?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let shape = CalloutShape(
            cornerRadius: IndicatorCardLayout.cornerRadius,
            caret: IndicatorCardLayout.caret,
            caretInset: caretInset ?? 0,
            showsCaret: caretInset != nil
        )
        // Wide enough for the caret to clear the rounded corner under its indicator.
        let reach = caretInset.map { $0 + IndicatorCardLayout.cornerRadius + IndicatorCardLayout.caret.width / 2 } ?? 0
        CardWidth(minWidth: reach, maxWidth: detail.maxWidth) {
            detail.content()
                .padding(IndicatorCardLayout.padding)
        }
        .background(shape.fill(theme.colour(of: .indicatorCard).color))
        .overlay(shape.stroke(.islandDecorative(0.1), lineWidth: 0.5))
        .compositingGroup()
        .shadow(color: theme.shadow(0.6), radius: 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: IndicatorCardLayout.cornerRadius))
        .onTapGesture {}
        .animation(.indicatorCard, value: caretInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detail.title)
    }
}

/// Sizes the card to its content: as wide as the content would be, given all the room
/// it asks for, within `minWidth` and `maxWidth`, and as tall as it then needs. A card
/// with a short line is no wider than that line; a longer one truncates at the most.
private struct CardWidth: Layout {
    var minWidth: CGFloat
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(.unspecified).width
        let width = min(max(ideal, minWidth), maxWidth)
        return CGSize(width: width, height: content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// A rounded rectangle with a caret rising from its top edge `caretInset` in from its
/// right edge, drawn above the rectangle it is given. Measured from the right, where
/// the card is pinned, the caret keeps its place under the indicator whatever width
/// the card takes.
private struct CalloutShape: Shape {
    var cornerRadius: CGFloat
    var caret: CGSize
    var caretInset: CGFloat
    var showsCaret: Bool

    var animatableData: CGFloat {
        get { caretInset }
        set { caretInset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.height / 2, rect.width / 2)
        let half = caret.width / 2
        // Kept clear of the rounded corners.
        let x = min(max(rect.maxX - caretInset, rect.minX + r + half), rect.maxX - r - half)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        if showsCaret {
            path.addLine(to: CGPoint(x: x - half, y: rect.minY))
            // A slightly rounded tip.
            path.addLine(to: CGPoint(x: x - 1.6, y: rect.minY - caret.height + 1.2))
            path.addQuadCurve(
                to: CGPoint(x: x + 1.6, y: rect.minY - caret.height + 1.2),
                control: CGPoint(x: x, y: rect.minY - caret.height)
            )
            path.addLine(to: CGPoint(x: x + half, y: rect.minY))
        }
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: r)
        path.closeSubpath()
        return path
    }
}
