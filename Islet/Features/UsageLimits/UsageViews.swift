import SwiftUI

enum UsageLayout {
    /// The line atop an activity's page.
    static let lineHeight: CGFloat = 18
    /// Right of the notch at the limit: "limit · 12:45" at full size.
    static let limitTrailingWidth: CGFloat = 76
    /// The ring round a mark in the compact island, and its line.
    static let ringSize: CGFloat = 21
    static let ringWidth: CGFloat = 2
    /// The mark's size inside the ring, so the two do not touch.
    static let ringMark: CGFloat = 0.72
    /// A bar on the tile.
    static let barHeight: CGFloat = 4
    /// The most windows a column of the tile has room for.
    static let tileRows = 2
    static let barTrack = IslandBackdrop.track(0.16)
}

/// The colours a level is drawn in: the agent's own below 80%, orange from 80%, red at
/// the limit. They never take the accent's place but for the agent's own.
enum UsageColours {
    static func hue(_ percent: Double, atLimit: Bool = false) -> SystemHue? {
        if atLimit || percent >= 100 { return .failure }
        if percent >= CompactUsage.ringFrom { return .warning }
        return nil
    }

    static func tint(_ agent: UsageAgent) -> FeatureTint {
        switch agent {
        case .claude: .claudeCode
        case .chatGPT: .chatGPT
        case .gemini: .gemini
        }
    }

    /// A bar's fill, on its track.
    static func fill(_ percent: Double, agent: UsageAgent) -> IslandStyle {
        hue(percent).map { .islandHue($0, on: UsageLayout.barTrack) } ?? .islandAccent(tint(agent), on: UsageLayout.barTrack)
    }

    /// A percentage's words, on `backdrop`; `dim` below 1 for an old figure among newer.
    static func text(_ percent: Double, on backdrop: IslandBackdrop = .island, dim: Double = 1) -> IslandStyle {
        guard dim >= 1 else { return .islandText(dim, on: backdrop) }
        return hue(percent).map { .islandHueText($0, on: backdrop) } ?? .islandText(1, on: backdrop)
    }
}

// MARK: - Home

/// The AI Usage tile: a column for each agent with a reading, its windows' bars, how
/// full each is and when it resets; the plan or how old the reading is beside its name.
/// A dimmed column is a Claude reading the app has not renewed for 20 minutes, or
/// Gemini's last while Antigravity is closed; a dimmed window an old figure beside newer
/// ones or the limit. The window at its limit says so in red, or "Limit reached" heads
/// the column where none can be told to be. As it shows, Gemini's quota is asked for
/// again where a read is due, and Claude's limits refreshed where they have grown old.
struct UsageHomeTile: View {
    let center: UsageCenter

    var body: some View {
        let statuses = UsageAgent.allCases.compactMap { center.status($0) }
        // Three columns, on a tile two-thirds as wide again (`UsageCenter.tileWeight`),
        // sit a little closer.
        HStack(alignment: .top, spacing: statuses.count >= 3 ? 10 : 14) {
            ForEach(statuses, id: \.agent) { status in
                UsageColumn(status: status)
            }
        }
        .onAppear {
            center.willShow()
            center.claudeWillShow()
        }
    }
}

/// One agent on the tile.
struct UsageColumn: View {
    let status: UsageStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(status.agent.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.islandText(0.9, on: .homeTile))
                    .fixedSize()
                Spacer(minLength: 2)
                // Only where it fits whole: the name comes first.
                if let detail {
                    ViewThatFits(in: .horizontal) {
                        UsageAgeText(status: status, prefix: "", fallback: detail)
                            .fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.islandText(0.45, on: .homeTile))
                }
            }
            .lineLimit(1)
            if status.showsLimit, status.shownLimitWindow == nil {
                Text("Limit reached")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.islandHueText(.failure, on: .homeTile))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, window in
                UsageWindowRow(status: status, window: window, atLimit: status.showsAtLimit(window))
                    .opacity(status.dimsAlone(window) ? 0.5 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(status.isDimmed ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.agent.name + ": " + UsageText.line(status))
    }

    /// The windows the column has room for: all of them, or of more (Gemini's), those
    /// at their limit and the fullest, in their order.
    private var rows: [UsageStatus.Window] {
        let windows = status.windows
        guard windows.count > UsageLayout.tileRows else { return windows }
        let ranked = windows.indices.sorted { a, b in
            let first = status.showsAtLimit(windows[a]), second = status.showsAtLimit(windows[b])
            if first != second { return first }
            return windows[a].percent > windows[b].percent
        }
        let kept = Set(ranked.prefix(UsageLayout.tileRows))
        return windows.indices.filter { kept.contains($0) }.map { windows[$0] }
    }

    /// Beside the name: how old the reading is where that is worth saying, or else the
    /// plan.
    private var detail: String? {
        status.showsAge ? "" : UsageText.plan(status.reading.plan)
    }
}

/// A window on the tile: its name and how full it is, a bar, and when it resets. At the
/// limit, "Limit" and a full bar in red, whatever the figure last said.
private struct UsageWindowRow: View {
    let status: UsageStatus
    let window: UsageStatus.Window
    var atLimit = false

    var body: some View {
        let percent = atLimit ? 100 : window.percent
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(UsageText.shortName(window.window, beside: status.agent))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.islandText(0.55, on: .homeTile))
                    .lineLimit(1)
                    // A source's long name keeps its end, which tells a model's limits apart.
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Text(atLimit ? "Limit" : window.isReset ? "0%" : UsageText.percent(percent))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(UsageColours.text(percent, on: .homeTile))
                    .fixedSize()
                    .layoutPriority(1)
            }
            UsageBar(percent: percent, agent: status.agent)
                .frame(height: UsageLayout.barHeight)
            Text(UsageText.resetShort(window, now: status.now) ?? " ")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.islandText(0.45, on: .homeTile))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// How full a window is, as a thin bar in the agent's colour, orange from 80%, red at
/// the limit.
struct UsageBar: View {
    let percent: Double
    let agent: UsageAgent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.islandSurface(0.16))
                if percent > 0 {
                    Capsule().fill(UsageColours.fill(percent, agent: agent))
                        .frame(width: max(proxy.size.height, proxy.size.width * min(1, percent / 100)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.4), value: percent)
    }
}

/// How old a reading is, "25 min ago", redrawn each minute while it shows, but not
/// while the island saves energy; `fallback` where it is not old enough to say.
struct UsageAgeText: View {
    let status: UsageStatus
    var prefix = "as of "
    var fallback = ""

    var body: some View {
        if EnergySaver.shared.isSaving || !status.showsAge {
            Text(text(at: status.now))
        } else {
            TimelineView(.everyMinute) { context in
                Text(text(at: max(context.date, status.now)))
            }
        }
    }

    private func text(at date: Date) -> String {
        guard status.showsAge else { return fallback }
        return prefix + UsageText.age(date.timeIntervalSince(status.reading.measured))
    }
}

// MARK: - Pages

/// The line atop an activity's page: "5h 42% · resets 4:10 PM · Week 18%", a window
/// from 80% in orange and at the limit in red, "5h limit"; dimmed while the reading is
/// old, a figure of it alone where only that one is, and how old said, each minute while
/// the island does not save energy.
struct UsageLine: View {
    let status: UsageStatus

    var body: some View {
        if status.showsAge, !EnergySaver.shared.isSaving {
            TimelineView(.everyMinute) { context in
                styled(line(at: max(context.date, status.now)))
            }
        } else {
            styled(line(at: status.now))
        }
    }

    private func styled(_ line: Text) -> some View {
        line
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .frame(height: UsageLayout.lineHeight)
            .opacity(status.isDimmed ? 0.5 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.agent.name + " usage: " + UsageText.line(status))
    }

    /// The words as of `date`, each window's percentage in its colour.
    private func line(at date: Date) -> Text {
        var text = Text("")
        var first = true
        func add(_ part: Text) {
            text = first ? part : text + Text(" · ").foregroundStyle(.islandText(0.35)) + part
            first = false
        }
        let limit = status.shownLimitWindow
        if status.showsLimit, limit == nil {
            add(Text("Limit reached").foregroundStyle(.islandHueText(.failure)))
        }
        for (index, window) in status.windows.enumerated() {
            // An old figure beside newer ones, or beside the limit, is dimmed alone.
            let dim = status.dimsAlone(window) ? 0.5 : 1
            let name = Text(UsageText.shortName(window.window, beside: status.agent) + " ").foregroundStyle(.islandText(0.55 * dim))
            if window.isReset {
                add(name + Text("reset").foregroundStyle(.islandText(0.75 * dim)))
                continue
            }
            let atLimit = status.showsAtLimit(window)
            let figure = atLimit
                ? Text("limit").foregroundStyle(.islandHueText(.failure))
                : Text(UsageText.percent(window.percent)).foregroundStyle(UsageColours.text(window.percent, dim: dim))
            add(name + figure)
            if index == 0 || atLimit || window.percent >= UsageAlerts.levels[0], let reset = UsageText.reset(window, now: status.now) {
                add(Text(reset).foregroundStyle(.islandText(0.55 * dim)))
            }
        }
        if status.showsAge {
            add(Text("as of " + UsageText.age(date.timeIntervalSince(status.reading.measured))).foregroundStyle(.islandText(0.4)))
        }
        return text
    }
}

// MARK: - Compact

/// An agent's mark in the compact island, inside a ring as full as its fullest window
/// from 80%: orange, and red at the limit. Below 80% the mark as it always was.
struct UsageRingMark<Mark: View>: View {
    let usage: CompactUsage
    @ViewBuilder var mark: Mark

    var body: some View {
        ZStack {
            if let fraction = usage.ring {
                UsageRing(fraction: fraction, atLimit: usage.atLimit)
                    .frame(width: UsageLayout.ringSize, height: UsageLayout.ringSize)
                    .transition(.opacity)
            }
            mark
                .scaleEffect(usage.ring == nil ? 1 : UsageLayout.ringMark)
        }
        .animation(.easeInOut(duration: 0.35), value: usage.ring == nil)
    }
}

struct UsageRing: View {
    let fraction: Double
    var atLimit = false

    var body: some View {
        let hue = UsageColours.hue(fraction * 100, atLimit: atLimit) ?? .warning
        ZStack {
            Circle().inset(by: UsageLayout.ringWidth / 2)
                .stroke(.islandDecorative(0.18), lineWidth: UsageLayout.ringWidth)
            Circle().inset(by: UsageLayout.ringWidth / 2)
                .trim(from: 0, to: min(1, max(0.04, fraction)))
                .stroke(.islandHue(hue), style: StrokeStyle(lineWidth: UsageLayout.ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityElement()
        .accessibilityLabel(atLimit ? "Usage limit reached" : "Usage at \(Int(fraction * 100)) percent")
    }
}

/// Right of the notch at the limit: "limit · 4:10", when it lifts, in red; "limit"
/// where nothing says when.
struct UsageLimitTrailing: View {
    let usage: CompactUsage
    let now: Date

    var body: some View {
        Text(words)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.islandHueText(.failure))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .accessibilityLabel(usage.resets.map { "Usage limit reached, lifts at " + UsageText.time($0, now: now) }
                                ?? "Usage limit reached")
    }

    private var words: String {
        guard let resets = usage.resets else { return "limit" }
        return "limit · " + UsageText.compactTime(resets, now: now)
    }
}

// MARK: - Settings

/// The usage settings in an agent's pane: whether its limits show, warn and ring the
/// mark, for Claude whether they are refreshed where old, and what Islet last read of
/// them.
struct UsageSettingsRows: View {
    let agent: UsageAgent
    let center: UsageCenter
    @AppStorage private var shows: Bool
    @AppStorage private var warns: Bool
    @AppStorage private var ring: Bool
    @AppStorage private var refreshes: Bool

    init(agent: UsageAgent, center: UsageCenter? = nil) {
        self.agent = agent
        let center = center ?? .shared
        self.center = center
        _shows = AppStorage(wrappedValue: true, UsagePrefs.showKey(agent), store: center.defaults)
        _warns = AppStorage(wrappedValue: true, UsagePrefs.warnKey(agent), store: center.defaults)
        _ring = AppStorage(wrappedValue: true, UsagePrefs.ringKey(agent), store: center.defaults)
        _refreshes = AppStorage(wrappedValue: true, UsagePrefs.refreshClaude, store: center.defaults)
    }

    /// The Claude toggle's title, as Settings' search finds it.
    static let refreshTitle = "Refresh Claude usage when it's old"

    var body: some View {
        Toggle(isOn: $shows) {
            Text("Show usage limits")
            Text(summary)
        }
        Toggle(isOn: $warns) {
            Text("Warn at 80% and 95%")
            Text("A banner as a window reaches 80% of your limit, and again at 95%, once for each window until it resets. Reaching the limit always gets one, with when it lifts.")
        }
        .disabled(!shows)
        Toggle(isOn: $ring) {
            Text("Usage ring in the compact island")
            Text("From 80%, an orange ring round the mark beside the notch, red at the limit. At the limit, when it lifts takes the place of the turn's time either way.")
        }
        .disabled(!shows)
        if agent == .claude {
            Toggle(isOn: $refreshes) {
                Text(Self.refreshTitle)
                Text("When the figures are over 20 minutes old as the AI Usage tile or this page opens, Islet sends Claude a tiny request with Quick Ask's token and stops it as soon as the figures arrive, at most once every 15 minutes. Each uses a sliver of your allowance.")
            }
            .disabled(!shows)
        }
        LabeledContent(Self.sourceLabel(agent)) {
            TimelineView(.everyMinute) { context in
                Text(source(at: context.date))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// What the line of what was last read is labelled, as Settings' search finds it.
    static func sourceLabel(_ agent: UsageAgent) -> String {
        switch agent {
        case .claude: "Last reading"
        case .chatGPT: "ChatGPT plan"
        case .gemini: "Gemini quota"
        }
    }

    private var summary: String {
        switch agent {
        case .claude:
            "Your plan's 5-hour and weekly limits on the AI Usage tile and atop the opened page, from the Claude app's own record of them, which it updates every 15 minutes while it's open, and exactly whenever Quick Ask asks Claude or Islet refreshes them. Dimmed once they're 20 minutes old."
        case .chatGPT:
            "Your plan's limits on the AI Usage tile and atop the opened page, as Codex notes them after each reply, with their exact resets. Nothing is read of the chats themselves; a window past its reset shows as reset."
        case .gemini:
            "Your Gemini quota on the AI Usage tile and atop the opened page, as Antigravity's own quota screen shows it: while Antigravity is open, Islet asks Antigravity's local server, at most once a minute, with the one-time key Antigravity starts it with, which Islet never keeps. Unofficial, so an update of Antigravity may stop it; while Antigravity is closed, the last figures show dimmed."
        }
    }

    /// "Last sample 12 min ago", "Plus · 120 credits".
    private func source(at date: Date) -> String {
        guard shows else { return "Not read while usage limits are off" }
        switch agent {
        case .claude:
            return Self.claude(history: center.claudeHistory, event: center.claudeEvent,
                               note: refreshes ? center.claudeRefreshNote : nil, now: date)
        case .chatGPT:
            guard let reading = center.readings[.chatGPT] else { return "Not seen yet: Codex notes it after a reply" }
            let plan = UsageText.plan(reading.plan) ?? "Unknown plan"
            return ([plan, UsageText.credits(reading.credits), "as of " + UsageText.age(date.timeIntervalSince(reading.measured))]
                .compactMap { $0 }).joined(separator: " · ")
        case .gemini:
            return Self.gemini(open: center.antigravityOpen, source: center.geminiSource, measured: center.geminiMeasured, now: date)
        }
    }

    /// Where the figures shown came from and how long ago: "Quick Ask 3 min ago",
    /// "Refreshed 2 min ago", "Claude app 38 h ago"; then, where the last refresh since
    /// failed or none can be made, why: "Claude app 38 h ago · couldn't refresh: no answer".
    static func claude(history: ClaudeUsage.History?, event: ClaudeUsage.LimitEvent?, note: ClaudeUsageRefresh.Note?,
                       now: Date) -> String {
        let sample = history?.reading?.measured
        var said: Date?
        var line: String
        if let event, sample.map({ event.at > $0 }) ?? true {
            said = event.at
            line = (event.source == .refresh ? "Refreshed " : "Quick Ask ") + UsageText.age(now.timeIntervalSince(event.at))
        } else {
            switch history {
            case .read(let reading)?:
                said = reading.measured
                line = "Claude app " + UsageText.age(now.timeIntervalSince(reading.measured))
            case .unknownFormat?:
                line = "Its usage file is in a format Islet doesn't know"
            case .missing?:
                line = "No usage file yet: open the Claude app"
            case nil:
                line = "Not read yet"
            }
        }
        let why: String?
        switch note {
        case .done(let at, let outcome)?:
            guard said.map({ at > $0 }) ?? true else { return line }
            switch outcome {
            case .read: why = nil
            case .notSignedIn: why = "couldn't refresh: Claude didn't accept the token"
            case .noFigures: why = "couldn't refresh: Claude didn't say"
            case .timedOut: why = "couldn't refresh: no answer"
            case .failed: why = "couldn't refresh"
            }
        case .cannot(.noToken)?: why = "connect Claude in Quick Ask to refresh"
        case .cannot(.notInstalled)?: why = "refreshing needs Claude Code in the Claude app"
        default: why = nil
        }
        if let why { line += " · " + why }
        return line
    }

    /// "Antigravity: read 2 min ago", "Antigravity closed: last read 3 h ago",
    /// "Antigravity's quota couldn't be read".
    static func gemini(open: Bool, source: UsageCenter.GeminiSource, measured: Date?, now: Date) -> String {
        guard open else {
            return "Antigravity closed: " + (measured.map { "last read " + UsageText.age(now.timeIntervalSince($0)) } ?? "nothing read yet")
        }
        switch source {
        case .read(let at): return "Antigravity: read " + UsageText.age(now.timeIntervalSince(at))
        case .failed: return "Antigravity's quota couldn't be read"
        case .notRead: return "Antigravity: not read yet"
        }
    }
}
