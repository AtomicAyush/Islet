import Foundation

/// The person's calendars, as Quick Calendar reads and writes them. The real one is
/// EventKit's (`EventKitCalendarStore`), and it is the only code in Islet that writes to
/// a calendar; tests hand in one of their own, so nothing is ever written to a real
/// calendar (which would sync to the person's other devices) while Islet is tested.
///
/// Quick Calendar writes only when the person asks: Add pressed on an event they typed,
/// Undo straight after it, or Add on a follow-up's place.
@MainActor
protocol CalendarStore: AnyObject {
    var access: CalendarAccess { get }
    /// Asks for full access to events. Only ever from a click.
    func requestAccess() async -> CalendarAccess
    /// The calendars an event can be added to, in the order Calendar lists them.
    func writableCalendars() -> [CalendarChoice]
    /// Every calendar with events but birthdays, the ones that can't be added to among
    /// them: for choosing which are checked for clashes.
    func eventCalendars() -> [CalendarChoice]
    /// The calendar new events go to unless another is chosen: the person's own default.
    var defaultCalendarID: String? { get }
    /// The events overlapping the range, soonest first, without the ones the person
    /// declined or that were cancelled, and without birthdays.
    func events(from start: Date, to end: Date) -> [DayEvent]
    /// Adds the event, and nothing else.
    func add(_ draft: EventDraft) throws -> AddedEvent
    /// An event added before, looked up by its identifier, or by its identifier on the
    /// server and its start should the first have changed as it synced.
    func event(id: String, externalID: String?, start: Date) -> DayEvent?
    /// Sets the event's place, or its notes, and nothing else of it.
    func update(id: String, location: String?, notes: String?) throws
    /// Takes away an event just added, only if it is as it was added: returns false,
    /// leaving it be, if it is gone or has been changed since.
    func removeIfUnchanged(_ added: AddedEvent) throws -> Bool
    /// Told whenever the calendars change, here or on another device.
    var changed: () -> Void { get set }
}

/// A calendar events can be added to.
struct CalendarChoice: Identifiable, Equatable {
    let id: String
    let title: String
    /// The calendar's own colour; `nil` for none.
    let colour: RGB?
}

/// One occurrence of an event, as Quick Calendar needs it: for clashes and the free
/// time between them, and to check on an event before asking for its place.
struct DayEvent: Identifiable, Equatable {
    /// Unique per occurrence.
    let id: String
    /// EventKit's identifier for the event.
    let eventID: String?
    /// The event's identifier on the calendar's server, which survives a sync.
    let externalID: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    /// It has a video call to join, in its link, place or notes.
    let isOnline: Bool
    /// Shown as free rather than busy: it blocks nothing.
    let isFree: Bool
    let calendarID: String?
    var lastModified: Date? = nil
}

/// An event as typed, to be added.
struct EventDraft: Equatable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var url: URL?
    /// `nil` for the person's default calendar.
    var calendarID: String?
}

/// An event just added: enough to undo it, or to find it again to ask for its place.
struct AddedEvent: Equatable {
    let id: String
    let externalID: String?
    let start: Date
    let lastModified: Date?
    /// The calendar it went to, by name, for "Added to Work".
    let calendarTitle: String
}

enum CalendarStoreError: Error {
    /// No calendar to add to: none is writable, or the one chosen has gone.
    case noCalendar
    /// Access is not granted.
    case noAccess
    case notFound
}
