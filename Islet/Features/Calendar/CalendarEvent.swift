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
    /// The calendar's colour, as chosen. It is the person's colour, so the island only
    /// fits it for contrast and never swaps it for the accent; on the black island it is
    /// lifted first if it is too dark to make out on black (`shown(_:in:)`). `nil` for a
    /// calendar without one, which is drawn in the accent (`ink(minimum:on:)`).
    let color: RGB?
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
            color: Self.ownColor(event.calendar?.cgColor),
            meeting: MeetingLink.find(url: event.url, in: [event.location, event.notes], detector: detector)
        )
    }

    /// The calendar's colour in sRGB; `nil` for none.
    private static func ownColor(_ cgColor: CGColor?) -> RGB? {
        guard let cgColor, let color = NSColor(cgColor: cgColor) else { return nil }
        return RGB(color)
    }

    /// The calendar's colour as `theme`'s island starts from it. On the black island,
    /// the same hue brightened just enough to stand out on black, as the island always
    /// drew it; on any other island the colour as chosen, which a light island keeps
    /// darker and so clearer. Either way it is then only fitted for contrast.
    static func shown(_ colour: RGB, in theme: IslandTheme) -> RGB {
        guard theme.isBlack else { return colour }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        colour.nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard brightness < 0.7 else { return colour }
        return rgb(hue: Double(hue), saturation: Double(saturation), brightness: 0.7)
    }

    /// A colour from hue (0..<1), saturation and brightness, as `Color(hue:saturation:brightness:)`
    /// gives it.
    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> RGB {
        let sector = (hue - hue.rounded(.down)) * 6
        let f = sector - sector.rounded(.down)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch Int(sector) % 6 {
        case 0: return RGB(brightness, t, p)
        case 1: return RGB(q, brightness, p)
        case 2: return RGB(p, brightness, t)
        case 3: return RGB(p, q, brightness)
        case 4: return RGB(t, p, brightness)
        default: return RGB(brightness, p, q)
        }
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

/// Calendar colours: the iPhone's dark-mode system colours, for the samples. They are
/// drawn as the person's colours are.
enum CalendarPalette {
    static let orange = RGB(1, 0.624, 0.039)
    static let green = RGB(0.188, 0.820, 0.345)
    static let blue = RGB(0.039, 0.518, 1)
    static let purple = RGB(0.749, 0.353, 0.949)
}

extension FeatureTint {
    /// "Up next" over the home tile's list: the Calendar app's red.
    static let calendarHeader = FeatureTint.colour(RGB(1, 0.271, 0.227))
    /// The Join button: the green of a call's answer button.
    static let calendarJoin = FeatureTint.colour(RGB(0.188, 0.820, 0.345))
    /// An event whose calendar has no colour: nobody chose one, so it is a highlight
    /// like any other, Calendar's own blue under Feature colours and otherwise the
    /// accent.
    static let calendarEvent = FeatureTint.colour(CalendarPalette.blue)
}

extension CalendarEvent {
    /// The event's colour on the island: its calendar's, only fitted for contrast, or,
    /// for a calendar without one, the accent. `Contrast.text` for words.
    func ink(minimum: Double = Contrast.graphic, on backdrop: IslandBackdrop = .island) -> CalendarEventInk {
        CalendarEventInk(colour: color, minimum: minimum, backdrop: backdrop)
    }
}

/// An event's colour as a shape style, worked out for the island's colour in the
/// environment (`CalendarEvent.shown(_:in:)`).
struct CalendarEventInk: ShapeStyle, Hashable, Sendable {
    let colour: RGB?
    let minimum: Double
    let backdrop: IslandBackdrop

    func ink(in theme: IslandTheme) -> IslandInk {
        guard let colour else { return .accent(.calendarEvent, minimum: minimum, on: backdrop) }
        return .fitted(CalendarEvent.shown(colour, in: theme), minimum: minimum, on: backdrop)
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        IslandStyle(ink: ink(in: environment.islandTheme)).resolve(in: environment)
    }
}
