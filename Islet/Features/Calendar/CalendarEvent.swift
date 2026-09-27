import AppKit
import EventKit
import SwiftUI

/// One occurrence of a calendar event, copied out of EventKit so it can cross threads
/// and be compared cheaply. `EKEvent`s go stale whenever the store changes; these don't.
struct CalendarEvent: Identifiable, Equatable, Sendable {
    /// Unique per occurrence: every occurrence of a repeating event shares an event
    /// identifier, so the start is folded in.
    let id: String
    /// EventKit's identifier, for opening the event in Calendar.
    let eventIdentifier: String?
    /// The date this occurrence was scheduled for, when it belongs to a series.
    /// Calendar needs it to open the right occurrence.
    let occurrence: Date?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    /// The calendar's colour, lifted if it is too dark to read on black.
    let color: Color
    let meeting: MeetingLink?

    /// When the island lets go of the event: five minutes in, or its end if sooner. A
    /// call whose Join button is still up is kept on for it (`CalendarTiming.shown`).
    var activityEnd: Date { min(start.addingTimeInterval(5 * 60), end) }

    /// Where the event is, for display. A location that is only the meeting's link
    /// reads better as the service's name.
    var place: String? {
        if let location, !location.contains("://") { return location }
        return meeting?.service.name ?? location
    }
}

extension CalendarEvent {
    /// Copies an event out of EventKit, or `nil` if it has no dates (it always should).
    init?(_ event: EKEvent, detector: NSDataDetector?) {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let identifier = event.eventIdentifier
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = event.location?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        self.init(
            id: "\(identifier ?? event.calendarItemIdentifier)@\(start.timeIntervalSinceReferenceDate)",
            eventIdentifier: identifier,
            occurrence: event.hasRecurrenceRules || event.isDetached ? event.occurrenceDate : nil,
            title: title.isEmpty ? "Untitled" : title,
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            location: location?.isEmpty == false ? location : nil,
            color: Self.readableColor(event.calendar?.cgColor),
            meeting: MeetingLink.find(url: event.url, in: [event.location, event.notes], detector: detector)
        )
    }

    /// The same hue, brightened just enough to stand out on the island's black.
    private static func readableColor(_ cgColor: CGColor?) -> Color {
        guard let cgColor, let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
            return CalendarPalette.blue
        }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: saturation, brightness: max(brightness, 0.7))
    }
}

/// Reads events on a background thread. EventKit's store is safe to read from any
/// thread, and a day of events with their notes is too much work for the main one.
final class CalendarEventSource: @unchecked Sendable {
    let store = EKEventStore()
    private let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// Wake, the clock and a due boundary often ask for a fetch at the same moment;
    /// they take turns rather than walking the same store in parallel.
    private let lock = NSLock()

    /// Every event overlapping the range in every calendar, soonest first, without
    /// the ones the user declined or that were cancelled.
    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        lock.withLock {
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            return store.events(matching: predicate)
                .filter { event in
                    event.status != .canceled
                        && !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
                }
                .compactMap { CalendarEvent($0, detector: detector) }
                .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        }
    }
}

/// Getting the user to Calendar, or to the switch that lets Islet read it.
@MainActor
enum CalendarApp {
    /// Opens Calendar on the event, or just brings Calendar forward when the event
    /// can't be addressed (it has no identifier yet, or is a preview sample).
    static func show(_ event: CalendarEvent) {
        if let url = url(for: event), NSWorkspace.shared.open(url) { return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// What opens meeting links. Tests hand in one that only writes them down.
    static var opener: any MeetingOpener = WorkspaceMeetingOpener()

    /// Opens the meeting in its service's app where that is installed, else in the
    /// browser.
    static func join(_ meeting: MeetingLink) {
        opener.open(meeting.launchURL(hasApp: opener.hasApp(for:)))
    }

    /// `ical://ekevent/<id>`, with the occurrence's date in front of the identifier
    /// for a repeating event, or Calendar opens the series' first occurrence.
    private static func url(for event: CalendarEvent) -> URL? {
        guard let identifier = event.eventIdentifier else { return nil }
        var components = URLComponents()
        components.scheme = "ical"
        components.host = "ekevent"
        if let occurrence = event.occurrence {
            occurrenceFormat.timeZone = event.isAllDay ? .current : TimeZone(identifier: "UTC")
            components.path = "/\(occurrenceFormat.string(from: occurrence))/\(identifier)"
        } else {
            components.path = "/\(identifier)"
        }
        components.queryItems = [
            URLQueryItem(name: "method", value: "show"),
            URLQueryItem(name: "options", value: "more"),
        ]
        return components.url
    }

    private static let occurrenceFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()
}

/// The iPhone's dark-mode system colours, which the island's content uses throughout.
enum CalendarPalette {
    static let red = Color(red: 1, green: 0.271, blue: 0.227)
    static let orange = Color(red: 1, green: 0.624, blue: 0.039)
    static let green = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let blue = Color(red: 0.039, green: 0.518, blue: 1)
    static let purple = Color(red: 0.749, green: 0.353, blue: 0.949)
}
