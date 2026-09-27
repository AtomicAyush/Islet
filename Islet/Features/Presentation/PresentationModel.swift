import Foundation
import Observation

/// A trigger's readings, steadied: it counts as on only once it has read on for
/// `onDelay`, and as off once it has read off for `offDelay`, so a moment either way
/// changes nothing. A screenshot's flash of capture never turns Presentation Mode on,
/// and a share that stops for a moment as the person picks another window never turns
/// it off.
struct PresentationDebounce: Equatable, Sendable {
    var onDelay: TimeInterval
    var offDelay: TimeInterval
    /// The steadied state.
    private(set) var isOn = false
    /// The newest reading, and since when it has read so.
    private(set) var reading = false
    private(set) var since = Date.distantPast

    init(onDelay: TimeInterval, offDelay: TimeInterval) {
        self.onDelay = onDelay
        self.offDelay = offDelay
    }

    mutating func read(_ value: Bool, at date: Date) {
        if value != reading {
            reading = value
            since = date
        }
        settle(at: date)
    }

    /// Takes the reading as the state once it has held long enough.
    mutating func settle(at date: Date) {
        guard reading != isOn, date.timeIntervalSince(since) >= (reading ? onDelay : offDelay) else { return }
        isOn = reading
    }

    /// When the state would next change if the reading holds; `nil` while it is steady.
    var deadline: Date? {
        guard reading != isOn else { return nil }
        return since.addingTimeInterval(reading ? onDelay : offDelay)
    }
}

/// The time, and a way to be called back later: the real clock, or a test's.
@MainActor
protocol PresentationClock: AnyObject {
    var now: Date { get }
    /// Calls `action` at `date`, unless the returned closure is called first.
    func wake(at date: Date, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void
}

@MainActor
final class SystemPresentationClock: PresentationClock {
    var now: Date { Date() }

    func wake(at date: Date, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}

/// Whether Presentation Mode is on, and why. It is on while a trigger turned on in
/// Settings is on (its readings steadied, `PresentationDebounce`) and has not been
/// turned off until it ends, or while it was turned on by hand.
///
/// Turned off while triggers are on, it stays off until those end: each is set aside
/// until its readings have steadied off. Another trigger coming on meanwhile turns it
/// on again, since that is something new. Turned on by hand, it stays on until turned
/// off, whatever the triggers do.
@MainActor
@Observable
final class PresentationModel {
    struct State: Equatable, Sendable {
        var isOn = false
        /// Why, the screen first, then a call, a slideshow, and a hand last.
        var reasons: [PresentationReason] = []

        /// Whether it can end by itself: something other than a hand has it on.
        var hasTrigger: Bool { reasons.contains { $0.trigger != nil } }
    }

    /// How long each trigger must read on before it counts, and off before it stops
    /// counting. The screen waits longest: a screenshot flashes a capture for a moment,
    /// and a share restarts as the window shared changes.
    static let delays: [PresentationTrigger: (on: TimeInterval, off: TimeInterval)] = [
        .screen: (3, 5),
        .call: (2, 5),
        .slideshow: (1, 3),
    ]

    private(set) var state = State()
    /// A sample standing in for `state` while a preview runs.
    private(set) var preview: State?
    /// What to show: the preview, or the real state.
    var shown: State { preview ?? state }
    /// Turned on by hand, and on until turned off.
    private(set) var isManual = false
    /// Triggers turned off until they end.
    private(set) var setAside: Set<PresentationTrigger> = []
    /// Whether, while off, a trigger reads on but has not yet for long enough to count:
    /// a share just started, or a screenshot's moment. Personal banners wait meanwhile
    /// (`ActivityCenter.mayHoldBack`), so the first seconds of a share show nothing of
    /// the person's, while the mark and the word afterwards wait for it to count.
    private(set) var isPending = false

    /// Called after `shown` or `isPending` changes.
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored private let clock: any PresentationClock
    @ObservationIgnored private var enabled = Set(PresentationTrigger.allCases)
    @ObservationIgnored private var debounces: [PresentationTrigger: PresentationDebounce]
    /// The newest reason each trigger gave, kept while its readings steady off.
    @ObservationIgnored private var reasons: [PresentationTrigger: PresentationReason] = [:]
    @ObservationIgnored private var cancelWake: (@MainActor () -> Void)?
    @ObservationIgnored private var cancelPreview: (@MainActor () -> Void)?

    init(clock: (any PresentationClock)? = nil) {
        self.clock = clock ?? SystemPresentationClock()
        debounces = Dictionary(uniqueKeysWithValues: PresentationTrigger.allCases.map { trigger in
            let delays = Self.delays[trigger] ?? (0, 0)
            return (trigger, PresentationDebounce(onDelay: delays.on, offDelay: delays.off))
        })
    }

    // MARK: Readings

    /// A trigger's newest reading: why it is on, or `nil` for off.
    func read(_ trigger: PresentationTrigger, _ reason: PresentationReason?) {
        if let reason { reasons[trigger] = reason }
        debounces[trigger]?.read(reason != nil, at: clock.now)
        update()
    }

    /// Forgets a trigger's readings at once, as if it had never read on: what it read
    /// no longer counts (an app capturing the screen is now ignored).
    func clear(_ trigger: PresentationTrigger) {
        reasons[trigger] = nil
        debounces[trigger] = debounces[trigger].map { PresentationDebounce(onDelay: $0.onDelay, offDelay: $0.offDelay) }
        update()
    }

    /// Which triggers Settings have on. One turned off stops counting at once.
    func setEnabled(_ triggers: Set<PresentationTrigger>) {
        guard triggers != enabled else { return }
        enabled = triggers
        update()
    }

    // MARK: By hand

    func turnOn() {
        isManual = true
        update()
    }

    /// Off, and the triggers on now set aside until they end.
    func turnOff() {
        isManual = false
        setAside.formUnion(PresentationTrigger.allCases.filter { isReading($0) })
        update()
    }

    func toggle() {
        state.isOn ? turnOff() : turnOn()
    }

    /// Forgets every reading, the hand and what was set aside: the feature stopped.
    func reset() {
        isManual = false
        setAside = []
        reasons = [:]
        for trigger in PresentationTrigger.allCases {
            debounces[trigger] = debounces[trigger].map { PresentationDebounce(onDelay: $0.onDelay, offDelay: $0.offDelay) }
        }
        endPreview()
        update()
    }

    // MARK: Previews

    /// Shows `sample` in place of the real state for `length` seconds.
    func showPreview(_ sample: State, for length: TimeInterval = 8) {
        cancelPreview?()
        preview = sample
        onChange()
        cancelPreview = clock.wake(at: clock.now.addingTimeInterval(length)) { [weak self] in
            self?.endPreview()
        }
    }

    func endPreview() {
        cancelPreview?()
        cancelPreview = nil
        guard preview != nil else { return }
        preview = nil
        onChange()
    }

    // MARK: State

    /// Whether a trigger reads on now, steadied or not yet.
    private func isReading(_ trigger: PresentationTrigger) -> Bool {
        guard let debounce = debounces[trigger] else { return false }
        return debounce.isOn || debounce.reading
    }

    private func update() {
        let now = clock.now
        for trigger in PresentationTrigger.allCases { debounces[trigger]?.settle(at: now) }
        // A trigger set aside has ended once it reads off, steadied.
        setAside = setAside.filter { isReading($0) }
        let active = PresentationTrigger.allCases.filter {
            enabled.contains($0) && !setAside.contains($0) && debounces[$0]?.isOn == true
        }
        let next = State(
            isOn: isManual || !active.isEmpty,
            reasons: active.compactMap { reasons[$0] } + (isManual ? [.manual] : [])
        )
        let pending = !next.isOn && PresentationTrigger.allCases.contains { trigger in
            guard enabled.contains(trigger), !setAside.contains(trigger), let debounce = debounces[trigger] else { return false }
            return debounce.reading && !debounce.isOn
        }
        if next != state || pending != isPending {
            state = next
            isPending = pending
            if preview == nil { onChange() }
        }
        scheduleWake()
    }

    /// Wakes when a reading next settles, to look again.
    private func scheduleWake() {
        cancelWake?()
        cancelWake = nil
        guard let next = debounces.values.compactMap(\.deadline).min() else { return }
        cancelWake = clock.wake(at: next) { [weak self] in self?.update() }
    }
}
