import AppIntents
import Foundation

/// Mute Microphone, the Shortcuts action: mutes, unmutes or toggles the Mac's
/// microphone for every app, as the home tile does. A shortcut made of it can be given
/// a key in Shortcuts, which is how the mute gets a keyboard shortcut of its own.
///
/// It runs inside Islet, in the background, and the island says what it did, as for
/// `islet://micMute/…`. Shortcuts launches Islet first if it is not running.
struct MuteMicrophoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute Microphone"
    static let description = IntentDescription(
        "Mutes or unmutes the Mac's microphone for every app, with a red mark beside the notch while it is muted.",
        categoryName: "Microphone"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Action", default: .toggle)
    var action: MicMuteAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) the microphone")
    }

    /// The feature that does it. Tests hand in one of their own.
    @MainActor static var target: () -> MicMuteFeature? = { FeatureRegistry.shared.feature(MicMuteFeature.self) }

    /// Returns whether the microphone is muted afterwards.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let feature = Self.target() else { throw MuteMicrophoneError.turnedOff }

        var event = await feature.perform(action)
        // Launched to run this, Islet may not have started its features yet; one that is
        // turned on is given a moment to.
        let deadline = ContinuousClock.now + .seconds(2)
        while event == nil, Self.isTurnedOn(feature), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            event = await feature.perform(action)
        }
        switch event {
        case nil:
            throw MuteMicrophoneError.turnedOff
        case .cannotMute(let name):
            throw MuteMicrophoneError.cannotMute(name)
        case .muted:
            return .result(value: true)
        case .unmuted, .unmutedElsewhere:
            return .result(value: false)
        }
    }

    /// Whether Settings has the feature on, read straight from the defaults with the
    /// feature's own default for an unset key, since while Islet is starting that default
    /// may not be registered yet.
    @MainActor
    private static func isTurnedOn(_ feature: MicMuteFeature) -> Bool {
        UserDefaults.standard.object(forKey: Prefs.Key.featureEnabled(feature.id)) as? Bool ?? feature.enabledByDefault
    }
}

/// Why Mute Microphone did not do it, in words Shortcuts shows the person.
enum MuteMicrophoneError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case turnedOff
    case cannotMute(String?)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .turnedOff: "Mic Mute is turned off in Islet's Settings."
        case .cannotMute(let name?): "\(name) has no mute that Islet can use."
        case .cannotMute(nil): "This microphone has no mute that Islet can use."
        }
    }
}

extension MicMuteAction: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Action"
    static let caseDisplayRepresentations: [MicMuteAction: DisplayRepresentation] = [
        .toggle: "Toggle",
        .mute: "Mute",
        .unmute: "Unmute",
    ]
}
