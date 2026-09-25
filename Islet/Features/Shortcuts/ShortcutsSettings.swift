import AppKit
import SwiftUI

struct ShortcutsSettingsView: View {
    let catalogue: ShortcutCatalogue
    @AppStorage(ShortcutsPrefs.showRuns) private var showRuns = true
    @AppStorage(ShortcutsPrefs.showOutsideRuns) private var showOutsideRuns = true
    @AppStorage(ShortcutsPrefs.pinned) private var pinned = ""
    @State private var isChoosing = false

    /// Opens Settings on this feature, from the home tile: the island closes, since
    /// Settings is where the person is going.
    @MainActor
    static func open() {
        IslandManager.shared.focusedController?.model.collapse()
        UserDefaults.standard.set("activities", forKey: SettingsView.tabKey)
        SettingsWindowController.shared.show()
    }

    var body: some View {
        ShortcutsAccessRow(catalogue: catalogue)

        Toggle(isOn: $showRuns) {
            Text("Show shortcut runs in the island")
            Text("A shortcut's icon beside the notch while it runs, then a tick or a cross. macOS shows its own indicator in the menu bar too, and has no setting to hide it.")
        }
        // Runs started elsewhere are known only from the Shortcuts database.
        if showRuns, catalogue.access == .granted {
            Toggle(isOn: $showOutsideRuns) {
                Text("Show runs started outside Islet")
                Text("From Shortcuts, the menu bar, Spotlight, Siri, automations and the command line.")
            }
        }

        LabeledContent {
            Button("Choose…") { isChoosing = true }
                .popover(isPresented: $isChoosing, arrowEdge: .trailing) {
                    ShortcutPicker(catalogue: catalogue, pinned: $pinned)
                }
        } label: {
            Text("Home tile")
            Text("Up to six shortcuts, each a click from running. islet://shortcuts/run?name=… runs any shortcut.")
        }
        ForEach(Array(identifiers.enumerated()), id: \.element) { index, identifier in
            PinnedShortcutRow(
                shortcut: catalogue.shortcut(identifier: identifier),
                isLoaded: catalogue.shortcuts != nil,
                canMoveUp: index > 0,
                canMoveDown: index < identifiers.count - 1,
                move: { move(identifier, by: $0) },
                remove: { remove(identifier) }
            )
        }

        LabeledContent {
            Button("Open Shortcuts") { ShortcutsTool.openShortcutsApp() }
        } label: {
            Text("Shortcuts are made and changed in the Shortcuts app.")
        }
        .onAppear { catalogue.refresh(relist: true) }
    }

    private var identifiers: [String] { ShortcutsPrefs.identifiers(pinned) }

    private func move(_ identifier: String, by offset: Int) {
        var list = identifiers
        guard let index = list.firstIndex(of: identifier), list.indices.contains(index + offset) else { return }
        list.swapAt(index, index + offset)
        pinned = ShortcutsPrefs.stored(list)
    }

    private func remove(_ identifier: String) {
        pinned = ShortcutsPrefs.stored(identifiers.filter { $0 != identifier })
    }
}

/// One of the home tile's shortcuts, with the means to move it or take it off. A
/// shortcut since deleted (or not listed) says so, rather than vanish from the list.
private struct PinnedShortcutRow: View {
    let shortcut: ShortcutInfo?
    let isLoaded: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let shortcut {
                ShortcutTile(shortcut: shortcut, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shortcut.name).lineLimit(1)
                    if let folder = shortcut.folder {
                        Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: 22, height: 22)
                Text(isLoaded ? "Shortcut not found" : "Loading…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!canMoveUp)
                .help("Move up")
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .disabled(!canMoveDown)
                .help("Move down")
            Button(action: remove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .help("Take off the home tile")
        }
        .buttonStyle(.borderless)
    }
}

/// Every shortcut, searchable by name or folder, each ticked on or off the home tile.
private struct ShortcutPicker: View {
    let catalogue: ShortcutCatalogue
    @Binding var pinned: String
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let chosen = ShortcutsPrefs.identifiers(pinned)
        VStack(spacing: 0) {
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            Group {
                if let shortcuts = catalogue.shortcuts {
                    let matches = filtered(shortcuts)
                    if matches.isEmpty {
                        Text(shortcuts.isEmpty ? "No shortcuts yet." : "No shortcut matches.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(matches) { shortcut in
                                    row(shortcut, chosen: chosen)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 300)
            Divider()
            HStack {
                Text("\(chosen.count) of \(ShortcutsPrefs.pinnedLimit) chosen")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 320)
        .onAppear { catalogue.refresh(relist: true) }
    }

    private func filtered(_ shortcuts: [ShortcutInfo]) -> [ShortcutInfo] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return shortcuts.filter { $0.identifier != nil } }
        return shortcuts.filter { shortcut in
            shortcut.identifier != nil
                && (shortcut.name.localizedStandardContains(query) || (shortcut.folder?.localizedStandardContains(query) ?? false))
        }
    }

    private func row(_ shortcut: ShortcutInfo, chosen: [String]) -> some View {
        let identifier = shortcut.identifier ?? ""
        let isChosen = chosen.contains(identifier)
        let isFull = chosen.count >= ShortcutsPrefs.pinnedLimit
        return Button {
            pinned = ShortcutsPrefs.stored(isChosen ? chosen.filter { $0 != identifier } : chosen + [identifier])
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen ? Color.accentColor : .secondary)
                    .font(.system(size: 15))
                ShortcutTile(shortcut: shortcut, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shortcut.name).lineLimit(1)
                    if let folder = shortcut.folder {
                        Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isChosen && isFull)
        .opacity(!isChosen && isFull ? 0.45 : 1)
    }
}

/// Whether Islet can read the Shortcuts database, and the way to let it.
private struct ShortcutsAccessRow: View {
    let catalogue: ShortcutCatalogue

    var body: some View {
        LabeledContent {
            switch catalogue.access {
            case .granted:
                Label {
                    Text("Allowed")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
            case .needsFullDiskAccess:
                Button("Open Privacy Settings…") { Self.openFullDiskAccess() }
            case .unavailable:
                Text("Unavailable").foregroundStyle(.secondary)
            case .unknown:
                ProgressView().controlSize(.small)
            }
        } label: {
            Text("Full Disk Access")
            Text(explanation)
        }
    }

    private var explanation: String {
        switch catalogue.access {
        case .granted, .unknown:
            "Islet reads your shortcuts' icons, and notices runs started elsewhere, from the Shortcuts database."
        case .needsFullDiskAccess:
            "macOS keeps shortcuts in a folder only apps with Full Disk Access can read. Until Islet has it, shortcuts show their names on a plain tile, and the island shows only the runs Islet starts."
        case .unavailable:
            "This version of macOS keeps shortcuts where Islet cannot read them: they show their names on a plain tile, and the island shows only the runs Islet starts."
        }
    }

    private static func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
