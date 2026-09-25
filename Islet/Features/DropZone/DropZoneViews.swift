import SwiftUI

/// iOS system blue, AirDrop's colour.
let dropZoneBlue = Color(red: 0.04, green: 0.52, blue: 1.0)
/// iOS system yellow, the shelf's colour.
let dropZoneYellow = Color(red: 1.0, green: 0.84, blue: 0.04)
/// iOS system red, for a drop that could not be handled.
let dropZoneRed = Color(red: 1.0, green: 0.27, blue: 0.23)

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

    private var accent: Color { place == .airDrop ? dropZoneBlue : dropZoneYellow }

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
                    .foregroundStyle(.white)
                Text(note?.text ?? subtitle(isLit: isLit))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(note?.isError == true ? dropZoneRed : .white.opacity(0.55))
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
        .background(shape.fill(isLit ? accent.opacity(0.2) : Color.white.opacity(0.06)))
        .overlay(
            shape.strokeBorder(
                isLit ? accent : Color.white.opacity(0.16),
                style: StrokeStyle(lineWidth: isLit ? 2 : 1.5, dash: isLit ? [] : [5, 4])
            )
        )
        .contentShape(shape)
        .scaleEffect(isLit ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isLit)
        .animation(.easeOut(duration: 0.2), value: note)
    }

    private func badge(isLit: Bool, note: DropZoneModel.Note?) -> some View {
        let tint = note?.isError == true ? dropZoneRed : accent
        let symbol = note.map { $0.isError ? "exclamationmark" : "checkmark" }
            ?? (place == .airDrop ? "dot.radiowaves.left.and.right" : "tray.and.arrow.down.fill")
        // Yellow is too light to carry a white glyph.
        let glyphOnFill: Color = place == .shelf ? .black : .white

        return Group {
            if note?.isWorking == true {
                // A picture still on its way from the web.
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isLit ? glyphOnFill : tint)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 40, height: 40)
        .background(Circle().fill(tint.opacity(isLit ? 1 : 0.2)))
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

    var body: some View {
        HStack(spacing: -12) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                FileIcon(url: item.url, size: 24)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .rotationEffect(.degrees((Double(index) - Double(items.count - 1) / 2) * 9))
                    .zIndex(Double(items.count - index))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: items.map(\.id))
    }
}
