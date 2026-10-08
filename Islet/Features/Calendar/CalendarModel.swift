import AppKit
import EventKit
import Observation

/// Whether Islet may read the user's calendars.
enum CalendarAccess: Equatable {
    case undetermined
    case granted
    /// Turned off in System Settings, or write-only, which can't read events.
    case denied
    /// Blocked by a device profile; only an administrator can change it.
    case restricted

    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .fullAccess: self = .granted
        case .notDetermined: self = .undetermined
        case .restricted: self = .restricted
        default: self = .denied
        }
    }
}

/// The day's events and which one is close enough to count down to, and the week's
/// for the home tile once today's are done.
///
/// Nothing polls. The model re-reads the calendar when EventKit says it changed, on
/// wake, as the day turns over, and every five minutes as a backstop, and otherwise
/// sleeps until the next moment something would change: an event coming into the
/// lead time, becoming imminent, starting, its Join button coming or going, or
/// letting go.
@MainActor
@Observable
final class CalendarModel {
    private(set) var access = CalendarAccess(EKEventStore.authorizationStatus(for: .event))
    /// Events from an hour ago to a day ahead, all-day ones included, soonest first.
    /// The island, joining and Shortcuts look no further than these.
    private(set) var events: [CalendarEvent] = []
    /// Events from an hour ago to the end of the week ahead, for the home tile's list,
    /// which turns to the next day with events once today's are done
    /// (`CalendarAgenda`). Nothing else reads them.
    private(set) var week: [CalendarEvent] = []
    /// Stand-in events shown by previews in place of the real ones.
    private(set) var sample: [CalendarEvent]?
    /// The timed event the island is counting down to, if one is close enough.
    private(set) var featured: CalendarEvent?
    /// The featured event is close enough to take the island over: from two minutes
    /// before it starts, or its Join button's coming, until it lets go
    /// (`CalendarTiming.State.isImminent`).
    private(set) var isImminent = false
    /// The featured event's meeting can be joined from beside the notch
    /// (`CalendarTiming.joinWindow(for:)`).
    private(set) var showsJoin = false

    /// How long before an event starts the island shows it.
    @ObservationIgnored var leadTime: TimeInterval = 10 * 60 {
        didSet { if leadTime != oldValue { evaluate() } }
    }
    /// How long before a meeting starts its Join button comes beside the notch; `nil`
    /// while Settings hides the button.
    @ObservationIgnored var joinLead: TimeInterval? = 5 * 60 {
        didSet { if joinLead != oldValue { evaluate() } }
    }
    /// Whether a fetch has come back since the model started, so a shortcut run as
    /// Islet launches can tell an empty calendar from one not read yet.
    @ObservationIgnored private(set) var hasFetched = false

    /// Called whenever the featured event, its urgency or the sample changes.
    @ObservationIgnored var onChange: () -> Void = {}

    private static let refreshInterval: TimeInterval = 5 * 60

    @ObservationIgnored private var source: CalendarEventSource?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isRequesting = false
    /// Bumped by every fetch and whenever the store is dropped, so a slow fetch can't
    /// overwrite a newer one or bring back events access no longer allows.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    @ObservationIgnored private var boundaryTimer: DispatchSourceTimer?
    @ObservationIgnored private var reloadWork: DispatchWorkItem?
    @ObservationIgnored private var sampleWork: DispatchWorkItem?
    /// Meetings joined from the island, by event, each with its end, when it is
    /// forgotten.
    @ObservationIgnored private var joined: [String: Date] = [:]

    /// What the views show: the preview's sample while one runs, else the calendar.
    var visibleEvents: [CalendarEvent] { sample ?? events }
    var visibleWeek: [CalendarEvent] { sample ?? week }
    var visibleAccess: CalendarAccess { sample == nil ? access : .granted }
    var isShowingSample: Bool { sample != nil }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let center = NotificationCenter.default
        // A new day brings a day further into the week the home tile can list.
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        access = CalendarAccess(EKEventStore.authorizationStatus(for: .event))
        if access == .granted { connect() }
        evaluate()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        reloadWork?.cancel()
        reloadWork = nil
        sampleWork?.cancel()
        sampleWork = nil
        sample = nil
        hasFetched = false
        disconnect()
        evaluate()
        onChange()
    }

    // MARK: Access

    /// Re-reads the authorisation status, which can change in System Settings at any
    /// time without telling the app.
    func refreshAccess() {
        let current = CalendarAccess(EKEventStore.authorizationStatus(for: .event))
        guard current != access else { return }
        access = current
        if access == .granted {
            if isStarted { connect() }
        } else {
            disconnect()
            evaluate()
        }
    }

    /// Asks for full access to events. Only ever called from a click: the system's
    /// prompt should answer something the user just did.
    func requestAccess() {
        refreshAccess()
        guard access == .undetermined, !isRequesting else { return }
        isRequesting = true
        let store = EKEventStore()
        Task { [weak self] in
            _ = try? await store.requestFullAccessToEvents()
            guard let self else { return }
            isRequesting = false
            refreshAccess()
        }
    }

    // MARK: Fetching

    /// Re-checks access and re-reads the calendar now.
    func refresh() {
        refreshAccess()
        reload()
    }

    /// A store created before access was granted can go on returning no calendars,
    /// so each grant gets a fresh one.
    private func connect() {
        guard source == nil else { return }
        let source = CalendarEventSource()
        self.source = source
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: source.store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        reload()
    }

    private func disconnect() {
        generation &+= 1
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
        source = nil
        reloadWork?.cancel()
        reloadWork = nil
        if !events.isEmpty { events = [] }
        if !week.isEmpty { week = [] }
    }

    /// EventKit posts a burst of change notifications while a calendar syncs; one
    /// fetch after it settles is enough. It also posts one when access is switched off,
    /// so the status is re-read too.
    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func reload() {
        guard isStarted, let source else { return }
        reloadWork?.cancel()
        reloadWork = nil
        generation &+= 1
        let generation = generation
        let now = Date()
        let end = CalendarAgenda.end(after: now)
        Task.detached(priority: .utility) { [weak self] in
            let week = source.events(from: now.addingTimeInterval(-Self.hourAgo), to: end)
            await self?.apply(Self.day(of: week, at: now), week: week, generation: generation)
        }
    }

    private nonisolated static let hourAgo: TimeInterval = 60 * 60
    private nonisolated static let dayAhead: TimeInterval = 24 * 60 * 60

    /// The week's events from an hour ago to a day ahead, the range the island, joining
    /// and Shortcuts look at: each that overlaps it, and one with no length that falls
    /// in it.
    nonisolated static func day(of week: [CalendarEvent], at now: Date) -> [CalendarEvent] {
        let from = now.addingTimeInterval(-hourAgo), to = now.addingTimeInterval(dayAhead)
        return week.filter { $0.start < to && ($0.end > from || $0.start >= from) }
    }

    private func apply(_ fetched: [CalendarEvent], week fetchedWeek: [CalendarEvent], generation: Int) {
        guard isStarted, generation == self.generation else { return }
        hasFetched = true
        if fetched != events { events = fetched }
        if fetchedWeek != week { week = fetchedWeek }
        evaluate()
    }

    // MARK: Previews

    /// Shows stand-in events for a while, as if the calendar held them. Each run starts
    /// afresh: a sample joined in the last one has its Join button again.
    func showSample(_ events: [CalendarEvent], for duration: TimeInterval) {
        forgetJoinedSamples()
        sampleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endSample() }
        }
        sampleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        sample = events.sorted { $0.start < $1.start }
        evaluate()
        onChange()
    }

    private func endSample() {
        sampleWork = nil
        guard sample != nil else { return }
        sample = nil
        forgetJoinedSamples()
        evaluate()
        onChange()
    }

    /// A sample's id is the same every time its preview runs.
    private func forgetJoinedSamples() {
        joined = joined.filter { !CalendarEvent.isSampleID($0.key) }
    }

    // MARK: Joining

    /// A shortcut or a link joins a call no further off than this, or the lead time if
    /// that is longer. One further off is as likely as not tomorrow's, and joining it
    /// would put the person in the meeting hours early, or start it as its host.
    static let joinHorizon: TimeInterval = 15 * 60

    /// The meeting a shortcut joins: the featured event's, else the one under way that
    /// began last, else the next to begin within the horizon (`joinHorizon`).
    func eventToJoin(at now: Date = Date()) -> CalendarEvent? {
        if let featured, featured.meeting != nil { return featured }
        let meetings = upcomingMeetings(at: now)
        if let current = meetings.filter({ $0.start <= now }).max(by: { $0.start < $1.start }) { return current }
        let horizon = now.addingTimeInterval(max(leadTime, Self.joinHorizon))
        return meetings.first { $0.start > now && $0.start <= horizon }
    }

    /// The next meeting there is to join, however far off: for saying when it is when
    /// there is none to join yet.
    func nextMeeting(at now: Date = Date()) -> CalendarEvent? {
        upcomingMeetings(at: now).first { $0.start > now }
    }

    /// Timed events with a meeting to join that have not ended, soonest first.
    private func upcomingMeetings(at now: Date) -> [CalendarEvent] {
        visibleEvents.filter { !$0.isAllDay && $0.meeting != nil && now < $0.end }
    }

    /// Opens the event's meeting, and takes its Join button from beside the notch: the
    /// person is on their way in. A preview's meetings are made up, and might be
    /// someone's real one, so for those only the button goes.
    func join(_ event: CalendarEvent) {
        guard let meeting = event.meeting else { return }
        if !event.isSample { CalendarApp.join(meeting) }
        joined[event.id] = event.end
        evaluate()
    }

    // MARK: Scheduling

    private var timing: CalendarTiming {
        CalendarTiming(leadTime: leadTime, joinLead: joinLead, joined: Set(joined.keys))
    }

    /// Picks the featured event for this moment and sleeps until the next one that
    /// matters.
    private func evaluate() {
        let now = Date()
        joined = joined.filter { now < $0.value }
        let timing = timing
        let timed = visibleEvents.filter { !$0.isAllDay }
        let state = timing.state(among: timed, at: now)

        if state.featured != featured || state.isImminent != isImminent || state.showsJoin != showsJoin {
            featured = state.featured
            isImminent = state.isImminent
            showsJoin = state.showsJoin
            onChange()
        }
        scheduleBoundary(after: now, among: timed, timing: timing)
    }

    private func scheduleBoundary(after now: Date, among timed: [CalendarEvent], timing: CalendarTiming) {
        boundaryTimer?.cancel()
        boundaryTimer = nil

        var next: Date? = isStarted && access == .granted ? now.addingTimeInterval(Self.refreshInterval) : nil
        for event in timed {
            for moment in timing.moments(of: event, among: timed) where moment > now {
                next = min(next ?? moment, moment)
            }
        }
        guard let next else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.boundaryReached() }
        }
        // Wall-clock time, so a boundary that passes while the Mac sleeps fires on wake
        // rather than that much later. `asyncAfter` would allow a tenth of the wait as
        // leeway, letting a five-minute wait slip by half a minute; this keeps it to a
        // blink. The small margin lands just past the boundary.
        timer.schedule(wallDeadline: .now() + next.timeIntervalSince(now) + 0.05, leeway: .milliseconds(250))
        timer.resume()
        boundaryTimer = timer
    }

    private func boundaryReached() {
        boundaryTimer?.cancel()
        boundaryTimer = nil
        evaluate()
        if isStarted { refresh() }
    }
}

/// When the island shows an event, and when a meeting's Join button sits beside the
/// notch, worked out from the events and the moment alone.
struct CalendarTiming {
    /// How long before an event starts the island shows it.
    var leadTime: TimeInterval
    /// How long before a meeting starts its Join button comes beside the notch; `nil`
    /// while Settings hides the button. Never earlier than the event itself shows.
    var joinLead: TimeInterval?
    /// Events whose meeting was joined from the island, whose button has done its job.
    var joined: Set<String> = []

    /// An event is imminent from two minutes before it starts.
    static let imminence: TimeInterval = 2 * 60
    /// Someone running late can still join from beside the notch this far in.
    static let joinGrace: TimeInterval = 10 * 60

    struct State: Equatable {
        var featured: CalendarEvent?
        /// Whether the event takes the island over from other activities: from two
        /// minutes before it starts, or from its Join button's coming if that is sooner,
        /// until it would have let go (`CalendarEvent.activityEnd`). The ten minutes a
        /// late joiner has are not worth taking the island back for, and a meeting
        /// already joined has nothing more to say over music.
        var isImminent = false
        var showsJoin = false
    }

    /// From `joinLead` before the meeting starts until ten minutes in, or its end if
    /// that is sooner. `nil` for an event with nothing to join, or joined already.
    func joinWindow(for event: CalendarEvent) -> Range<Date>? {
        guard let joinLead, event.meeting != nil, !event.isAllDay, !joined.contains(event.id) else { return nil }
        let opens = event.start.addingTimeInterval(-min(joinLead, leadTime))
        let closes = min(event.start.addingTimeInterval(Self.joinGrace), event.end)
        return opens < closes ? opens..<closes : nil
    }

    /// While the island shows the event: from the lead time before it starts until it
    /// lets go (`CalendarEvent.activityEnd`), stretched to cover its Join button until
    /// the next event comes into view. Back to back, the next meeting's start matters
    /// more than a late way into the last, and once the island has moved on to it, it
    /// never goes back.
    func shown(_ event: CalendarEvent, among timed: [CalendarEvent]) -> Range<Date> {
        let from = event.start.addingTimeInterval(-leadTime)
        var until = event.activityEnd
        if let window = joinWindow(for: event) {
            let next = timed.lazy.filter { $0.start > event.start }.map { $0.start.addingTimeInterval(-leadTime) }.min()
            until = max(until, min(window.upperBound, next ?? window.upperBound))
        }
        return from..<max(from, until)
    }

    /// The event to show, the soonest first; one kept on only for its Join button gives
    /// way to any still before its own letting go.
    func state(among timed: [CalendarEvent], at now: Date) -> State {
        let shown = timed.filter { self.shown($0, among: timed).contains(now) }
        guard let event = shown.first(where: { now < $0.activityEnd }) ?? shown.first else { return State() }
        let joinable = joinWindow(for: event)?.contains(now) ?? false
        let takesOver = joinable || now >= event.start.addingTimeInterval(-Self.imminence)
        return State(
            featured: event,
            isImminent: takesOver && now < event.activityEnd && !joined.contains(event.id),
            showsJoin: joinable
        )
    }

    /// The moments the event's part in `state` can change.
    func moments(of event: CalendarEvent, among timed: [CalendarEvent]) -> [Date] {
        let shown = shown(event, among: timed)
        var moments = [shown.lowerBound, event.start.addingTimeInterval(-Self.imminence), event.start, event.activityEnd,
                       shown.upperBound]
        if let window = joinWindow(for: event) {
            moments += [window.lowerBound, window.upperBound]
        }
        return moments
    }
}

/// What the home tile lists at a moment: the rest of today while a timed event is
/// left in it, and otherwise the next day within a week that has events, with today's
/// all-day ones, a birthday say, kept to a line above it.
struct CalendarAgenda {
    /// How many days past today the list looks once today is done.
    static let days = 7

    /// How many days after today the day listed is: 0 for today, `nil` when nothing
    /// is on in the week ahead.
    let offset: Int?
    /// The day's events, timed ones first, since they are the ones with somewhere to
    /// be, then all-day ones.
    let events: [CalendarEvent]
    /// Today's all-day events still on, said above another day's list.
    let allDayToday: [CalendarEvent]
    /// "Tomorrow", the weekday's name for the days after, "Next Tuesday" on the same
    /// weekday a week on; `nil` for today or no day.
    let dayName: String?

    init(events: [CalendarEvent], at now: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let day = { Self.day(offset: $0, from: today, in: calendar) }
        let left = events.filter { $0.end > now && $0.start < day(1) }
        let allDay = left.filter(\.isAllDay)
        guard !left.contains(where: { !$0.isAllDay }) else {
            self.init(offset: 0, events: left.filter { !$0.isAllDay } + allDay, allDayToday: [], dayName: nil)
            return
        }
        // An all-day event that goes on past today is said once, in today's line: a day
        // with only that left of it has nothing new on it.
        let said = Set(allDay.map(\.id))
        for offset in 1...Self.days {
            let from = day(offset), to = day(offset + 1)
            let on = events.filter {
                !said.contains($0.id) && $0.start < to && ($0.end > from || $0.start >= from)
            }
            guard !on.isEmpty else { continue }
            self.init(
                offset: offset, events: on.filter { !$0.isAllDay } + on.filter(\.isAllDay), allDayToday: allDay,
                dayName: Self.name(of: from, offset: offset, in: calendar)
            )
            return
        }
        self.init(offset: nil, events: [], allDayToday: allDay, dayName: nil)
    }

    private init(offset: Int?, events: [CalendarEvent], allDayToday: [CalendarEvent], dayName: String?) {
        self.offset = offset
        self.events = events
        self.allDayToday = allDayToday
        self.dayName = dayName
    }

    /// The end of the last day the list can show, which is as far as the calendar is
    /// read (`CalendarModel.week`).
    static func end(after now: Date, calendar: Calendar = .current) -> Date {
        day(offset: days + 1, from: calendar.startOfDay(for: now), in: calendar)
    }

    /// The start of the day so many days on, by the calendar, so a clock change on the
    /// way doesn't shift it by an hour.
    private static func day(offset: Int, from today: Date, in calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today)
            ?? today.addingTimeInterval(TimeInterval(offset) * 24 * 60 * 60)
    }

    private static func name(of day: Date, offset: Int, in calendar: Calendar) -> String {
        if offset == 1 { return "Tomorrow" }
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        let weekday = day.formatted(style)
        return offset == days ? "Next \(weekday)" : weekday
    }
}
