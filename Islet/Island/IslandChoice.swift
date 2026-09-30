import AppKit
import SwiftUI

/// Something the island's menus offer about which activity holds the compact island
/// (`ActivityCenter.pinnedID`): right-click a bubble, the icon folded into the island,
/// an activity's tab in the opened island, or the compact island itself. VoiceOver
/// has the same as actions on each bubble, the folded icon, the tabs and the island.
/// Last comes the way to the order that decides it otherwise, in Settings.
enum IslandChoice: Hashable {
    /// Put this activity in the island, and keep it there.
    case show(String)
    /// Keep this activity, already in the island, there.
    case keep(String)
    /// Let the person's order, or priority, rank and age, decide again.
    case letIsletChoose
    /// Open Settings at that order, to choose what stays in the island from now on
    /// (`IslandOrderSection`).
    case arrange

    var title: String {
        switch self {
        case .show: "Show in Island"
        case .keep: "Keep in Island"
        case .letIsletChoose: "Let Islet Choose"
        case .arrange: "Choose What Stays in the Island…"
        }
    }
}

extension IslandViewModel {
    /// The choices for activity `id`: to put it in the island, or, while it is the one
    /// chosen, to let Islet choose again; then to arrange the order in Settings. None
    /// for one no longer running.
    func choices(forActivity id: String) -> [IslandChoice] {
        guard center.isShowing(id: id) else { return [] }
        if center.pinnedID == id { return [.letIsletChoose, .arrange] }
        return [center.primary?.id == id ? .keep(id) : .show(id), .arrange]
    }

    /// The compact island's menu: the folded activity's choices with the pointer on its
    /// end of the island, the same patch a click there opens it from; otherwise to keep
    /// the activity in front there or, while one is chosen, to let Islet choose again.
    /// None in any other mode.
    var compactChoices: [IslandChoice] {
        guard case .compact = mode else { return [] }
        if let folded = foldedActivity, hoveredSecondary == .activity(folded.id) {
            return choices(forActivity: folded.id)
        }
        return compactOwnChoices
    }

    /// The compact island's own choices, wherever the pointer is: to keep the activity
    /// in front there or, while one is chosen, to let Islet choose again; then to
    /// arrange the order in Settings.
    var compactOwnChoices: [IslandChoice] {
        guard case .compact(let id) = mode else { return [] }
        return center.pinnedID != nil ? [.letIsletChoose, .arrange] : choices(forActivity: id)
    }

    /// The compact island's own choices as VoiceOver actions on the island as a whole
    /// (`IslandHostingView`), so Let Islet Choose is there without opening it. On the
    /// island rather than on what its activity shows, which may be a picture with no
    /// element of its own, and whose actions the folded icon and the count would take
    /// on too.
    var compactAccessibilityActions: [NSAccessibilityCustomAction] {
        compactOwnChoices.map { choice in
            NSAccessibilityCustomAction(name: choice.title) { [weak self] in
                self?.choose(choice)
                return self != nil
            }
        }
    }

    /// Does what `choice` says. The opened island stays on the page it is showing,
    /// rather than following the activity in front to the one chosen; for Settings, it
    /// closes, as for its gear.
    func choose(_ choice: IslandChoice) {
        if isExpanded, focus == nil { focus = resolvedFocus }
        switch choice {
        case .show(let id), .keep(let id): center.pin(id: id)
        case .letIsletChoose: center.unpin()
        case .arrange:
            collapse()
            openSettings(.islandOrder)
        }
    }
}

extension View {
    /// Activity `id`'s choices, on a right-click and as VoiceOver actions, for a bubble,
    /// a tab or the folded icon. With `menu` off, only VoiceOver's: the folded icon's
    /// menu is the compact island's (`IslandViewModel.compactChoices`).
    func islandChoices(forActivity id: String?, menu: Bool = true) -> some View {
        modifier(IslandChoiceMenu(kind: .activity(id, menu: menu)))
    }

    /// The compact island's choices on a right-click anywhere on its row.
    func compactIslandChoices() -> some View {
        modifier(IslandChoiceMenu(kind: .compactMenu))
    }
}

private struct IslandChoiceMenu: ViewModifier {
    enum Kind {
        case activity(String?, menu: Bool)
        case compactMenu
    }

    let kind: Kind
    @Environment(\.island) private var island

    func body(content: Content) -> some View {
        switch kind {
        case .compactMenu:
            content
                .contentShape(Rectangle())
                .contextMenu { buttons(island?.compactChoices ?? []) }
        case .activity(let id, menu: true):
            let choices = choices(forActivity: id)
            content
                .contextMenu { buttons(choices) }
                .accessibilityActions { buttons(choices, divided: false) }
        case .activity(let id, menu: false):
            content.accessibilityActions { buttons(choices(forActivity: id), divided: false) }
        }
    }

    private func choices(forActivity id: String?) -> [IslandChoice] {
        guard let island, let id else { return [] }
        return island.choices(forActivity: id)
    }

    /// The choices as a menu's items, the way to Settings apart from the rest, or as
    /// VoiceOver's actions, which have no dividers.
    private func buttons(_ choices: [IslandChoice], divided: Bool = true) -> some View {
        ForEach(choices, id: \.self) { choice in
            if divided, choice == .arrange { Divider() }
            Button(choice.title) { island?.choose(choice) }
        }
    }
}
