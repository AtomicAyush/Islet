import AppIntents
import Foundation

/// Start Pomodoro, the Shortcuts action: what the home tile's Start does. A session
/// already under way carries on, resuming if paused.
///
/// It runs inside Islet, in the background, as Keep Mac Awake does, and Shortcuts
/// launches Islet first if it is not running. A session lasts only while Islet runs, so
/// a shortcut that quits Islet afterwards ends it.
struct StartPomodoroIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Pomodoro"
    static let description = IntentDescription(
        "Starts a focus session, with the time left beside the notch, then a break; or carries on with one under way.",
        categoryName: "Pomodoro"
    )
    static let openAppWhenRun = false

    /// The feature that runs sessions. Tests hand in one of their own.
    @MainActor static var target: () -> PomodoroFeature? = { FeatureRegistry.shared.feature(PomodoroFeature.self) }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let feature = Self.target() else { throw PomodoroError.turnedOff }

        var outcome = feature.startSession()
        // Launched to run this, Islet may not have started its features yet; one that is
        // turned on is given a moment to.
        let deadline = ContinuousClock.now + .seconds(2)
        while outcome == .off, Self.isTurnedOn(feature), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            outcome = feature.startSession()
        }
        guard outcome == .on else { throw PomodoroError.turnedOff }
        return .result()
    }

    /// Whether Settings has the feature on, read straight from the defaults with the
    /// feature's own default for an unset key, since while Islet is starting that default
    /// may not be registered yet.
    @MainActor
    static func isTurnedOn(_ feature: PomodoroFeature) -> Bool {
        UserDefaults.standard.object(forKey: Prefs.Key.featureEnabled(feature.id)) as? Bool ?? feature.enabledByDefault
    }
}

/// Stop Pomodoro: ends the session under way, whatever its phase. Today's count stays.
struct StopPomodoroIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Pomodoro"
    static let description = IntentDescription(
        "Ends the Pomodoro session under way. It does nothing if none is.",
        categoryName: "Pomodoro"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        StartPomodoroIntent.target()?.stopSession()
        return .result()
    }
}

/// Why Start Pomodoro did not start one, in words Shortcuts shows the person.
enum PomodoroError: Error, CustomLocalizedStringResourceConvertible {
    case turnedOff

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .turnedOff: "Pomodoro is turned off in Islet's Settings."
        }
    }
}
