import AppIntents
import Foundation

/// Open Quick Ask, the Shortcuts action: opens the island's input box on the display
/// under the pointer, ready to type, as the shortcut does. A shortcut made of it can be
/// given a key of its own in Shortcuts.
///
/// It runs inside Islet, in the background. Shortcuts launches Islet first if it is not
/// running.
struct OpenQuickAskIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Ask"
    static let description = IntentDescription(
        "Opens the box in the island to ask a quick question, or to add an event, ready to type.",
        categoryName: "Quick Ask"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Mode", default: .ask)
    var mode: InputModeChoice

    @MainActor
    func perform() async throws -> some IntentResult {
        guard InputCenter.shared.mode(id: mode.rawValue)?.id == mode.rawValue else { throw OpenQuickAskError.turnedOff }
        InputCenter.shared.open(mode.rawValue)
        return .result()
    }
}

/// The box's modes, as Shortcuts offers them.
enum InputModeChoice: String, AppEnum {
    case ask
    case event

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
    static let caseDisplayRepresentations: [InputModeChoice: DisplayRepresentation] = [
        .ask: "Ask",
        .event: "New event",
    ]
}

enum OpenQuickAskError: Error, CustomLocalizedStringResourceConvertible {
    case turnedOff

    var localizedStringResource: LocalizedStringResource {
        "That part of Islet is turned off in Settings."
    }
}
