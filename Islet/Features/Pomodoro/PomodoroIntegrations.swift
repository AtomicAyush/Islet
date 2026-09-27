import AppKit
import IOKit.pwr_mgt

/// Plays the sound at each change. Pomodoro asks this rather than AppKit, so tests can
/// hand in one that only takes notes.
@MainActor
protocol PomodoroSoundPlayer: AnyObject {
    func play(_ name: String)
}

/// The system's alert sounds, by name.
final class SystemSoundPlayer: PomodoroSoundPlayer {
    func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
}

/// Runs the shortcut Focus's settings chose to turn Focus on and off. Pomodoro asks this
/// rather than the `shortcuts` tool, so tests can hand in one that only takes notes.
@MainActor
protocol PomodoroShortcutRunner: AnyObject {
    /// Whether it ran to the end.
    func run(_ name: String) async -> Bool
}

/// Through the runner the Focus feature uses, so a run is recorded as Islet's as its
/// are.
final class FocusShortcutRunner: PomodoroShortcutRunner {
    func run(_ name: String) async -> Bool {
        let failure = await FocusShortcut.run(name)
        if let failure {
            let reason = String(describing: failure)
            IslandLog.app.error("Pomodoro: the Focus shortcut did not run (\(reason, privacy: .public))")
        }
        return failure == nil
    }
}

/// Turns Focus on for a focus session and off again for its break, with the one
/// shortcut there is for it, which toggles.
///
/// A toggle cannot be told "on": run with Focus already on, it would turn it off. So it
/// is run only when the switch can see what it will do. A Focus already on is left
/// alone, and left on after the session too, since it was not Pomodoro's to turn off; a
/// Focus someone turned off by hand in the meantime is not turned back on; and while
/// nobody can tell which Focus is on (the Focus feature off, not yet looked, or without
/// Full Disk Access), nothing is turned on at all, and it waits for the Focus feature to
/// see.
///
/// Runs go one after another, never two at once, and what to do next is decided as each
/// ends, from what it did, not when it was asked for: a run that failed to turn Focus on
/// is never followed by one that would turn it on while meaning to turn it off. After a
/// run of its own, what that run did counts over the Focus database, which lags, until
/// the database says the same.
///
/// That Pomodoro turned a Focus on is kept in the defaults, with which Focus it was,
/// until it is turned off again. Islet waits a few seconds on quitting for that; if it
/// could not wait long enough, the next launch turns the same Focus off, if it is still
/// the one on.
@MainActor
final class PomodoroFocusSwitch {
    /// How long a run's word counts over a Focus database that says otherwise: time
    /// enough for the database to catch up, and not so long that a change made by hand
    /// since goes unseen. Tests shorten it.
    static var confirmWithin: TimeInterval = 10

    /// Whether Pomodoro turned Focus on, and so owes turning it off: from when a run to
    /// turn it on starts until one turns it off, or it is seen off.
    private(set) var turnedOn = false
    /// Whether a run is under way.
    var isBusy: Bool { running != nil }

    private let runner: any PomodoroShortcutRunner
    /// The Focus as the database has it; `nil` when that cannot be told.
    private let reading: @MainActor () -> FocusState?
    private let defaults: UserDefaults
    /// Nothing is decided until the feature first says what it wants, and with which
    /// shortcut.
    private var asked = false
    private var wanted = false
    private var shortcut: String?
    /// Whether the latest change in what is wanted has been seen to, by a run or by
    /// finding nothing to do: until it changes again, nothing more is run.
    private var handled = false
    private var running: Task<Void, Never>?
    /// What the last run did, and when, until the database says the same.
    private var ran: (on: Bool, at: Date)?
    /// Which Focus Pomodoro turned on, once the database showed it, by identifier.
    private var ownFocus: String?

    init(
        runner: any PomodoroShortcutRunner,
        reading: @escaping @MainActor () -> FocusState?,
        defaults: UserDefaults
    ) {
        self.runner = runner
        self.reading = reading
        self.defaults = defaults
        // Left on by a quit that could not wait: owed still.
        if let own = defaults.string(forKey: PomodoroPrefs.focusTurnedOn) {
            ownFocus = own
            turnedOn = true
        }
    }

    /// Turns Focus on (`true`) or back off, running the shortcut called `name` if that
    /// changes anything. A `name` of `nil` (none chosen) turns nothing on, and gives up
    /// turning off what Pomodoro turned on.
    func want(_ on: Bool, shortcut name: String?) {
        shortcut = name
        if !asked {
            asked = true
            // Not before: the switch is made with the feature list the Focus feature is
            // looked up in.
            watch()
        }
        if on != wanted {
            wanted = on
            handled = false
        }
        decide()
    }

    /// Waits for the runs asked for so far, and any they lead to, for quitting and tests.
    func settled() async {
        while let running { await running.value }
    }

    // MARK: Private

    private func decide() {
        // As the run under way ends, this is called again.
        guard asked, running == nil, !handled else { return }
        let focus = look()
        if wanted {
            if turnedOn { handled = true; return }
            // Nothing to run, or no telling what it would do: wait for either to change.
            guard let name = shortcut, let focus else { return }
            handled = true
            // Someone's own Focus: left alone.
            guard !focus else { return }
            turnedOn = true
            run(name, on: true)
        } else {
            guard turnedOn else { handled = true; return }
            guard let name = shortcut else {
                handled = true
                return forget()
            }
            guard let focus else { return }
            handled = true
            // Turned off by hand already, or a different Focus on in its place.
            guard focus, isOwnFocus() else { return forget() }
            run(name, on: false)
        }
    }

    private func run(_ name: String, on: Bool) {
        running = Task { [weak self, runner] in
            let done = await runner.run(name)
            guard let self else { return }
            running = nil
            if done {
                ran = (on, Date())
                if !on { forget() }
            } else if on {
                // Focus did not come on, so there is nothing to turn off.
                forget()
            }
            // A failed "off" is owed still, and tried again at the next break, or the
            // next launch; not straight away, over and over.
            recheck()
        }
    }

    /// Whether a Focus is on: the database's word, or what the last run did until the
    /// database says the same. `nil` when that cannot be told.
    private func look() -> Bool? {
        let state = reading()
        let seen = state.map { $0.mode != nil }
        guard let ran else { return seen }
        if seen == ran.on {
            self.ran = nil
            // The Focus this turned on, now it shows, kept so a relaunch knows it.
            if ran.on, turnedOn, let mode = state?.mode { remember(mode.identifier) }
            return seen
        }
        if seen == nil || Date().timeIntervalSince(ran.at) < Self.confirmWithin { return ran.on }
        self.ran = nil
        return seen
    }

    /// Whether the Focus on is the one Pomodoro turned on, as far as can be told.
    private func isOwnFocus() -> Bool {
        guard let ownFocus, let mode = reading()?.mode else { return true }
        return mode.identifier == ownFocus
    }

    private func remember(_ identifier: String) {
        ownFocus = identifier
        defaults.set(identifier, forKey: PomodoroPrefs.focusTurnedOn)
    }

    /// Owes nothing any more.
    private func forget() {
        turnedOn = false
        ownFocus = nil
        defaults.removeObject(forKey: PomodoroPrefs.focusTurnedOn)
    }

    /// Looks again whenever the Focus feature sees a change: access granted at last, or
    /// the database catching up.
    private func watch() {
        withObservationTracking { _ = reading() } onChange: { [weak self] in
            Task { @MainActor in
                self?.watch()
                self?.recheck()
            }
        }
    }

    /// A change in the Focus reopens a decision still waiting on it; one already made
    /// stands. And a Focus Pomodoro turned on, once the database shows it, is noted.
    private func recheck() {
        guard running == nil else { return }
        if ran != nil { _ = look() }
        decide()
    }
}

/// Keeps the Mac awake through a focus session with a power assertion of its own,
/// through the same assertions Keep Awake takes, named "Islet: Pomodoro" in
/// `pmset -g assertions`. Its own, so it neither shows as a Keep Awake session nor
/// ends one someone started there.
@MainActor
final class PomodoroAwakeHold {
    nonisolated static let assertionName = "Islet: Pomodoro"

    private let assertions: any PowerAssertions
    private(set) var held: IOPMAssertionID?

    init(assertions: any PowerAssertions) {
        self.assertions = assertions
    }

    /// Takes the assertion, or gives it back.
    func want(_ awake: Bool) {
        if awake {
            guard held == nil else { return }
            held = assertions.create(.display, name: Self.assertionName)
        } else if let held {
            self.held = nil
            assertions.release(held)
        }
    }
}
