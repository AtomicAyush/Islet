import AppKit
import SwiftUI
import Observation

/// What Quick Calendar shares between the box, the follow-ups and Settings: the store,
/// the calendars there are to add to, and the settings. Nothing typed is kept here.
@MainActor
@Observable
final class QuickCalendarModel {
    @ObservationIgnored let store: any CalendarStore
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let followUps: QuickCalendarFollowUps
    @ObservationIgnored let clashes: QuickCalendarClashes
    /// Told as the days read change, or the day the Day page shows.
    @ObservationIgnored var daysChanged: () -> Void = {}
    /// The moment, the calendar and the locale events are read in. Tests fix them.
    @ObservationIgnored var now: () -> Date
    @ObservationIgnored var calendar: Calendar = .autoupdatingCurrent
    @ObservationIgnored var locale: Locale = .autoupdatingCurrent
    /// Told after each write, so the Calendar tile shows it at once.
    @ObservationIgnored var didWrite: () -> Void = {
        FeatureRegistry.shared.feature(CalendarFeature.self)?.model.refresh()
    }
    private(set) var access: CalendarAccess
    private(set) var calendars: [CalendarChoice] = []
    private(set) var defaultCalendarID: String?
    /// Every calendar with events, the ones that can't be added to among them: those
    /// Settings' Calendars to check lists.
    private(set) var eventCalendars: [CalendarChoice] = []
    /// Today's and tomorrow's events in the calendars checked, as last read: what the
    /// Today tile, the Day page and clashes are worked out from.
    private(set) var upcoming: (range: DateInterval, events: [DayEvent])?
    /// The day the Day page shows. Memory only.
    var dayShown = QuickDay.today {
        didSet { if dayShown != oldValue { daysChanged() } }
    }

    /// The store is handed in: the person's own is made only where the feature is
    /// (`EventKitCalendarStore.swift`), which test builds leave out.
    init(
        store: any CalendarStore,
        defaults: UserDefaults = .standard,
        clock: (any KeepAwakeClock)? = nil,
        presenter: (any FollowUpPresenter)? = nil,
        clashPresenter: (any ClashPresenter)? = nil
    ) {
        let clock = clock ?? WallClock()
        self.store = store
        self.defaults = defaults
        now = { [clock] in clock.now }
        access = store.access
        uncheckedCalendars = Set(defaults.stringArray(forKey: QuickCalendarFeature.Key.unchecked) ?? [])
        followUps = QuickCalendarFollowUps(
            store: store, defaults: defaults, clock: clock, presenter: presenter ?? IslandFollowUpPresenter()
        )
        clashes = QuickCalendarClashes(clock: clock, presenter: clashPresenter ?? IslandClashPresenter())
        followUps.didWrite = { [weak self] in self?.didWrite() }
        clashes.model = self
    }

    /// Re-reads access, which can change in System Settings at any time, and the
    /// calendars there are to add to.
    func refresh() {
        let current = store.access
        if current != access { access = current }
        let writable = store.writableCalendars()
        if writable != calendars { calendars = writable }
        let fallback = store.defaultCalendarID
        if fallback != defaultCalendarID { defaultCalendarID = fallback }
        let all = store.eventCalendars()
        if all != eventCalendars { eventCalendars = all }
        readDays()
    }

    /// Reads today's and tomorrow's events again.
    func readDays() {
        let today = calendar.startOfDay(for: now())
        guard let end = calendar.date(byAdding: .day, value: 2, to: today) else { return }
        let range = DateInterval(start: today, end: end)
        let events = access == .granted ? checked(store.events(from: range.start, to: range.end)) : []
        guard upcoming?.range != range || upcoming?.events != events else { return }
        upcoming = (range, events)
        daysChanged()
    }

    /// Only ever from a click.
    func requestAccess() {
        Task {
            _ = await store.requestAccess()
            refresh()
        }
    }

    // MARK: Settings

    /// The calendar Settings adds to; `nil` for the person's default.
    var chosenCalendarID: String? {
        let id = defaults.string(forKey: QuickCalendarFeature.Key.calendar) ?? ""
        return id.isEmpty ? nil : id
    }

    var defaultMinutes: Int {
        let minutes = defaults.integer(forKey: QuickCalendarFeature.Key.length)
        return QuickCalendarFeature.lengthChoices.contains(minutes) ? minutes : QuickCalendarFeature.defaultLength
    }

    var asksForDetails: Bool {
        defaults.object(forKey: QuickCalendarFeature.Key.askDetails) as? Bool ?? true
    }

    var askAfter: TimeInterval {
        let hours = defaults.integer(forKey: QuickCalendarFeature.Key.askAfter)
        return TimeInterval((QuickCalendarFeature.askAfterChoices.contains(hours) ? hours : QuickCalendarFeature.defaultAskAfter) * 3600)
    }

    var travel: TimeInterval {
        guard let minutes = defaults.object(forKey: QuickCalendarFeature.Key.travel) as? Int,
              QuickCalendarFeature.travelChoices.contains(minutes) else {
            return TimeInterval(QuickCalendarFeature.defaultTravel * 60)
        }
        return TimeInterval(minutes * 60)
    }

    /// The start and end of the person's day, in minutes after midnight.
    var dayFrom: Int {
        let minutes = defaults.object(forKey: QuickCalendarFeature.Key.dayFrom) as? Int ?? QuickCalendarFeature.defaultDayFrom
        return min(max(minutes, 0), 23 * 60)
    }

    var dayTo: Int {
        let minutes = defaults.object(forKey: QuickCalendarFeature.Key.dayTo) as? Int ?? QuickCalendarFeature.defaultDayTo
        return min(max(minutes, dayFrom + 60), 24 * 60)
    }

    /// The calendars left out of clashes and free time.
    private(set) var uncheckedCalendars: Set<String> = []

    func setChecked(_ checked: Bool, calendarID: String) {
        var unchecked = uncheckedCalendars
        if checked { unchecked.remove(calendarID) } else { unchecked.insert(calendarID) }
        uncheckedCalendars = unchecked
        defaults.set(unchecked.sorted(), forKey: QuickCalendarFeature.Key.unchecked)
        readDays()
        (InputCenter.shared.box.session as? QuickAddSession)?.calendarChanged()
    }

    var tellsClashes: Bool {
        defaults.object(forKey: QuickCalendarFeature.Key.tellClashes) as? Bool ?? true
    }

    /// The events of calendars checked (Settings' Calendars to check): an event of one
    /// left out keeps no one busy.
    private func checked(_ events: [DayEvent]) -> [DayEvent] {
        let unchecked = uncheckedCalendars
        guard !unchecked.isEmpty else { return events }
        return events.filter { $0.calendarID.map { !unchecked.contains($0) } ?? true }
    }

    func parser() -> EventParser {
        EventParser(now: now(), calendar: calendar, locale: locale, defaultMinutes: defaultMinutes)
    }

    func calendarTitle(_ id: String?) -> String? {
        let id = id ?? defaultCalendarID
        return calendars.first { $0.id == id }?.title
    }

    // MARK: Writing

    /// Adds the event, the only way the box writes, and, if it has no place and isn't
    /// online, asks for its place later (`QuickCalendarFollowUps`).
    func add(_ draft: EventDraft) throws -> AddedEvent {
        let added = try store.add(draft)
        // Its clashes were shown as it was typed.
        clashes.hush(added)
        didWrite()
        let hasPlace = !(draft.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isOnline = draft.url.flatMap { MeetingLink.find(url: $0, in: [draft.notes], detector: nil) } != nil
            || MeetingLink.find(url: nil, in: [draft.notes], detector: Self.links) != nil
        if asksForDetails, !hasPlace, !isOnline, !draft.isAllDay {
            followUps.add(added, created: now(), delay: askAfter)
        }
        return added
    }

    /// Takes away an event just added, if it is unchanged, and the follow-up for it.
    func undo(_ added: AddedEvent) -> Bool {
        guard (try? store.removeIfUnchanged(added)) == true else { return false }
        followUps.remove(id: added.id)
        didWrite()
        return true
    }

    /// The events on `day`'s calendar day, in the calendars checked: from what was read
    /// for today and tomorrow, or read now for another day.
    func events(on day: Date) -> [DayEvent] {
        let start = calendar.startOfDay(for: day)
        guard access == .granted, let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        if let upcoming, upcoming.range.start <= start, end <= upcoming.range.end {
            return upcoming.events.filter { $0.end > start && $0.start < end }
        }
        return checked(store.events(from: start, to: end))
    }

    // MARK: Days

    /// `day`'s free time and clashes as they stand at `now`: today's from now on, within
    /// the person's day.
    func plan(_ day: QuickDay, at now: Date) -> DayPlan {
        let today = calendar.startOfDay(for: now)
        let start = day == .today ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let window = DayPlan.window(for: start, now: now, calendar: calendar, from: dayFrom, to: dayTo)
        return DayPlan.make(events: events(on: start), window: window, travel: travel, now: now)
    }

    private static let links = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

/// The box in Event mode, while it is open: the event read from the draft, the choices
/// made in its preview, and what was just added. Memory only; closing the box forgets
/// it. Nothing is written until Add (or ⌘Return, or Return in Notes), and then only the
/// event shown.
@MainActor
@Observable
final class QuickAddSession: InputSession {
    enum Outcome: Equatable {
        /// Added to the calendar named: Undo is offered for a while.
        case added(AddedEvent)
        case removed(String)
        /// Undo found the event changed since.
        case changedSince
        case failed(String)
    }

    let model: QuickCalendarModel
    private(set) var parsed = ParsedEvent()
    private(set) var draft = ""
    /// Choices made in the preview, over what was typed: a day's start, minutes into the
    /// day, a length in minutes, all day or not.
    var dayChoice: Date? { didSet { refreshClashes() } }
    var timeChoice: Int? { didSet { refreshClashes() } }
    var lengthChoice: Int? { didSet { refreshClashes() } }
    var allDayChoice: Bool? { didSet { refreshClashes() } }
    var location = "" {
        didSet {
            if location != (parsed.location ?? "") { locationEdited = true }
            refreshClashes()
        }
    }
    var notes = ""
    /// The calendar chosen in the box, for this box only.
    var calendarID: String?
    private(set) var outcome: Outcome?
    private(set) var clashes: [Clash] = []
    /// Goes up when Return asks for the caret in Location.
    private(set) var locationFocus = 0
    /// How long Undo is offered. Tests shorten it.
    @ObservationIgnored var undoFor: TimeInterval = 8
    /// The place was typed or changed in its blank, rather than read from the draft.
    private(set) var locationEdited = false
    @ObservationIgnored private weak var box: InputBox?
    @ObservationIgnored private var outcomeWork: Task<Void, Never>?
    @ObservationIgnored private var dayEvents: (day: Date, events: [DayEvent])?

    init(model: QuickCalendarModel) {
        self.model = model
    }

    static let candidateID = "quickcalendar.typed"

    // MARK: The event

    /// The event as it would be added, or `nil` while there is no title or no when.
    var event: EventDraft? {
        let title = parsed.title
        guard !title.isEmpty, let when else { return nil }
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return EventDraft(
            title: title, start: when.start, end: when.end, isAllDay: when.isAllDay,
            location: place.isEmpty ? nil : place, notes: notes.isEmpty ? nil : notes,
            url: parsed.url, calendarID: calendarID ?? model.chosenCalendarID
        )
    }

    /// When, with the preview's choices over what was typed.
    var when: (start: Date, end: Date, isAllDay: Bool)? {
        let calendar = model.calendar
        let typedStart = parsed.start
        guard typedStart != nil || dayChoice != nil || timeChoice != nil else { return nil }
        let isAllDay = allDayChoice ?? (parsed.isAllDay && timeChoice == nil)
        let base = typedStart ?? calendar.startOfDay(for: model.now())
        let day = dayChoice ?? calendar.startOfDay(for: base)
        if isAllDay {
            let start = calendar.startOfDay(for: day)
            return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start, true)
        }
        let minutes: Int = timeChoice ?? {
            if let typedStart, !parsed.isAllDay {
                let parts = calendar.dateComponents([.hour, .minute], from: typedStart)
                return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
            return QuickAddSession.defaultStartMinutes
        }()
        // A time typed in another zone keeps its moment, unless the day or time is changed.
        let start: Date
        if let typedStart, dayChoice == nil, timeChoice == nil, !parsed.isAllDay {
            start = typedStart
        } else {
            start = calendar.date(minutes: minutes, into: day) ?? day
        }
        let length = lengthChoice ?? typedLength ?? model.defaultMinutes
        return (start, start.addingTimeInterval(TimeInterval(length * 60)), false)
    }

    /// An event given only a day, then a time, starts at nine.
    static let defaultStartMinutes = 9 * 60

    /// The length typed, in minutes.
    var typedLength: Int? {
        guard let start = parsed.start, let end = parsed.end, !parsed.isAllDay else { return nil }
        return Int(end.timeIntervalSince(start) / 60)
    }

    /// The place was read from "at …" in the draft, and is shown as a guess.
    var isLocationGuessed: Bool {
        parsed.flags.contains(.guessedLocation) && !locationEdited && !location.isEmpty
    }

    var canAdd: Bool {
        event != nil && model.access == .granted
    }

    // MARK: InputSession

    func attach(to box: InputBox) {
        self.box = box
    }

    func opened() {
        model.refresh()
    }

    func below() -> AnyView? {
        if model.access != .granted { return AnyView(QuickAddAccessRow(model: model)) }
        if draft.isEmpty {
            return outcome.map { _ in AnyView(QuickAddOutcomeRow(session: self)) }
        }
        return AnyView(QuickAddPreview(session: self))
    }

    func trailingChip() -> AnyView? {
        AnyView(QuickAddCalendarChip(session: self))
    }

    func draftChanged(_ draft: String) {
        self.draft = draft
        let next = model.parser().parse(draft)
        if next != parsed {
            parsed = next
            if !locationEdited {
                location = next.location ?? ""
                locationEdited = false
            }
        }
        if draft.isEmpty {
            resetChoices()
        } else if outcome != nil {
            outcome = nil
            outcomeWork?.cancel()
        }
        refreshClashes()
    }

    /// Return in the field: on to Location. It never adds; ⌘Return, Add or Return in Notes does.
    func submit(_ draft: String) -> Bool {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        locationFocus &+= 1
        return false
    }

    /// ⌘Return, or Add.
    func accept(_ draft: String) -> Bool {
        add()
    }

    func close() {
        outcomeWork?.cancel()
        outcomeWork = nil
        outcome = nil
        draft = ""
        parsed = ParsedEvent()
        resetChoices()
        dayEvents = nil
        box = nil
    }

    // MARK: Adding

    /// Adds the event shown, and nothing else, and offers Undo for a while.
    @discardableResult
    func add() -> Bool {
        guard canAdd, let event else { return false }
        do {
            let added = try model.add(event)
            show(.added(added))
            return true
        } catch CalendarStoreError.noCalendar {
            show(.failed("That calendar can't be added to — choose another"))
        } catch {
            show(.failed("Calendar didn't take it — try again"))
        }
        return false
    }

    /// The Add button, and Return in Notes: as ⌘Return, emptying the field for another event.
    func addFromButton() {
        if let box { box.key(.accept) } else { add() }
    }

    func undo() {
        guard case .added(let added) = outcome else { return }
        show(model.undo(added) ? .removed(added.calendarTitle) : .changedSince)
    }

    /// Cancel: nothing is added, and the box closes.
    func cancel() {
        box?.island?.endTyping(.close)
    }

    private func show(_ next: Outcome) {
        outcome = next
        outcomeWork?.cancel()
        let seconds = undoFor
        outcomeWork = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.outcome == next else { return }
            self.outcome = nil
        }
    }

    private func resetChoices() {
        dayChoice = nil
        timeChoice = nil
        lengthChoice = nil
        allDayChoice = nil
        notes = ""
        location = ""
        locationEdited = false
        calendarID = nil
    }

    // MARK: Clashes

    /// The typed event's clashes with the rest of its day.
    private func refreshClashes() {
        guard let event, !event.isAllDay, model.access == .granted else {
            if !clashes.isEmpty { clashes = [] }
            return
        }
        let day = model.calendar.startOfDay(for: event.start)
        if dayEvents?.day != day { dayEvents = (day, model.events(on: day)) }
        let candidate = DayEvent(
            id: Self.candidateID, eventID: nil, externalID: nil, title: event.title, start: event.start, end: event.end,
            isAllDay: false, location: event.location, isOnline: parsed.flags.contains(.online), isFree: false,
            calendarID: event.calendarID
        )
        let found = Clashes.involving(candidate, among: dayEvents?.events ?? [], travel: model.travel)
        if found != clashes { clashes = found }
    }

    /// The calendar changed: the day is read again.
    func calendarChanged() {
        dayEvents = nil
        refreshClashes()
    }
}
