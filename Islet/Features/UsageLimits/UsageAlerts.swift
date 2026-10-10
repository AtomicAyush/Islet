import Foundation

/// When to warn of a limit: at 80% and again at 95% of each window, and when the limit
/// is reached, each once per window until it resets.
///
/// What has been said is kept, by agent, window and level, with when that window
/// resets; a reading taken before then is of the same window, and says nothing new. A
/// reading taken after it, or one whose own reset falls clearly later, is of a window
/// started afresh, which is warned of again. Where nothing says when a window resets, it
/// is taken to run its whole length from the reading that was warned of, by which time
/// it has surely started afresh. A window warned of at 95% has its 80% noted too, and one
/// at its limit both, so a jump straight past a level is warned of once, at the highest.
/// Where the source names its windows (Gemini's), each is a limit of its own: one at its
/// limit can leave the others usable, so each has its own banner when it gets there.
struct UsageAlerts: Equatable, Codable {
    /// The levels warned of before the limit, lowest first.
    static let levels: [Double] = [80, 95]
    /// The window a limit is kept under, apart from any one window: one limit at a time.
    static let limitWindow = 0
    /// What is said is forgotten once this long past its window's reset.
    static let kept: TimeInterval = 8 * 24 * 60 * 60

    struct Said: Equatable, Codable {
        var agent: UsageAgent
        /// The window's length (`UsageWindow.span`), or `limitWindow`.
        var window: Int
        /// 80, 95, or 100 for the limit.
        var level: Int
        /// When the window starts afresh.
        var until: Date
        /// The window's own name, where the source names its windows (`UsageWindow.name`):
        /// two of Gemini's limits can run as long.
        var name: String? = nil
    }

    /// A banner due.
    struct Alert: Equatable {
        enum Kind: Equatable {
            /// A window at 80% or 95%.
            case warning(level: Int, window: UsageWindow)
            case limit
        }

        var agent: UsageAgent
        var kind: Kind
        var resets: Date?
        var resetIsEstimate: Bool
        /// The limit's own name, of a window the source names (`UsageWindow.name`).
        var name: String? = nil
    }

    var said: [Said] = []

    /// The banners `status` calls for, noted as said. Warnings only where `warns`; the
    /// limit always. A figure the island dims is too old to warn of.
    mutating func due(_ status: UsageStatus, warns: Bool) -> [Alert] {
        let agent = status.agent
        let measured = status.reading.measured
        said.removeAll { $0.until.addingTimeInterval(Self.kept) < status.now }
        var alerts: [Alert] = []

        // A limit the source has just said was reached is news however old the windows'
        // numbers are.
        let limitSaid = status.reading.limitSince.map { status.now.timeIntervalSince($0) <= UsageStatus.staleAfter } ?? false
        if !status.windows.isEmpty, status.windows.allSatisfy({ $0.window.name != nil }) {
            // Named windows: each at its limit is a limit of its own, said once until it
            // resets.
            for window in status.windows where !window.isReset && !window.isStale && window.percent >= 100 {
                let name = window.window.name
                let resets = window.window.resets
                if !isSaid(agent, Self.limitWindow, name, 100, measured: window.measured, resets: resets, span: window.window.span) {
                    alerts.append(Alert(agent: agent, kind: .limit, resets: resets, resetIsEstimate: window.window.resetIsEstimate,
                                        name: name))
                }
                note(agent, Self.limitWindow, name, 100, until: endOfWindow(measured: window.measured)(window.window),
                     known: resets != nil, measured: window.measured)
            }
        } else if status.atLimit, !status.isStale || limitSaid {
            let measured = max(measured, status.reading.limitSince ?? measured)
            let window = status.limitWindow?.window
            let resets = status.limitResets
            let until = resets?.date ?? window.map(endOfWindow(measured: measured))
                ?? measured.addingTimeInterval(UsageStatus.limitHold)
            if !isSaid(agent, Self.limitWindow, nil, 100, measured: measured, resets: resets?.date,
                       span: window?.span ?? Int(UsageStatus.limitHold / 60)) {
                alerts.append(Alert(agent: agent, kind: .limit, resets: resets?.date, resetIsEstimate: resets?.isEstimate ?? false))
            }
            note(agent, Self.limitWindow, nil, 100, until: until, known: resets != nil || window?.resets != nil, measured: measured)
        }

        for window in status.windows where !window.isReset && !window.isStale {
            let reached = Self.levels.filter { window.percent >= $0 }.map { Int($0) } + (window.percent >= 100 ? [100] : [])
            guard let highest = reached.last else { continue }
            let span = window.window.span
            let name = window.window.name
            let measured = window.measured
            let fresh = reached.filter { !isSaid(agent, span, name, $0, measured: measured, resets: window.window.resets, span: span) }
            let until = endOfWindow(measured: measured)(window.window)
            for level in reached {
                note(agent, span, name, level, until: until, known: window.window.resets != nil, measured: measured)
            }
            // The limit has its own banner; under it, only the highest level not yet said.
            guard warns, highest < 100, fresh.contains(highest) else { continue }
            alerts.append(Alert(agent: agent, kind: .warning(level: highest, window: window.window),
                                resets: window.window.resets, resetIsEstimate: window.window.resetIsEstimate))
        }
        return alerts
    }

    /// Whether `level` has been said of `window` for a reading taken at `measured`, which
    /// says the window resets at `resets`: said of a window that had not reset by then,
    /// and not one that resets later than that one could, give or take a fifth of its
    /// `span` in minutes, as a worked-out reset can.
    private func isSaid(_ agent: UsageAgent, _ window: Int, _ name: String?, _ level: Int, measured: Date, resets: Date?,
                        span: Int) -> Bool {
        let slack = TimeInterval(span) * 60 * ClaudeUsage.gapShare
        return said.contains { entry in
            entry.agent == agent && entry.window == window && entry.name == name && entry.level == level && measured < entry.until
                && (resets.map { $0 <= entry.until.addingTimeInterval(slack) } ?? true)
        }
    }

    /// Notes `level` said of `window` until `until`, which `known` says is the window's
    /// own reset rather than worked out from the reading. Said again of the same window,
    /// it keeps the later of the two resets, but never moves for one worked out; of a
    /// window started afresh, it takes the new one.
    private mutating func note(_ agent: UsageAgent, _ window: Int, _ name: String?, _ level: Int, until: Date, known: Bool,
                               measured: Date) {
        guard let index = said.firstIndex(where: {
            $0.agent == agent && $0.window == window && $0.name == name && $0.level == level
        }) else {
            said.append(Said(agent: agent, window: window, level: level, until: until, name: name))
            return
        }
        if measured >= said[index].until {
            said[index].until = until
        } else if known {
            said[index].until = max(said[index].until, until)
        }
    }

    private func endOfWindow(measured: Date) -> (UsageWindow) -> Date {
        { window in window.resets ?? measured.addingTimeInterval(TimeInterval(window.span) * 60) }
    }
}

extension UsageAlerts.Alert {
    /// "Claude 5-hour limit at 80%", "ChatGPT limit reached"; for a window the source
    /// names, "Gemini weekly limit reached", "Gemini Claude/GPT 5-hour limit at 80%", with
    /// the agent's name before one that lacks it.
    var title: String {
        switch kind {
        case .warning(let level, let window):
            if let name = window.name { return named(name) + " limit at \(level)%" }
            return "\(agent.name) \(UsageText.longName(window)) limit at \(level)%"
        case .limit:
            return (name.map(named) ?? agent.name) + " limit reached"
        }
    }

    /// The source's name for a window, said with the agent's.
    private func named(_ name: String) -> String {
        name.localizedCaseInsensitiveContains(agent.name) ? name : agent.name + " " + name
    }

    /// The source's name for the window warned of, where it names it.
    private var windowName: String? {
        switch kind {
        case .warning(_, let window): window.name
        case .limit: name
        }
    }

    /// "Resets about 4:10 PM"; `nil` where nothing says when.
    func subtitle(now: Date) -> String? {
        guard let resets else { return nil }
        return "Resets " + (resetIsEstimate ? "about " : "") + UsageText.time(resets, now: now)
    }

    /// Which of several goes first: the limit, then the higher level, then the shorter
    /// window.
    var rank: Int {
        switch kind {
        case .limit: Int.max
        case .warning(let level, let window): level * 100_000 - window.span
        }
    }

    /// This one in the banner of `first`: "Weekly limit at 80%" of the same agent, the
    /// whole title of another, or of a window the source names by more than its length.
    func mention(beside first: Self) -> String {
        guard first.agent == agent, title.hasPrefix(agent.name + " "),
              windowName.map({ UsageText.length($0) != nil }) ?? true
        else { return title }
        let rest = title.dropFirst(agent.name.count + 1)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }
}
