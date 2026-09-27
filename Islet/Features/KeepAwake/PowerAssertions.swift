import Foundation
import IOKit.pwr_mgt

/// Which sleep a power assertion holds off. Neither stops the Mac sleeping when its lid
/// is closed, or when someone chooses Sleep: an assertion only stands in for the person
/// still being there.
enum PowerAssertionKind: Equatable {
    /// The display stays on, and so the Mac stays awake with it.
    case display
    /// The display dims and sleeps as it would; the Mac itself stays awake behind it,
    /// for a download or a long task.
    case system

    /// The IOKit assertion type.
    var type: String {
        switch self {
        case .display: kIOPMAssertionTypePreventUserIdleDisplaySleep
        case .system: kIOPMAssertionTypePreventUserIdleSystemSleep
        }
    }
}

/// Takes and gives back power assertions. Keep Awake asks this rather than IOKit, so
/// tests can hand in one that only takes notes.
@MainActor
protocol PowerAssertions: AnyObject {
    /// Takes an assertion named `name`, or returns `nil` if macOS would not give one.
    func create(_ kind: PowerAssertionKind, name: String) -> IOPMAssertionID?
    func release(_ id: IOPMAssertionID)
}

/// The real thing, through IOKit. macOS lists each assertion by name, with the app that
/// holds it, in `pmset -g assertions`, and releases any an app still holds when it quits
/// or crashes: nothing Islet takes can outlive it.
final class SystemPowerAssertions: PowerAssertions {
    func create(_ kind: PowerAssertionKind, name: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kind.type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id
        )
        guard result == kIOReturnSuccess else {
            IslandLog.app.error("Keep Awake: no power assertion (\(result, privacy: .public))")
            return nil
        }
        return id
    }

    func release(_ id: IOPMAssertionID) {
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess {
            IslandLog.app.error("Keep Awake: power assertion not released (\(result, privacy: .public))")
        }
    }
}

/// The time, and a call back once a given moment has come. Keep Awake asks this rather
/// than the system, so tests can move time on by hand, a night's sleep included.
@MainActor
protocol KeepAwakeClock: AnyObject {
    var now: Date { get }
    /// Calls `action` once `date` has come by the wall clock, which counts the time the
    /// Mac spends asleep: a moment that passed while it slept is called as it wakes.
    /// Returns what cancels the call.
    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> KeepAwakeAlarm
}

/// A call `KeepAwakeClock` will make, until it is cancelled.
@MainActor
protocol KeepAwakeAlarm: AnyObject {
    func cancel()
}

/// The Mac's own clock, with a dispatch timer on the wall clock for each call back.
final class WallClock: KeepAwakeClock {
    var now: Date { Date() }

    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> KeepAwakeAlarm {
        WallAlarm(at: date, action)
    }

    private final class WallAlarm: KeepAwakeAlarm {
        private let timer = DispatchSource.makeTimerSource(queue: .main)

        init(at date: Date, _ action: @escaping @MainActor () -> Void) {
            // The wall clock, not uptime, which stands still while the Mac sleeps. And a
            // leeway of our own: `asyncAfter` allows itself a tenth of the wait, up to a
            // minute, which would end an hour a minute late.
            timer.schedule(wallDeadline: .now() + max(0, date.timeIntervalSinceNow), leeway: .milliseconds(50))
            timer.setEventHandler { MainActor.assumeIsolated { action() } }
            timer.resume()
        }

        func cancel() {
            timer.cancel()
        }

        deinit {
            timer.cancel()
        }
    }
}
