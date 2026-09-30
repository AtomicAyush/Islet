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
/// and a time or a stretch of it, in the person's own words.
struct CalendarQuery: Equatable, Sendable {
    var day: String
    var days: Int?
    var time: String?
    var until: String?

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
        case "", "now", "today", "tonight", "this morning", "this afternoon", "this evening":
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
        if ["", "all day", "whole day", "the whole day", "day", "the day", "any time", "anytime"].contains(text) { return [] }
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

/// The calendar as the tool tells it to Apple's model, in short lines: for each day, its
/// all-day events, its timed ones (with place, calendar and the travel time before them),
/// its clashes, and its free time within the person's day; and, for a time asked about,
/// whether it is free and if not what takes it. Worked out as the Day page is (`DayPlan`),
/// on this Mac.
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
        var lines = ["Times are in \(calendar.timeZone.identifier)."]
        let asked = query.days ?? implied ?? 1
        let count = min(max(asked, 1), AskCalendar.maxDays)
        if asked > AskCalendar.maxDays { lines.append("Only \(AskCalendar.maxDays) days are read at once: these are the first.") }
        let windows = CalendarQuery.windows(query.time, until: query.until)
        if windows == nil, let time = query.time { lines.append("Couldn't read the time \"\(Self.trim(time, 20))\": the whole day follows.") }
        guard let end = calendar.date(byAdding: .day, value: count, to: start),
              let events = model.read(from: start, to: end)
        else { return CalendarReading.noAccess }
        let names = Dictionary(model.store.eventCalendars().map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var listed = 0, left = 0, clashes = 0, clashesLeft = 0
        for offset in 0..<count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start).map(calendar.startOfDay(for:)),
                  let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { continue }
            let onDay = events.filter { $0.end > day && $0.start < next }
            lines.append(heading(day) + ":")
            // The whole calendar day, for the travel before each event and the times asked
            // about; the person's day, for the free time.
            let whole = DayPlan.make(events: onDay, window: DateInterval(start: day, end: next), travel: model.travel, now: day)
            var travel: [String: DateInterval] = [:]
            for case .travel(let span, let event) in whole.rows { travel[event.id] = span }
            let dayEvents = onDay.filter(\.isAllDay).sorted { $0.title < $1.title }
                + onDay.filter { !$0.isAllDay }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            if dayEvents.isEmpty { lines.append("- No events.") }
            for event in dayEvents {
                guard listed < AskCalendar.maxEvents else {
                    left += 1
                    continue
                }
                listed += 1
                lines.append("- " + line(event, on: day, travel: travel[event.id], calendars: names))
            }
            let words = DayWords(format: format)
            for clash in whole.clashes {
                guard clashes < AskCalendar.maxClashes else {
                    clashesLeft += 1
                    continue
                }
                clashes += 1
                lines.append("- Clash: " + words.sentence(clash))
            }
            if count <= AskCalendar.maxFreeDays { lines.append(free(on: day, events: onDay)) }
            for window in windows ?? [] { lines.append(check(window, on: day, plan: whole)) }
        }
        if left > 0 { lines.append("…and \(left) more events not listed: ask about fewer days to see them.") }
        if clashesLeft > 0 { lines.append("…and \(clashesLeft) more clashes not listed.") }
        return lines.joined(separator: "\n")
    }

    /// "Wednesday 30 September 2026 (today)".
    private func heading(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy"
        let today = calendar.startOfDay(for: now)
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        let relative = [-1: " (yesterday)", 0: " (today)", 1: " (tomorrow)"][offset] ?? ""
        return formatter.string(from: day) + relative
    }

    /// "9:00 – 10:00: Dentist; at Main St; calendar Home; travel before it 8:30 – 9:00".
    private func line(_ event: DayEvent, on day: Date, travel: DateInterval?, calendars: [String: String]) -> String {
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
        return "\(format.range(event.start, event.end))\(from): " + parts.joined(separator: "; ")
    }

    /// The free time within the person's day (Settings' Your day).
    private func free(on day: Date, events: [DayEvent]) -> String {
        let window = DayPlan.window(for: day, now: day, calendar: calendar, from: model.dayFrom, to: model.dayTo)
        let plan = DayPlan.make(events: events, window: window, travel: model.travel, now: day)
        let hours = format.range(window.start, window.end)
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
            words += " You can read the person's calendar, on this Mac, with the readCalendar tool. Use it for any question about their"
                + " events, classes, meetings or plans, or when they are free, busy or available, and answer only from what it"
                + " returns. Pass the day and the time as they said them. A time without am or pm, like \"at 8\", can be the"
                + " morning or the evening: the tool checks both, so answer for both unless one is clearly meant."
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
    let description = "Reads the person's calendar on this Mac: the events on a day or a few days, their free time, and whether a time asked about is free. It only reads."
    let read: @MainActor @Sendable (CalendarQuery) -> String

    @Generable
    struct Arguments {
        @Guide(description: "The day: \"today\", \"tomorrow\", a weekday such as \"friday\" or \"next monday\", \"this week\", \"the weekend\", or a date as YYYY-MM-DD")
        var day: String
        @Guide(description: "How many days to read from that day; leave out for just that day. At most 31")
        var days: Int?
        @Guide(description: "A time asked about, as the person said it: \"8\", \"8pm\", \"14:30\", \"morning\". Leave out for the whole day")
        var time: String?
        @Guide(description: "The end of a stretch of time asked about, as the person said it, such as \"5pm\". Usually left out")
        var until: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let query = CalendarQuery(day: arguments.day, days: arguments.days, time: arguments.time, until: arguments.until)
        return await read(query)
    }
}
#endif
