import Foundation

/// Two events that don't fit together: they overlap, or there isn't the time to get
/// from the first to the second.
struct Clash: Equatable, Identifiable {
    enum Kind: Equatable {
        /// For this many minutes.
        case overlap(minutes: Int)
        /// Only `gap` minutes between them, where getting to the second takes `needs`.
        case travel(gap: Int, needs: Int)
    }

    /// The one that starts first.
    let first: DayEvent
    let second: DayEvent
    let kind: Kind

    var id: String { first.id + "|" + second.id }
}

/// Which events keep the person busy, where they are, and which clash, worked out from
/// the events alone.
///
/// Busy means a timed event that isn't shown as free (declined and cancelled ones never
/// get this far). An event's place is its location, unless it is online or has none.
/// Getting to an event with a place takes the travel time, unless the busy event just
/// before it is at the same place; after an online event, or one with no place, the
/// person still has to get there.
enum Clashes {
    /// Overlaps shorter than this are events that meet, not a clash.
    static let overlapGrace: TimeInterval = 60

    static func isBusy(_ event: DayEvent) -> Bool {
        !event.isAllDay && !event.isFree
    }

    /// Where the event is, to compare: trimmed, with its spaces and case evened out.
    /// `nil` for an online event, or one without a place.
    static func place(of event: DayEvent) -> String? {
        guard !event.isOnline, let location = event.location else { return nil }
        let place = location.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return place.isEmpty || place.contains("://") ? nil : place
    }

    /// Whether getting to `event` takes the travel time, after `previous`.
    static func needsTravel(to event: DayEvent, after previous: DayEvent?) -> Bool {
        guard let place = place(of: event) else { return false }
        return previous.flatMap(Self.place(of:)) != place
    }

    /// Busy events in the order they start, as `all(in:travel:)` and `previous(of:in:)`
    /// take them.
    static func busy(_ events: [DayEvent]) -> [DayEvent] {
        events.filter(isBusy).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// The busy event just before `busy[index]`, which the person comes from: of those
    /// starting earlier, the one ending last by the time it starts.
    static func previous(of index: Int, in busy: [DayEvent]) -> DayEvent? {
        let second = busy[index]
        return busy[..<index].filter { $0.end <= second.start.addingTimeInterval(overlapGrace) }
            .max(by: { $0.end < $1.end })
    }

    /// Whether the person is already at `busy[index]`'s place when it starts, at an event
    /// there that is still going on.
    static func isAlreadyThere(for index: Int, in busy: [DayEvent]) -> Bool {
        let event = busy[index]
        guard let place = place(of: event) else { return false }
        return busy[..<index].contains { $0.end > event.start && Self.place(of: $0) == place }
    }

    /// Every clash among `events`, in the order the second of each starts.
    static func all(in events: [DayEvent], travel: TimeInterval) -> [Clash] {
        let busy = busy(events)
        var clashes: [Clash] = []
        for (index, second) in busy.enumerated() {
            let earlier = busy[..<index]
            for first in earlier {
                let overlap = min(first.end, second.end).timeIntervalSince(second.start)
                if overlap >= overlapGrace {
                    clashes.append(Clash(first: first, second: second, kind: .overlap(minutes: Int((overlap / 60).rounded()))))
                }
            }
            guard travel > 0,
                  let previous = previous(of: index, in: busy),
                  !clashes.contains(where: { $0.first == previous && $0.second == second }),
                  needsTravel(to: second, after: previous)
            else { continue }
            let gap = max(0, second.start.timeIntervalSince(previous.end))
            if gap < travel {
                clashes.append(Clash(first: previous, second: second,
                                     kind: .travel(gap: Int((gap / 60).rounded()), needs: Int((travel / 60).rounded()))))
            }
        }
        return clashes
    }

    /// The clashes `candidate` would have among `events`: for an event being typed.
    static func involving(_ candidate: DayEvent, among events: [DayEvent], travel: TimeInterval) -> [Clash] {
        all(in: events.filter { $0.id != candidate.id } + [candidate], travel: travel)
            .filter { $0.first.id == candidate.id || $0.second.id == candidate.id }
    }

    /// A clash as the event being typed has it: "Clashes with Standup 3:00–3:30", "Only
    /// 10 min after Gym (Main St) — allow 30 to get there".
    static func line(_ clash: Clash, for candidateID: String, time: (Date) -> String) -> String {
        let other = clash.first.id == candidateID ? clash.second : clash.first
        switch clash.kind {
        case .overlap:
            return "Clashes with \(named(other)) \(time(other.start))–\(time(other.end))"
        case .travel(let gap, let needs):
            let place = other.location.map { " (\($0))" } ?? ""
            let side = clash.second.id == candidateID ? "after" : "before"
            if gap == 0 { return "Right \(side) \(named(other))\(place) — allow \(needs) to get there" }
            return "Only \(gap) min \(side) \(named(other))\(place) — allow \(needs) to get there"
        }
    }

    static func named(_ event: DayEvent) -> String {
        event.title.isEmpty ? "Untitled" : event.title
    }
}

/// A day as time taken and time free, from the events alone: what "Summarise" shows.
///
/// The day is the person's own hours of it (Settings' Your day, 8:00 to 22:00 unless
/// changed), and today's starts now. Each busy event takes its own time and, where it
/// has a place, the travel time before it (`Clashes.needsTravel`); what is left, in
/// stretches of a quarter of an hour or more, is free. All-day events block nothing and
/// are named on a line of their own. Calendar data goes nowhere: this is worked out on
/// this Mac, and never by a model.
struct DayPlan: Equatable {
    enum Row: Equatable, Identifiable {
        case free(DateInterval)
        /// Getting to the event: the travel time before it, cut to the day.
        case travel(DateInterval, to: DayEvent)
        case event(DayEvent)
        /// Before the second of the two.
        case clash(Clash)

        var id: String {
            switch self {
            case .free(let span): "free@\(span.start.timeIntervalSinceReferenceDate)"
            case .travel(_, let event): "travel|" + event.id
            case .event(let event): "event|" + event.id
            case .clash(let clash): "clash|" + clash.id
            }
        }
    }

    /// The part of the day looked at: empty once today's hours are over.
    let window: DateInterval
    /// Today's, starting now rather than at the start of the person's day.
    let startsNow: Bool
    let allDay: [DayEvent]
    let rows: [Row]
    let free: [DateInterval]
    /// The clashes whose second event is still to come in the window.
    let clashes: [Clash]

    /// Shorter gaps than this aren't free time worth the name.
    static let shortestFree: TimeInterval = 15 * 60

    var freeTime: TimeInterval { free.reduce(0) { $0 + $1.duration } }
    var isOver: Bool { window.duration <= 0 }

    /// The hours of `day` the person counts as theirs, `from` and `to` in minutes into
    /// it, starting no sooner than `now`: an empty window (at the end) once they are over.
    static func window(for day: Date, now: Date, calendar: Calendar, from: Int, to: Int) -> DateInterval {
        let midnight = calendar.startOfDay(for: day)
        let start = calendar.date(minutes: from, into: midnight) ?? midnight
        let end = calendar.date(minutes: to, into: midnight) ?? midnight
        let begins = min(max(start, now), end)
        return DateInterval(start: begins, end: end)
    }

    /// `events` are the day's, as the store gives them (an event from the day before that
    /// runs into it among them); `travel` is the time allowed to get to a place.
    static func make(events: [DayEvent], window: DateInterval, travel: TimeInterval, now: Date) -> DayPlan {
        let allDay = events.filter(\.isAllDay).sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        let busy = Clashes.busy(events)
        let inWindow: (Date, Date) -> Bool = { start, end in end > window.start && start < window.end }
        let clashes = Clashes.all(in: events, travel: travel).filter { inWindow($0.second.start, $0.second.end) }

        var rows: [(at: Date, rank: Int, row: Row)] = []
        var taken: [DateInterval] = []
        for (index, event) in busy.enumerated() where inWindow(event.start, event.end) {
            let start = max(event.start, window.start)
            let end = min(event.end, window.end)
            var blockStart = start
            if travel > 0, event.start > window.start, !Clashes.isAlreadyThere(for: index, in: busy),
               Clashes.needsTravel(to: event, after: Clashes.previous(of: index, in: busy)) {
                let leaves = max(event.start.addingTimeInterval(-travel), window.start)
                blockStart = leaves
                rows.append((leaves, 1, .travel(DateInterval(start: leaves, end: event.start), to: event)))
            }
            rows.append((start, 2, .event(event)))
            taken.append(DateInterval(start: blockStart, end: max(blockStart, end)))
        }

        // What isn't taken, merged, in stretches long enough to count.
        var free: [DateInterval] = []
        var cursor = window.start
        for block in taken.sorted(by: { $0.start < $1.start }) {
            if block.start > cursor { free.append(DateInterval(start: cursor, end: block.start)) }
            cursor = max(cursor, block.end)
        }
        if window.end > cursor { free.append(DateInterval(start: cursor, end: window.end)) }
        free.removeAll { $0.duration < shortestFree }
        rows += free.map { ($0.start, 0, Row.free($0)) }

        var ordered = rows.sorted { ($0.at, $0.rank) < ($1.at, $1.rank) }.map(\.row)
        // Each clash just before the second event, or the travel to it.
        for clash in clashes.reversed() {
            let index = ordered.firstIndex {
                switch $0 {
                case .travel(_, let event), .event(let event): event.id == clash.second.id
                default: false
                }
            }
            if let index { ordered.insert(.clash(clash), at: index) }
        }
        return DayPlan(
            window: window, startsNow: window.start == now,
            allDay: allDay, rows: ordered, free: free, clashes: clashes
        )
    }

    enum Status: Equatable {
        /// Free now, until then; `restOfDay` when nothing more is on.
        case free(until: Date, restOfDay: Bool)
        /// Taken now (an event, or getting to one), until then.
        case busy(until: Date)
        case over
    }

    /// How the day stands at `now`: before the person's day begins, as it will at its start.
    func status(at now: Date) -> Status {
        guard !isOver, now < window.end else { return .over }
        let now = max(now, window.start)
        if let span = free.first(where: { $0.start <= now && now < $0.end }) {
            return .free(until: span.end, restOfDay: span.end >= window.end)
        }
        let next = free.first { $0.start > now }
        return .busy(until: next?.start ?? window.end)
    }
}

/// The day the Today tile, the Day page and "summarise" look at.
enum QuickDay: String, CaseIterable, Identifiable {
    case today, tomorrow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        }
    }
}

/// Words typed in the box that ask for the day summed up — "summarise my day", "what's
/// on tomorrow" — rather than a question for a model. They are recognised here, by fixed
/// rules, before anything could be sent anywhere, and answered from the calendar on this
/// Mac.
enum DaySummaryRequest {
    /// Asked for as they are, once evened out.
    static let phrases: Set<String> = [
        "my day", "my day today", "my day tomorrow", "today", "tomorrow", "summarise", "summarize",
        "summarise day", "summarize day", "day summary", "summary of my day", "summary of today",
        "summary of tomorrow", "what's my day like", "what does my day look like", "what does today look like",
        "what does tomorrow look like", "what's on", "am i free today", "am i free tomorrow",
        "when am i free", "when am i free today", "when am i free tomorrow", "free time", "free time today",
        "free time tomorrow", "my free time", "agenda", "my agenda", "today's agenda", "tomorrow's agenda",
    ]

    /// "summarise my day", "summarize today", "what's on tomorrow", "show my day".
    private static let pattern = try? NSRegularExpression(
        pattern: "^(summari[sz]e|what's on|whats on|what's|whats|show)\\s+(my\\s+)?(day|today|tomorrow)(\\s+(today|tomorrow))?(\\s+please)?$"
    )

    /// The words as they are compared: lower case, apostrophes straightened, spaces
    /// evened out, and a question mark or full stop at the end dropped.
    static func normalised(_ text: String) -> String {
        var text = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = text.last, "?.!".contains(last) { text.removeLast() }
        if text.hasPrefix("please ") { text.removeFirst("please ".count) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The day `text` asks to have summed up, or `nil` if it asks for something else.
    static func day(for text: String) -> QuickDay? {
        let text = normalised(text)
        guard !text.isEmpty, text.count <= 40 else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard phrases.contains(text) || pattern?.firstMatch(in: text, range: range) != nil else { return nil }
        return text.contains("tomorrow") ? .tomorrow : .today
    }

    /// "what about tomorrow", "and Friday?", "how about next Monday then", "the day after",
    /// "yesterday?": a day, and at most a few words leading to it.
    private static let followUpPattern: NSRegularExpression? = {
        let lead = #"(?:(?:and|so|ok|okay)\s+){0,2}(?:(?:what|how)\s+about\s+|what'?s\s+on\s+|summari[sz]e\s+)?(?:(?:on|for)\s+)?"#
        let day = #"(today|tomorrow|yesterday|(?:the\s)?day\safter\stomorrow|(?:the\s)?day\sbefore\syesterday|"#
            + #"the\s(?:next|following|previous)\sday|the\sday\s(?:after|before)(?:\sthat)?|"#
            + #"(?:(this|next|last)\s)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday))"#
        return try? NSRegularExpression(pattern: "^" + lead + day + #"(?:\s(?:then|instead|too))?$"#)
    }()

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// The day a follow-up to a day summed up asks for, or `nil` if it asks something
    /// else. Only a day named, with at most a few words leading to it, is taken: "what
    /// about tomorrow", "and Friday?", "next Monday", "the day after", "yesterday?".
    /// Anything more ("what about the French revolution", "what about tomorrow's
    /// weather") or a span ("next week", "the weekend") is asked as usual.
    ///
    /// "The day after" and "the day before" count from `shown`, the day summed up last;
    /// a weekday counts from today as typing an event does: "Friday" is the next one,
    /// today if it is Friday, "next Friday" a week on then, and "last Friday" the one
    /// before today.
    static func followUp(to text: String, after shown: Date, now: Date, calendar: Calendar) -> Date? {
        // "ok, what about tomorrow", "Friday, then?": a comma is a space here.
        let text = normalised(text.replacingOccurrences(of: ",", with: " "))
        guard !text.isEmpty, text.count <= 60, let pattern = followUpPattern,
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let dayRange = Range(match.range(at: 1), in: text)
        else { return nil }
        let today = calendar.startOfDay(for: now)
        let shown = calendar.startOfDay(for: shown)
        let offset: (Date, Int)
        switch String(text[dayRange]) {
        case "today": offset = (today, 0)
        case "tomorrow": offset = (today, 1)
        case "yesterday": offset = (today, -1)
        case let words where words.hasSuffix("after tomorrow"): offset = (today, 2)
        case let words where words.hasSuffix("before yesterday"): offset = (today, -2)
        case let words where words.hasPrefix("the next") || words.hasPrefix("the following") || words.hasPrefix("the day after"):
            offset = (shown, 1)
        case let words where words.hasPrefix("the previous") || words.hasPrefix("the day before"):
            offset = (shown, -1)
        default:
            guard let nameRange = Range(match.range(at: 3), in: text),
                  let target = weekdays.firstIndex(of: String(text[nameRange])) else { return nil }
            let which = Range(match.range(at: 2), in: text).map { String(text[$0]) }
            let weekday = calendar.component(.weekday, from: today) - 1
            if which == "last" {
                let behind = (weekday - target + 7) % 7
                offset = (today, -(behind == 0 ? 7 : behind))
            } else {
                let ahead = (target - weekday + 7) % 7
                offset = (today, ahead == 0 && which == "next" ? 7 : ahead)
            }
        }
        return calendar.date(byAdding: .day, value: offset.1, to: offset.0).map(calendar.startOfDay(for:))
    }
}

/// What Quick Calendar says of a day, its free time and its clashes: in the tile, the Day
/// page, the box and the clash card.
@MainActor
struct DayWords {
    let format: QuickCalendarFormat

    /// "3 h 15 m", "45 min", "2 h".
    static func span(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) m"
    }

    /// "Today", "Tomorrow", "Wed 30 Sep".
    func dayName(_ plan: DayPlan) -> String {
        format.day(plan.window.end.addingTimeInterval(-1))
    }

    /// "Today · free 3 h 15 m in 3 gaps", "Tomorrow · free all day", "Today · no free time".
    func headline(_ plan: DayPlan) -> String {
        let day = dayName(plan)
        if plan.isOver { return "\(day) · your day is done" }
        if plan.rows.count == 1, case .free = plan.rows[0] {
            return "\(day) · free " + (plan.startsNow ? "from now on" : "all day")
        }
        guard !plan.free.isEmpty else { return "\(day) · no free time" }
        let gaps = plan.free.count == 1 ? "" : " in \(plan.free.count) gaps"
        return "\(day) · free \(Self.span(plan.freeTime))\(gaps)"
    }

    /// The Today tile's second line: "3 h 15 m free in 3 gaps", "No free time left";
    /// `nil` once the day is done.
    func freeLine(_ plan: DayPlan) -> String? {
        if plan.isOver { return nil }
        guard !plan.free.isEmpty else { return plan.startsNow ? "No free time left" : "No free time" }
        let gaps = plan.free.count == 1 ? "" : " in \(plan.free.count) gaps"
        return "\(Self.span(plan.freeTime)) free\(gaps)"
    }

    /// A free stretch: "Free until 10:30", "Free 12:00 – 14:00", "Free from 17:00".
    func free(_ span: DateInterval, in plan: DayPlan) -> String {
        let fromStart = span.start <= plan.window.start
        let toEnd = span.end >= plan.window.end
        switch (fromStart, toEnd) {
        case (true, true): return plan.startsNow ? "Free for the rest of your day" : "Free all day"
        case (true, false): return "Free until \(format.time(span.end))"
        case (false, true): return "Free from \(format.time(span.start))"
        case (false, false): return "Free \(format.range(span.start, span.end))"
        }
    }

    /// "Travel to Main St", or "Travel" for a place too long to say.
    func travel(to event: DayEvent) -> String {
        event.location.map { "Travel to \($0)" } ?? "Travel"
    }

    /// Between the rows of the Day page: "Overlaps 15 min", "10 min to get to Main St
    /// (allow 30)".
    func marker(_ clash: Clash) -> String {
        switch clash.kind {
        case .overlap(let minutes):
            return "Overlaps \(minutes) min"
        case .travel(let gap, let needs):
            let place = clash.second.location.map { " to \($0)" } ?? ""
            return gap == 0 ? "No time to get\(place) (allow \(needs))" : "\(gap) min to get\(place) (allow \(needs))"
        }
    }

    /// The clash said in full: "Standup and Dentist overlap 15:00 – 15:15", "Only 10
    /// minutes to get from the office to Main St for Dentist".
    func sentence(_ clash: Clash) -> String {
        let first = Clashes.named(clash.first), second = Clashes.named(clash.second)
        switch clash.kind {
        case .overlap:
            let end = min(clash.first.end, clash.second.end)
            return "\(first) and \(second) overlap \(format.range(clash.second.start, end))"
        case .travel(let gap, _):
            let minutes = gap == 1 ? "1 minute" : "\(gap) minutes"
            let from = Clashes.place(of: clash.first) == nil ? "" : " from \(clash.first.location ?? "")"
            let to = clash.second.location.map { " to \($0)" } ?? ""
            if gap == 0 { return "No time to get\(from)\(to) for \(second)" }
            return "Only \(minutes) to get\(from)\(to) for \(second)"
        }
    }

    /// "No clashes today", "1 clash", "2 clashes".
    func clashCount(_ plan: DayPlan) -> String {
        switch plan.clashes.count {
        case 0: "No clashes \(dayName(plan).lowercased())"
        case 1: "1 clash"
        case let count: "\(count) clashes"
        }
    }

    /// The tile's line: "Free until 15:00", "Busy until 16:00", "Free for the rest of the day".
    func status(_ plan: DayPlan, at now: Date) -> String {
        switch plan.status(at: now) {
        case .free(_, true): "Free for the rest of the day"
        case .free(let until, false): "Free until \(format.time(until))"
        case .busy(let until): "Busy until \(format.time(until))"
        case .over: "Your day is done"
        }
    }

    /// The whole plan for VoiceOver, a row at a time.
    func spoken(_ plan: DayPlan) -> String {
        var parts = [headline(plan)]
        if !plan.allDay.isEmpty { parts.append("All day: " + plan.allDay.map(Clashes.named).joined(separator: ", ")) }
        for row in plan.rows {
            switch row {
            case .free(let span): parts.append(free(span, in: plan))
            case .travel(let span, let event): parts.append("\(format.time(span.start)), \(travel(to: event))")
            case .event(let event): parts.append("\(format.range(event.start, event.end)), \(Clashes.named(event))")
            case .clash(let clash): parts.append(sentence(clash))
            }
        }
        return parts.joined(separator: ". ")
    }
}
