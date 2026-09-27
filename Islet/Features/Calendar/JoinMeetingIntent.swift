import AppIntents
import Foundation

/// Join Meeting, the Shortcuts action: joins the video call under way or coming up in
/// the next few minutes, as `islet://calendar/join` does, in the service's app where it
/// is installed. A shortcut made of it can be given a key in Shortcuts.
///
/// It runs inside Islet, in the background. Shortcuts launches Islet first if it is not
/// running.
struct JoinMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Join Meeting"
    static let description = IntentDescription(
        "Joins the video call that is under way or about to start on your calendar, in Zoom or Teams where they are installed.",
        categoryName: "Calendar"
    )
    static let openAppWhenRun = false

    /// The feature that does it. Tests hand in one of their own.
    @MainActor static var target: () -> CalendarFeature? = { FeatureRegistry.shared.feature(CalendarFeature.self) }

    /// Returns the meeting's title.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let feature = Self.target() else { throw JoinMeetingError.turnedOff }

        // Launched to run this, Islet may not have read the calendar yet; a feature that
        // is turned on is given a moment to.
        let deadline = ContinuousClock.now + .seconds(2)
        while !feature.hasReadCalendar, Self.isTurnedOn(feature), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard Self.isTurnedOn(feature) else { throw JoinMeetingError.turnedOff }
        guard let event = feature.joinMeeting() else {
            guard feature.model.access == .granted else { throw JoinMeetingError.noAccess }
            if let next = feature.model.nextMeeting() { throw JoinMeetingError.notYet(Self.when(next.start)) }
            throw JoinMeetingError.noMeeting
        }
        return .result(value: event.title)
    }

    /// "9:30", or "tomorrow at 9:30": the calendar is read a day ahead.
    private static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return time }
        if Calendar.current.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Whether Settings has the feature on, read straight from the defaults with the
    /// feature's own default for an unset key, since while Islet is starting that default
    /// may not be registered yet.
    @MainActor
    private static func isTurnedOn(_ feature: CalendarFeature) -> Bool {
        UserDefaults.standard.object(forKey: Prefs.Key.featureEnabled(feature.id)) as? Bool ?? feature.enabledByDefault
    }
}

/// Why Join Meeting did not do it, in words Shortcuts shows the person.
enum JoinMeetingError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case turnedOff
    case noAccess
    case noMeeting
    /// The next call is too far off to join yet; when it starts, in words.
    case notYet(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .turnedOff: "Calendar is turned off in Islet's Settings."
        case .noAccess: "Islet can't read your calendar. Allow it in Islet's Settings."
        case .noMeeting: "There's no meeting with a link to join, under way or coming up."
        case .notYet(let when): "Your next call isn't until \(when)."
        }
    }
}
