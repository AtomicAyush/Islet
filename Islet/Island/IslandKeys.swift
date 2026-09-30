import AppKit
import Carbon.HIToolbox

// Typing in the island. The panel never has the keyboard but while something in it is
// being typed in, and only because the person asked for that: a shortcut pressed, a
// field or a tile clicked. It stays a non-activating panel meanwhile, so the app in
// front stays in front, menu bar and all, and gets the keyboard back as typing ends.

/// Where something in an island is being typed in.
enum TypingPlace: Equatable {
    /// A page of the opened island (`IslandPage.id`), such as the input box.
    case page(String)
    /// A card in the island's place (`IslandBanner.id`).
    case card(String)
}

/// Why typing in the island ended, as logged: a word, never what was typed.
enum TypingEnd: String {
    case escape = "input.escape"
    case close = "input.close"
    case done = "input.done"
    case shortcut = "input.shortcut"
    case clickOutside = "input.click-outside"
    case collapse = "input.collapse"
    case otherPage = "input.other-page"
    case suppressed = "input.full-screen"
    case resignedKey = "input.resigned-key"
    case invalidated = "input.invalidated"
    case featureStopped = "input.feature-stopped"
    case otherIsland = "input.other-island"
}

/// What a key equivalent pressed while the island has the keyboard does to what is
/// being typed in, besides the Edit menu's own.
enum IslandKeyAction: Equatable {
    /// ⌘Return: the other way to send what was typed (add, or take the suggestion).
    case accept
    /// ⌘1, ⌘2…: the box's first mode, its second…, from 0.
    case mode(Int)
    /// ⌘W or ⌘.: close the box.
    case close
    /// ⇧⌘S: look at the screen, for the next question.
    case look
}

/// What the panel does with a key equivalent while it takes keys (`IslandPanel`).
enum KeyEquivalentRule: Equatable {
    /// On to the field and then to the main menu's Edit items: copy, paste, cut, select
    /// all, undo and redo, and the field's own moving and deleting (⌘←, ⇧⌘→, ⌘⌫).
    case pass
    /// The island's own (`IslandKeyAction`).
    case handle(IslandKeyAction)
    /// Swallowed, so it reaches none of Islet's own menu items: ⌘Q would quit Islet, ⌘H
    /// hide it, ⌘, open its Settings.
    case swallow

    /// The rule for a key pressed with `modifiers`, `characters` being what it types
    /// with none held but Shift (`charactersIgnoringModifiers`). Keys without ⌘ are the
    /// field's own, and pass.
    static func rule(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Self {
        let held = modifiers.intersection([.command, .option, .control, .shift])
        guard held.contains(.command) else { return .pass }
        let others = held.subtracting(.command)
        let key = (characters ?? "").lowercased()

        if keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            return others.isEmpty ? .handle(.accept) : .swallow
        }
        // To the start or end of the line or text, selecting there, or deleting to it.
        if editingKeys.contains(Int(keyCode)) { return .pass }
        if others.isEmpty {
            switch key {
            case "c", "v", "x", "a", "z":
                return .pass
            case "w", ".":
                return .handle(.close)
            default:
                if let digit = Int(key), (1...9).contains(digit) { return .handle(.mode(digit - 1)) }
            }
        }
        // Redo.
        if others == .shift, key == "z" { return .pass }
        if others == .shift, key == "s" { return .handle(.look) }
        return .swallow
    }

    private static let editingKeys: Set<Int> = [
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End,
        kVK_PageUp, kVK_PageDown, kVK_Delete, kVK_ForwardDelete,
    ]

    /// The Edit menu's action for a key equivalent that passes: copy, paste, cut,
    /// select all, undo or redo.
    static func editAction(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Selector? {
        guard rule(keyCode: keyCode, characters: characters, modifiers: modifiers) == .pass,
              modifiers.contains(.command) else { return nil }
        let shifted = modifiers.contains(.shift)
        switch (characters ?? "").lowercased() {
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "x": return #selector(NSText.cut(_:))
        case "a": return #selector(NSText.selectAll(_:))
        case "z": return shifted ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }

    static func editAction(for event: NSEvent) -> Selector? {
        editAction(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
    }

    static func rule(for event: NSEvent) -> Self {
        rule(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
    }
}

/// A window that can be given the keyboard while something in it is typed in: the
/// island's panel, or a test's stand-in for it.
@MainActor
protocol KeyTakingWindow: AnyObject {
    /// Whether the window may become key at all.
    var takesKeys: Bool { get set }
    var isKeyWindow: Bool { get }
    func makeKey()
    /// Hands the keyboard back to the app that had it, the one in front.
    func returnKey()
}

/// Gives an island's window the keyboard as typing begins, and hands it back as typing
/// ends: only if the window still has it, since a click in another app or ⌘Tab has
/// already taken it where the person wanted it.
@MainActor
final class IslandKeyboard {
    private let window: any KeyTakingWindow

    init(window: any KeyTakingWindow) {
        self.window = window
    }

    func typingChanged(_ isTyping: Bool) {
        if isTyping {
            window.takesKeys = true
            window.makeKey()
        } else {
            window.takesKeys = false
            if window.isKeyWindow { window.returnKey() }
        }
    }
}

/// Whatever is being typed in, as the island tells it what happens to its keyboard.
struct TypingClient {
    /// A key equivalent of the island's own was pressed (`IslandKeyAction`).
    var key: @MainActor (IslandKeyAction) -> Void = { _ in }
    /// Typing ended, and why. What was typed is the client's to forget.
    var ended: @MainActor (TypingEnd) -> Void = { _ in }
    /// Whether the island leaves the page as typing ends, for one reason or another
    /// that is not already taking it elsewhere: back to the page it was on, or closed
    /// with the pointer away.
    var leavesPage = true
}
