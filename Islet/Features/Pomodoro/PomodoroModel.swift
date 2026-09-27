import Foundation
import Observation

/// The lengths and rules a Pomodoro session follows, as Settings has them. A phase takes
/// its length as it starts: one changed in Settings applies from the next phase on.
struct PomodoroSettings: Equatable {
    var focus: TimeInterval = 25 * 60
    var shortBreak: TimeInterval = 5 * 60
    var longBreak: TimeInterval = 15 * 60
    /// Focus sessions to a cycle: the break after the last of them is the long one.
    var rounds = 4
    var autoStartsBreaks = true
    var autoStartsFocus = false

    /// What Settings offers, in minutes, and in focus sessions to a cycle.
    static let focusMinutes = 1...120
    static let shortBreakMinutes = 1...30
    static let longBreakMinutes = 1...60
    static let roundChoices = 2...8

    func length(of phase: PomodoroModel.Phase) -> TimeInterval {
        switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }

    func startsByItself(_ phase: PomodoroModel.Phase) -> Bool {
        phase == .focus ? autoStartsFocus : autoStartsBreaks
    }

    /// Settings as the defaults have them, each number kept within what Settings offers,
    /// so a value written by hand cannot make a phase of no length.
    static func read(from defaults: UserDefaults) -> PomodoroSettings {
        func minutes(_ key: String, _ range: ClosedRange<Int>, _ fallback: TimeInterval) -> TimeInterval {
            guard let value = defaults.object(forKey: key) as? Int else { return fallback }
            return TimeInterval(min(max(value, range.lowerBound), range.upperBound) * 60)
        }
        var settings = PomodoroSettings()
        settings.focus = minutes(PomodoroPrefs.focusMinutes, focusMinutes, settings.focus)
        settings.shortBreak = minutes(PomodoroPrefs.shortBreakMinutes, shortBreakMinutes, settings.shortBreak)
        settings.longBreak = minutes(PomodoroPrefs.longBreakMinutes, longBreakMinutes, settings.longBreak)
        if let rounds = defaults.object(forKey: PomodoroPrefs.rounds) as? Int {
            settings.rounds = min(max(rounds, roundChoices.lowerBound), roundChoices.upperBound)
        }
        settings.autoStartsBreaks = PomodoroPrefs.bool(PomodoroPrefs.autoStartBreaks, default: true, in: defaults)
        settings.autoStartsFocus = PomodoroPrefs.bool(PomodoroPrefs.autoStartFocus, default: false, in: defaults)
        return settings
    }
}

/// The Pomodoro method's cycle: a focus session, a short break, and after every fourth
/// focus (or however many Settings asks for) a long break instead. It knows nothing of
/// the island: it keeps time, and says when one phase gave way to the next.
///
/// A running phase ends at a time on the wall clock, as Keep Awake's sessions do, so one
/// that ran out while the Mac slept is over when it wakes, and so is a break that
/// followed it by itself. A focus is never started by itself in a change that came due
/// while nobody was there to see it: it waits, as does the count, which takes only a
/// focus that was running. Pausing holds the time left, whatever the clock does.
@MainActor
@Observable
final class PomodoroModel {
    enum Phase: String, Equatable, CaseIterable {
        case focus
        case shortBreak
        case longBreak

        var isBreak: Bool { self != .focus }
    }

    enum Clock: Equatable {
        case running(end: Date)
        case paused(remaining: TimeInterval)
        /// The phase is next, and waits for a click to start.
        case waiting
    }

    struct Session: Equatable {
        var phase: Phase
        /// Which focus of the cycle, from 1: the one under way or next, or, in a break,
        /// the one just done.
        var round: Int
        /// The phase's whole length, for the ring.
        var length: TimeInterval
        var clock: Clock

        func remaining(at date: Date) -> TimeInterval {
            switch clock {
            case .running(let end): max(0, end.timeIntervalSince(date))
            case .paused(let remaining): remaining
            case .waiting: length
            }
        }

        /// Fraction left, 1 at the start and 0 at the end.
        func progress(at date: Date) -> Double {
            guard length > 0 else { return 0 }
            return min(1, max(0, remaining(at: date) / length))
        }

        var isRunning: Bool {
            if case .running = clock { return true }
            return false
        }

        var isPaused: Bool {
            if case .paused = clock { return true }
            return false
        }

        var isWaiting: Bool { clock == .waiting }

        /// Focus sessions of the cycle done: those before this one, or, in a break,
        /// this one too.
        var roundsDone: Int { phase.isBreak ? round : round - 1 }
    }

    /// One phase giving way to the next by running out, rather than by a click.
    struct Transition: Equatable {
        var finished: Phase
        /// The phase now under way, or waiting to start.
        var next: Session
    }

    /// How late a change may come and still count as seen: a timer fires a moment late,
    /// but one this late is the Mac waking, or its clock set on.
    nonisolated static let lateness: TimeInterval = 60

    /// The longest a focus may be asked for from a URL: the longest Settings offers.
    nonisolated static let longestFocus: TimeInterval = TimeInterval(PomodoroSettings.focusMinutes.upperBound * 60)

    private(set) var settings = PomodoroSettings()
    /// The session under way, if any.
    private(set) var session: Session?
    /// A made-up session a preview shows in place of the real one. It never runs out,
    /// counts for nothing and turns nothing on.
    private(set) var preview: Session?
    /// Focus sessions finished today, by running out. Nought again from midnight.
    private(set) var completedToday = 0

    /// What the island shows: a preview over the real session.
    var shown: Session? { preview ?? session }
    var isActive: Bool { session != nil }

    /// Called whenever the session or the count changes, so the activity can show or end.
    @ObservationIgnored var onChange: () -> Void = {}
    /// Called when a phase runs out and the next takes over. After a night's sleep only
    /// the last of the changes it slept through is told: one banner, not a dozen.
    @ObservationIgnored var onTransition: (Transition) -> Void = { _ in }

    @ObservationIgnored private let clock: any KeepAwakeClock
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var alarm: KeepAwakeAlarm?
    @ObservationIgnored private var midnight: KeepAwakeAlarm?
    /// The day `completedToday` counts, as "2026-09-27".
    @ObservationIgnored private var countedDay: String

    /// Today's count is kept in `defaults`, and read back on launch if it is still today.
    /// A session is not: see `PomodoroFeature`.
    init(clock: any KeepAwakeClock, defaults: UserDefaults, calendar: Calendar = .autoupdatingCurrent) {
        self.clock = clock
        self.defaults = defaults
        self.calendar = calendar
        countedDay = defaults.string(forKey: PomodoroPrefs.countedDay) ?? ""
        completedToday = defaults.integer(forKey: PomodoroPrefs.completedToday)
        if countedDay != day(of: clock.now) {
            countedDay = day(of: clock.now)
            completedToday = 0
        }
        scheduleMidnight()
    }

    func apply(_ settings: PomodoroSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        // Fewer rounds to a cycle than the one under way: this is the last of them.
        if var session, session.round > settings.rounds {
            session.round = settings.rounds
            self.session = session
        }
        // A short break after what is now the last focus of the cycle: the long break,
        // longer by the difference, rather than another focus to come.
        if var session, session.phase == .shortBreak, session.round >= settings.rounds {
            let more = settings.longBreak - session.length
            session.phase = .longBreak
            session.length = settings.longBreak
            switch session.clock {
            case .running(let end): session.clock = .running(end: end.addingTimeInterval(more))
            case .paused(let remaining): session.clock = .paused(remaining: max(0, remaining + more))
            case .waiting: break
            }
            self.session = session
            scheduleAlarm()
        }
        onChange()
        // A long break shorter than the time already spent in the short one.
        if case .running(let end) = session?.clock, end <= clock.now { settle() }
    }

    // MARK: Controls

    /// Starts a session with its first focus, of `focusLength` or the one in Settings.
    /// A session under way carries on instead: paused, it resumes, and a phase waiting
    /// starts. Returns false for a length that is no length.
    @discardableResult
    func start(focusLength: TimeInterval? = nil) -> Bool {
        if let focusLength, !(focusLength.isFinite && focusLength > 0) { return false }
        guard let session else {
            let length = min(focusLength ?? settings.focus, Self.longestFocus)
            preview = nil
            run(Session(phase: .focus, round: 1, length: length, clock: .waiting), from: clock.now)
            return true
        }
        switch session.clock {
        case .running: break
        case .paused: resume()
        case .waiting: run(session, from: clock.now)
        }
        return true
    }

    /// Holds the time left until `resume()`.
    func pause() {
        guard var session, case .running(let end) = session.clock else { return }
        let now = clock.now
        // Its time is already up, and only the alarm has yet to say so.
        guard end > now else { return settle() }
        session.clock = .paused(remaining: end.timeIntervalSince(now))
        self.session = session
        cancelAlarm()
        onChange()
    }

    /// Carries on from where it was paused, or starts a phase waiting for a click.
    func resume() {
        guard let session else { return }
        switch session.clock {
        case .running:
            return
        case .paused(let remaining):
            var resumed = session
            resumed.clock = .running(end: clock.now.addingTimeInterval(remaining))
            self.session = resumed
            scheduleAlarm()
            onChange()
        case .waiting:
            run(session, from: clock.now)
        }
    }

    /// Pauses a phase running, and otherwise carries on or starts: one button for both.
    func toggle() {
        if session?.isRunning == true { pause() } else { start() }
    }

    /// Ends the phase now and starts the next straight away, whatever Settings says
    /// about waiting: whoever clicked is there. A focus skipped is not counted as done,
    /// though the cycle moves on as if it were, so the long break still comes round.
    func skip() {
        guard let session else { return }
        run(next(after: session), from: clock.now)
    }

    /// Ends the session, and any preview, without a word. Today's count stays.
    func stop() {
        guard session != nil || preview != nil else { return }
        cancelAlarm()
        session = nil
        preview = nil
        onChange()
    }

    /// Ends a phase whose time has come, and anything after it that ran its course by
    /// itself too, and otherwise sets the call for its end again. Its alarm calls it,
    /// and so does the Mac waking or its clock being changed. It starts a new day's
    /// count, too, once midnight has passed.
    func settle() {
        let rolled = rollDay()
        // Midnight may have moved, with the clock or the time zone.
        scheduleMidnight()
        guard var current = session, case .running(let end) = current.clock, clock.now >= end else {
            if session?.isRunning == true { scheduleAlarm() }
            if rolled { onChange() }
            return
        }
        var transition: Transition?
        var ended = end
        var first = true
        while clock.now >= ended {
            let finished = current.phase
            // Only the focus that was running counts: one that came and went while the
            // Mac slept was done by nobody.
            if finished == .focus, first { countFocus(endedAt: ended) }
            first = false
            var following = next(after: current)
            // Nobody saw this change come: a break may carry on without them, but a focus
            // waits for someone to be there to start it.
            let unseen = clock.now.timeIntervalSince(ended) > Self.lateness
            if settings.startsByItself(following.phase), !(unseen && following.phase == .focus) {
                // From when the last one ended, not from now: the Mac may have slept
                // through the change, and a timer fires a moment late.
                following.clock = .running(end: ended.addingTimeInterval(following.length))
            }
            current = following
            transition = Transition(finished: finished, next: following)
            guard case .running(let end) = following.clock else { break }
            ended = end
        }
        session = current
        scheduleAlarm()
        onChange()
        if let transition { onTransition(transition) }
    }

    // MARK: Previews

    /// Shows a made-up session until `endPreview()`, or until a real one starts. It
    /// never shows over a real session.
    func showPreview(_ sample: Session) {
        guard session == nil else { return }
        preview = sample
        onChange()
    }

    func endPreview() {
        guard preview != nil else { return }
        preview = nil
        onChange()
    }

    // MARK: Private

    /// The phase after `session`'s, waiting to start, with its length from Settings.
    private func next(after session: Session) -> Session {
        switch session.phase {
        case .focus:
            let phase: Phase = session.round >= settings.rounds ? .longBreak : .shortBreak
            return Session(phase: phase, round: session.round, length: settings.length(of: phase), clock: .waiting)
        case .shortBreak:
            let round = min(session.round + 1, settings.rounds)
            return Session(phase: .focus, round: round, length: settings.focus, clock: .waiting)
        case .longBreak:
            return Session(phase: .focus, round: 1, length: settings.focus, clock: .waiting)
        }
    }

    private func run(_ session: Session, from start: Date) {
        var running = session
        running.clock = .running(end: start.addingTimeInterval(session.length))
        self.session = running
        scheduleAlarm()
        onChange()
    }

    private func scheduleAlarm() {
        cancelAlarm()
        guard case .running(let end) = session?.clock else { return }
        alarm = clock.schedule(at: end) { [weak self] in self?.settle() }
    }

    private func cancelAlarm() {
        alarm?.cancel()
        alarm = nil
    }

    // MARK: Today's count

    private func day(of date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Counts a focus that ran out at `date`, if that was today: one that ended before
    /// midnight while the Mac slept belongs to a day already over.
    private func countFocus(endedAt date: Date) {
        guard day(of: date) == countedDay else { return }
        completedToday += 1
        save()
    }

    /// Starts the count again once the day has changed. Whether it did.
    private func rollDay() -> Bool {
        let today = day(of: clock.now)
        guard today != countedDay else { return false }
        countedDay = today
        let hadCount = completedToday != 0
        completedToday = 0
        save()
        return hadCount
    }

    private func save() {
        defaults.set(countedDay, forKey: PomodoroPrefs.countedDay)
        defaults.set(completedToday, forKey: PomodoroPrefs.completedToday)
    }

    /// A call at the next midnight, so the count goes back to nought on time with the
    /// island open, not only at the next change.
    private func scheduleMidnight() {
        midnight?.cancel()
        let start = calendar.startOfDay(for: clock.now)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        midnight = clock.schedule(at: next) { [weak self] in self?.settle() }
    }
}
