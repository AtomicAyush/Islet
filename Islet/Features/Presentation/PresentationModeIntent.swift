import AppIntents
import Foundation

/// Presentation Mode, the Shortcuts action: turns it on, off or the other way by hand,
/// as `islet://presentation/…` does. Turned on here, it stays on until turned off;
/// turned off while the screen is shared or a call is on, it stays off until that ends.
/// A shortcut made of it can run from a key, or from a Focus or an automation.
///
/// It runs inside Islet, in the background, and the island says what it did. Shortcuts
/// launches Islet first if it is not running.
struct PresentationModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Presentation Mode"
    static let description = IntentDescription(
        "Turns Islet's Presentation Mode on or off. While it is on, the island holds back personal alerts.",
        categoryName: "Presentation"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Action", default: .toggle)
    var action: PresentationAction

    static var parameterSummary: some ParameterSummary {
        Summary("Turn Presentation Mode \(\.$action)")
    }

    /// The feature that does it. Tests hand in one of their own.
    @MainActor static var target: () -> PresentationFeature? = { FeatureRegistry.shared.feature(PresentationFeature.self) }

    /// Returns whether Presentation Mode is on afterwards.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let feature = Self.target() else { throw PresentationModeError.turnedOff }

        var isOn = feature.perform(action)
        // Launched to run this, Islet may not have started its features yet; one that is
        // turned on is given a moment to.
        let deadline = ContinuousClock.now + .seconds(2)
        while isOn == nil, Self.isTurnedOn(feature), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            isOn = feature.perform(action)
        }
        guard let isOn else { throw PresentationModeError.turnedOff }
        return .result(value: isOn)
    }

    /// Whether Settings has the feature on, read straight from the defaults with the
    /// feature's own default for an unset key, since while Islet is starting that default
    /// may not be registered yet.
    @MainActor
    private static func isTurnedOn(_ feature: PresentationFeature) -> Bool {
        UserDefaults.standard.object(forKey: Prefs.Key.featureEnabled(feature.id)) as? Bool ?? feature.enabledByDefault
    }
}

/// Why Presentation Mode did not change, in words Shortcuts shows the person.
enum PresentationModeError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case turnedOff

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .turnedOff: "Presentation Mode is turned off in Islet's Settings."
        }
    }
}

extension PresentationAction: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Action"
    static let caseDisplayRepresentations: [PresentationAction: DisplayRepresentation] = [
        .toggle: "On or Off",
        .on: "On",
        .off: "Off",
    ]
}
