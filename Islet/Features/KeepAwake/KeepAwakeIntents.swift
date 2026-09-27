import AppIntents
import Foundation

/// Keep Mac Awake, the Shortcuts action: what the home tile's buttons do, for a length
/// chosen in the action.
///
/// It runs inside Islet, in the background, as Show in Islet does, and Shortcuts
/// launches Islet first if it is not running. Islet keeps the Mac awake only while it
/// runs, so a shortcut that quits Islet afterwards ends the session with it.
struct KeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Keep Mac Awake"
    static let description = IntentDescription(
        "Keeps the Mac from sleeping for a while, or until turned off, with the time left beside the notch.",
        categoryName: "Keep Awake"
    )
    static let openAppWhenRun = false

    @Parameter(title: "How Long", default: .oneHour)
    var length: KeepAwakeLength

    static var parameterSummary: some ParameterSummary {
        Summary("Keep Mac awake \(\.$length)")
    }

    /// The feature that keeps the Mac awake. Tests hand in one of their own.
    @MainActor static var target: () -> KeepAwakeFeature? = { FeatureRegistry.shared.feature(KeepAwakeFeature.self) }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let feature = Self.target() else { throw KeepAwakeError.turnedOff }

        var outcome = feature.keepAwake(for: length.seconds)
        // Launched to run this, Islet may not have started its features yet; one that is
        // turned on is given a moment to.
        let deadline = ContinuousClock.now + .seconds(2)
        while outcome == .off, Self.isTurnedOn(feature), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            outcome = feature.keepAwake(for: length.seconds)
        }
        switch outcome {
        case .on: return .result()
        case .off: throw KeepAwakeError.turnedOff
        case .refused: throw KeepAwakeError.refused
        }
    }

    /// Whether Settings has the feature on, read straight from the defaults with the
    /// feature's own default for an unset key, since while Islet is starting that default
    /// may not be registered yet.
    @MainActor
    static func isTurnedOn(_ feature: KeepAwakeFeature) -> Bool {
        UserDefaults.standard.object(forKey: Prefs.Key.featureEnabled(feature.id)) as? Bool ?? feature.enabledByDefault
    }
}

/// Stop Keeping Mac Awake: ends what Keep Awake started, however it was started. Other
/// apps keeping the Mac awake are theirs to stop.
struct StopKeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Keeping Mac Awake"
    static let description = IntentDescription(
        "Lets the Mac sleep as usual again, ending what Keep Awake started. It does nothing if Keep Awake is not on.",
        categoryName: "Keep Awake"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        KeepAwakeIntent.target()?.letSleep()
        return .result()
    }
}

/// Why Keep Mac Awake did not keep it awake, in words Shortcuts shows the person.
enum KeepAwakeError: Error, CustomLocalizedStringResourceConvertible {
    case turnedOff
    case refused

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .turnedOff: "Keep Awake is turned off in Islet's Settings."
        case .refused: "macOS did not let Islet keep the Mac awake."
        }
    }
}

extension KeepAwakeLength: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Length"
    static let caseDisplayRepresentations: [KeepAwakeLength: DisplayRepresentation] = [
        .fifteenMinutes: "For 15 Minutes",
        .oneHour: "For 1 Hour",
        .twoHours: "For 2 Hours",
        .untilTurnedOff: "Until Turned Off",
    ]
}
