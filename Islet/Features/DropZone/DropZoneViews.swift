import SwiftUI

extension FeatureTint {
    /// The AirDrop tile: iOS system blue, AirDrop's colour.
    static let dropZoneAirDrop = FeatureTint.colour(RGB(0.04, 0.52, 1.0))
    /// The shelf's tile, its label on the home page and the screenshot's Add to Shelf:
    /// iOS system yellow.
    static let dropZoneShelf = FeatureTint.colour(RGB(1.0, 0.84, 0.04))
}

enum DropZonePalette {
    /// A drop that could not be handled: the failure red as this page has always drawn
    /// it, a shade off the system's. It means something, so it never takes the accent
    /// and is only fitted.
    static let failed = RGB(1.0, 0.27, 0.23)
}

/// The page the island opens onto while a file or a picture is dragged to the notch:
/// AirDrop on the left, the shelf on the right. The island takes the drops and says
/// which tile they landed on.
struct DropZonePage: View {
    let model: DropZoneModel

    var body: some View {
        HStack(spacing: 10) {
            DropTile(place: .airDrop, model: model)
            DropTile(place: .shelf, model: model)
        }
        .padding(.top, 4)
        .padding(.horizontal, 4)
        .onAppear { model.shelf.refresh() }
    }
}

/// One place to drop files. It swells and lights up in its colour while a drag is
/// over it, and says what happened for a moment after the drop. The island takes
/// the drop and says which tile it landed on.
private struct DropTile: View {
    let place: DropZoneModel.Place
    let model: DropZoneModel
    @Environment(\.islandTheme) private var theme

    private var tint: FeatureTint { place == .airDrop ? .dropZoneAirDrop : .dropZoneShelf }

    /// The tile's colour at full strength, fitted to the island: on the black island
    /// with Feature colours, exactly the feature's own.
    private var accent: RGB { theme.fitted(theme.accentSource(tint)) }

    /// Lit, the tile is a wash of its colour, as strong as leaves its words readable.
    private var litWash: Double { theme.readableWash(0.2, of: accent, over: theme.island) }

    /// What the tile's words and badge lie on: a wash of its colour while lit, or of the
    /// ink.
    private func backdrop(isLit: Bool) -> IslandBackdrop {
        isLit ? .fill(accent.composited(litWash, over: theme.island)) : .surface(0.06)
    }

    var body: some View {
        let isLit = model.hovered == place || model.demoTarget == place
        // A new drag over the tile takes precedence over the last drop's note.
        let note = !isLit && model.note?.place == place ? model.note : nil
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        VStack(spacing: 7) {
            badge(isLit: isLit, note: note)

            VStack(spacing: 1) {
                Text(place == .airDrop ? "AirDrop" : "Shelf")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.islandText(1, on: backdrop(isLit: isLit)))
                Text(note?.text ?? subtitle(isLit: isLit))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(note?.isError == true
                        ? .islandFitted(DropZonePalette.failed, minimum: Contrast.text, on: backdrop(isLit: isLit))
                        : .islandText(0.55, on: backdrop(isLit: isLit)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if place == .shelf, !model.shelf.items.isEmpty {
                ShelfFan(items: Array(model.shelf.items.prefix(3)))
                    .padding(12)
            }
        }
        .background(shape.fill(isLit ? .island(.fitted(accent)).opacity(litWash) : .islandSurface(0.06)))
        .overlay(
            shape.strokeBorder(
                isLit ? .islandAccent(tint) : .islandDecorative(0.16),
                style: StrokeStyle(lineWidth: isLit ? 2 : 1.5, dash: isLit ? [] : [5, 4])
            )
        )
        .contentShape(shape)
        .scaleEffect(isLit ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isLit)
        .animation(.easeOut(duration: 0.2), value: note)
    }

    private func badge(isLit: Bool, note: DropZoneModel.Note?) -> some View {
        let symbol = note.map { $0.isError ? "exclamationmark" : "checkmark" }
            ?? (place == .airDrop ? "dot.radiowaves.left.and.right" : "tray.and.arrow.down.fill")
        let colours = badgeColours(isLit: isLit, isError: note?.isError == true)

        return Group {
            if note?.isWorking == true {
                // A picture still on its way from the web.
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(colours.glyph)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 40, height: 40)
        .background(Circle().fill(colours.disc))
    }

    /// Lit, the badge is a disc of the tile's colour with the glyph in black or white on
    /// it; otherwise the glyph is in the colour (red for a failed drop) on a wash of it
    /// over the tile, as a round button's is (`IslandTheme.onWash`).
    private func badgeColours(isLit: Bool, isError: Bool) -> (glyph: AnyShapeStyle, disc: AnyShapeStyle) {
        if isLit {
            guard !theme.isDefault else {
                // Yellow is too light to carry a white glyph.
                let glyph: Color = place == .shelf ? .black : .white
                return (AnyShapeStyle(glyph), AnyShapeStyle(accent.color))
            }
            return (AnyShapeStyle(.islandOnFill(accent)), AnyShapeStyle(.islandFill(accent)))
        }
        let ink: IslandInk = isError ? .fitted(DropZonePalette.failed) : .accent(tint)
        let colours = theme.onWash(ink, wash: 0.2, on: backdrop(isLit: false))
        return (AnyShapeStyle(colours.mark), AnyShapeStyle(colours.wash))
    }

    private func subtitle(isLit: Bool) -> String {
        switch place {
        case .airDrop:
            return isLit ? "Release to share" : "Send to a nearby device"
        case .shelf:
            if isLit { return "Release to keep" }
            let count = model.shelf.items.count
            switch count {
            case 0: return "Keep files for later"
            case 1: return "1 item on the shelf"
            default: return "\(count) items on the shelf"
            }
        }
    }
}

/// The newest few files on the shelf, fanned like a hand of cards in the tile's
/// corner, so a drop is seen to land.
private struct ShelfFan: View {
    let items: [ShelfItem]
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: -12) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                FileIcon(url: item.url, size: 24)
                    .shadow(color: theme.shadow(0.45), radius: 3, y: 1)
                    .rotationEffect(.degrees((Double(index) - Double(items.count - 1) / 2) * 9))
                    .zIndex(Double(items.count - index))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: items.map(\.id))
    }
}
