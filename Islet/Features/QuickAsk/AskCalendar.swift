import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's model reading the calendar, on this Mac, when Settings lets it: a tool it can
/// call for the events of a day or a few, the free time between them and whether a time
/// asked about is free, read through Quick Calendar (its calendars to check, the person's
/// day and the travel time) as short lines of text.
///
/// It only reads. Nothing here can add, change or delete an event: adding one is still
/// only Quick Calendar's Add. What it reads goes to Apple's model on this Mac alone, and
/// an answer made from it is kept from ChatGPT and Claude as a day summed up is
/// (`QuickAskSession.turn(_:for:)`); a question about the calendar meant for them offers
/// Apple's model instead (`CalendarQuestion`).
@MainActor
final class AskCalendar {
    /// The most days one reading covers.
    static let maxDays = 31
    /// The most events, and clashes, one reading names; the rest are counted.
    static let maxEvents = 30
    static let maxClashes = 10
    /// Free time is said for up to this many days at once; a longer stretch lists its
    /// events alone.
    static let maxFreeDays = 7
    static let maxTitle = 60
    static let maxPlace = 40
    static let maxCalendarName = 30
    /// With nothing left on the day asked, the next event is looked for this many days on.
    static let lookAhead = 7

    /// What ChatGPT and Claude are told, with a follow-up, of an answer Apple's model gave
    /// from the calendar: that there was one, and nothing of it.
    static let note = "(Apple's model answered this from their calendar, on their Mac. Its details are private and weren't shared with you.)"

    let defaults: UserDefaults
    /// Quick Calendar's model, whose store, settings and clock the calendar is read
    /// through. Tests hand in their own.
    var source: () -> QuickCalendarModel?
    /// How many times the model has read the calendar, for the box to tell which answers
    /// were made from it.
    private(set) var reads = 0
    /// Calendar access as the latest reading found it.
    private(set) var lastAccess = CalendarAccess.granted
    /// Whether Apple's model's conversation going on has read the calendar, for any
    /// exchange, kept in the box or not (one stopped, failed or asked again of another):
    /// its later answers may repeat what it read.
    private(set) var readInConversation = false

    init(defaults: UserDefaults = .standard, source: (() -> QuickCalendarModel?)? = nil) {
        self.defaults = defaults
        self.source = source ?? { FeatureRegistry.shared.feature(QuickCalendarFeature.self)?.model }
    }

    /// Settings' "Let Apple's model read your calendar": on unless turned off, since
    /// nothing leaves the Mac.
    var isOn: Bool {
        defaults.object(forKey: QuickAskFeature.Key.calendar) as? Bool ?? true
    }

    /// Whether Apple's model is given the tool: the switch on, and Quick Calendar there to
    /// read through.
    var offered: Bool {
        isOn && source() != nil
    }

    /// The moment, the calendar and the locale a question is asked in: Quick Calendar's,
    /// which tests fix, or the Mac's own.
    func clock() -> (now: Date, calendar: Calendar, locale: Locale) {
        if let model = source() { return (model.now(), model.calendar, model.locale) }
        return (Date(), .autoupdatingCurrent, .autoupdatingCurrent)
    }

    /// The model's reading of the calendar, as text: counted, with access as it stands.
    func read(_ query: CalendarQuery) -> String {
        reads += 1
        readInConversation = true
        guard isOn, let model = source() else { return CalendarReading.turnedOff }
        lastAccess = model.store.access
        guard lastAccess == .granted else {
            return lastAccess == .restricted ? CalendarReading.restricted : CalendarReading.noAccess
        }
        return CalendarReading(model: model).text(for: query)
    }

    /// Apple's model's conversation is made afresh, or dropped: it has read nothing yet.
    func conversationStarted() {
        readInConversation = false
    }

    /// The button under an answer that found access off: macOS is asked, only from that
    /// click, or Privacy settings open where it was turned off.
    func allowAccess() {
        guard let model = source() else { return }
        if model.store.access == .undetermined {
            model.requestAccess()
        } else {
            CalendarApp.openPrivacySettings()
        }
    }
}

/// What the calendar tool is asked, as the model passes it: a day, how many days from it,
/// a time or a stretch of it, in the person's own words, and how much of it to tell.
struct CalendarQuery: Equatable, Sendable {
    var day: String
    var days: Int?
    var time: String?
    var until: String?
    var scope = Scope.all

    /// How much of the day to tell: all of it, what is still to come, or the next event
    /// alone.
    enum Scope: Equatable, Sendable {
        case all, remaining, next

        /// The scope `words` name, as the model says it; the whole day for anything else.
        init(_ words: String?) {
            switch CalendarQuery.clean(words ?? "") {
            case "next", "next event", "next one", "first", "first event", "first one":
                self = .next
            case "remaining", "rest", "the rest", "left", "what's left", "upcoming", "to come", "still to come", "later",
                 "rest of the day", "the rest of the day", "rest of today", "the rest of today", "after now":
                self = .remaining
            default:
                self = .all
            }
        }
    }

    /// A stretch of the day asked about, in minutes after midnight.
    struct Window: Equatable {
        /// "at 8 in the morning", "at 8pm", "in the afternoon", "from 2pm to 4pm".
        let label: String
        let start: Int
        let end: Int
    }

    /// The words, evened out: lower case, apostrophes straightened, spaces single, and
    /// "on", "at" and the like in front, or a question mark after, dropped.
    static func clean(_ words: String) -> String {
        var text = words.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = text.last, "?.!,".contains(last) { text.removeLast() }
        for lead in ["on ", "at ", "around ", "about ", "by ", "from ", "for ", "this ", "in the "] where text.hasPrefix(lead) {
            text.removeFirst(lead.count)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The day `words` names, and how many days it means when it names a stretch ("this
    /// week"); `nil` when it names none. Days count from `now` as a day summed up does:
    /// "Friday" is the next one, today if it is Friday.
    static func day(_ words: String, now: Date, calendar: Calendar, parser: EventParser) -> (start: Date, days: Int?)? {
        let text = words.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!, "))
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let ahead = { (days: Int) in calendar.date(byAdding: .day, value: days, to: today).map(calendar.startOfDay(for:)) }
        switch text.hasPrefix("on ") ? String(text.dropFirst(3)) : text {
        case "", "now", "today", "tonight", "this morning", "this afternoon", "this evening", "later", "later today",
             "rest of today", "the rest of today", "rest of the day", "the rest of the day":
            return (today, nil)
        case "week", "this week", "the week", "the rest of the week", "rest of the week":
            // Today to Sunday.
            return (today, (8 - weekday) % 7 + 1)
        case "next week":
            let monday = (9 - weekday) % 7
            return ahead(monday == 0 ? 7 : monday).map { ($0, 7) }
        case "weekend", "this weekend", "the weekend":
            if weekday == 7 { return (today, 2) }
            if weekday == 1 { return (today, 1) }
            return ahead(7 - weekday).map { ($0, 2) }
        default:
            break
        }
        if let match = try? NSRegularExpression(pattern: #"^(\d{4})-(\d{1,2})-(\d{1,2})$"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let number = { (index: Int) in Range(match.range(at: index), in: text).flatMap { Int(text[$0]) } }
            let parts = DateComponents(year: number(1), month: number(2), day: number(3))
            guard parts.isValidDate(in: calendar), let date = calendar.date(from: parts) else { return nil }
            return (calendar.startOfDay(for: date), nil)
        }
        if let date = DaySummaryRequest.followUp(to: text, after: today, now: now, calendar: calendar) {
            return (date, nil)
        }
        // "2 October", "Oct 2", "2/10": as typing an event reads them.
        let parsed = parser.parse(text)
        guard let start = parsed.start, parsed.title.isEmpty else { return nil }
        return (calendar.startOfDay(for: start), nil)
    }

    /// Parts of the day, in minutes after midnight.
    private static let parts: [String: (String, Int, Int)] = [
        "morning": ("in the morning", 6 * 60, 12 * 60),
        "afternoon": ("in the afternoon", 12 * 60, 17 * 60),
        "evening": ("in the evening", 17 * 60, 22 * 60),
        "tonight": ("tonight", 18 * 60, 24 * 60),
        "night": ("at night", 21 * 60, 24 * 60),
        "noon": ("at noon", 12 * 60, 13 * 60),
        "midday": ("at midday", 12 * 60, 13 * 60),
        "lunch": ("at lunchtime", 12 * 60, 14 * 60),
        "lunchtime": ("at lunchtime", 12 * 60, 14 * 60),
        "midnight": ("at midnight", 0, 60),
    ]

    private static let clockPattern = try? NSRegularExpression(
        pattern: #"^(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a|p|o'clock|oclock)?$"#
    )

    /// A time as said, in minutes after midnight: two for an hour with no am or pm that
    /// could be the morning or the evening ("8", "8:30"), one otherwise ("8pm", "08:00",
    /// "14:30", "12"). `nil` for words that aren't a time.
    static func clock(_ words: String) -> [Int]? {
        // "8 p.m." is "8 pm".
        let text = clean(words).replacingOccurrences(of: ".m", with: "m")
        guard let match = clockPattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(match.range(at: 1), in: text), var hour = Int(text[hourRange])
        else { return nil }
        let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
        let meridiem = Range(match.range(at: 3), in: text).map { String(text[$0]) }
        guard minute < 60, hour <= 23 else { return nil }
        switch meridiem {
        case "am", "a":
            guard (1...12).contains(hour) else { return nil }
            if hour == 12 { hour = 0 }
        case "pm", "p":
            guard (1...12).contains(hour) else { return nil }
            if hour < 12 { hour += 12 }
        default:
            // "8" or "8 o'clock" could be either; "08:00" and "20:00" say which.
            if (1...11).contains(hour), !text.hasPrefix("0") {
                return [hour * 60 + minute, (hour + 12) * 60 + minute]
            }
        }
        return [hour * 60 + minute]
    }

    /// The stretches `time` (to `until`, if said) asks about: an hour from a time, both
    /// the morning's and the evening's for one that could be either, or a part of the day.
    /// Empty for the whole day; `nil` for words that aren't a time.
    static func windows(_ time: String?, until: String?) -> [Window]? {
        guard let time else { return [] }
        let text = clean(time)
        if ["", "all day", "whole day", "the whole day", "day", "the day", "any time", "anytime", "now", "right now", "later",
            "rest of the day", "the rest of the day", "remaining", "next"].contains(text) { return [] }
        if let part = parts[text] { return [Window(label: part.0, start: part.1, end: part.2)] }
        guard let starts = clock(text) else { return nil }
        let ends = until.flatMap { clock($0) } ?? []
        return starts.map { start in
            let end = ends.first { $0 > start } ?? min(start + 60, 24 * 60)
            var label = "at " + text
            if starts.count == 2 { label += start < 12 * 60 ? " in the morning" : " in the evening" }
            if let until, !ends.isEmpty { label = "from \(text) to \(clean(until))" }
            return Window(label: label, start: start, end: end)
        }
    }
}

/// The calendar as the tool tells it to Apple's model, in short lines: the time now and,
/// with today among the days read, a line saying what is on now, what is next and, unless
/// the whole day is asked for, what is still to start today; then for each day its all-day
/// events, its timed ones (with place, calendar and the travel time before them, and
/// today's marked as over, on now or next), its clashes, and its free time within the
/// person's day; and, for a time asked about, whether it is free and if not what takes it.
/// Asked for what remains, the events that are over are left out; asked for the next, that
/// event alone, looked for up to a week on. Worked out as the Day page is (`DayPlan`), on
/// this Mac.
@MainActor
struct CalendarReading {
    let model: QuickCalendarModel
    let now: Date
    let calendar: Calendar
    let format: QuickCalendarFormat

    init(model: QuickCalendarModel) {
        self.model = model
        now = model.now()
        calendar = model.calendar
        format = QuickCalendarFormat(model: model)
    }

    static let noAccess = "Islet isn't allowed to read the calendar, so nothing was read. Tell the person to allow calendar access with the button under this answer."
    static let restricted = "Calendar access is restricted on this Mac by a profile, so nothing was read. Say so."
    static let turnedOff = "Reading the calendar is turned off in Settings, so nothing was read. Say so."

    func text(for query: CalendarQuery) -> String {
        guard let (start, implied) = CalendarQuery.day(query.day, now: now, calendar: calendar, parser: model.parser()) else {
            return "Couldn't tell which day \"\(Self.trim(query.day, 40))\" is. Read it again with the date as YYYY-MM-DD."
        }
        var lines = ["It is now \(format.time(now)) on \(heading(now, relative: false)). Times are in \(calendar.timeZone.identifier)."]
        if query.scope == .next {
            guard let next = next(from: start) else { return CalendarReading.noAccess }
            return (lines + next).joined(separator: "\n")
        }
        let asked = query.days ?? implied ?? 1
        let count = min(max(asked, 1), AskCalendar.maxDays)
        if asked > AskCalendar.maxDays { lines.append("Only \(AskCalendar.maxDays) days are read at once: these are the first.") }
        let windows = CalendarQuery.windows(query.time, until: query.until)
        if windows == nil, let time = query.time { lines.append("Couldn't read the time \"\(Self.trim(time, 20))\": the whole day follows.") }
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: count, to: start),
              let events = model.read(from: start, to: end)
        else { return CalendarReading.noAccess }
        // Today among the days read: where it stands, first, as the short answer. Asked for
        // the whole day, what is left today isn't counted, so the rest isn't read as all.
        var upNext: DayEvent?
        let readsToday = start <= today && end > today
        if readsToday {
            guard let standing = standing(counting: query.scope != .all) else { return CalendarReading.noAccess }
            lines.append(standing.words)
            upNext = standing.next
        }
        let remaining = query.scope == .remaining
        if remaining { lines.append("Only what is still to come is listed: events that are over are left out.") }
        if !remaining, readsToday { lines.append("All of today is listed, its events that are over among them.") }
        let names = calendarNames()
        var listed = 0, left = 0, clashes = 0, clashesLeft = 0
        for offset in 0..<count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start).map(calendar.startOfDay(for:)),
                  let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { continue }
            let onDay = events.filter { $0.end > day && $0.start < next }
            let isToday = day == today
            lines.append(heading(day) + ":")
            // The whole calendar day, for the travel before each event and the times asked
            // about; the person's day, for the free time.
            let whole = DayPlan.make(events: onDay, window: DateInterval(start: day, end: next), travel: model.travel, now: day)
            let travel = travelTimes(whole)
            var dayEvents = onDay.filter(\.isAllDay).sorted { $0.title < $1.title }
                + onDay.filter { !$0.isAllDay }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            let over = dayEvents.filter { $0.end <= now }.count
            if remaining { dayEvents.removeAll { $0.end <= now } }
            if dayEvents.isEmpty { lines.append(remaining && over > 0 ? "- Nothing left: all \(over) of its events are over." : "- No events.") }
            if remaining, over > 0, !dayEvents.isEmpty { lines.append("- \(over) earlier \(over == 1 ? "event is" : "events are") over, not listed.") }
            for event in dayEvents {
                guard listed < AskCalendar.maxEvents else {
                    left += 1
                    continue
                }
                listed += 1
                let status = isToday ? self.status(event, next: upNext) : ""
                lines.append("- " + line(event, on: day, travel: travel[event.id], calendars: names, status: status))
            }
            let words = DayWords(format: format)
            for clash in whole.clashes where !remaining || clash.second.end > now {
                guard clashes < AskCalendar.maxClashes else {
                    clashesLeft += 1
                    continue
                }
                clashes += 1
                lines.append("- Clash: " + words.sentence(clash))
            }
            // Today's free time from now: what has gone by can't be used.
            if count <= AskCalendar.maxFreeDays { lines.append(free(on: day, events: onDay, from: remaining || isToday ? now : day)) }
            for window in windows ?? [] { lines.append(check(window, on: day, plan: whole)) }
        }
        if left > 0 { lines.append("…and \(left) more events not listed: ask about fewer days to see them.") }
        if clashesLeft > 0 { lines.append("…and \(clashesLeft) more clashes not listed.") }
        return lines.joined(separator: "\n")
    }

    /// Where today stands, in a line: the time, what is on now, the next event (on a later
    /// day within a week when none is left today) and, `counting`, what is still to start
    /// today. `nil` when the calendar can't be read.
    private func standing(counting: Bool) -> (words: String, next: DayEvent?)? {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let horizon = calendar.date(byAdding: .day, value: AskCalendar.lookAhead + 1, to: today),
              let events = model.read(from: today, to: horizon)
        else { return nil }
        let timed = events.filter { !$0.isAllDay }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        let onNow = timed.filter { $0.start <= now && $0.end > now }
        let toCome = timed.filter { $0.start > now && $0.start < tomorrow }
        let next = timed.first { $0.start > now }
        var words = "Now \(format.time(now))."
        words += onNow.isEmpty ? " Nothing on now."
            : " On now: " + onNow.map { brief($0) + ", until \(format.time($0.end))" }.joined(separator: "; ") + "."
        if let next, next.start < tomorrow {
            words += " Next: \(brief(next)), in \(DayWords.span(next.start.timeIntervalSince(now)))."
        } else if let next {
            words += " Nothing else today. Next: \(brief(next, withDay: true))."
        } else {
            words += " Nothing else today, and nothing in the next \(AskCalendar.lookAhead) days."
        }
        if counting, !toCome.isEmpty {
            let named = toCome.prefix(8).map { "\(Self.trim(Clashes.named($0), AskCalendar.maxTitle)) \(format.time($0.start))" }
            let more = toCome.count > named.count ? " and \(toCome.count - named.count) more" : ""
            let current = onNow.isEmpty ? "" : "\(onNow.count) on now and "
            words += " Left today: \(current)\(toCome.count) still to start (" + named.joined(separator: ", ") + more + ")."
        }
        return (words, next)
    }

    /// The next event from `day` on, for a reading of the next alone: from now for today (or
    /// a day gone), from its start for a later day; looked for within a week. `nil` when the
    /// calendar can't be read.
    private func next(from day: Date) -> [String]? {
        let today = calendar.startOfDay(for: now)
        var lines: [String] = []
        let next: DayEvent?
        if day <= today {
            guard let standing = standing(counting: false) else { return nil }
            lines.append(standing.words)
            next = standing.next
        } else {
            guard let horizon = calendar.date(byAdding: .day, value: AskCalendar.lookAhead + 1, to: day),
                  let events = model.read(from: day, to: horizon)
            else { return nil }
            next = events.filter { !$0.isAllDay && $0.start >= day }.min { ($0.start, $0.end) < ($1.start, $1.end) }
            if let next, calendar.isDate(next.start, inSameDayAs: day) {
                lines.append("First on \(heading(day)): \(brief(next)).")
            } else if let next {
                lines.append("Nothing on \(heading(day)). The next after it: \(brief(next, withDay: true)).")
            } else {
                lines.append("Nothing on \(heading(day)), or in the \(AskCalendar.lookAhead) days after it.")
            }
        }
        guard let next else { return lines }
        // The event in full, with the travel before it.
        let nextDay = calendar.startOfDay(for: next.start)
        guard let after = calendar.date(byAdding: .day, value: 1, to: nextDay),
              let onDay = model.read(from: nextDay, to: after)
        else { return nil }
        let travel = travelTimes(DayPlan.make(events: onDay, window: DateInterval(start: nextDay, end: after), travel: model.travel, now: nextDay))
        let status = nextDay == today ? self.status(next, next: next) : ""
        lines.append(heading(nextDay) + ":")
        lines.append("- " + line(next, on: nextDay, travel: travel[next.id], calendars: calendarNames(), status: status))
        return lines
    }

    /// For an event today: " (over)", " (on now)", " (next, in 55 min)", or nothing.
    private func status(_ event: DayEvent, next: DayEvent?) -> String {
        if event.isAllDay { return "" }
        if event.end <= now { return " (over)" }
        if event.start <= now { return " (on now)" }
        if event.id == next?.id { return " (next, in \(DayWords.span(event.start.timeIntervalSince(now))))" }
        return ""
    }

    /// "Dentist, 15:00 – 15:45, at Main St"; with its day, "Physics lecture, tomorrow
    /// (Tuesday 29 September 2026), 09:00 – 10:00, at Hall B".
    private func brief(_ event: DayEvent, withDay: Bool = false) -> String {
        var parts = [Self.trim(Clashes.named(event), AskCalendar.maxTitle)]
        if withDay {
            let day = calendar.startOfDay(for: event.start)
            let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: day).day ?? 0
            parts.append(offset == 1 ? "tomorrow (\(heading(day, relative: false)))" : heading(day, relative: false))
        }
        parts.append(format.range(event.start, event.end))
        if event.isOnline {
            parts.append("online")
        } else if let place = event.location.map({ Self.trim($0, AskCalendar.maxPlace) }), !place.isEmpty {
            parts.append("at " + place)
        }
        return parts.joined(separator: ", ")
    }

    /// The travel time before each event of a day's plan, by event.
    private func travelTimes(_ plan: DayPlan) -> [String: DateInterval] {
        var travel: [String: DateInterval] = [:]
        for case .travel(let span, let event) in plan.rows { travel[event.id] = span }
        return travel
    }

    private func calendarNames() -> [String: String] {
        Dictionary(model.store.eventCalendars().map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// "Wednesday 30 September 2026 (today)", or without "(today)".
    private func heading(_ day: Date, relative: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy"
        guard relative else { return formatter.string(from: day) }
        let today = calendar.startOfDay(for: now)
        let offset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: day)).day ?? 0
        let words = [-1: " (yesterday)", 0: " (today)", 1: " (tomorrow)"][offset] ?? ""
        return formatter.string(from: day) + words
    }

    /// "9:00 – 10:00 (next, in 1 h): Dentist; at Main St; calendar Home; travel before it
    /// 8:30 – 9:00".
    private func line(_ event: DayEvent, on day: Date, travel: DateInterval?, calendars: [String: String], status: String = "") -> String {
        var parts = [Self.trim(Clashes.named(event), AskCalendar.maxTitle)]
        if event.isOnline {
            parts.append("online")
        } else if let place = event.location.map({ Self.trim($0, AskCalendar.maxPlace) }), !place.isEmpty {
            parts.append("at " + place)
        }
        if let name = event.calendarID.flatMap({ calendars[$0] }) { parts.append("calendar " + Self.trim(name, AskCalendar.maxCalendarName)) }
        if event.isFree { parts.append("shown as free, so it keeps no one busy") }
        if let travel { parts.append("travel time before it \(format.range(travel.start, travel.end))") }
        if event.isAllDay { return "All day: " + parts.joined(separator: "; ") }
        let from = event.start < day ? " (from the day before)" : ""
        return "\(format.range(event.start, event.end))\(from)\(status): " + parts.joined(separator: "; ")
    }

    /// The free time within the person's day (Settings' Your day), from `from` on: its
    /// start, or now for today.
    private func free(on day: Date, events: [DayEvent], from: Date) -> String {
        let window = DayPlan.window(for: day, now: from, calendar: calendar, from: model.dayFrom, to: model.dayTo)
        let plan = DayPlan.make(events: events, window: window, travel: model.travel, now: from)
        let hours = format.range(window.start, window.end)
        if window.duration <= 0 { return "- Free time in their day: none left, their day is over." }
        if plan.free.isEmpty { return "- Free time in their day (\(hours)): none." }
        if plan.free.count == 1, plan.free[0] == window { return "- Free time in their day (\(hours)): all of it." }
        return "- Free time in their day (\(hours)): " + plan.free.map { format.range($0.start, $0.end) }.joined(separator: ", ") + "."
    }

    /// "At 8 in the morning (8:00 – 9:00): free.", or what takes it: events, and the travel
    /// time before them, said as such.
    private func check(_ window: CalendarQuery.Window, on day: Date, plan: DayPlan) -> String {
        guard let start = calendar.date(minutes: window.start, into: day),
              let end = calendar.date(minutes: window.end, into: day)
        else { return "- \(Self.capitalised(window.label)): couldn't be checked." }
        var taken: [String] = []
        for row in plan.rows {
            switch row {
            case .event(let event) where event.end > start && event.start < end:
                taken.append("\(Self.trim(Clashes.named(event), AskCalendar.maxTitle)) \(format.range(event.start, event.end))")
            case .travel(let span, let event) where span.end > start && span.start < end:
                taken.append("travel time before \(Self.trim(Clashes.named(event), AskCalendar.maxTitle)) \(format.range(span.start, span.end))")
            default:
                break
            }
        }
        let head = "- \(Self.capitalised(window.label)) (\(format.range(start, end)))"
        return taken.isEmpty ? head + ": free." : head + ": busy — " + taken.joined(separator: ", ") + "."
    }

    static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// On one line, and cut to `limit` characters.
    static func trim(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

/// Words that ask about the calendar — "am I available today at 8", "when's my first
/// class tomorrow", "any meetings on Friday?" — recognised by fixed rules, on this Mac,
/// before anything is sent: meant for ChatGPT or Claude, they offer Apple's model, which
/// can read the calendar here, instead.
enum CalendarQuestion {
    private static let about = #"\b(availab(le|ility)|free|busy|schedule[sd]?|calendar|meetings?|events?|appointments?|"#
        + #"class(es)?|lectures?|lessons?|booked|plans|agenda|diary)\b"#
    private static let when = #"\b(today|tonight|tomorrow|yesterday|mon(day)?|tue(s(day)?)?|wed(nesday)?|thu(rs(day)?)?|"#
        + #"fri(day)?|sat(urday)?|sun(day)?|week|weekend|morning|afternoon|evening|noon|midnight|"#
        + #"jan(uary)?|feb(ruary)?|march|april|june|july|aug(ust)?|sep(t(ember)?)?|oct(ober)?|nov(ember)?|dec(ember)?)\b"#
        + #"|\bat \d|\d\s?(am|pm)\b|\d:\d\d|\d{4}-\d{2}-\d{2}"#
    private static let next = #"\bmy (next|first|last) (meeting|class|lecture|lesson|event|appointment)\b"#

    private static let aboutPattern = try? NSRegularExpression(pattern: about)
    private static let whenPattern = try? NSRegularExpression(pattern: when)
    private static let nextPattern = try? NSRegularExpression(pattern: next)

    static func matches(_ text: String) -> Bool {
        let text = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let range = NSRange(text.startIndex..., in: text)
        let found = { (pattern: NSRegularExpression?) in pattern?.firstMatch(in: text, range: range) != nil }
        return found(nextPattern) || (found(aboutPattern) && found(whenPattern))
    }
}

extension AskInstructions {
    /// Apple's model's words: the usual ones, the moment of asking, so "today at 8" and
    /// "this Friday" are the right days, and how to use the calendar tool if it has it.
    @MainActor
    static func apple(now: Date, calendar: Calendar, locale: Locale, readsCalendar: Bool) -> String {
        var words = text + " " + moment(now, calendar: calendar, locale: locale)
        if readsCalendar {
            words += " You can read the person's calendar, on this Mac, with the readCalendar tool. Always call it before answering"
                + " any question about their events, classes, meetings or plans (what is on a day, what is next, what is left"
                + " today), or when they are free, busy or available, and answer only from what it returns: never make up an event."
                + " Pass the day and the time as they said them, and the scope by what they asked: \"all\" for what is on a day,"
                + " today included (\"what's on today\", \"what do I have today\", \"my schedule today\"), which asks for the"
                + " whole day; \"remaining\" only when they ask what is left, remaining or still to come today; \"next\" only for"
                + " their next event. A time without am or pm, like \"at 8\", can be the morning or the evening: the tool checks"
                + " both, so answer for both unless one is clearly meant. Answer only what was asked, briefly: for what is on a day,"
                + " every event of it in order, saying which of today's are over, and of one on now that it is on now; for their"
                + " next event, that one event with its time and place; for what is left today, only the events still to come,"
                + " saying of one on now that it is on now. Leave out the events that are over only when asked what is next or"
                + " what is left."
        }
        return words
    }

    /// "It is now Wednesday 30 September 2026, 19:05, in the time zone Europe/London (BST)."
    @MainActor
    static func moment(_ now: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy"
        let time = QuickCalendarFormat(calendar: calendar, locale: locale, now: now).time(now)
        let zone = calendar.timeZone
        let short = zone.abbreviation(for: now).map { " (\($0))" } ?? ""
        return "It is now \(formatter.string(from: now)), \(time), in the time zone \(zone.identifier)\(short)."
    }
}

#if canImport(FoundationModels)
/// The tool Apple's model is given to read the calendar. It reads and nothing else, on
/// the main actor where Quick Calendar's store is, through `AskCalendar.read(_:)`.
@available(macOS 26, *)
struct CalendarTool: Tool {
    let name = "readCalendar"
    let description = "Reads the person's calendar on this Mac: the events on a day or a few days, their next event, what is left today, their free time, and whether a time asked about is free. It only reads."
    let read: @MainActor @Sendable (CalendarQuery) -> String

    @Generable
    struct Arguments {
        @Guide(description: "The day: \"today\", \"tomorrow\", a weekday such as \"friday\" or \"next monday\", \"this week\", \"the weekend\", or a date as YYYY-MM-DD")
        var day: String
        @Guide(description: "How much to read: \"all\" for the whole day, as for what is on a day or their schedule, today's too; \"remaining\" only for what is left or still to come today; \"next\" for the next event alone. Leave out for all")
        var scope: String?
        @Guide(description: "How many days to read from that day; leave out for just that day. At most 31")
        var days: Int?
        @Guide(description: "A time asked about, as the person said it: \"8\", \"8pm\", \"14:30\", \"morning\". Leave out for the whole day")
        var time: String?
        @Guide(description: "The end of a stretch of time asked about, as the person said it, such as \"5pm\". Usually left out")
        var until: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let query = CalendarQuery(day: arguments.day, days: arguments.days, time: arguments.time, until: arguments.until,
                                  scope: CalendarQuery.Scope(arguments.scope))
        return await read(query)
    }
}
#endif
