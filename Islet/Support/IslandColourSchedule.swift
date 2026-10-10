import AppKit
import Observation

/// Appearance › Change colour, once an hour or once a day: the island takes one colour of
/// a list the person picks at a time, in turn or shuffled, and moves to the next on the
/// hour or at midnight. Continuously is the Rotating fill, and Never the island's own
/// colour or gradient; neither is a schedule.
///
/// Which colour shows is worked out from the clock alone, never remembered: the hour or
/// the day it is now, counted from a fixed day, picks a place in the list. So it is the
/// same after a relaunch, after the Mac has slept for days, and after the clock or the
/// time zone is changed, and it never drifts. Hours are counted as they pass, so the
/// night the clocks go forward or back no colour is skipped or shown twice, and change on
/// the hour of the time zone the Mac is in; days are the dates of the calendar where the
/// Mac is, so a day's colour changes at local midnight whatever its length.
///
/// Shuffled, the list is dealt out in rounds: each round shows every colour once, in an
/// order drawn from the round's number, and a round never starts with the colour the
/// last one ended on, so no colour comes round again before every other has shown.
struct IslandColourSchedule: Hashable, Sendable {
    enum Every: String, CaseIterable, Sendable {
        case hour, day
    }

    enum Order: String, CaseIterable, Sendable {
        case inTurn, shuffled

        var title: String {
            switch self {
            case .inTurn: "In turn"
            case .shuffled: "Shuffled"
            }
        }
    }

    /// How often the colour changes; nil while the island keeps its own (the list is kept
    /// for when it is turned on again).
    var every: Every?
    var order: Order = .inTurn
    var colours: [RGB]
    /// How far along the count of hours or days the list is taken from: set whenever the
    /// schedule is edited, so the colour showing then stays until the next change
    /// (`keeping`).
    var shift = 0

    static let colourRange = 2...12
    /// No schedule, with a list to start from: four colours that each read as a hue.
    static let standardPref = "off;inTurn;0;#5E5CE6,#FF4FA3,#0E7C86,#FF9500"

    /// Reads the stored preference: "<every>;<order>;<shift>;<colours>", where every is
    /// "off", "hour" or "day" and the colours are two to twelve "#RRGGBB" joined by commas.
    /// A field it can't read takes the standard's.
    init(pref: String) {
        let standard = Self.standardColours
        let parts = pref.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else {
            self.init(every: nil, colours: standard)
            return
        }
        let colours = parts[3].split(separator: ",").compactMap { RGB(hex: String($0)) }
        self.init(
            every: Every(rawValue: parts[0]),
            order: Order(rawValue: parts[1]) ?? .inTurn,
            colours: Self.colourRange.contains(colours.count) ? colours : standard,
            shift: Int(parts[2]) ?? 0
        )
    }

    init(every: Every?, order: Order = .inTurn, colours: [RGB], shift: Int = 0) {
        self.every = every
        self.order = order
        self.colours = colours
        self.shift = shift
    }

    private static let standardColours = [0x5E5CE6, 0xFF4FA3, 0x0E7C86, 0xFF9500].map { RGB(hex: UInt32($0)) }

    var prefValue: String {
        "\(every?.rawValue ?? "off");\(order.rawValue);\(shift);\(colours.map(\.hex).joined(separator: ","))"
    }

    // MARK: The clock's arithmetic

    /// Whole hours or whole days from a fixed day to `date`. Days are counted by the date
    /// on the calendar in `timeZone`, so a day of 23 or 25 hours counts as one. Hours are
    /// counted as they pass, moved by the part of an hour the time zone's standard time is
    /// off from GMT (India's half hour, Nepal's three quarters), so each starts on the hour
    /// there; only on Lord Howe Island, whose clocks go forward half an hour in summer, do
    /// they then start at half past.
    static func slot(of date: Date, every: Every, in timeZone: TimeZone) -> Int {
        switch every {
        case .day:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let local = calendar.dateComponents([.year, .month, .day], from: date)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let midnight = utc.date(from: local) ?? date
            return Int((midnight.timeIntervalSinceReferenceDate / 86400).rounded(.down))
        case .hour:
            let part = Double(standardPart(of: timeZone, at: date))
            return Int(((date.timeIntervalSinceReferenceDate + part) / 3600).rounded(.down))
        }
    }

    /// The next moment after `date` when the slot changes: midnight in `timeZone`, or the
    /// next hour there. Where midnight is skipped for a change of clocks, the first moment
    /// of the day.
    static func nextChange(after date: Date, every: Every, in timeZone: TimeZone) -> Date {
        switch every {
        case .day:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0, second: 0),
                                     matchingPolicy: .nextTime) ?? date.addingTimeInterval(86400)
        case .hour:
            let part = Double(standardPart(of: timeZone, at: date))
            let next = Double(slot(of: date, every: .hour, in: timeZone) + 1) * 3600 - part
            return Date(timeIntervalSinceReferenceDate: next)
        }
    }

    /// The seconds past the hour `timeZone`'s standard time is from GMT. Standard time,
    /// not the time of the moment, so a change of clocks never moves the count back.
    private static func standardPart(of timeZone: TimeZone, at date: Date) -> Int {
        let standard = timeZone.secondsFromGMT(for: date) - Int(timeZone.daylightSavingTimeOffset(for: date))
        return mod(standard, 3600)
    }

    /// The place in `colours` showing at `date`; nil with no schedule.
    func index(at date: Date, in timeZone: TimeZone) -> Int? {
        guard let every else { return nil }
        return index(atPosition: Self.slot(of: date, every: every, in: timeZone) + shift)
    }

    func colour(at date: Date, in timeZone: TimeZone) -> RGB? {
        index(at: date, in: timeZone).map { colours[$0] }
    }

    /// The place in `colours` at `position` of the count.
    func index(atPosition position: Int) -> Int {
        let n = colours.count
        guard order == .shuffled, n > 2 else { return Self.mod(position, n) }
        return Self.round(Self.div(position, n), of: n)[Self.mod(position, n)]
    }

    /// Round `round` of a shuffle of `count` colours: every place once, in an order drawn
    /// from the round's number alone. If it would start with the place the round before
    /// ended on, its first two are swapped; with three or more that never touches its
    /// last, so each round is worked out from the one before without going further back.
    static func round(_ round: Int, of count: Int) -> [Int] {
        var order = dealt(round, of: count)
        if count > 2, order[0] == dealt(round - 1, of: count)[count - 1] { order.swapAt(0, 1) }
        return order
    }

    /// A Fisher–Yates shuffle driven by SplitMix64 seeded with the round: the same on
    /// every Mac and every launch, as Swift's own hashing is not.
    private static func dealt(_ round: Int, of count: Int) -> [Int] {
        var state = UInt64(bitPattern: Int64(round)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(count) &* 0xD1B5_4A32_D192_ED03
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var order = Array(0..<count)
        for i in stride(from: count - 1, to: 0, by: -1) {
            order.swapAt(i, Int(next() % UInt64(i + 1)))
        }
        return order
    }

    /// `edited`, moved along the count so that what shows at `date` is, in order of
    /// preference: the colour showing under this schedule, if `edited` still has it; the
    /// colour now in its place, when that one was changed or taken away; or, turned on,
    /// the first. Shuffled, a fresh round starts from it, so every other colour shows
    /// before it comes round again.
    func keeping(_ edited: IslandColourSchedule, at date: Date, in timeZone: TimeZone) -> IslandColourSchedule {
        guard let every = edited.every else { return edited }
        var target = 0
        if let place = index(at: date, in: timeZone) {
            target = edited.colours.firstIndex(of: colours[place]) ?? min(place, edited.colours.count - 1)
        }
        var next = edited
        let slot = Self.slot(of: date, every: every, in: timeZone)
        let n = edited.colours.count
        if edited.order == .shuffled, n > 2 {
            // The first round from now that starts with it; failing that, unlikely as it
            // is, its place in this round.
            let first = Self.div(slot, n)
            let round = (first..<first + 64 * n).first { Self.round($0, of: n)[0] == target }
            let start = round.map { $0 * n } ?? first * n + (Self.round(first, of: n).firstIndex(of: target) ?? 0)
            next.shift = start - slot
        } else {
            next.shift = Self.mod(target - slot, n)
        }
        return next
    }

    private static func mod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }
    private static func div(_ a: Int, _ n: Int) -> Int { (a - mod(a, n)) / n }
}

/// The island's colour now, while it changes once an hour or once a day, and the change
/// the clock last made by itself, for the island to fade through.
///
/// It keeps one timer, to the next change, and none while the island keeps its own
/// colour. A timer counts only while the Mac is awake, so it also works the colour out
/// again when the Mac wakes and when the clock or the time zone is changed; and when the
/// schedule is edited, at once and without a fade.
@MainActor
@Observable
final class IslandColourClock {
    static let shared = IslandColourClock()

    /// The colour the island wears now, in place of its own; nil with no schedule.
    private(set) var colour: RGB?
    /// The last change of colour the clock made as time passed, for the island to fade.
    private(set) var change: Change?

    struct Change: Equatable {
        let from: RGB
        let to: RGB
        /// Counts changes, so two alike are still told apart.
        let serial: Int
    }

    #if DEBUG
    /// For the harness: the time and time zone in place of the Mac's.
    /// Set it, then `handle` what the Mac would post.
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var timeZone: TimeZone?
    /// For the harness: a fade posed this far from `from` to the colour now.
    var posedFade: (from: RGB, progress: Double)?
    /// For the harness: when the timer will fire, and how many are live.
    var nextFire: Date? { timer?.fireDate }
    @ObservationIgnored private(set) var liveTimers = 0
    @ObservationIgnored private(set) var timersMade = 0
    /// For the harness: as the Mac would tell it.
    func handle(_ name: Notification.Name) { observed(name) }
    #endif

    @ObservationIgnored private(set) var schedule = IslandColourSchedule(pref: IslandColourSchedule.standardPref)
    @ObservationIgnored private var pref: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var watchers: [NSObjectProtocol] = []
    @ObservationIgnored private var serial = 0

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        })
        read()
    }

    /// The time and time zone the colour is worked out in.
    private var date: Date {
        #if DEBUG
        return now()
        #else
        return Date()
        #endif
    }

    private var zone: TimeZone {
        #if DEBUG
        if let timeZone { return timeZone }
        #endif
        return .current
    }

    /// The colour showing at `date` (now, by default) and when the next change comes, for
    /// Settings.
    func showing() -> (index: Int?, next: Date?) {
        guard let every = schedule.every else { return (nil, nil) }
        return (schedule.index(at: date, in: zone), IslandColourSchedule.nextChange(after: date, every: every, in: zone))
    }

    /// `edited`, keeping the colour showing now (`IslandColourSchedule.keeping`).
    func keeping(_ edited: IslandColourSchedule) -> IslandColourSchedule {
        schedule.keeping(edited, at: date, in: zone)
    }

    /// Whether a change fades now: not with Reduce Motion or Low Power Mode on, the Mac
    /// running hot, or the island saving energy, as the moving colours hold still.
    static var fades: Bool {
        let info = ProcessInfo.processInfo
        var still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || info.isLowPowerModeEnabled
            || info.thermalState == .serious || info.thermalState == .critical
        #if DEBUG
        if let conditions = IslandMotion.shared.conditions {
            still = conditions.reduceMotion || conditions.lowPower || conditions.hot
        }
        #endif
        return !still && !EnergySaver.shared.isSaving
    }

    private func read() {
        let pref = UserDefaults.standard.string(forKey: Prefs.Key.islandColourSchedule) ?? IslandColourSchedule.standardPref
        guard pref != self.pref else { return }
        self.pref = pref
        schedule = IslandColourSchedule(pref: pref)
        watch(schedule.every != nil)
        update(byClock: false)
    }

    private func observed(_ name: Notification.Name) {
        // The system's time zone is kept until it is asked for again.
        if name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
        update(byClock: true)
    }

    /// Works out the colour for now, and sets the one timer to the next change.
    private func update(byClock: Bool) {
        let now = date
        let next = schedule.colour(at: now, in: zone)
        if next != colour {
            if byClock, let from = colour, let next {
                serial += 1
                change = Change(from: from, to: next, serial: serial)
            }
            colour = next
        }
        timer?.invalidate()
        if timer != nil { countTimer(-1) }
        timer = nil
        guard let every = schedule.every else { return }
        var fire = IslandColourSchedule.nextChange(after: now, every: every, in: zone)
        if fire <= now { fire = now.addingTimeInterval(60) }
        #if DEBUG
        // A fixed clock: the timer is set from the Mac's own, as far off as it would be.
        let fireDate = Date().addingTimeInterval(fire.timeIntervalSince(now))
        #else
        let fireDate = fire
        #endif
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(byClock: true) }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        countTimer(1)
    }

    private func countTimer(_ delta: Int) {
        #if DEBUG
        liveTimers += delta
        if delta > 0 { timersMade += 1 }
        #endif
    }

    /// Listens for the Mac waking and its clock or time zone changing only while there is
    /// a schedule.
    private func watch(_ wanted: Bool) {
        guard wanted == watchers.isEmpty else { return }
        guard wanted else {
            for watcher in watchers {
                NotificationCenter.default.removeObserver(watcher)
                NSWorkspace.shared.notificationCenter.removeObserver(watcher)
            }
            watchers = []
            return
        }
        watchers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.observed(note.name) }
        })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            watchers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.observed(note.name) }
            })
        }
    }
}

extension IslandTheme {
    /// The island's colours from the stored preferences, with the colour of the hour or
    /// the day in place of its own while it changes on a schedule.
    @MainActor
    static func current(islandPref: String, accentPref: String, fillPref: String) -> IslandTheme {
        if let colour = IslandColourClock.shared.colour {
            return cached(island: colour, accent: AccentChoice(pref: accentPref))
        }
        return cached(islandPref: islandPref, accentPref: accentPref, fillPref: fillPref)
    }
}
