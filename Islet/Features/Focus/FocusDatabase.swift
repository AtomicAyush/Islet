import AppKit

/// Where macOS keeps Focus, and how to make sense of it.
///
/// No public API says which Focus is on. `INFocusStatusCenter` only says whether one
/// is, and needs an entitlement Apple restricts; the Focus daemon's own service turns
/// other apps away. But the daemon keeps its state as JSON in
/// `~/Library/DoNotDisturb/DB`, which an app with Full Disk Access may read:
///
/// - `Assertions.json` — what is holding a Focus on right now
///   (`storeAssertionRecords`), and what ended earlier ones.
/// - `ModeConfigurations.json` — each Focus's name, symbol, colour and triggers.
///
/// The format is undocumented, so everything here reads it defensively: unknown keys
/// are ignored, missing ones fall back, and nothing in the files is force-unwrapped.
enum FocusDatabase {
    static let assertionsFile = "Assertions.json"
    static let configurationsFile = "ModeConfigurations.json"

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    /// One look at the database.
    enum Reading: Equatable {
        /// There is no database where macOS used to keep it: a future macOS may keep
        /// Focus somewhere else.
        case unavailable
        /// macOS refused to open it: Islet does not have Full Disk Access.
        case needsFullDiskAccess
        /// The files are there but could not be made sense of. Whatever was read last
        /// still stands; the daemon replaces them whole, so the next read will do.
        case unreadable
        case state(FocusState)
    }

    /// Reads the database in `directory`. Blocking, but the files are a few
    /// kilobytes: call it off the main thread all the same.
    static func read(directory: URL, now: Date = Date(), calendar: Calendar = .current) -> Reading {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            return isPermissionError(error) ? .needsFullDiskAccess : .unavailable
        }
        // A folder with neither file is not one this code knows how to read.
        guard names.contains(assertionsFile) || names.contains(configurationsFile) else {
            return .unavailable
        }
        do {
            // A missing file reads as empty: a Mac that has never had a Focus on has
            // no assertions yet.
            let assertions = try contents(of: assertionsFile, in: directory, listed: names)
            let configurations = try contents(of: configurationsFile, in: directory, listed: names)
            guard let state = resolve(assertions: assertions, configurations: configurations, now: now, calendar: calendar) else {
                return .unreadable
            }
            return .state(state)
        } catch {
            return isPermissionError(error) ? .needsFullDiskAccess : .unreadable
        }
    }

    private static func contents(of name: String, in directory: URL, listed names: [String]) throws -> Data {
        guard names.contains(name) else { return Data() }
        return try Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// Whether `error` is macOS refusing access, as it does for this folder without
    /// Full Disk Access: Cocoa's "no permission" (257), or EPERM or EACCES beneath it.
    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionError(underlying)
        }
        return false
    }

    // MARK: Resolving

    /// Which Focus is on at `now`, given the two files' contents (empty for a file that
    /// is not there). `nil` when either file is not JSON of the expected shape at all,
    /// so a bad read never reads as "Focus turned off".
    ///
    /// A Focus is on while something holds it: the newest assertion still standing
    /// wins, as the newest request does in the daemon (one with no start it can read
    /// counts as the oldest). With none standing, a Focus
    /// scheduled for this time of day is on, unless it was turned off since its window
    /// began.
    static func resolve(assertions: Data, configurations: Data, now: Date, calendar: Calendar = .current) -> FocusState? {
        guard let assertionStores = stores(in: assertions),
              let configurationStores = stores(in: configurations)
        else { return nil }

        var modes: [String: [String: Any]] = [:]
        for store in configurationStores {
            for (key, value) in store["modeConfigurations"] as? [String: Any] ?? [:] {
                if let configuration = value as? [String: Any] { modes[key] = configuration }
            }
        }

        let standing = assertionStores
            .flatMap { $0["storeAssertionRecords"] as? [Any] ?? [] }
            .compactMap { ($0 as? [String: Any]).map(Assertion.init(record:)) }
            // A lifetime that has run out is over, even if the daemon, asleep with the
            // Mac, has yet to say so.
            .filter { $0.end.map { $0 > now } ?? true }
        let newestFirst = standing.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
        if let named = newestFirst.first(where: { $0.modeIdentifier != nil }), let identifier = named.modeIdentifier {
            return FocusState(mode: FocusMode(identifier: identifier, configuration: modes[identifier]), until: named.end)
        }
        // The daemon keeps a record here only while a Focus is on, so one that names no
        // Focus this code can read (a future macOS moving the key, say) is still a
        // Focus: a plain one, as for a mode with no configuration, rather than none.
        if let unnamed = newestFirst.first {
            return FocusState(mode: FocusMode(identifier: "", configuration: nil), until: unnamed.end)
        }

        let endings = assertionStores.flatMap { Ending.all(in: $0, knownModes: Set(modes.keys)) }
        let scheduled = modes.compactMap { identifier, configuration -> (identifier: String, window: DateInterval)? in
            let windows = Schedule.all(in: configuration).compactMap { $0.window(containing: now, calendar: calendar) }
            guard let window = windows.max(by: { $0.start < $1.start }),
                  !endings.contains(where: { $0.ends(identifier, since: window.start) })
            else { return nil }
            return (identifier, window)
        }
        // Where two schedules overlap, people report that the Focus already on stays
        // on through the second one's start, so the window that opened first wins.
        if let first = scheduled.min(by: { $0.window.start < $1.window.start }) {
            return FocusState(mode: FocusMode(identifier: first.identifier, configuration: modes[first.identifier]), until: first.window.end)
        }
        return .off
    }

    /// The `data` entries of one file: `{"data": [{…}], "header": {…}}`. An empty file
    /// has none; anything that is not a JSON object is `nil`.
    private static func stores(in data: Data) -> [[String: Any]]? {
        guard !data.isEmpty else { return [] }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (root["data"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// Seconds since 2001, the way every date in the database is kept.
    private static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    // MARK: Assertions

    /// Something holding a Focus on: Control Center, a shortcut, a schedule.
    private struct Assertion {
        /// `nil` when the record names no mode this code can read.
        var modeIdentifier: String?
        /// `nil` when the record has no start this code can read.
        var start: Date?
        /// When it lets go by itself, where the record says.
        var end: Date?

        init(record: [String: Any]) {
            let details = record["assertionDetails"] as? [String: Any] ?? [:]
            let mode = details["assertionDetailsModeIdentifier"] as? String ?? ""
            modeIdentifier = mode.isEmpty ? nil : mode
            start = FocusDatabase.date(record["assertionStartDateTimestamp"])
            end = Self.end(of: details, after: start)
        }

        /// A Focus turned on "for 1 hour" or "until this evening" says when it ends.
        /// The daemon writes the time it shows people as `…UserVisibleEndDate` (seen
        /// on a scheduled Sleep); the lifetime it keeps (`assertionDetailsLifetime`)
        /// has no published shape, so any end found in it is taken. Neither there —
        /// "until I leave", "until turned off", a lifetime tied to a schedule, which
        /// names the schedule but no time — means `nil`.
        ///
        /// Every end is measured against a start, and must be `plausible` after it; so
        /// with no start to measure against, an end is not trusted, and the Focus reads
        /// as on until turned off rather than as over (a duration counted from nothing
        /// would have ended it long ago).
        private static func end(of details: [String: Any], after start: Date?) -> Date? {
            if let start, let end = FocusDatabase.date(details["assertionDetailsUserVisibleEndDate"]),
               let plausible = plausible(end, after: start) {
                return plausible
            }
            let lifetimes = details.filter { $0.key.localizedCaseInsensitiveContains("lifetime") }.map(\.value)
            return lifetimes.compactMap { latestEnd(in: $0, after: start) }.max()
        }

        /// `end`, if it is from a minute after `start` to a year after it, so a stray
        /// number cannot end a Focus the moment it began, or keep one on for ever (or
        /// name a day of the week that is years away).
        private static func plausible(_ end: Date, after start: Date) -> Date? {
            let length = end.timeIntervalSince(start)
            return length >= 60 && length < 366 * 24 * 60 * 60 ? end : nil
        }

        /// The latest plausible end anywhere in `value`. An end is either a number
        /// under a key named for a date, a timestamp or an end, but not for a start (a
        /// lifetime may well restate its own start a few milliseconds after the
        /// assertion's), or a duration: the shape a `DateInterval` takes when it is
        /// written out as `{"start": …, "duration": …}`. Both are measured from a start
        /// beside them, or else the assertion's.
        private static func latestEnd(in value: Any, after start: Date?) -> Date? {
            var ends: [Date] = []
            if let dictionary = value as? [String: Any] {
                let ownStart = dictionary.lazy
                    .filter { $0.key.localizedCaseInsensitiveContains("start") }
                    .compactMap { FocusDatabase.date($0.value) }
                    .first
                let start = ownStart ?? start
                for (key, value) in dictionary {
                    let key = key.lowercased()
                    if key.contains("duration"), let seconds = (value as? NSNumber)?.doubleValue, seconds.isFinite {
                        if let start, let end = plausible(start.addingTimeInterval(seconds), after: start) { ends.append(end) }
                    } else if !key.contains("start"),
                              key.contains("date") || key.contains("timestamp") || key.hasSuffix("end"),
                              let date = FocusDatabase.date(value) {
                        if let start, let end = plausible(date, after: start) { ends.append(end) }
                    } else if let end = latestEnd(in: value, after: start) {
                        ends.append(end)
                    }
                }
            } else if let array = value as? [Any] {
                ends += array.compactMap { latestEnd(in: $0, after: start) }
            }
            return ends.max()
        }
    }

    /// A Focus being ended: an assertion that was invalidated, or a request to end
    /// Focus ("any", or particular modes). Only a scheduled Focus looks at these, to
    /// learn it was turned off before its window closed.
    private struct Ending {
        var date: Date
        /// The modes it ended; `nil` for all of them.
        var modes: Set<String>?

        func ends(_ mode: String, since start: Date) -> Bool {
            date >= start && (modes?.contains(mode) ?? true)
        }

        static func all(in store: [String: Any], knownModes: Set<String>) -> [Ending] {
            let invalidated = (store["storeInvalidationRecords"] as? [Any] ?? []).compactMap { item -> Ending? in
                guard let record = item as? [String: Any],
                      let date = FocusDatabase.date(record["invalidationDateTimestamp"]),
                      let assertion = record["invalidationAssertion"] as? [String: Any],
                      let details = assertion["assertionDetails"] as? [String: Any],
                      let mode = details["assertionDetailsModeIdentifier"] as? String
                else { return nil }
                return Ending(date: date, modes: [mode])
            }
            let requested = (store["storeInvalidationRequestRecords"] as? [Any] ?? []).compactMap { item -> Ending? in
                guard let record = item as? [String: Any],
                      let date = FocusDatabase.date(record["invalidationRequestDateTimestamp"])
                else { return nil }
                // Control Center's "off" asks to end "any". A predicate naming modes
                // ends those; one whose shape is unknown is taken to end them all,
                // since ending Focus is what a request is for.
                let predicate = record["invalidationRequestPredicate"] as? [String: Any] ?? [:]
                let named = strings(in: predicate).intersection(knownModes)
                let isAny = predicate["invalidationPredicateType"] as? String == "any"
                return Ending(date: date, modes: isAny || named.isEmpty ? nil : named)
            }
            return invalidated + requested
        }

        private static func strings(in value: Any) -> Set<String> {
            if let string = value as? String { return [string] }
            if let dictionary = value as? [String: Any] {
                return dictionary.values.reduce(into: []) { $0.formUnion(strings(in: $1)) }
            }
            if let array = value as? [Any] {
                return array.reduce(into: []) { $0.formUnion(strings(in: $1)) }
            }
            return []
        }
    }

    // MARK: Schedules

    /// A Focus set to turn on at the same time on chosen days
    /// (`DNDModeConfigurationScheduleTrigger`).
    ///
    /// Best effort, and small on purpose: recent macOS also writes an assertion when a
    /// schedule starts, which is read above. This is for when it has not. It knows
    /// nothing of Smart Activation, location, app or Sleep triggers, and reads the
    /// weekday mask as community tools do (Monday in the lowest bit, Sunday in the
    /// seventh); Apple documents none of it.
    struct Schedule: Equatable {
        /// Minutes after midnight.
        var start: Int
        var end: Int
        /// Monday in bit 0 … Sunday in bit 6. `nil` when the trigger does not say,
        /// which is read as every day.
        var weekdays: Int?

        /// Every switched-on schedule trigger in a mode's configuration.
        static func all(in configuration: [String: Any]) -> [Schedule] {
            let triggers = (configuration["triggers"] as? [String: Any])?["triggers"] as? [Any] ?? []
            return triggers.compactMap { item in
                guard let trigger = item as? [String: Any],
                      trigger["class"] as? String == "DNDModeConfigurationScheduleTrigger",
                      // 2 is on; 1 is off, and 0 has been seen on triggers never set up.
                      (trigger["enabledSetting"] as? NSNumber)?.intValue == 2,
                      let startHour = (trigger["timePeriodStartTimeHour"] as? NSNumber)?.intValue,
                      let endHour = (trigger["timePeriodEndTimeHour"] as? NSNumber)?.intValue
                else { return nil }
                let startMinute = (trigger["timePeriodStartTimeMinute"] as? NSNumber)?.intValue ?? 0
                let endMinute = (trigger["timePeriodEndTimeMinute"] as? NSNumber)?.intValue ?? 0
                return Schedule(
                    start: startHour * 60 + startMinute,
                    end: endHour * 60 + endMinute,
                    weekdays: (trigger["timePeriodWeekdays"] as? NSNumber)?.intValue
                )
            }
        }

        /// The window this schedule has open at `date`, if one is. A window whose end
        /// is before its start runs past midnight, and belongs to the day it began.
        ///
        /// Its bounds are the clock times on the day, not minutes counted on from
        /// midnight, so a day an hour short or long (a daylight saving change) moves
        /// neither. A start in the hour skipped in spring is the first minute after it.
        func window(containing date: Date, calendar: Calendar) -> DateInterval? {
            guard start != end, (0..<24 * 60).contains(start), (0..<24 * 60).contains(end) else { return nil }
            let today = calendar.startOfDay(for: date)
            let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)

            let day: Date
            if start < end {
                guard minute >= start, minute < end else { return nil }
                day = today
            } else if minute >= start {
                day = today
            } else if minute < end, let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
                day = yesterday
            } else {
                return nil
            }

            guard includes(day, calendar: calendar),
                  let closingDay = start < end ? day : calendar.date(byAdding: .day, value: 1, to: day),
                  let opened = calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: day),
                  let closed = calendar.date(bySettingHour: end / 60, minute: end % 60, second: 0, of: closingDay),
                  opened <= date, date < closed
            else { return nil }
            return DateInterval(start: opened, end: closed)
        }

        private func includes(_ day: Date, calendar: Calendar) -> Bool {
            guard let weekdays else { return true }
            // Calendar counts Sunday as 1 … Saturday as 7; the mask starts at Monday.
            let bit = (calendar.component(.weekday, from: day) + 5) % 7
            return weekdays & (1 << bit) != 0
        }
    }
}

/// Which Focus is on, as the database has it.
struct FocusState: Equatable, Sendable {
    /// The Focus that is on; `nil` when none is.
    var mode: FocusMode?
    /// When it is due to end, where the database says: a Focus turned on for an hour,
    /// or a schedule's end.
    var until: Date?

    static let off = FocusState()
}

/// One Focus: Do Not Disturb, Sleep, Work, or one of the person's own.
struct FocusMode: Equatable, Sendable {
    /// `com.apple.focus.work` and the like; empty for a Focus the database has on
    /// without saying which.
    var identifier: String
    var name: String
    /// An SF Symbol this Mac can draw.
    var symbol: String
    var tint: FocusTint

    init(identifier: String, name: String, symbol: String, tint: FocusTint) {
        self.identifier = identifier
        self.name = name
        self.symbol = symbol
        self.tint = tint
    }

    /// The mode as configured in ModeConfigurations.json; with no configuration (a
    /// Focus made on another device and not synced yet, say, or one not named at
    /// all), a plain "Focus".
    init(identifier: String, configuration: [String: Any]?) {
        let mode = configuration?["mode"] as? [String: Any] ?? [:]
        let name = (mode["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            identifier: identifier,
            name: name.isEmpty ? "Focus" : name,
            symbol: Self.drawable(mode["symbolImageName"] as? String),
            tint: FocusTint(systemColorName: mode["tintColorName"] as? String) ?? .indigo
        )
    }

    /// Some of the Focus's own symbols come from a private catalogue other apps cannot
    /// draw. These stand in for the ones seen so far, each chosen to read as the same
    /// thing at the indicator's 11 points (the public `lanyardcard.fill`, without its
    /// person, reads as a phone there); anything else unknown is a moon.
    private static let standIns = [
        "person.lanyardcard.fill": "briefcase.fill",
        "rocket.fill": "gamecontroller.fill",
    ]

    static func drawable(_ symbol: String?) -> String {
        for name in [symbol, symbol.flatMap { standIns[$0] }].compactMap({ $0 }) where !name.isEmpty {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return name }
        }
        return "moon.fill"
    }
}

/// A Focus's colour, one of the system colours it is configured with by name
/// (`"systemIndigoColor"`).
enum FocusTint: String, CaseIterable, Sendable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    /// Reads `systemIndigoColor`, `systemIndigo` or `indigo` alike, and the numbered
    /// greys as grey. `nil` for anything else.
    init?(systemColorName name: String?) {
        guard var name = name?.lowercased() else { return nil }
        if name.hasPrefix("system") { name.removeFirst("system".count) }
        if name.hasSuffix("color") { name.removeLast("color".count) }
        name = name.trimmingCharacters(in: .decimalDigits)
        if name == "grey" { name = "gray" }
        self.init(rawValue: name)
    }
}
