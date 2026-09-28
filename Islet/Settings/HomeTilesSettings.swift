import SwiftUI

/// Settings' list of home tiles: every tile the features that are on can show, in the
/// order the home page has them, to drag into another; a switch on each to hide it or
/// show it again; and Reset, back to the features' own order with every tile showing.
struct HomeTilesSection: View {
    let arrangement: HomeArrangement

    /// A row's height as laid out; the list goes by how its rows are drawn once they are.
    static let rowHeight: CGFloat = 36

    /// Where the rows are drawn, by tile, in the window.
    @State private var rowFrames: [String: CGRect] = [:]

    var body: some View {
        let tiles = arrangement.arrangedTiles
        let ids = tiles.map(\.id)
        Section {
            if tiles.isEmpty {
                Text("None of the activities that are on has a tile on the home page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // A list of its own inside the form, since only a list takes a row
                // dragged to another place. It is as tall as its rows and never scrolls:
                // the form scrolls around it. Only its rows are measured: a list wrapped
                // in anything more loses the form's own margins and lines.
                List {
                    ForEach(tiles) { tile in
                        let index = ids.firstIndex(of: tile.id) ?? 0
                        HomeTileRow(
                            tile: tile,
                            isShown: Binding(
                                get: { !arrangement.isHidden(tile.id) },
                                set: { arrangement.setHidden(!$0, tile.id) }
                            ),
                            moveUp: index > 0 ? { arrangement.move(tile.id, to: index - 1, in: ids) } : nil,
                            moveDown: index < ids.count - 1 ? { arrangement.move(tile.id, to: index + 1, in: ids) } : nil
                        )
                        .frame(height: Self.rowHeight)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames[tile.id] = $0 }
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                        // The line between rows runs from the handle, as the form's run
                        // from the start of the row.
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .contextMenu { menu(for: tile, in: ids) }
                    }
                    .onMove { offsets, destination in
                        arrangement.move(fromOffsets: offsets, toOffset: destination, in: ids)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .environment(\.defaultMinListRowHeight, Self.rowHeight)
                .frame(height: Self.listHeight(
                    rows: ids.count, first: rowFrames[ids[0]], second: ids.count > 1 ? rowFrames[ids[1]] : nil
                ))
            }
        } header: {
            Text("Home Tiles")
        } footer: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Drag tiles into the order they go in on the home page, first on the left, and switch off the ones you would rather not see. Right-click the home page in the island to arrange it there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Reset") { arrangement.reset() }
                    .disabled(!arrangement.isCustomised)
            }
        }
    }

    /// As tall as every row. A row is not drawn the same height on every macOS, nor
    /// always with the same space between rows, so this goes by how far apart the first
    /// two are drawn (a plain list keeps no margin above or below its rows); until they
    /// have been, or with one row, by the row itself.
    static func listHeight(rows count: Int, first: CGRect?, second: CGRect?) -> CGFloat {
        let pitch = first.flatMap { first in second.map { $0.minY - first.minY } } ?? max(first?.height ?? 0, rowHeight)
        return (CGFloat(count) * max(pitch, rowHeight)).rounded(.up)
    }
}

extension HomeTilesSection {
    /// The row's menu: another way to move it than dragging.
    @ViewBuilder
    private func menu(for tile: HomeTileInfo, in ids: [String]) -> some View {
        let index = ids.firstIndex(of: tile.id) ?? 0
        Button("Move Up") { arrangement.move(tile.id, to: index - 1, in: ids) }
            .disabled(index == 0)
        Button("Move Down") { arrangement.move(tile.id, to: index + 1, in: ids) }
            .disabled(index == ids.count - 1)
        Divider()
        Button("Move to Start") { arrangement.move(tile.id, to: 0, in: ids) }
            .disabled(index == 0)
        Button("Move to End") { arrangement.move(tile.id, to: ids.count - 1, in: ids) }
            .disabled(index == ids.count - 1)
    }
}

/// One tile in the list: a handle to drag it by, its feature's symbol and name, and
/// whether it shows. VoiceOver moves it with the switch's actions.
private struct HomeTileRow: View {
    let tile: HomeTileInfo
    @Binding var isShown: Bool
    /// One place up or down the list; `nil` at that end of it.
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            IslandSymbolBadge(symbol: tile.symbol, size: 22, cornerRadius: 6, pointSize: 11)
                .accessibilityHidden(true)
            Text(tile.title)
                .foregroundStyle(isShown ? .primary : .secondary)
            Spacer(minLength: 8)
            // The form's own size of switch, which a list inside it keeps.
            Toggle(tile.title, isOn: $isShown)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityHint("Use the Move Up and Move Down actions, or drag the row, to change where the tile goes on the home page")
                .accessibilityActions {
                    if let moveUp { Button("Move Up", action: moveUp) }
                    if let moveDown { Button("Move Down", action: moveDown) }
                }
        }
    }
}
