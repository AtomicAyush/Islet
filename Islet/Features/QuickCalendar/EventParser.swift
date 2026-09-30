import Foundation

/// An event as read from what was typed: "Dentist tomorrow 3pm", "lunch at Nando's at 1",
/// "Standup 15:00–15:30". Read again with every key, and never kept.
struct ParsedEvent: Equatable {
    struct Flags: OptionSet, Hashable {
        let rawValue: Int
        /// An hour typed without am or pm ("at 3"), or a part of the day ("morning"),
        /// taken as the likelier: shown with a "?" until it is confirmed.
        static let guessedHour = Flags(rawValue: 1 << 0)
        /// A time with no day that has passed today, taken as tomorrow's.
        static let rolledToTomorrow = Flags(rawValue: 1 << 1)
        /// Today's weekday with its time passed, taken as next week's.
        static let rolledToNextWeek = Flags(rawValue: 1 << 2)
        /// A place read from "at …", shown as a guess.
        static let guessedLocation = Flags(rawValue: 1 << 3)
        /// A time typed in another time zone ("3pm PT").
        static let foreignTimeZone = Flags(rawValue: 1 << 4)
        /// A day was typed.
        static let hasDay = Flags(rawValue: 1 << 5)
        /// A time was typed.
        static let hasTime = Flags(rawValue: 1 << 6)
        /// It ends the day after it starts ("8pm–midnight").
        static let crossesMidnight = Flags(rawValue: 1 << 7)
        /// A link to a video call was typed: it is online, and has no place to get to.
        static let online = Flags(rawValue: 1 << 8)
    }

    var title = ""
    /// `nil` while nothing typed says when.
    var start: Date?
    var end: Date?
    var isAllDay = false
    var location: String?
    var url: URL?
    var flags: Flags = []
    /// The time as typed in another zone, for the preview: "3 pm PT".
    var typedZone: String?

    var hasWhen: Bool { start != nil }
}

/// Reads an event from a line of text, by rules alone: the same line always gives the
/// same event for the same moment, instantly, and nothing is sent anywhere. The moment,
/// the calendar (with its time zone) and the locale are handed in, so it can be tested.
///
/// It understands days (today, tonight, tomorrow, weekdays, "next tue", "Oct 3", "3rd of
/// October", "3/10" in the locale's order, "2026-10-03", "in 2 days"), times ("3pm",
/// "3:30", "15:00", "0930", "noon", "at 3", "half 3", "quarter to 4", "morning"), ranges
/// ("3–4pm", "from 3 to 4:30", "8pm–midnight", "till 1am"), lengths ("for 90 min", "1h",
/// "1.5 hours", "half an hour", "2h30"), time zones ("3pm PT") and a place after "at".
/// What is left is the title. "Next tue" is the next Tuesday to come.
struct EventParser {
    var now: Date
    var calendar: Calendar
    /// How long an event lasts when nothing typed says.
    var defaultMinutes = 60

    init(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current, defaultMinutes: Int = 60) {
        self.now = now
        var calendar = calendar
        calendar.locale = locale
        self.calendar = calendar
        self.defaultMinutes = defaultMinutes
    }

    func parse(_ text: String) -> ParsedEvent {
        var scan = Scan(text)
        var result = ParsedEvent()

        // Links first: their digits and words are not times or titles.
        if let links = Self.linkDetector {
            let found = links.matches(in: text, range: scan.whole)
            for match in found where !scan.isTaken(match.range) {
                scan.take(match.range)
                if result.url == nil, let url = match.url { result.url = url }
            }
            if let url = result.url, MeetingLink.find(url: url, in: [], detector: nil) != nil { result.flags.insert(.online) }
        }

        var day: Day?
        var relativeStart: Date?
        if let match = scan.first(Self.relative) {
            scan.take(match.range)
            let amount = Self.amount(scan.string(match, 1))
            let unit = scan.string(match, 2)?.lowercased() ?? ""
            if unit.hasPrefix("d") || unit.hasPrefix("w") {
                day = Day(offset: Int(amount) * (unit.hasPrefix("w") ? 7 : 1))
            } else {
                let minutes = unit.hasPrefix("h") ? amount * 60 : amount
                relativeStart = now.addingTimeInterval((minutes * 60).rounded())
            }
        }
        if day == nil { day = findDay(&scan) }
        let dayRange = day == nil ? nil : scan.taken.last

        var wantsAllDay = false
        if let match = scan.first(Self.allDay) {
            scan.take(match.range)
            wantsAllDay = true
        }

        // A length, before times: "1.25 hours" is not a quarter past one.
        var minutes: Int?
        if let match = scan.first(Self.duration) {
            scan.take(match.range)
            minutes = Self.durationMinutes(scan, match)
        }

        var start: Clock?
        var end: Clock?
        var zone: (TimeZone, String)?
        if let match = scan.first(Self.range), let range = range(scan, match, day: day) {
            scan.take(match.range)
            (start, end) = range
            zone = Self.zone(scan.string(match, 11))
        } else if let match = scan.first(Self.spoken), let clock = Self.spokenClock(scan, match) {
            scan.take(match.range)
            start = clock
        } else if let match = scan.first(Self.single) {
            scan.take(match.range)
            let clock = Self.clock(scan, match, hour: 1, minute: 2, meridiem: 3)
                ?? Self.clock(scan, match, hour: 4, minute: 5, meridiem: nil)
                ?? Self.clock(scan, match, hour: 6, minute: 7, meridiem: nil, twentyFour: true)
                ?? Self.named(scan.string(match, 8))
            // "till 1am" says when it ends.
            if scan.follows(match.range.location, words: ["till", "til", "until"]) { end = clock } else { start = clock }
            zone = Self.zone(scan.string(match, 9))
        } else if let match = scan.first(Self.bareAt) ?? bareBesideDay(scan, dayRange: dayRange) {
            scan.take(match.range)
            start = Self.clock(scan, match, hour: 1, minute: nil, meridiem: 2)
        }
        if start == nil, let match = scan.first(Self.partOfDay) {
            scan.take(match.range)
            start = Self.partOfDay(scan.string(match, 1))
        }
        if start == nil, day?.isTonight == true {
            start = Clock(hour: 19, minute: 0, guessed: true)
        }
        // An end alone, with nothing to start it, is the start after all.
        if start == nil, let lone = end {
            start = lone
            end = nil
        }

        // A place, and the title: what is left.
        var words = scan.leftover()
        if let place = Self.place(in: &words) {
            result.location = place
            result.flags.insert(.guessedLocation)
        }
        result.title = Self.title(words)

        // When.
        if day != nil { result.flags.insert(.hasDay) }
        if start != nil { result.flags.insert(.hasTime) }
        if let zone, zone.0.identifier != calendar.timeZone.identifier,
           zone.0.secondsFromGMT(for: now) != calendar.timeZone.secondsFromGMT(for: now) {
            result.flags.insert(.foreignTimeZone)
        }
        if let relativeStart, start == nil, day == nil {
            result.flags.insert(.hasTime)
            result.start = relativeStart
            result.end = relativeStart.addingTimeInterval(TimeInterval((minutes ?? defaultMinutes) * 60))
            return result
        }
        guard var start, !wantsAllDay else {
            guard wantsAllDay || day != nil, let date = date(of: day ?? Day(offset: 0)) else { return result }
            result.isAllDay = true
            result.start = date
            result.end = calendar.date(byAdding: .day, value: 1, to: date)
            return result
        }
        let leaning: Clock.Leaning = day?.isTonight == true ? .tonight : Self.isEvening(result.title) ? .evening : .day
        start = start.resolved(leaning)
        if start.guessed { result.flags.insert(.guessedHour) }

        let zoneCalendar: Calendar = {
            guard let zone, result.flags.contains(.foreignTimeZone) else { return calendar }
            var other = calendar
            other.timeZone = zone.0
            return other
        }()
        var offset = 0
        guard let baseDay = date(of: day ?? Day(offset: 0)),
              var startDate = moment(on: baseDay, start, in: zoneCalendar) else { return result }
        var startDay = baseDay
        if startDate <= now {
            // Tonight's time that has gone is tomorrow night's, like a time with no day.
            if day == nil || day?.isTonight == true {
                offset = 1
                result.flags.insert(.rolledToTomorrow)
            } else if day?.isWeekday == true, day?.offset == 0 {
                offset = 7
                result.flags.insert(.rolledToNextWeek)
            }
            if offset > 0, let later = calendar.date(byAdding: .day, value: offset, to: baseDay),
               let moved = moment(on: later, start, in: zoneCalendar) {
                startDate = moved
                startDay = later
            }
        }
        result.start = startDate
        if let zone, result.flags.contains(.foreignTimeZone) {
            result.typedZone = start.spoken + " " + zone.1.uppercased()
        }

        if var end {
            end = end.resolved(after: start)
            let minutes = start.hour * 60 + start.minute + end.minutes(since: start)
            result.end = moment(on: startDay, Clock(hour: minutes / 60, minute: minutes % 60), in: zoneCalendar)
        } else {
            result.end = startDate.addingTimeInterval(TimeInterval((minutes ?? defaultMinutes) * 60))
        }
        // Ending at midnight counts: the event runs up to the next day.
        if let end = result.end, !calendar.isDate(startDate, inSameDayAs: end) {
            result.flags.insert(.crossesMidnight)
        }
        return result
    }

    // MARK: Days

    /// A day typed: some days from today, a weekday, or a date.
    struct Day: Equatable {
        var offset: Int?
        var date: DateComponents?
        var isWeekday = false
        var isTonight = false
    }

    private func findDay(_ scan: inout Scan) -> Day? {
        if let match = scan.first(Self.relativeDay) {
            scan.take(match.range)
            switch scan.string(match, 1)?.lowercased().replacingOccurrences(of: "  ", with: " ") ?? "" {
            case let word where word.hasPrefix("day after"): return Day(offset: 2)
            case "today": return Day(offset: 0)
            case "tonight": return Day(offset: 0, isTonight: true)
            default: return Day(offset: 1)
            }
        }
        if let match = Self.weekday.matches(in: scan.text as String, range: scan.whole)
            .first(where: { !scan.isTaken($0.range) && Self.isWeekday(scan, $0) }) {
            scan.take(match.range)
            let isNext = scan.string(match, 1)?.lowercased() == "next"
            let name = scan.string(match, 2)?.lowercased() ?? ""
            let target = Self.weekdays.firstIndex { name.hasPrefix($0) }.map { $0 + 1 } ?? 1
            let today = calendar.component(.weekday, from: now)
            var ahead = (target - today + 7) % 7
            if ahead == 0, isNext { ahead = 7 }
            return Day(offset: ahead, isWeekday: true)
        }
        if let match = scan.first(Self.iso) {
            scan.take(match.range)
            return Day(date: DateComponents(year: scan.int(match, 1), month: scan.int(match, 2), day: scan.int(match, 3)))
        }
        // Whichever is written first: "12 Oct 10:30" is the 12th, "Oct 3 10:30" the 3rd.
        let written = [(scan.first(monthFirst), true), (scan.first(dayFirst), false)]
            .compactMap { match, isMonthFirst in match.map { ($0, isMonthFirst) } }
            .sorted { $0.0.range.location < $1.0.range.location }
        for (match, isMonthFirst) in written {
            let month = monthNumber(scan.string(match, isMonthFirst ? 1 : 2))
            let dayOfMonth = scan.int(match, isMonthFirst ? 2 : 1)
            if let month, let dayOfMonth, (1...31).contains(dayOfMonth) {
                scan.take(match.range)
                return Day(date: dated(month: month, day: dayOfMonth, year: scan.int(match, 3)))
            }
        }
        if let match = scan.first(Self.numeric) {
            let first = scan.int(match, 1) ?? 0, second = scan.int(match, 2) ?? 0
            let (dayOfMonth, month) = Self.isDayFirst(calendar.locale ?? .current) ? (first, second) : (second, first)
            if (1...12).contains(month), (1...31).contains(dayOfMonth) {
                scan.take(match.range)
                var year = scan.int(match, 3)
                if let short = year, short < 100 { year = 2000 + short }
                return Day(date: dated(month: month, day: dayOfMonth, year: year))
            }
        }
        return nil
    }

    /// A weekday's three letters are words too ("sat nav", "sun lounger"): they are a day
    /// only with a capital, after "this", "next" or "on", with a full stop, or beside a
    /// time.
    private static func isWeekday(_ scan: Scan, _ match: NSTextCheckingResult) -> Bool {
        guard let name = scan.string(match, 2), name.count == 3 else { return true }
        if scan.string(match, 1) != nil || name.first?.isUppercase == true || scan.string(match, 0)?.hasSuffix(".") == true {
            return true
        }
        let after = scan.text.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespaces)
        let before = scan.text.substring(to: match.range.location).trimmingCharacters(in: .whitespaces).lowercased()
        return after.first?.isNumber == true || before.last?.isNumber == true
            || before.range(of: #"\d\s*[ap]\.?m\.?$"#, options: .regularExpression) != nil
    }

    /// A day and month without a year: this year's, or next year's once this year's
    /// has gone.
    private func dated(month: Int, day: Int, year: Int?) -> DateComponents {
        if let year { return DateComponents(year: year, month: month, day: day) }
        let thisYear = calendar.component(.year, from: now)
        let today = calendar.startOfDay(for: now)
        if let date = calendar.date(from: DateComponents(year: thisYear, month: month, day: day)), date < today {
            return DateComponents(year: thisYear + 1, month: month, day: day)
        }
        return DateComponents(year: thisYear, month: month, day: day)
    }

    /// The day's start, in the calendar's time zone.
    private func date(of day: Day) -> Date? {
        if let components = day.date {
            guard let date = calendar.date(from: components),
                  calendar.component(.day, from: date) == components.day else { return nil }
            return calendar.startOfDay(for: date)
        }
        return calendar.date(byAdding: .day, value: day.offset ?? 0, to: calendar.startOfDay(for: now))
    }

    /// `clock` on `day` (a local day), read in `zoneCalendar`'s time zone: the time on the
    /// clock, so it holds on the days the clocks change. From 24 on, the hours run into the
    /// next day.
    private func moment(on day: Date, _ clock: Clock, in zoneCalendar: Calendar) -> Date? {
        let minutes = clock.hour * 60 + clock.minute
        guard let local = calendar.date(byAdding: .day, value: minutes / (24 * 60), to: day) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: local)
        components.hour = minutes % (24 * 60) / 60
        components.minute = minutes % 60
        return zoneCalendar.date(from: components)
    }

    private func monthNumber(_ name: String?) -> Int? {
        guard let name = name?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return nil }
        if let index = Self.englishMonths.firstIndex(where: { name.hasPrefix($0) }) { return index + 1 }
        let symbols = [calendar.monthSymbols, calendar.shortMonthSymbols]
        for list in symbols {
            if let index = list.firstIndex(where: { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == name }) {
                return index + 1
            }
        }
        return nil
    }

    static func isDayFirst(_ locale: Locale) -> Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "dM", options: 0, locale: locale) ?? "d/M"
        guard let d = format.firstIndex(of: "d"), let m = format.firstIndex(of: "M") else { return true }
        return d < m
    }

    // MARK: Times

    /// A time of day as typed: an hour and minute, and whether it is known to be
    /// morning or afternoon.
    struct Clock: Equatable {
        var hour: Int
        var minute: Int
        /// `true` for pm, `false` for am, `nil` as typed without either.
        var isPM: Bool?
        /// Typed as a 24-hour time ("15:00", "09:30"): exactly that.
        var isExact = false
        var guessed = false
        /// Midnight at the end of a range: the next day's start.
        var isMidnight = false

        init(hour: Int, minute: Int, isPM: Bool? = nil, isExact: Bool = false, guessed: Bool = false, isMidnight: Bool = false) {
            self.hour = hour
            self.minute = minute
            self.isPM = isPM
            self.isExact = isExact
            self.guessed = guessed
            self.isMidnight = isMidnight
        }

        /// Which way an hour typed with neither am nor pm is taken.
        enum Leaning {
            /// 1 to 6 in the afternoon, 7 to 11 in the morning, and 12 noon.
            case day
            /// For an evening's event (dinner, drinks): 1 to 11 in the afternoon or evening.
            case evening
            /// Tonight: 5 to 11 in the evening, 12 midnight, and 1 to 4 the small hours
            /// after it, as is any time in the morning.
            case tonight
        }

        /// In 24 hours, the likelier way for an hour with neither am nor pm, which is then
        /// a guess. Hours from 24 on are the next day's.
        func resolved(_ leaning: Leaning = .day) -> Clock {
            var clock = self
            if isMidnight {
                clock.hour = 24
                return clock
            }
            if let isPM {
                clock.hour = hour % 12 + (isPM ? 12 : 0) + (leaning == .tonight && !isPM ? 24 : 0)
                clock.isPM = isPM
                return clock
            }
            if isExact || hour == 0 || hour > 12 {
                if leaning == .tonight, hour < 5 { clock.hour += 24 }
                return clock
            }
            if hour == 12, leaning != .tonight {
                clock.isPM = true
                if leaning == .evening { clock.guessed = true }
                return clock
            }
            clock.guessed = true
            switch leaning {
            case .day:
                clock.isPM = hour <= 6
            case .evening:
                clock.isPM = true
            case .tonight:
                clock.isPM = hour >= 5 && hour < 12
            }
            clock.hour = hour % 12 + (clock.isPM == true ? 12 : 0) + (leaning == .tonight && clock.isPM == false ? 24 : 0)
            return clock
        }

        /// A range's end, after `start` (already resolved): the same half of the day if
        /// that comes after it, else the next time the hour comes round.
        func resolved(after start: Clock) -> Clock {
            if isMidnight { return Clock(hour: 24, minute: 0, isMidnight: true) }
            var clock = self
            if let isPM {
                clock.hour = hour % 12 + (isPM ? 12 : 0)
            } else if !isExact, hour <= 12 {
                // Whichever of the hour's two times comes first after the start.
                let morning = hour % 12, evening = hour % 12 + 12
                let startMinutes = start.hour * 60 + start.minute
                clock.hour = [morning, evening].first { $0 * 60 + minute > startMinutes } ?? morning
            }
            return clock
        }

        /// Minutes from `start` to this, into the next day if it is earlier.
        func minutes(since start: Clock) -> Int {
            var difference = (hour * 60 + minute) - (start.hour * 60 + start.minute)
            if difference <= 0 { difference += 24 * 60 }
            return difference
        }

        /// "3 pm", "3:30 pm", for a time typed in another zone.
        var spoken: String {
            let hour12 = hour % 12 == 0 ? 12 : hour % 12
            let half = hour >= 12 && hour < 24 ? "pm" : "am"
            return minute == 0 ? "\(hour12) \(half)" : String(format: "%d:%02d %@", hour12, minute, half)
        }
    }

    /// A range of times, its start resolved and its end left to follow it. One side's am
    /// or pm is the other's too ("3–4pm"), unless that would end it before it starts
    /// ("11–1pm").
    private func range(_ scan: Scan, _ match: NSTextCheckingResult, day: Day?) -> (Clock, Clock)? {
        let keyword = scan.string(match, 1)?.lowercased()
        let separator = scan.string(match, 6)?.lowercased()
        if separator == "and", keyword != "between" { return nil }
        guard var start = Self.clock(scan, match, hour: 2, minute: 3, meridiem: 4) ?? Self.named(scan.string(match, 5)),
              let end = Self.clock(scan, match, hour: 7, minute: 8, meridiem: 9) ?? Self.named(scan.string(match, 10))
        else { return nil }
        let strong = keyword != nil || start.isPM != nil || end.isPM != nil || start.isExact || end.isExact
            || scan.string(match, 3) != nil || scan.string(match, 8) != nil
            || scan.string(match, 5) != nil || scan.string(match, 10) != nil
            || scan.follows(match.range.location, words: ["at", "@"])
            || (day != nil && scan.followsTaken(match.range.location))
        guard strong else { return nil }
        if start.isPM == nil, !start.isExact, let isPM = end.isPM, start.hour <= 12 {
            start.isPM = isPM
            // "11–1pm": eleven in the morning.
            if isPM, start.hour % 12 + 12 >= (end.hour % 12 + 12) { start.isPM = false }
        }
        return (start, end)
    }

    /// An hour alone just after or just before the day typed: "review next tue 10", "gym 6
    /// tomorrow", but not "table for 6 tomorrow".
    private func bareBesideDay(_ scan: Scan, dayRange: NSRange?) -> NSTextCheckingResult? {
        guard let dayRange else { return nil }
        for match in Self.bare.matches(in: scan.text as String, range: scan.whole) where !scan.isTaken(match.range) {
            if scan.followsTaken(match.range.location) { return match }
            let end = NSMaxRange(match.range)
            if end <= dayRange.location,
               scan.text.substring(with: NSRange(location: end, length: dayRange.location - end)).allSatisfy(\.isWhitespace),
               !scan.follows(match.range.location, words: ["for", "of", "x", "×"]) {
                return match
            }
        }
        return nil
    }

    private static func clock(
        _ scan: Scan, _ match: NSTextCheckingResult, hour: Int, minute: Int?, meridiem: Int?,
        twentyFour: Bool = false
    ) -> Clock? {
        guard let hourText = scan.string(match, hour), let value = Int(hourText) else { return nil }
        let minutes = minute.flatMap { scan.int(match, $0) } ?? 0
        guard value <= 24, minutes < 60 else { return nil }
        var clock = Clock(hour: value, minute: minutes)
        if let meridiem, let text = scan.string(match, meridiem)?.lowercased().trimmingCharacters(in: .whitespaces) {
            guard (1...12).contains(value) else { return nil }
            clock.isPM = text.hasPrefix("p")
        }
        if twentyFour || (clock.isPM == nil && (value == 0 || value > 12 || (hourText.hasPrefix("0") && hourText.count == 2))) {
            clock.isExact = true
        }
        if value == 24 { return Clock(hour: 24, minute: 0, isMidnight: true) }
        return clock
    }

    /// "half 3" and "half past 3" (3:30), "quarter past 3" (3:15), "quarter to 4" (3:45).
    private static func spokenClock(_ scan: Scan, _ match: NSTextCheckingResult) -> Clock? {
        guard let hour = scan.int(match, 3), (1...12).contains(hour) else { return nil }
        var clock: Clock
        switch (scan.string(match, 1)?.lowercased(), scan.string(match, 2)?.lowercased()) {
        case ("half", "past"), ("half", nil): clock = Clock(hour: hour, minute: 30)
        case ("quarter", "past"): clock = Clock(hour: hour, minute: 15)
        case ("quarter", "to"): clock = Clock(hour: hour == 1 ? 12 : hour - 1, minute: 45)
        default: return nil
        }
        if let meridiem = scan.string(match, 4)?.lowercased() { clock.isPM = meridiem.hasPrefix("p") }
        return clock
    }

    /// Words for something in the evening: an hour typed with them is taken as pm.
    private static let eveningWords: Set<String> = ["dinner", "supper", "drinks", "pub", "party", "gig", "concert"]

    private static func isEvening(_ title: String) -> Bool {
        title.lowercased().split { !$0.isLetter }.contains { eveningWords.contains(String($0)) }
    }

    private static func named(_ word: String?) -> Clock? {
        switch word?.lowercased() {
        case "noon", "midday": Clock(hour: 12, minute: 0, isPM: true)
        case "midnight": Clock(hour: 0, minute: 0, isMidnight: true)
        default: nil
        }
    }

    private static func partOfDay(_ word: String?) -> Clock? {
        switch word?.lowercased() {
        case "morning": Clock(hour: 9, minute: 0, isExact: true, guessed: true)
        case "afternoon": Clock(hour: 14, minute: 0, isExact: true, guessed: true)
        case "evening": Clock(hour: 18, minute: 0, isExact: true, guessed: true)
        case "night": Clock(hour: 20, minute: 0, isExact: true, guessed: true)
        default: nil
        }
    }

    private static func zone(_ abbreviation: String?) -> (TimeZone, String)? {
        guard let abbreviation, let identifier = zones[abbreviation.lowercased()],
              let zone = TimeZone(identifier: identifier) else { return nil }
        return (zone, abbreviation)
    }

    // MARK: Lengths

    private static func amount(_ text: String?) -> Double {
        switch text?.lowercased().trimmingCharacters(in: .whitespaces) ?? "" {
        case "a", "an", "one": 1
        case let half where half.hasPrefix("half"): 0.5
        case let number: Double(number) ?? 1
        }
    }

    private static func durationMinutes(_ scan: Scan, _ match: NSTextCheckingResult) -> Int? {
        if let hours = scan.string(match, 1) {
            let extra = scan.int(match, 2) ?? 0
            return Int((amount(hours) * 60).rounded()) + extra
        }
        if let minutes = scan.int(match, 3) { return minutes }
        let phrase = scan.string(match, 0)?.lowercased() ?? ""
        if phrase.contains("and a half") { return 90 }
        if phrase.contains("half") { return 30 }
        return 60
    }

    // MARK: Place and title

    /// A place after "at" or "@" that is not a time: "lunch at Nando's", "call at home".
    /// It runs to the end, or to a gap where something was read, or to "with", "for",
    /// "about".
    private static func place(in words: inout [Scan.Word]) -> String? {
        for at in words.indices {
            guard case .text(let word) = words[at], ["at", "@"].contains(word.lowercased()) else { continue }
            var end = at + 1
            var place: [String] = []
            while end < words.count, case .text(let text) = words[end],
                  !["with", "for", "about", "re", "and", "at", "@"].contains(text.lowercased()) {
                place.append(text)
                end += 1
            }
            let joined = place.joined(separator: " ").trimmingCharacters(in: punctuation)
            guard !joined.isEmpty, !joined.contains("://") else { continue }
            words.replaceSubrange(at..<end, with: [.gap])
            return joined
        }
        return nil
    }

    /// What is left, without the little words that went with what was read ("on",
    /// "at", "from"), trimmed, and with a capital.
    static func title(_ words: [Scan.Word]) -> String {
        var words = words
        // A connector before a gap, or at either end, went with what was read.
        var changed = true
        while changed {
            changed = false
            for index in words.indices.reversed() {
                guard case .text(let text) = words[index], connectors.contains(text.lowercased()) else { continue }
                let beforeGap = index + 1 >= words.count || words[index + 1] == .gap
                let atStart = words[..<index].allSatisfy { $0 == .gap }
                if beforeGap || atStart {
                    words.remove(at: index)
                    changed = true
                    break
                }
            }
        }
        let text = words.compactMap { word -> String? in
            if case .text(let text) = word { return text }
            return nil
        }
        .joined(separator: " ")
        .trimmingCharacters(in: punctuation)
        guard let first = text.first else { return "" }
        return first.uppercased() + text.dropFirst()
    }

    private static let punctuation = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:-–—|/"))
    private static let connectors: Set<String> = [
        "at", "@", "on", "from", "for", "by", "this", "next", "in", "the", "of", "until", "till", "to", "-", "–", "—", ",",
    ]

    // MARK: Patterns

    private static let englishMonths = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    private static let monthNames = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"
    private static let zones: [String: String] = [
        "pt": "America/Los_Angeles", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles",
        "mt": "America/Denver", "mst": "America/Denver", "mdt": "America/Denver",
        "ct": "America/Chicago", "cst": "America/Chicago", "cdt": "America/Chicago",
        "et": "America/New_York", "est": "America/New_York", "edt": "America/New_York",
        "utc": "GMT", "gmt": "GMT", "bst": "Europe/London", "uk": "Europe/London",
        "cet": "Europe/Paris", "cest": "Europe/Paris", "ist": "Asia/Kolkata", "jst": "Asia/Tokyo",
        "aest": "Australia/Sydney", "aedt": "Australia/Sydney",
    ]
    private static let zoneNames = "pt|pst|pdt|mt|mst|mdt|ct|cst|cdt|et|est|edt|utc|gmt|bst|cet|cest|ist|jst|aest|aedt"

    private static func pattern(_ source: String) -> NSRegularExpression {
        // The patterns are constants; one that doesn't compile is a mistake here.
        try! NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let relative = pattern(#"\bin\s+(\d+(?:\.\d+)?|an?|half\s+an?)\s*(minutes?|mins?|m|hours?|hrs?|h|days?|weeks?)\b"#)
    private static let relativeDay = pattern(#"\b(day\s+after\s+tomorrow|today|tonight|tomorrow|tomorow|tmrw|tmr)\b"#)
    private static let weekday = pattern(
        #"\b(?:(this|next|on)\s+)?(monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat|sunday|sun)\b\.?"#
    )
    private static let iso = pattern(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#)
    private static let numeric = pattern(#"(?<![\d/])(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?(?![\d/])"#)
    private var monthFirst: NSRegularExpression {
        Self.pattern(#"\b("# + Self.monthNames + otherMonths + #")\.?\s+(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)?\b(?![:.]\d)(?:,?\s+(\d{4})\b)?"#)
    }
    private var dayFirst: NSRegularExpression {
        Self.pattern(#"\b(?:the\s+)?(?<![:.\d])(\d{1,2})(?:st|nd|rd|th)?(?:\s+of)?\s+("# + Self.monthNames + otherMonths + #")\b\.?(?:,?\s+(\d{4})\b)?"#)
    }
    /// The locale's own month names, besides English's.
    private var otherMonths: String {
        let names = (calendar.monthSymbols + calendar.shortMonthSymbols)
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty && !Self.englishMonths.contains(where: $0.hasPrefix) }
        return names.isEmpty ? "" : "|" + names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    }
    private static let duration = pattern(
        #"(?:\bfor\s+)?(?:\ban?\s+hour\s+and\s+a\s+half\b|\bhalf\s+an?\s+hour\b|\b(\d+(?:\.\d+)?|an?|one)\s*(?:hours?|hrs?|h)(?![a-z])\s*(?:(\d{1,2})\s*(?:minutes?|mins?|m)?\b)?|\b(\d+)\s*(?:minutes?|mins?|m)\b)"#
    )
    private static let range = pattern(
        #"(?:\b(from|between)\s+)?(?<![\w:.])"#
            + #"(?:(\d{1,2})(?:[:.](\d{2}))?\s*(?:(a\.?m\.?|p\.?m\.?)(?![a-z]))?|\b(noon|midday|midnight)\b)"#
            + #"\s*(-|–|—|\bto\b|\btill\b|\btil\b|\buntil\b|\band\b)\s*"#
            + #"(?:(\d{1,2})(?:[:.](\d{2}))?\s*(?:(a\.?m\.?|p\.?m\.?)(?![a-z]))?|\b(noon|midday|midnight)\b)(?![\w:.])"#
            + #"(?:\s*\b("# + zoneNames + #")\b)?"#
    )
    private static let single = pattern(
        #"(?<![\w:./])(?:(\d{1,2})(?:[:.](\d{2}))?\s*(a\.?m\.?|p\.?m\.?)(?![a-z])|(\d{1,2})[:.](\d{2})(?!\d)|([01]\d|2[0-3])([0-5]\d)(?!\d)|\b(noon|midday|midnight)\b)"#
            + #"(?:\s*\b("# + zoneNames + #")\b)?"#
    )
    private static let bareAt = pattern(#"(?:\b(?:at|by)\s+|@\s*)(\d{1,2})([ap])?(?![\w:./%])"#)
    private static let spoken = pattern(
        #"\b(half|quarter)\s+(?:(past|to)\s+)?(\d{1,2})(?:\s*(a\.?m\.?|p\.?m\.?)(?![a-z]))?(?![\w:]|\.\d)"#
    )
    private static let bare = pattern(#"(?<![\w:./])(\d{1,2})(?![\w:./%])"#)
    private static let allDay = pattern(#"\ball[\s-]day\b"#)
    private static let partOfDay = pattern(#"\b(?:in\s+the\s+|this\s+)?(morning|afternoon|evening|night)\b"#)
}

extension EventParser {
    /// Text being read: what has been taken for a day, a time or a place, and what is
    /// left.
    struct Scan {
        let text: NSString
        private(set) var taken: [NSRange] = []

        init(_ text: String) {
            self.text = text as NSString
        }

        var whole: NSRange { NSRange(location: 0, length: text.length) }

        func isTaken(_ range: NSRange) -> Bool {
            taken.contains { NSIntersectionRange($0, range).length > 0 }
        }

        /// The first match of `pattern` in what is left.
        func first(_ pattern: NSRegularExpression) -> NSTextCheckingResult? {
            pattern.matches(in: text as String, range: whole).first { !isTaken($0.range) && $0.range.length > 0 }
        }

        mutating func take(_ range: NSRange) {
            taken.append(range)
        }

        func string(_ match: NSTextCheckingResult, _ group: Int) -> String? {
            guard group < match.numberOfRanges else { return nil }
            let range = match.range(at: group)
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            return text.substring(with: range)
        }

        func int(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            string(match, group).flatMap { Int($0) }
        }

        /// Whether the word before `location` is one of `words`.
        func follows(_ location: Int, words: Set<String>) -> Bool {
            let before = text.substring(to: location).trimmingCharacters(in: .whitespaces)
            guard let last = before.split(whereSeparator: \.isWhitespace).last else { return false }
            return words.contains(last.lowercased()) || last.hasSuffix("@")
        }

        /// Whether only spaces lie between something taken and `location`.
        func followsTaken(_ location: Int) -> Bool {
            taken.contains { range in
                let end = NSMaxRange(range)
                guard end <= location else { return false }
                return text.substring(with: NSRange(location: end, length: location - end))
                    .allSatisfy(\.isWhitespace)
            }
        }

        enum Word: Equatable {
            case text(String)
            /// Where something was taken.
            case gap
        }

        /// What is left, word by word, with a gap wherever something was taken.
        func leftover() -> [Word] {
            var words: [Word] = []
            var cursor = 0
            func add(_ piece: String) {
                for word in piece.split(whereSeparator: \.isWhitespace) { words.append(.text(String(word))) }
            }
            for range in taken.sorted(by: { $0.location < $1.location }) where range.location >= cursor {
                add(text.substring(with: NSRange(location: cursor, length: range.location - cursor)))
                if words.last != .gap { words.append(.gap) }
                cursor = NSMaxRange(range)
            }
            add(text.substring(from: min(cursor, text.length)))
            return words
        }
    }
}

extension Calendar {
    /// The moment `minutes` into `day` by the clock, rather than by time gone by: on the
    /// days the clocks change the two are an hour apart. From 24 hours on, it runs into
    /// the days after.
    func date(minutes: Int, into day: Date) -> Date? {
        guard let local = date(byAdding: .day, value: minutes / (24 * 60), to: startOfDay(for: day)) else { return nil }
        var components = dateComponents([.year, .month, .day], from: local)
        components.hour = minutes % (24 * 60) / 60
        components.minute = minutes % 60
        return date(from: components)
    }
}
