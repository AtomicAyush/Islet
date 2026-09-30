import SwiftUI
import Observation

/// One way of typing in the input box — asking a question, adding an event — which a
/// feature registers with `InputCenter` while it runs.
@MainActor
struct InputMode: Identifiable {
    let id: String
    /// The mode's chip, and VoiceOver's name for the field: "Ask", "New event".
    let title: String
    let symbol: String
    let tint: FeatureTint
    /// What the empty field says.
    let placeholder: String
    /// Lower comes first in the chip's menu, and ⌘1 is the first.
    let order: Int
    /// Typed first in another mode, switches the box to this one, and is taken away:
    /// "+" for an event. Shown by the chip changing.
    var prefix: Character? = nil
    /// Offered a draft typed in another mode: a line offering to take it over ("Add
    /// “Dentist” tomorrow 15:00 to Calendar?"), or `nil`. Taking it (⌘Return, or a click) only
    /// switches the box to this mode, the draft and all; it does nothing more.
    var suggest: (@MainActor (String) -> String?)? = nil
    /// Who a draft sent in this mode goes to, by name ("ChatGPT"), for a mode that sends
    /// it off to be answered: a command answered on this Mac instead says it wasn't sent
    /// there, and offers to send it anyway.
    var recipient: (@MainActor () -> String)? = nil
    /// What the box holds in this mode while it is open: made as the mode is first
    /// used after the box opens, and forgotten as it closes.
    let makeSession: @MainActor () -> any InputSession
}

/// A request typed in any mode that is answered on this Mac, before it could be sent
/// anywhere: "summarise my day". It is recognised by fixed rules only, and its answer is
/// shown above the field.
@MainActor
struct InputCommand: Identifiable {
    let id: String
    /// Whether the words typed ask for it.
    let matches: @MainActor (String) -> Bool
    /// Under the field while the draft asks for it: what Return will do.
    let hint: String
    let symbol: String
    /// The answer to `text`. `anyway` sends just those words on to the mode that would
    /// have had them, where there is one.
    let view: @MainActor (_ text: String, _ anyway: InputAnyway?) -> AnyView
}

/// Words a command answered, sent on after all to whoever answers the box's questions.
struct InputAnyway {
    /// "ChatGPT".
    let name: String
    let send: @MainActor () -> Void
}

/// What a mode keeps while the box is open, and draws around the field. It lives in
/// memory only, for as long as the box is open (`close()`).
@MainActor
protocol InputSession: AnyObject {
    /// Drawn above the field: a conversation.
    func above() -> AnyView?
    /// Drawn below the field: an event's preview.
    func below() -> AnyView?
    /// The chip after the field: who answers, which calendar.
    func trailingChip() -> AnyView?
    /// The draft changed, with each key.
    func draftChanged(_ draft: String)
    /// Return, with the draft. Returns whether the field empties.
    func submit(_ draft: String) -> Bool
    /// ⌘Return, with the draft. Returns whether the field empties.
    func accept(_ draft: String) -> Bool
    /// Whether something is under way that Stop ends (an answer coming).
    var isBusy: Bool { get }
    func stop()
    /// The box opened on this mode with the keyboard: a moment to get ready.
    func opened()
    /// The box closed: everything typed and shown is forgotten.
    func close()
    /// The box the session was made for, as it is made: for a button of its own that
    /// does what ⌘Return does, and empties the field as that does.
    func attach(to box: InputBox)
}

extension InputSession {
    func above() -> AnyView? { nil }
    func below() -> AnyView? { nil }
    func trailingChip() -> AnyView? { nil }
    func draftChanged(_ draft: String) {}
    func accept(_ draft: String) -> Bool { submit(draft) }
    var isBusy: Bool { false }
    func stop() {}
    func opened() {}
    func attach(to box: InputBox) {}
}

/// The input box's modes, and the one page of the opened island they are typed in
/// (`islet://open?focus=input` shows it, and a click on its field types in it). The
/// page is there while any mode is registered.
///
/// What is typed and shown there is kept in memory only, and only while the box is
/// open: typing in it ending, for any reason, forgets it (`InputBox.close()`).
@MainActor
@Observable
final class InputCenter {
    static let shared = InputCenter()
    static let pageID = "input"
    static let symbol = "text.cursor"

    private(set) var modes: [InputMode] = []
    private(set) var commands: [InputCommand] = []
    let box = InputBox()
    /// Begins typing in an island: the manager's, which ends typing in any other first.
    /// Tests replace it.
    @ObservationIgnored var beginTyping: (IslandViewModel, TypingPlace, TypingClient) -> Void = { island, place, client in
        IslandManager.shared.beginTyping(on: island, in: place, client: client)
    }
    /// The island under the pointer. Tests replace it.
    @ObservationIgnored var focusedIsland: () -> IslandViewModel? = {
        IslandManager.shared.focusedController?.model
    }

    init() {
        box.center = self
        box.heightChanged = { [weak self] in self?.publishPage(animated: true) }
    }

    func register(_ mode: InputMode) {
        var next = modes.filter { $0.id != mode.id }
        next.append(mode)
        next.sort { $0.order < $1.order }
        modes = next
        publishPage(animated: false)
    }

    /// Takes a mode away as its feature stops: the box closes if it was open on it.
    func unregister(id: String) {
        guard modes.contains(where: { $0.id == id }) else { return }
        if box.modeID == id { box.island?.endTyping(.featureStopped) }
        modes.removeAll { $0.id == id }
        if box.modeID == id { box.modeID = nil }
        publishPage(animated: false)
    }

    func register(_ command: InputCommand) {
        commands = commands.filter { $0.id != command.id } + [command]
    }

    /// Takes a command away as its feature stops, and its answer from the box.
    func unregister(command id: String) {
        commands.removeAll { $0.id == id }
        box.forgetCommand(id)
    }

    /// The command the words typed ask for, if any.
    func command(for text: String) -> InputCommand? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return commands.first { $0.matches(text) }
    }

    func mode(id: String?) -> InputMode? {
        guard let id else { return modes.first }
        return modes.first { $0.id == id } ?? modes.first
    }

    /// Opens the box in `modeID` (the one it was last in, or the first) on `island`, or
    /// the island under the pointer, and gives it the keyboard. Only for the person's
    /// own act: the shortcut, a click on the field or a tile, the Shortcuts action.
    func open(_ modeID: String? = nil, on island: IslandViewModel? = nil) {
        guard let island = island ?? focusedIsland(), let mode = mode(id: modeID ?? box.modeID) else { return }
        // Typing in another island ends first, and the box with it: it moves over empty.
        beginTyping(island, .page(Self.pageID), TypingClient(
            key: { [weak self] action in self?.box.key(action) },
            ended: { [weak self] reason in self?.box.close(reason) }
        ))
        box.island = island
        box.show(mode)
        box.session?.opened()
    }

    /// The shortcut: closes the box where it is being typed in, and otherwise opens it.
    func toggle(_ modeID: String? = nil) {
        if let island = box.island, island.typingPlace == .page(Self.pageID) {
            island.endTyping(.shortcut)
        } else {
            open(modeID)
        }
    }

    /// The page, at the box's height, while there is a mode to type in.
    private func publishPage(animated: Bool) {
        let center = ActivityCenter.shared
        guard !modes.isEmpty else {
            center.removePage(id: Self.pageID)
            return
        }
        let page = IslandPage(
            id: Self.pageID, symbol: Self.symbol, height: box.height,
            view: AnyView(InputBoxView(center: self))
        )
        if animated, center.pages[Self.pageID]?.height != page.height {
            withAnimation(.islandMorph) { center.setPage(page) }
        } else {
            center.setPage(page)
        }
    }
}
