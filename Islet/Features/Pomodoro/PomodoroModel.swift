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
///
/// The session is kept in the defaults as it changes, and picked back up at the next
/// launch by `restore()`, so quitting Islet, or Islet crashing, loses nothing: the time
/// Islet was not running is caught up as a night's sleep is, though only a change that
/// came due in the minute before the launch is told.
///
/// While its bar is dragged, the phase is held still by `hold()`: it cannot run out
/// under the knob, and is moved to wherever the knob is let go.
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

    /// The longest a drag may hold the phase still: past this it carries on as if the
    /// drag had been called off, so one whose end never comes cannot stop it for good.
    nonisolated static let longestHold: TimeInterval = 60

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
    /// the last of the changes it slept through is told: one banner, not a dozen. At
    /// launch, not even that, unless it came due in the last minute: a change from while
    /// Islet was closed is old news by the time anyone sees it.
    @ObservationIgnored var onTransition: (Transition) -> Void = { _ in }

    @ObservationIgnored private let clock: any KeepAwakeClock
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var alarm: KeepAwakeAlarm?
    @ObservationIgnored private var midnight: KeepAwakeAlarm?
    /// The day `completedToday` counts, as "2026-09-27".
    @ObservationIgnored private var countedDay: String
    /// Whether the session is saved as it changes: from `restore()` until `close()`.
    @ObservationIgnored private var picksUp = false
    /// The session as last saved, to write only a change.
    @ObservationIgnored private var written: Session?
    /// Until when the phase is held still while its bar is dragged: from `hold()` until
    /// `letGo(atRemaining:)`, until something else moves or ends the phase, or at the
    /// latest until this.
    @ObservationIgnored private var heldUntil: Date?
    var isHeld: Bool { heldUntil != nil }

    /// Today's count is kept in `defaults`, and read back on launch if it is still today.
    /// So is the session, though not until `restore()` has read back the one saved.
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
        fitToSettings()
        changed()
        // A long break shorter than the time already spent in the short one.
        if case .running(let end) = session?.clock, end <= clock.now { settle() }
    }

    /// Puts the session in line with the settings, as they change or as it is picked
    /// back up.
    private func fitToSettings() {
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
            // No longer the phase a drag took hold of.
            heldUntil = nil
            scheduleAlarm()
        }
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
        // No alarm for a phase paused, bar a drag's that holds it.
        scheduleAlarm()
        changed()
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
            changed()
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

    /// Moves the phase on or back so that `remaining` is left of it, kept between its
    /// start and its end: on to skip ahead, back for more time. A phase paused stays
    /// paused, with the new time left. Moved to its very end, it finishes as if its time
    /// had run out, with the word, the sound and the count that go with that, and the
    /// phase after it starts by itself or waits, as Settings says. A phase waiting for a
    /// click has not begun, and does not move. Whether it moved.
    ///
    /// A phase whose end has just passed, its alarm a moment late, is still the phase
    /// being looked at, and is moved as if under way, so asking for more time gives it
    /// more rather than ending it; and so is one held by its bar however long the drag
    /// took. One whose time ran out more than a minute ago, the Mac asleep, is over: that
    /// is caught up instead, and nothing moves.
    @discardableResult
    func move(toRemaining remaining: TimeInterval) -> Bool {
        guard remaining.isFinite, var session, !session.isWaiting else { return false }
        let now = clock.now
        if case .running(let end) = session.clock, !isHeld, now.timeIntervalSince(end) > Self.lateness {
            settle()
            return false
        }
        // Whoever moved it, a drag holding it is over.
        heldUntil = nil
        let left = min(max(0, remaining), session.length)
        if left > 0 {
            session.clock = session.isPaused ? .paused(remaining: left) : .running(end: now.addingTimeInterval(left))
            self.session = session
            scheduleAlarm()
            changed()
        } else {
            session.clock = .running(end: now)
            self.session = session
            settle()
        }
        return true
    }

    /// Moves the phase on by `seconds`, or back by as many for a negative number, as
    /// `move(toRemaining:)` does.
    @discardableResult
    func move(by seconds: TimeInterval) -> Bool {
        guard seconds.isFinite, let session else { return false }
        return move(toRemaining: session.remaining(at: clock.now) - seconds)
    }

    /// Holds the phase still while its bar is dragged, so it cannot run out under the
    /// knob: its alarm is off, and neither the Mac waking nor its clock changing ends it,
    /// until `letGo(atRemaining:)`, or for a minute at most. Anything else that moves or
    /// ends the phase meanwhile lets go of it too. Whether there was a phase to hold: not
    /// one waiting for a click, nor one whose time ran out more than a minute ago, which
    /// is caught up instead.
    @discardableResult
    func hold() -> Bool {
        guard let session, !session.isWaiting else { return false }
        if case .running(let end) = session.clock, clock.now.timeIntervalSince(end) > Self.lateness {
            settle()
            return false
        }
        heldUntil = clock.now.addingTimeInterval(Self.longestHold)
        scheduleAlarm()
        return true
    }

    /// Lets go of the phase `hold()` held: moved so that `remaining` is left, as
    /// `move(toRemaining:)` moves it, the time the drag took not counted; or, for a drag
    /// called off (`nil`), as it was, caught up on anything that came due meanwhile.
    /// Nothing, if the phase was let go of already.
    func letGo(atRemaining remaining: TimeInterval?) {
        guard isHeld else { return }
        if let remaining, move(toRemaining: remaining) { return }
        heldUntil = nil
        settle()
    }

    /// Ends the session, and any preview, without a word. Today's count stays, and the
    /// saved session goes: there is nothing to pick back up.
    func stop() {
        guard session != nil || preview != nil else { return }
        heldUntil = nil
        cancelAlarm()
        session = nil
        preview = nil
        changed()
    }

    /// Ends a phase whose time has come, and anything after it that ran its course by
    /// itself too, and otherwise sets the call for its end again. Its alarm calls it,
    /// and so does the Mac waking or its clock being changed. It starts a new day's
    /// count, too, once midnight has passed. A phase held by its bar is left be.
    func settle() {
        catchUp(tellingOldNews: true)
    }

    /// `settle()`, telling the last change that came due only if it did so within the
    /// last minute, or `tellingOldNews`.
    private func catchUp(tellingOldNews: Bool) {
        let rolled = rollDay()
        // Midnight may have moved, with the clock or the time zone.
        scheduleMidnight()
        guard !isHeld, var current = session, case .running(let end) = current.clock, clock.now >= end else {
            if session?.isRunning == true { scheduleAlarm() }
            if rolled { changed() }
            return
        }
        var transition: Transition?
        var changedAt = end
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
            changedAt = ended
            guard case .running(let end) = following.clock else { break }
            ended = end
        }
        session = current
        scheduleAlarm()
        changed()
        guard let transition, tellingOldNews || clock.now.timeIntervalSince(changedAt) <= Self.lateness else { return }
        onTransition(transition)
    }

    // MARK: Keeping the session

    /// Picks back up the session saved as Islet last quit, or crashed, and catches up on
    /// the time since as the Mac waking does: a phase that ran out meanwhile is over, a
    /// break after it carried on by itself, a focus that should have started more than a
    /// minute ago waits for a click, and only the focus that was running is counted, if
    /// it ended today. The last change is told, with its word and its sound, only if it
    /// came due in the minute before the launch; one older than that is old news, and the
    /// island simply shows the session as it now is. Saved data that cannot be read, or
    /// that another version wrote in another form, is dropped. Until this has run,
    /// nothing is saved, so the session is not overwritten before it is read.
    func restore() {
        picksUp = true
        written = nil
        guard session == nil else { return changed() }
        guard let saved = defaults.object(forKey: PomodoroPrefs.session) else { return }
        guard let found = Self.decode(saved, now: clock.now) else {
            defaults.removeObject(forKey: PomodoroPrefs.session)
            return
        }
        preview = nil
        session = found
        fitToSettings()
        // Catches up, and saves the session as it now is, an end brought nearer included.
        catchUp(tellingOldNews: false)
        changed()
    }

    /// Lets go of the session as Islet quits, without ending it: it stays saved, for
    /// `restore()` to pick back up at the next launch. Any preview ends.
    func close() {
        heldUntil = nil
        cancelAlarm()
        picksUp = false
        session = nil
        preview = nil
        onChange()
    }

    /// The form the session is saved in; one written in another is dropped.
    static let savedVersion = 1

    /// The session as the defaults keep it: plain values, readable with `defaults read`.
    /// A phase takes its length as it starts, so its own is kept; the phases after it
    /// take theirs from Settings, as they would have with Islet running.
    static func encode(_ session: Session) -> [String: Any] {
        var saved: [String: Any] = [
            "version": savedVersion,
            "phase": session.phase.rawValue,
            "round": session.round,
            "length": session.length,
        ]
        switch session.clock {
        case .running(let end):
            saved["clock"] = "running"
            saved["end"] = end
        case .paused(let remaining):
            saved["clock"] = "paused"
            saved["remaining"] = remaining
        case .waiting:
            saved["clock"] = "waiting"
        }
        return saved
    }

    /// The session `saved` holds, or nil for anything `encode` would not have written:
    /// another version's form, a phase or a clock it does not know, or a number out of
    /// range. A phase due to end further off than its whole length, the clock having
    /// been set back since, ends a length from `now`.
    static func decode(_ saved: Any, now: Date) -> Session? {
        guard let saved = saved as? [String: Any],
              saved["version"] as? Int == savedVersion,
              let phase = (saved["phase"] as? String).flatMap(Phase.init(rawValue:)),
              let round = saved["round"] as? Int,
              (1...PomodoroSettings.roundChoices.upperBound).contains(round),
              let length = saved["length"] as? Double,
              length.isFinite, length > 0, length <= longestFocus
        else { return nil }
        let clock: Clock
        switch saved["clock"] as? String {
        case "running":
            guard let end = saved["end"] as? Date, end.timeIntervalSinceReferenceDate.isFinite else { return nil }
            clock = .running(end: min(end, now.addingTimeInterval(length)))
        case "paused":
            guard let remaining = saved["remaining"] as? Double,
                  remaining.isFinite, remaining > 0, remaining <= length else { return nil }
            clock = .paused(remaining: remaining)
        case "waiting":
            clock = .waiting
        default:
            return nil
        }
        return Session(phase: phase, round: round, length: length, clock: clock)
    }

    // MARK: Previews

    /// Shows a made-up session until `endPreview()`, or until a real one starts. It
    /// never shows over a real session.
    func showPreview(_ sample: Session) {
        guard session == nil else { return }
        preview = sample
        changed()
    }

    func endPreview() {
        guard preview != nil else { return }
        preview = nil
        changed()
    }

    // MARK: Private

    /// Saves the session as it now is, and says it changed.
    private func changed() {
        saveSession(session)
        onChange()
    }

    /// Writes the session to the defaults, or removes it once there is none, only when
    /// it differs from what was last written: a preview coming and going writes nothing.
    private func saveSession(_ session: Session?) {
        guard picksUp, session != written else { return }
        written = session
        if let session {
            defaults.set(Self.encode(session), forKey: PomodoroPrefs.session)
        } else {
            defaults.removeObject(forKey: PomodoroPrefs.session)
        }
    }

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
        heldUntil = nil
        var running = session
        running.clock = .running(end: start.addingTimeInterval(session.length))
        self.session = running
        scheduleAlarm()
        changed()
    }

    /// Sets the call for the running phase's end, or, while it is held, for the hold's.
    private func scheduleAlarm() {
        cancelAlarm()
        if let heldUntil {
            alarm = clock.schedule(at: heldUntil) { [weak self] in self?.letGo(atRemaining: nil) }
            return
        }
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
