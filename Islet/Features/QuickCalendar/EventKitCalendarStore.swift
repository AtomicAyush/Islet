import AppKit
import EventKit

extension QuickCalendarFeature {
    /// Quick Calendar on the person's own calendars. Made here, beside the store, so a
    /// build that leaves this file out has no way to write to a real calendar.
    convenience init() {
        self.init(model: QuickCalendarModel(store: EventKitCalendarStore()))
    }
}

/// The person's calendars, through EventKit: the only code in Islet that writes to a
/// calendar. It adds the one event typed, to the calendar chosen, takes it away again on
/// Undo if it is unchanged, and sets a place asked for later; it never touches any
/// other event. Tests never make one (their harness leaves this file out).
@MainActor
final class EventKitCalendarStore: CalendarStore {
    var changed: () -> Void = {}

    /// A store made before access was granted can go on seeing no calendars, so each
    /// grant gets a fresh one.
    private var store = EKEventStore()
    private var storeObserver: NSObjectProtocol?
    private let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    init() {
        observe()
    }

    var access: CalendarAccess {
        CalendarAccess(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async -> CalendarAccess {
        guard access == .undetermined else { return access }
        _ = try? await store.requestFullAccessToEvents()
        if access == .granted {
            store = EKEventStore()
            observe()
        }
        changed()
        return access
    }

    func writableCalendars() -> [CalendarChoice] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event)
            .filter { $0.allowsContentModifications && $0.type != .birthday }
            .map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title, colour: Self.colour($0)) }
    }

    func eventCalendars() -> [CalendarChoice] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event)
            .filter { $0.type != .birthday }
            .map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title, colour: Self.colour($0)) }
    }

    var defaultCalendarID: String? {
        guard access == .granted else { return nil }
        return store.defaultCalendarForNewEvents?.calendarIdentifier
    }

    func events(from start: Date, to end: Date) -> [DayEvent] {
        guard access == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { event in
                event.status != .canceled && event.calendar?.type != .birthday
                    && !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
            }
            .compactMap(dayEvent)
            .sorted { $0.start < $1.start }
    }

    func add(_ draft: EventDraft) throws -> AddedEvent {
        guard access == .granted else { throw CalendarStoreError.noAccess }
        // The calendar chosen, or the default when none was: never the default in place of
        // one that has gone.
        let calendar = draft.calendarID.map(store.calendar(withIdentifier:)) ?? store.defaultCalendarForNewEvents
        guard let calendar, calendar.allowsContentModifications else { throw CalendarStoreError.noCalendar }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.isAllDay = draft.isAllDay
        event.startDate = draft.start
        // An all-day event is its day; EventKit takes the same date as its end.
        event.endDate = draft.isAllDay ? draft.start : draft.end
        event.location = draft.location
        event.notes = draft.notes
        event.url = draft.url
        try store.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier else { throw CalendarStoreError.notFound }
        return AddedEvent(
            id: id, externalID: event.calendarItemExternalIdentifier, start: event.startDate,
            lastModified: event.lastModifiedDate, calendarTitle: calendar.title
        )
    }

    func event(id: String, externalID: String?, start: Date) -> DayEvent? {
        guard access == .granted else { return nil }
        if let event = store.event(withIdentifier: id) { return dayEvent(event) }
        guard let externalID else { return nil }
        let items = store.calendarItems(withExternalIdentifier: externalID).compactMap { $0 as? EKEvent }
        return (items.first { $0.startDate == start } ?? items.first).flatMap(dayEvent)
    }

    func update(id: String, location: String?, notes: String?) throws {
        guard access == .granted else { throw CalendarStoreError.noAccess }
        guard let event = store.event(withIdentifier: id) else { throw CalendarStoreError.notFound }
        if let location { event.location = location }
        if let notes { event.notes = notes }
        try store.save(event, span: .thisEvent, commit: true)
    }

    func removeIfUnchanged(_ added: AddedEvent) throws -> Bool {
        guard access == .granted, let event = store.event(withIdentifier: added.id) else { return false }
        guard event.startDate == added.start, event.lastModifiedDate == added.lastModified else { return false }
        try store.remove(event, span: .thisEvent, commit: true)
        return true
    }

    // MARK: Reading

    private func observe() {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    private func dayEvent(_ event: EKEvent) -> DayEvent? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let location = event.location?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let meeting = MeetingLink.find(url: event.url, in: [event.location, event.notes], detector: detector)
        return DayEvent(
            id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)@\(start.timeIntervalSinceReferenceDate)",
            eventID: event.eventIdentifier,
            externalID: event.calendarItemExternalIdentifier,
            title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            location: location?.isEmpty == false ? location : nil,
            isOnline: meeting != nil,
            isFree: event.availability == .free,
            calendarID: event.calendar?.calendarIdentifier,
            lastModified: event.lastModifiedDate
        )
    }

    /// The calendar's own colour in sRGB, as data for the calendar menu; `nil` for none.
    private static func colour(_ calendar: EKCalendar) -> RGB? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let own = calendar.cgColor?.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let parts = own.components, parts.count >= 3 else { return nil }
        let clamped = parts.prefix(3).map { min(max(Double($0), 0), 1) }
        return RGB(clamped[0], clamped[1], clamped[2])
    }
}
