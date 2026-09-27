import Foundation
import IOKit.pwr_mgt
import Observation

/// Keeping the Mac awake: one session at a time, for a length or until turned off, with
/// a power assertion held for exactly as long as it runs and not a moment longer.
///
/// A timed session ends at a time on the wall clock, not after so much running time, so
/// one that ran out while the Mac slept with its lid closed is over when it wakes.
@MainActor
@Observable
final class KeepAwakeModel {
    struct Session: Equatable {
        /// When it began, for the ring.
        var start: Date
        /// When it ends. `nil` keeps the Mac awake until turned off.
        var end: Date?

        /// Time left, or `nil` until turned off.
        func remaining(at date: Date) -> TimeInterval? {
            end.map { max(0, $0.timeIntervalSince(date)) }
        }

        /// Fraction left, 1 at the start and 0 at the end; 1 throughout until turned off.
        func progress(at date: Date) -> Double {
            guard let end else { return 1 }
            let length = end.timeIntervalSince(start)
            guard length > 0 else { return 0 }
            return min(1, max(0, end.timeIntervalSince(date) / length))
        }
    }

    /// The name `pmset -g assertions` lists the assertion under, so it can be told from
    /// other apps' at a glance.
    nonisolated static let assertionName = "Islet: Keep Awake"
    /// The longest a timed session runs, lengthened or not. Past a day, until turned off
    /// is what is meant.
    nonisolated static let longest: TimeInterval = 24 * 3600

    /// The session running, if any.
    private(set) var session: Session?
    /// A made-up session a preview shows in place of the real one. It holds no
    /// assertion: the Mac sleeps as it would.
    private(set) var preview: Session?

    /// What the island shows: a preview over the real session.
    var shown: Session? { preview ?? session }
    var isOn: Bool { session != nil }

    /// Holds off only the Mac's sleep, and lets the display sleep as it would. Changed
    /// while a session runs, the assertion is swapped for the other kind, the new one
    /// taken before the old one goes, so the Mac is never left unheld in between.
    var letsDisplaySleep = false {
        didSet {
            guard letsDisplaySleep != oldValue, held != nil else { return }
            swapAssertion()
        }
    }

    /// Called whenever what is shown changes, so the activity can show or end.
    @ObservationIgnored var onChange: () -> Void = {}
    /// Called once when a timed session runs out, as it releases the Mac. Not called
    /// when a session is stopped.
    @ObservationIgnored var onFinish: () -> Void = {}

    @ObservationIgnored private let assertions: any PowerAssertions
    @ObservationIgnored private let clock: any KeepAwakeClock
    @ObservationIgnored private var held: (id: IOPMAssertionID, kind: PowerAssertionKind)?
    @ObservationIgnored private var alarm: KeepAwakeAlarm?

    init(assertions: any PowerAssertions, clock: any KeepAwakeClock) {
        self.assertions = assertions
        self.clock = clock
    }

    /// Keeps the Mac awake for `length` from now, up to `longest`, or until turned off
    /// with `nil`. A session already running takes the new length, from now, keeping
    /// the assertion it holds. Returns false, changing nothing, for a length that is no
    /// length or when macOS will not give an assertion.
    @discardableResult
    func start(for length: TimeInterval?) -> Bool {
        if let length, !(length.isFinite && length > 0) { return false }
        guard hold() else { return false }
        let now = clock.now
        preview = nil
        session = Session(start: now, end: length.map { now.addingTimeInterval(min($0, Self.longest)) })
        scheduleEnd()
        onChange()
        return true
    }

    /// Adds `seconds` to a timed session, never past `longest` from now; a session
    /// until turned off has nothing to add to. With no session, it lengthens a preview.
    func extend(by seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        if session != nil {
            guard let lengthened = lengthened(session, by: seconds) else { return }
            session = lengthened
            scheduleEnd()
        } else {
            guard let lengthened = lengthened(preview, by: seconds) else { return }
            preview = lengthened
        }
        onChange()
    }

    /// Lets the Mac sleep again, ending the session (and any preview) without a word.
    func stop() {
        guard session != nil || preview != nil || held != nil else { return }
        alarm?.cancel()
        alarm = nil
        release()
        session = nil
        preview = nil
        onChange()
    }

    /// Ends a session whose time has come, and otherwise sets the call for its end
    /// again. Its alarm calls it, and so does the Mac waking or its clock being changed:
    /// the alarm should see to both, and this makes sure.
    func settle() {
        guard let end = session?.end else { return }
        if clock.now >= end {
            finish()
        } else {
            scheduleEnd()
        }
    }

    // MARK: Previews

    /// Shows a made-up session, lasting `length` from now or until turned off, until
    /// `endPreview()`. It takes no assertion, and never shows over a real session.
    func showPreview(length: TimeInterval?) {
        guard session == nil else { return }
        let now = clock.now
        preview = Session(start: now, end: length.map { now.addingTimeInterval(min($0, Self.longest)) })
        onChange()
    }

    func endPreview() {
        guard preview != nil else { return }
        preview = nil
        onChange()
    }

    // MARK: Private

    private func lengthened(_ session: Session?, by seconds: TimeInterval) -> Session? {
        guard var session, let end = session.end else { return nil }
        let now = clock.now
        // The start stays where it was, so the ring fills by the share of the whole
        // session that was added, rather than jumping back to full.
        session.end = min(max(end, now).addingTimeInterval(seconds), now.addingTimeInterval(Self.longest))
        return session
    }

    private func finish() {
        guard session != nil else { return }
        alarm?.cancel()
        alarm = nil
        release()
        session = nil
        onChange()
        onFinish()
    }

    private func scheduleEnd() {
        alarm?.cancel()
        alarm = nil
        guard let end = session?.end else { return }
        alarm = clock.schedule(at: end) { [weak self] in self?.settle() }
    }

    private var wantedKind: PowerAssertionKind { letsDisplaySleep ? .system : .display }

    /// Takes the assertion, unless it is already held. Whether one is now held.
    private func hold() -> Bool {
        if held != nil { return true }
        guard let id = assertions.create(wantedKind, name: Self.assertionName) else { return false }
        held = (id, wantedKind)
        return true
    }

    private func swapAssertion() {
        guard let old = held, old.kind != wantedKind else { return }
        // Keep the old one if macOS will not give the new one: the Mac stays awake as
        // it was asked to, if with its display on.
        guard let id = assertions.create(wantedKind, name: Self.assertionName) else { return }
        held = (id, wantedKind)
        assertions.release(old.id)
    }

    private func release() {
        guard let held else { return }
        self.held = nil
        assertions.release(held.id)
    }
}
