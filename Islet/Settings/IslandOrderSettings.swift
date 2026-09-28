import SwiftUI

/// Settings' Island Order: the live activities of the features that are on, in the
/// order the island takes them in when several are going on at once, to drag into
/// another; and Reset, back to priority, rank and age (`IslandArrangement`).
struct IslandOrderSection: View {
    let arrangement: IslandArrangement

    var body: some View {
        Section {
            IslandOrderList(id: GeneralRow.islandOrder.id, arrangement: arrangement)
        } header: {
            Text("Island Order")
        } footer: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Drag activities into the order the island shows them in when several are going on: the first holds the island, and the rest go in bubbles beside it. Until you do, what matters most now goes first, like a timer or a meeting about to start, and the list shows that order. To keep one in the island for now, right-click its bubble and choose Show in Island.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Reset") { arrangement.reset() }
                    .disabled(!arrangement.isArranged)
            }
        }
    }
}

/// The list itself, as the Island Order section and search results show it.
struct IslandOrderList: View {
    let id: String
    let arrangement: IslandArrangement

    /// Where the rows are drawn, by activity, in the window.
    @State private var rowFrames: [String: CGRect] = [:]

    var body: some View {
        let activities = arrangement.arrangedActivities
        let ids = activities.map(\.id)
        if activities.isEmpty {
            Text("None of the activities that are on shows in the island.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .settingsSearchTarget(id)
        } else {
            // A list of its own inside the form, as Home Tiles' is, since only a list
            // takes a row dragged to another place. As tall as its rows; the form
            // scrolls around it.
            List {
                ForEach(activities) { activity in
                    let index = ids.firstIndex(of: activity.id) ?? 0
                    IslandOrderRow(
                        activity: activity,
                        moveUp: index > 0 ? { arrangement.move(activity.id, to: index - 1, in: ids) } : nil,
                        moveDown: index < ids.count - 1 ? { arrangement.move(activity.id, to: index + 1, in: ids) } : nil
                    )
                    .frame(height: HomeTilesSection.rowHeight)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames[activity.id] = $0 }
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .contextMenu { menu(for: activity, in: ids) }
                }
                .onMove { offsets, destination in
                    arrangement.move(fromOffsets: offsets, toOffset: destination, in: ids)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .environment(\.defaultMinListRowHeight, HomeTilesSection.rowHeight)
            .frame(height: HomeTilesSection.listHeight(
                rows: ids.count, first: rowFrames[ids[0]], second: ids.count > 1 ? rowFrames[ids[1]] : nil
            ))
            .settingsSearchTarget(id)
        }
    }

    /// The row's menu: another way to move it than dragging.
    @ViewBuilder
    private func menu(for activity: IslandActivityInfo, in ids: [String]) -> some View {
        let index = ids.firstIndex(of: activity.id) ?? 0
        Button("Move Up") { arrangement.move(activity.id, to: index - 1, in: ids) }
            .disabled(index == 0)
        Button("Move Down") { arrangement.move(activity.id, to: index + 1, in: ids) }
            .disabled(index == ids.count - 1)
        Divider()
        Button("Move to Top") { arrangement.move(activity.id, to: 0, in: ids) }
            .disabled(index == 0)
        Button("Move to Bottom") { arrangement.move(activity.id, to: ids.count - 1, in: ids) }
            .disabled(index == ids.count - 1)
    }
}

/// One activity in the list: a handle to drag it by, and its feature's symbol and name.
/// VoiceOver moves it with the row's actions.
private struct IslandOrderRow: View {
    let activity: IslandActivityInfo
    /// One place up or down the list; `nil` at that end of it.
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            IslandSymbolBadge(symbol: activity.symbol, size: 22, cornerRadius: 6, pointSize: 11)
                .accessibilityHidden(true)
            Text(activity.title)
            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Use the Move Up and Move Down actions, or drag the row, to change which activity the island shows first")
        .accessibilityActions {
            if let moveUp { Button("Move Up", action: moveUp) }
            if let moveDown { Button("Move Down", action: moveDown) }
        }
    }
}
