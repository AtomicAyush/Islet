import SwiftUI
import UniformTypeIdentifiers

/// What the home page needs to be arranged where it is shown: whether it is being, and
/// where the person's changes go. The island's model and the arrangement answer these;
/// the page only draws.
struct HomeEditing {
    var isOn: Bool
    /// Whether the tiles rock while arranged: only with the pointer on the island, so an
    /// island left arranging does not keep drawing.
    var wiggles = true
    /// How many tiles on the page the person hid, to say so when none is left showing.
    var hiddenCount = 0
    /// Starts arranging the page (its menu's Edit Home Page).
    var begin: () -> Void
    /// Done arranging.
    var end: () -> Void
    /// Moves a tile to `destination` among the tiles shown, counted without it
    /// (`HomeTileOrder.move`).
    var move: (_ id: String, _ destination: Int, _ shown: [String]) -> Void
    var hide: (_ id: String) -> Void
    /// A tile's name, for its menu and VoiceOver.
    var title: (_ id: String) -> String
}

extension EnvironmentValues {
    /// Starts arranging the home page, for a menu inside a tile (an item's in the
    /// clipboard or on the shelf) to offer, since it takes the right-click from the
    /// page's own; `nil` off the home page and while it is being arranged.
    @Entry var editHomePage: EditHomePageAction? = nil
}

/// Starts arranging the home page the menu is on (`editHomePage`). Any two are the same:
/// each island's page only ever starts its own arranging, so views reading it need not
/// be drawn again whenever the page is.
struct EditHomePageAction: Equatable {
    let run: () -> Void

    func callAsFunction() { run() }

    static func == (_: Self, _: Self) -> Bool { true }
}

extension UTType {
    /// A home tile dragged to another place while the home page is arranged. Only the
    /// home page takes it.
    static let homeTile = UTType(exportedAs: "com.ayush.Islet.home-tile")
}

/// Where a tile dragged over another would go.
enum HomeTileDrop {
    /// The place, among `shown` counted without `dragged`, for `dragged` held over
    /// `target`: before it while the pointer is on its leading half, after it on its
    /// trailing half. Deciding by halves rather than on arrival keeps a wide tile and a
    /// narrow one from swapping back and forth, and lets a tile go either side of any
    /// other, whichever way it came in.
    static func destination(of dragged: String, over target: String, trailingHalf: Bool, in shown: [String]) -> Int? {
        let others = shown.filter { $0 != dragged }
        guard dragged != target, let index = others.firstIndex(of: target) else { return nil }
        return trailingHalf ? index + 1 : index
    }

    /// The drag's payload: the tile's id, under a type only the home page takes. It is
    /// offered to every process: the drag pasteboard is shared between apps, and one
    /// kept to Islet's own might not reach its own drop either. No other app takes the
    /// type, and the id is all it carries.
    static func provider(for id: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.homeTile.identifier, visibility: .all) { done in
            done(Data(id.utf8), nil)
            return nil
        }
        return provider
    }
}

/// A tile in its place on the home page: the tile itself and, while the page is being
/// arranged, what arranges it laid over it. The tile is the same view either way, so
/// nothing in it starts over as arranging begins and ends; it only stops taking clicks.
struct HomeTileSlot: View {
    /// How far the hide badge sits out past the tile's corner, clear of what the tile
    /// draws inside its padding; the rows leave room for it.
    static let badgeOverhang: CGFloat = 6

    let widget: HomeWidget
    /// Every tile shown, in order, on every page.
    let shown: [String]
    let editing: HomeEditing?
    @Binding var dragging: String?

    var body: some View {
        let isArranging = editing?.isOn == true
        HomeTile { widget.view }
            .allowsHitTesting(!isArranging)
            // Nor can VoiceOver use it: the overlay stands for it, with its own actions.
            .accessibilityHidden(when: isArranging)
            .overlay {
                if isArranging, let editing {
                    ArrangingOverlay(widget: widget, shown: shown, editing: editing, dragging: $dragging)
                        .transition(.opacity)
                }
            }
            // The tile being dragged leaves a faint copy in the place it would land.
            .opacity(isArranging && dragging == widget.id ? 0.35 : 1)
            // Out of step with its neighbours by its name, so a tile keeps its own rock
            // as it moves.
            .modifier(Wiggle(
                isOn: isArranging && editing?.wiggles == true,
                seed: widget.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            ))
    }
}

/// Laid over a tile while the home page is arranged: an outline, the badge that hides
/// it, and what drags it and takes others dropped on it.
private struct ArrangingOverlay: View {
    let widget: HomeWidget
    let shown: [String]
    let editing: HomeEditing
    @Binding var dragging: String?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            let title = editing.title(widget.id)
            shape.strokeBorder(.islandDecorative(0.22), lineWidth: 1)
                .contentShape(shape)
                .onDrag {
                    dragging = widget.id
                    return HomeTileDrop.provider(for: widget.id)
                } preview: {
                    // Drawn apart from the island, so on the island's colour and with its
                    // theme, as the tile is on the page.
                    HomeTile { widget.view }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .background(shape.fill(theme.background))
                        .environment(\.islandTheme, theme)
                        .environment(\.colorScheme, theme.colorScheme)
                }
                .onDrop(of: [.homeTile], delegate: TileDropDelegate(
                    target: widget.id, size: geo.size, shown: shown, dragging: $dragging, move: editing.move
                ))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityHint("Drag it to another place, or use the Move actions")
                .accessibilityAction(named: "Move Left") { step(-1) }
                .accessibilityAction(named: "Move Right") { step(1) }
                .accessibilityAction(named: "Move to Start") { place(at: 0) }
                .accessibilityAction(named: "Move to End") { place(at: shown.count - 1) }
                .accessibilityAction(named: "Hide") { editing.hide(widget.id) }
                .overlay(alignment: .topLeading) {
                    HideBadge(title: title) { editing.hide(widget.id) }
                        .offset(x: -HomeTileSlot.badgeOverhang, y: -HomeTileSlot.badgeOverhang)
                }
                .contextMenu { menu(title: title) }
        }
    }

    @ViewBuilder
    private func menu(title: String) -> some View {
        let index = shown.firstIndex(of: widget.id) ?? 0
        Button("Move Left") { step(-1) }
            .disabled(index == 0)
        Button("Move Right") { step(1) }
            .disabled(index >= shown.count - 1)
        Divider()
        Button("Move to Start") { place(at: 0) }
            .disabled(index == 0)
        Button("Move to End") { place(at: shown.count - 1) }
            .disabled(index >= shown.count - 1)
        Divider()
        Button("Hide \(title)") { editing.hide(widget.id) }
        Divider()
        Button("Done") { editing.end() }
    }

    /// One place along, for the menu and VoiceOver: past the end of a page, onto the
    /// next.
    private func step(_ by: Int) {
        guard let index = shown.firstIndex(of: widget.id) else { return }
        place(at: index + by)
    }

    private func place(at destination: Int) {
        guard shown.indices.contains(destination), shown.firstIndex(of: widget.id) != destination else { return }
        withAnimation(.islandMorph) { editing.move(widget.id, destination, shown) }
    }
}

/// Moves the tile being dragged as it passes over this one, the others making room, so
/// the page shows where it will land before it is let go.
private struct TileDropDelegate: DropDelegate {
    let target: String
    let size: CGSize
    let shown: [String]
    @Binding var dragging: String?
    let move: (String, Int, [String]) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) { place(at: info.location) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        place(at: info.location)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    private func place(at point: CGPoint) {
        guard let dragged = dragging, let from = shown.firstIndex(of: dragged),
              let destination = HomeTileDrop.destination(
                  of: dragged, over: target, trailingHalf: point.x > size.width / 2, in: shown
              ),
              destination != from
        else { return }
        withAnimation(.islandMorph) { move(dragged, destination, shown) }
    }
}

/// The small round badge at a tile's corner that hides it: a minus on a grey disc, solid
/// so it reads over the tile's corner on any island, with a rim of shadow that parts it
/// from the tile.
private struct HideBadge: View {
    let title: String
    let action: () -> Void
    @Environment(\.islandTheme) private var theme
    static let disc = RGB(0.36, 0.36, 0.36)

    var body: some View {
        // Held to 3:1 against the tile it overhangs, so it never fades into a grey or
        // mid-tone island; as it is wherever it already stands out, black included.
        let disc = theme.fitted(Self.disc, minimum: Contrast.graphic, on: .homeTile)
        Button(action: action) {
            Image(systemName: "minus")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.islandOnFill(disc))
                .frame(width: 16, height: 16)
                .background(Circle().fill(.islandFill(disc)))
                .overlay(Circle().strokeBorder(theme.shadow(0.55), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Hide \(title)")
        .accessibilityLabel("Hide \(title)")
    }
}

/// The tiles' gentle rock while the home page is arranged, each a little out of step
/// with its neighbours. With Reduce Motion on they keep still; their outlines still say
/// they can be moved.
struct Wiggle: ViewModifier {
    let isOn: Bool
    let seed: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far a tile's ends travel either way, in points, and how long one rock takes.
    static let travel: CGFloat = 1.1
    static let period: TimeInterval = 0.34

    func body(content: Content) -> some View {
        let moving = isOn && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) { context in
            content.modifier(Rock(swing: moving ? Self.swing(at: context.date, seed: seed) : 0))
        }
    }

    /// Where a tile is in its rock at `date`, from -1 to 1.
    static func swing(at date: Date, seed: Int) -> Double {
        sin(date.timeIntervalSinceReferenceDate * 2 * .pi / period + Double(seed) * 1.9)
    }

    /// The turn, in radians, that takes the ends of a tile `width` wide `swing` of the
    /// way to `travel`: a wide tile turns less than a narrow one, rather than swinging its
    /// ends further, and out of the row.
    static func angle(swing: Double, width: CGFloat) -> CGFloat {
        CGFloat(swing) * travel / max(width / 2, 1)
    }

    /// Turns a tile about its centre.
    private struct Rock: GeometryEffect {
        var swing: Double

        var animatableData: Double {
            get { swing }
            set { swing = newValue }
        }

        func effectValue(size: CGSize) -> ProjectionTransform {
            guard swing != 0 else { return ProjectionTransform() }
            let transform = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
                .rotated(by: Wiggle.angle(swing: swing, width: size.width))
                .translatedBy(x: -size.width / 2, y: -size.height / 2)
            return ProjectionTransform(transform)
        }
    }
}

/// The left of the opened island's header while the home page is arranged: the hidden
/// tiles, to show again, or a word on what to do when none is hidden.
struct HiddenTilesMenu: View {
    let arrangement: HomeArrangement

    var body: some View {
        let hidden = arrangement.hiddenTiles
        if hidden.isEmpty {
            Text("Drag tiles to move them")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.islandText(0.45))
                .lineLimit(1)
        } else {
            Menu {
                Section("Show on the Home Page") {
                    ForEach(hidden) { tile in
                        Button {
                            withAnimation(.islandMorph) { arrangement.setHidden(false, tile.id) }
                        } label: {
                            Label(tile.title, systemImage: tile.symbol)
                        }
                    }
                }
                if hidden.count > 1 {
                    Divider()
                    Button("Show All") {
                        withAnimation(.islandMorph) { arrangement.showAll() }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(hidden.count) Hidden")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.islandText(0.75, on: .surface(0.1)))
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(Capsule().fill(.islandSurface(0.1)))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show hidden tiles")
        }
    }
}

/// Ends arranging the home page, at the right of the header.
struct HomeDoneButton: View {
    let action: () -> Void
    @State private var isHovering = false

    /// How wide the button is drawn, taken from the button itself, once, so it stays
    /// true to its word and padding whatever they become. The header leaves the
    /// indicators the rest of its room.
    @MainActor static let width: CGFloat = ceil(NSHostingView(rootView: HomeDoneButton {}.fixedSize()).fittingSize.width)

    var body: some View {
        let wash = isHovering ? 0.28 : 0.2
        Button(action: action) {
            Text("Done")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.islandText(1, on: .surface(wash)))
                .padding(.horizontal, 11)
                .frame(height: 20)
                .background(Capsule().fill(.islandSurface(wash)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
