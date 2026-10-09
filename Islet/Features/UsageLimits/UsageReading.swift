import Foundation

/// The agents whose plans' usage limits the island follows.
enum UsageAgent: String, CaseIterable, Codable, Sendable {
    case claude
    case chatGPT

    var name: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        }
    }

    /// The activity whose page and compact island show the agent's limits, and whose news
    /// its banners are.
    var activityID: String {
        switch self {
        case .claude: "claudeCode"
        case .chatGPT: "chatGPT"
        }
    }
}

/// One of a plan's limits: how much of it is used, how long it runs, and when it starts
/// afresh.
struct UsageWindow: Equatable, Sendable {
    /// How long the window runs, in minutes, as the source says: 300 for five hours,
    /// 10080 for a week.
    var minutes: Int
    /// How much of it is used, from 0 to 100.
    var percent: Double
    var resets: Date?
    /// Whether `resets` was worked out from the Claude app's history rather than told:
    /// the latest it can be, and shown as "about".
    var resetIsEstimate = false
    /// When the figure was true, where that is later than the reading it is part of: one
    /// Quick Ask said since the Claude app's sample, of one window alone.
    var measured: Date? = nil

    /// The length it stands for, which the source may give a minute short: Codex has
    /// said 299 minutes for five hours and 10079 for a week.
    var span: Int { UsageText.span(minutes) }
}

/// A plan's credits, as Codex reports them.
struct UsageCredits: Equatable, Sendable {
    var hasCredits: Bool
    var unlimited: Bool
    /// As Codex writes it, a number in a string.
    var balance: String?
}

/// What a source last said of an agent's limits, and when that was true.
struct UsageReading: Equatable, Sendable {
    var agent: UsageAgent
    /// When the numbers were true: the Claude app's sample, Quick Ask's answer, Codex's
    /// reply. Where they were true at different times, the oldest.
    var measured: Date
    /// Shortest first.
    var windows: [UsageWindow]
    /// The plan as the source names it ("plus"), where it does.
    var plan: String? = nil
    var credits: UsageCredits? = nil
    /// When the source last said the limit had been reached, apart from any window at
    /// 100%: Codex's `rate_limit_reached_type`, Quick Ask turned away, Claude Code's
    /// StopFailure.
    var limitSince: Date? = nil

    /// The reading as of `now`: which windows have started afresh, whether it is old,
    /// whether the limit holds.
    func status(at now: Date) -> UsageStatus {
        UsageStatus(reading: self, now: now)
    }
}

/// A reading as of a moment.
struct UsageStatus: Equatable {
    struct Window: Equatable {
        var window: UsageWindow
        /// When its figure was true.
        var measured: Date
        /// Its reset time has passed since the reading: it has started afresh. Where
        /// nothing says when that is, it surely has once its whole length has passed
        /// since its figure was true.
        var isReset: Bool
        /// Its figure is dimmed: a Claude figure the app has not renewed.
        var isStale: Bool

        /// What is used now: nothing, once it has reset.
        var percent: Double { isReset ? 0 : window.percent }

        /// When it starts afresh at the latest, as far as anything says.
        var lapses: Date { window.resets ?? measured.addingTimeInterval(TimeInterval(window.span) * 60) }
    }

    /// A Claude reading older than this is dimmed: the Claude app samples every 15
    /// minutes while it runs, so one this old says the app is not running.
    static let staleAfter: TimeInterval = 20 * 60
    /// An age past which it is said: "as of 25 min ago".
    static let ageShownAfter: TimeInterval = 20 * 60
    /// How long a limit the source said was reached holds where nothing says when it
    /// lifts: the shortest window there is.
    static let limitHold: TimeInterval = 5 * 60 * 60

    var reading: UsageReading
    var now: Date
    var windows: [Window]

    init(reading: UsageReading, now: Date) {
        self.reading = reading
        self.now = now
        windows = reading.windows.map { window in
            let measured = max(window.measured ?? reading.measured, reading.measured)
            var shown = Window(window: window, measured: measured, isReset: false,
                               isStale: reading.agent == .claude && now.timeIntervalSince(measured) > Self.staleAfter)
            shown.isReset = shown.lapses <= now
            return shown
        }
    }

    var agent: UsageAgent { reading.agent }
    var age: TimeInterval { max(0, now.timeIntervalSince(reading.measured)) }
    /// Dimmed: a Claude reading the app has not renewed, every figure of it. Codex's last
    /// reply is exact until a window resets, which it then shows.
    var isStale: Bool {
        guard !windows.isEmpty else { return reading.agent == .claude && age > Self.staleAfter }
        return windows.allSatisfy(\.isStale)
    }
    var showsAge: Bool { age > Self.ageShownAfter }

    /// How full the fullest window is now, 0 to 100, of those not reset or dimmed.
    var level: Double {
        windows.filter { !$0.isReset && !$0.isStale }.map(\.percent).max() ?? 0
    }

    /// The window the limit is in, while it holds: the window at 100%, or for a limit the
    /// source said was reached, the one it can be told to be in, until it resets.
    var limitWindow: Window? {
        if let full = windows.filter({ !$0.isReset && $0.percent >= 100 }).max(by: { $0.lapses < $1.lapses }) {
            return full
        }
        guard let said = saidWindow, !said.isReset else { return nil }
        return said
    }

    /// The window the source said was at its limit, where the reading can tell, of
    /// those whose reset is known and was still to come when it said so: one at 100%;
    /// or else the fullest from 80% of figures true shortly before; or else the shortest,
    /// which is reached first. Two windows' percentages say little of which will fill
    /// first, an old figure less. Where the shortest had reset by then, the limit is in
    /// one begun since the reading, and nothing says when it lifts.
    private var saidWindow: Window? {
        guard let since = reading.limitSince else { return nil }
        let running = windows.filter { $0.window.resets.map { $0 > since } ?? false }
        if let full = running.filter({ $0.window.percent >= 100 }).max(by: { $0.lapses < $1.lapses }) { return full }
        let filling = running.filter {
            since.timeIntervalSince($0.measured) <= Self.staleAfter && $0.window.percent >= UsageAlerts.levels[0]
        }
        if let fullest = filling.max(by: { $0.window.percent < $1.window.percent }) { return fullest }
        guard let shortest = windows.min(by: { $0.window.span < $1.window.span }),
              running.contains(shortest)
        else { return nil }
        return shortest
    }

    /// Whether the limit has been reached and has not yet lifted: a window at 100%, or
    /// one the source said was at its limit, until it resets. Where nothing says when
    /// that is, the limit holds `limitHold` from when it was said.
    var atLimit: Bool {
        if windows.contains(where: { !$0.isReset && $0.percent >= 100 }) { return true }
        guard let since = reading.limitSince else { return false }
        if let said = saidWindow { return !said.isReset }
        return now < since.addingTimeInterval(Self.limitHold)
    }

    /// Whether the island shows the limit: while it holds, unless only a dimmed figure
    /// says so. One the source said was reached shows however old the figures are.
    var showsLimit: Bool { atLimit && (!isStale || reading.limitSince != nil) }

    /// The window shown at its limit, while it is.
    var shownLimitWindow: Window? { showsLimit ? limitWindow : nil }

    /// Whether the whole reading is dimmed: every figure old, and no limit to show, which
    /// is news however old they are.
    var isDimmed: Bool { isStale && !showsLimit }

    /// Whether `window` is dimmed on its own: an old figure beside newer ones, or beside
    /// the limit.
    func dimsAlone(_ window: Window) -> Bool {
        window.isStale && !isDimmed && window.window.span != shownLimitWindow?.window.span
    }

    /// When the limit lifts, while it holds and where that is known.
    var limitResets: (date: Date, isEstimate: Bool)? {
        guard atLimit, let window = limitWindow?.window, let resets = window.resets else { return nil }
        return (resets, window.resetIsEstimate)
    }
}

/// The words and numbers the island shows for usage.
enum UsageText {
    /// The lengths the sources use, which a length within a minute or so stands for.
    private static let spans = [300, 1440, 10080, 43200]

    static func span(_ minutes: Int) -> Int {
        spans.first { abs($0 - minutes) <= max(2, $0 / 100) } ?? minutes
    }

    /// "5h", "Week": beside a bar, in a line.
    static func shortName(_ window: UsageWindow) -> String {
        let minutes = window.span
        switch minutes {
        case 1440: return "Day"
        case 10080: return "Week"
        case 43200: return "Month"
        default:
            if minutes >= 1440, minutes % 1440 == 0 { return "\(minutes / 1440)d" }
            if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60)h" }
            return "\(minutes)m"
        }
    }

    /// "5-hour", "weekly": in a banner, "Claude 5-hour limit at 80%".
    static func longName(_ window: UsageWindow) -> String {
        let minutes = window.span
        switch minutes {
        case 1440: return "daily"
        case 10080: return "weekly"
        case 43200: return "monthly"
        default:
            if minutes >= 1440, minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
            if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60)-hour" }
            return "\(minutes)-minute"
        }
    }

    /// "42%": rounded down, so 99.6 is not yet the limit.
    static func percent(_ value: Double) -> String {
        "\(Int(min(100, max(0, value)).rounded(.down)))%"
    }

    /// "4:10 PM" today, "Fri 4:10 PM" within the week, "12 Oct" past it.
    static func time(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let clock = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if date > now, date.timeIntervalSince(now) < 6 * 24 * 60 * 60 {
            return date.formatted(.dateTime.weekday(.abbreviated)) + " " + clock
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "4:10" beside the notch, without AM or PM, within half a day, past midnight
    /// included; "Fri" further off.
    static func compactTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) || abs(date.timeIntervalSince(now)) < 12 * 60 * 60 {
            return date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
        }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// "resets 4:10 PM", "resets about 4:10 PM", "reset"; `nil` where nothing says when.
    static func reset(_ window: UsageStatus.Window, now: Date) -> String? {
        if window.isReset { return "reset" }
        guard let resets = window.window.resets else { return nil }
        return "resets " + (window.window.resetIsEstimate ? "about " : "") + time(resets, now: now)
    }

    /// The reset alone, for under a bar: "4:10 PM", "about 4:10 PM", "reset".
    static func resetShort(_ window: UsageStatus.Window, now: Date) -> String? {
        if window.isReset { return "reset" }
        guard let resets = window.window.resets else { return nil }
        return (window.window.resetIsEstimate ? "about " : "") + time(resets, now: now)
    }

    /// "25 min ago", "3 h ago", "2 d ago".
    static func age(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
    }

    /// The line atop an activity's page: "5h 42% · resets 4:10 PM · Week 18%". The
    /// first window says when it resets, and so does any other at 80% or more; the window
    /// at its limit says so, "5h limit", or the line starts "Limit reached" where no
    /// window can be told to be; an old reading says how old.
    static func line(_ status: UsageStatus) -> String {
        var parts: [String] = []
        let limit = status.shownLimitWindow
        if status.showsLimit, limit == nil {
            parts.append("Limit reached")
        }
        for (index, window) in status.windows.enumerated() {
            let name = shortName(window.window)
            if window.isReset {
                parts.append(name + " reset")
                continue
            }
            let atLimit = window.window.span == limit?.window.span
            parts.append(name + " " + (atLimit ? "limit" : percent(window.percent)))
            if index == 0 || atLimit || window.percent >= UsageAlerts.levels[0], let reset = reset(window, now: status.now) {
                parts.append(reset)
            }
        }
        if status.showsAge { parts.append("as of " + age(status.age)) }
        return parts.joined(separator: " · ")
    }

    /// "Plus", from Codex's "plus"; "Pro", "Free", "Team".
    static func plan(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// "120 credits", "Unlimited credits"; `nil` with none.
    static func credits(_ credits: UsageCredits?) -> String? {
        guard let credits else { return nil }
        if credits.unlimited { return "Unlimited credits" }
        guard credits.hasCredits, let balance = credits.balance, let value = Double(balance) else { return nil }
        let shown = value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
        return "\(shown) credits"
    }
}
