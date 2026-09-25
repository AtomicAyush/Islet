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

/// The day's events and which one is close enough to count down to.
///
/// Nothing polls. The model re-reads the calendar when EventKit says it changed, on
/// wake, and every five minutes as a backstop, and otherwise sleeps until the next
/// moment something would change: an event coming into the lead time, becoming
/// imminent, starting, or letting go.
@MainActor
@Observable
final class CalendarModel {
    private(set) var access = CalendarAccess(EKEventStore.authorizationStatus(for: .event))
    /// Events from an hour ago to a day ahead, all-day ones included, soonest first.
    private(set) var events: [CalendarEvent] = []
    /// Stand-in events shown by previews in place of the real ones.
    private(set) var sample: [CalendarEvent]?
    /// The timed event the island is counting down to, if one is close enough.
    private(set) var featured: CalendarEvent?
    /// The featured event starts within two minutes, or has started.
    private(set) var isImminent = false

    /// How long before an event starts the island shows it.
    @ObservationIgnored var leadTime: TimeInterval = 10 * 60 {
        didSet { if leadTime != oldValue { evaluate() } }
    }

    /// Called whenever the featured event, its urgency or the sample changes.
    @ObservationIgnored var onChange: () -> Void = {}

    static let imminence: TimeInterval = 2 * 60
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

    /// What the views show: the preview's sample while one runs, else the calendar.
    var visibleEvents: [CalendarEvent] { sample ?? events }
    var visibleAccess: CalendarAccess { sample == nil ? access : .granted }
    var isShowingSample: Bool { sample != nil }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let center = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
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
        Task.detached(priority: .utility) { [weak self] in
            let events = source.events(from: now.addingTimeInterval(-60 * 60), to: now.addingTimeInterval(24 * 60 * 60))
            await self?.apply(events, generation: generation)
        }
    }

    private func apply(_ fetched: [CalendarEvent], generation: Int) {
        guard isStarted, generation == self.generation else { return }
        if fetched != events { events = fetched }
        evaluate()
    }

    // MARK: Previews

    /// Shows stand-in events for a while, as if the calendar held them.
    func showSample(_ events: [CalendarEvent], for duration: TimeInterval) {
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
        evaluate()
        onChange()
    }

    // MARK: Scheduling

    /// A meeting to join from a shortcut: the featured event's, else one under way.
    func joinableMeeting(at now: Date = Date()) -> MeetingLink? {
        if let meeting = featured?.meeting { return meeting }
        return visibleEvents.first { !$0.isAllDay && $0.start <= now && now < $0.end && $0.meeting != nil }?.meeting
    }

    /// Picks the featured event for this moment and sleeps until the next one that
    /// matters.
    private func evaluate() {
        let now = Date()
        let timed = visibleEvents.filter { !$0.isAllDay }
        let next = timed.first { $0.start.addingTimeInterval(-leadTime) <= now && now < $0.activityEnd }
        let imminent = next.map { now >= $0.start.addingTimeInterval(-Self.imminence) } ?? false

        if next != featured || imminent != isImminent {
            featured = next
            isImminent = imminent
            onChange()
        }
        scheduleBoundary(after: now, among: timed)
    }

    private func scheduleBoundary(after now: Date, among timed: [CalendarEvent]) {
        boundaryTimer?.cancel()
        boundaryTimer = nil

        var next: Date? = isStarted && access == .granted ? now.addingTimeInterval(Self.refreshInterval) : nil
        for event in timed {
            let moments = [
                event.start.addingTimeInterval(-leadTime),
                event.start.addingTimeInterval(-Self.imminence),
                event.start,
                event.activityEnd,
            ]
            for moment in moments where moment > now {
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
