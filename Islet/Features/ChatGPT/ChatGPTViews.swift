import AppKit
import SwiftUI

extension FeatureTint {
    /// The island's ink, as ChatGPT's own look is black and white: the mark, the ring
    /// and the spinners. Under any other accent, the accent.
    static let chatGPT = FeatureTint.neutral
}

enum ChatGPTLayout {
    /// Room right of the notch for the turn's time, to an hour and past it (smaller), or
    /// for the count of tasks at work beside a spinner, or beside a ring filling as the
    /// sessions get on.
    static let trailingWidth: CGFloat = 58
    static let compactSpinner: CGFloat = 16
    static let compactSymbol: CGFloat = 15
    static let minimalSymbol: CGFloat = 12
    /// Between the bubble's edge and the ring round the mark, as a share of its width;
    /// and the mark's size inside the ring.
    static let minimalRingInset: CGFloat = 0.1
    static let minimalRingMark: CGFloat = 0.75

    // The opened page: a row per session; under it the turn's steps so far, the goal, the
    // plan, the agents and the commands left running.
    static let topInset: CGFloat = 4
    static let bottomInset: CGFloat = 2
    static let rowPadding: CGFloat = 5
    static let sessionSpacing: CGFloat = 4
    static let titleHeight: CGFloat = 18
    static let textHeight: CGFloat = 16
    /// Above the plan, and above the agents.
    static let sectionTop: CGFloat = 3
    /// The plan's first line, how far it has got; then a line a step.
    static let planHeaderHeight: CGFloat = 15
    static let planLineHeight: CGFloat = 16
    /// An agent's line: its task and for how long; and under it what it is doing.
    static let agentHeight: CGFloat = 17
    static let agentDetailHeight: CGFloat = 15
    /// The line of the turn's steps so far, under what was asked.
    static let historyHeight: CGFloat = 15
    /// The goal's line; and under it, where it has a budget, how much of it is used.
    static let goalHeight: CGFloat = 17
    static let goalDetailHeight: CGFloat = 15
    /// A command left running: what it runs, and for how long.
    static let terminalHeight: CGFloat = 17
    /// The width of a progress bar.
    static let barWidth: CGFloat = 76
    /// The tallest the page grows before its rows scroll, as for Claude Code: as tall as
    /// the island leaves room for under a notch 40 points deep.
    static let maxPageHeight: CGFloat = 244
    static let scrollFade: CGFloat = 18
    /// How far the page's foot cuts into the last line it shows, once the rows scroll,
    /// so the fade always lies across a line's words.
    static let scrollPeek: CGFloat = 12
    /// The fade at the head of the rows once they are scrolled down.
    static let topFade: CGFloat = 10

    /// Between the spinner and the island's outer end, in a row `rowHeight` tall: the
    /// mark on the left is centred in the default wing, so the spinner is centred in the
    /// same width at the right, whatever the notch's height.
    static func trailingInset(rowHeight: CGFloat) -> CGFloat {
        max(0, (IslandLayout.defaultSide(for: CGSize(width: 0, height: rowHeight)) - compactSpinner) / 2)
    }

    static func planHeight(_ session: ChatGPTSession) -> CGFloat {
        session.plan.isEmpty ? 0 : sectionTop + planHeaderHeight + CGFloat(session.plan.count) * planLineHeight
    }

    static func agentsHeight(_ session: ChatGPTSession) -> CGFloat {
        let count = session.agentsShown.count
        return count == 0 ? 0 : sectionTop + CGFloat(count) * (agentHeight + agentDetailHeight)
    }

    static func goalHeight(_ session: ChatGPTSession) -> CGFloat {
        guard let goal = session.goal else { return 0 }
        return sectionTop + goalHeight + (goal.budget == nil ? 0 : goalDetailHeight)
    }

    static func terminalsHeight(_ session: ChatGPTSession) -> CGFloat {
        session.terminals.isEmpty ? 0 : sectionTop + CGFloat(session.terminals.count) * terminalHeight
    }

    static func rowHeight(_ session: ChatGPTSession, showsText: Bool) -> CGFloat {
        var height = 2 * rowPadding + titleHeight
        if ChatGPTText.detail(session, showsText: showsText) != nil { height += textHeight }
        if ChatGPTText.history(session) != nil { height += historyHeight }
        return height + goalHeight(session) + planHeight(session) + agentsHeight(session) + terminalsHeight(session)
    }

    static func listHeight(_ sessions: [ChatGPTSession], showsText: Bool) -> CGFloat {
        guard !sessions.isEmpty else { return 2 * rowPadding + titleHeight }
        let rows = sessions.reduce(0) { $0 + rowHeight($1, showsText: showsText) }
        return rows + CGFloat(sessions.count - 1) * sessionSpacing
    }

    /// The most the rows take before they scroll.
    static var listLimit: CGFloat { maxPageHeight - topInset }

    /// Where each line of the rows begins, from the top of the list, in the order the
    /// rows show them: each session's title, what was asked and its steps so far; its
    /// goal's lines, its plan's, its agents', then its commands left running.
    static func lineTops(_ sessions: [ChatGPTSession], showsText: Bool) -> [CGFloat] {
        var tops: [CGFloat] = []
        var rowTop: CGFloat = 0
        for session in sessions {
            var y = rowTop + rowPadding
            func line(_ height: CGFloat) {
                tops.append(y)
                y += height
            }
            line(titleHeight)
            if ChatGPTText.detail(session, showsText: showsText) != nil { line(textHeight) }
            if ChatGPTText.history(session) != nil { line(historyHeight) }
            if let goal = session.goal {
                y += sectionTop
                line(goalHeight)
                if goal.budget != nil { line(goalDetailHeight) }
            }
            if !session.plan.isEmpty {
                y += sectionTop
                line(planHeaderHeight)
                for _ in session.plan { line(planLineHeight) }
            }
            if !session.agentsShown.isEmpty {
                y += sectionTop
                for _ in session.agentsShown {
                    line(agentHeight)
                    line(agentDetailHeight)
                }
            }
            if !session.terminals.isEmpty {
                y += sectionTop
                for _ in session.terminals { line(terminalHeight) }
            }
            rowTop += rowHeight(session, showsText: showsText) + sessionSpacing
        }
        return tops
    }

    /// How much of the rows the page shows: all of them where they fit; otherwise as
    /// much as fits that ends `scrollPeek` into a line, so the fade lies across its words.
    static func visibleHeight(_ sessions: [ChatGPTSession], showsText: Bool) -> CGFloat {
        let list = listHeight(sessions, showsText: showsText)
        guard list > listLimit else { return list }
        return lineTops(sessions, showsText: showsText).map { $0 + scrollPeek }.last { $0 <= listLimit } ?? listLimit
    }

    static func pageHeight(for sessions: [ChatGPTSession], showsText: Bool) -> CGFloat {
        let list = listHeight(sessions, showsText: showsText)
        guard list > listLimit else { return min(topInset + list + bottomInset, maxPageHeight) }
        return topInset + visibleHeight(sessions, showsText: showsText)
    }
}

/// The words the island uses for a session.
enum ChatGPTText {
    /// How much of a prompt names a plain chat.
    static let titleLimit = 34
    /// How much of a step's name its words take, so they leave the title room.
    static let stepNameLimit = 22

    /// The project, or for a plain chat the prompt's first words, or the app it runs in.
    @MainActor
    static func title(_ session: ChatGPTSession, showsText: Bool) -> String {
        let record = session.record
        if !record.project.isEmpty { return record.project }
        if showsText, let words = firstWords(record.prompt) { return words }
        return ClaudeHostApps.name(for: record.hostApp) ?? "ChatGPT"
    }

    /// The start of `text`, cut at a word to at most `limit` characters.
    static func firstWords(_ text: String, limit: Int = titleLimit) -> String? {
        let text = oneLine(text)
        guard !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        let cut = text.prefix(limit - 1)
        let words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return words.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:—–-")) + "…"
    }

    /// The line under the title: what was asked, or once the reply is done the start of
    /// it. A plain chat named by the whole of its prompt does not say it twice.
    static func detail(_ session: ChatGPTSession, showsText: Bool) -> String? {
        guard showsText else { return nil }
        let record = session.record
        let text = oneLine(session.state == .idle && !record.reply.isEmpty ? record.reply : record.prompt)
        guard !text.isEmpty else { return nil }
        if record.isPlainChat, text == oneLine(record.prompt), firstWords(text) == text { return nil }
        return text
    }

    /// How a session stands, in words: what it is doing ("Running swift"), or that it is
    /// waiting on you, or that only its agents, or its goal, are at work.
    static func status(_ session: ChatGPTSession) -> String {
        switch session.state {
        case .working: session.record.step.map(doing) ?? "Working"
        case .needsPermission: "Needs permission"
        case .waitingForInput: "Has a question"
        case .idle: session.agentsAtWork.isEmpty && session.goal != nil ? "Working on the goal" : "Agents at work"
        }
    }

    /// A step's words, its name cut short enough to leave the title room.
    static func doing(_ step: ChatGPTStep) -> String {
        var step = step
        if step.name.count > stepNameLimit { step.name = String(step.name.prefix(stepNameLimit - 1)) + "…" }
        return ChatGPTToolWords.doing(step)
    }

    /// The words for how a session stands: the accent while it works, orange while it
    /// waits on you, grey while only its agents are at work.
    static func style(_ state: ChatGPTSessionState) -> IslandStyle {
        switch state {
        case .working: .islandAccentText(.chatGPT)
        case .needsPermission, .waitingForInput: .islandHueText(.warning)
        case .idle: .islandText(0.5)
        }
    }

    /// What the timer beside a session counts from: the turn's start while it works,
    /// the asking while it waits on you; nothing once the reply is done.
    static func timerStart(_ session: ChatGPTSession) -> Date? {
        switch session.state {
        case .working: session.record.turnStart
        case .needsPermission, .waitingForInput: session.record.since
        case .idle: nil
        }
    }

    /// "3 of 7 done".
    static func planHeader(_ session: ChatGPTSession) -> String {
        "\(session.record.planDone) of \(session.plan.count) done"
    }

    /// "Agent · fix tests", by the task it was sent off with; "Agent" where the hook
    /// could not tell which.
    static func agent(_ agent: ChatGPTAgent) -> String {
        let name = ChatGPTToolWords.readable(agent.name)
        return name.isEmpty ? "Agent" : "Agent · \(name)"
    }

    /// What an agent is doing, and how far it has gone: "Running cargo · 12 steps", or
    /// with a plan of its own, "2 of 5 done · Running cargo".
    static func agentDoing(_ agent: ChatGPTAgent) -> String {
        let doing = !agent.isRunning ? "Finished" : agent.step.map(Self.doing) ?? (agent.steps > 0 ? "Working" : "Starting")
        if let total = agent.planTotal, total > 0 { return "\(agent.planDone ?? 0) of \(total) done · \(doing)" }
        guard agent.steps > 0 else { return doing }
        return "\(doing) · " + (agent.steps == 1 ? "1 step" : "\(agent.steps) steps")
    }

    /// The compact island's count, read out.
    static func agents(_ count: Int) -> String {
        count == 1 ? "1 agent at work" : "\(count) agents at work"
    }

    /// How long a name in the steps so far may be.
    static let historyNameLimit = 18

    /// The turn's steps so far, while it goes on and has taken two or more: how many,
    /// and the latest programs, files and tools among them, "14 steps · swift,
    /// Store.swift, the computer +3".
    static func history(_ session: ChatGPTSession) -> String? {
        let steps = session.record.steps
        guard !session.history.isEmpty, steps >= 2 else { return nil }
        var names: [String] = []
        for entry in session.history.reversed() {
            let name: String
            switch entry.kind {
            case .shell, .patch: name = oneLine(entry.name)
            case .mcp: name = entry.name == "cua_repl" ? "the computer" : oneLine(entry.name)
            default: continue
            }
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        var line = "\(steps) steps"
        guard !names.isEmpty else { return line }
        line += " · " + names.prefix(3).map { middle($0, historyNameLimit) }.joined(separator: ", ")
        if names.count > 3 { line += " +\(names.count - 3)" }
        return line
    }

    /// `text` cut to `limit` characters in its middle: "AVeryLong…Name.swift".
    static func middle(_ text: String, _ limit: Int) -> String {
        guard text.count > limit, limit > 2 else { return text }
        let head = (limit - 1) / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(limit - 1 - head))
    }

    /// A command left running: "Running npm".
    static func terminal(_ shell: ChatGPTShell) -> String {
        let name = oneLine(shell.name)
        return name.isEmpty ? "Running a command" : "Running " + middle(name, stepNameLimit)
    }

    /// How a goal stands, in a word or two.
    static func goalStatus(_ goal: ChatGPTGoal) -> String {
        switch goal.status {
        case .active: "Goal"
        case .paused: "Paused"
        case .blocked: "Blocked"
        case .usageLimited: "Usage limit"
        case .budgetLimited: "Budget reached"
        case .complete: "Done"
        }
    }

    /// A goal's use of its budget: "12k of 50k tokens".
    static func tokens(_ used: Int, of budget: Int) -> String {
        "\(shortCount(used)) of \(shortCount(budget)) tokens"
    }

    /// A count of tokens, short: 850, 1.5k, 12k, 1.2M.
    static func shortCount(_ value: Int) -> String {
        func short(_ number: Double, _ unit: String) -> String {
            number < 10 && number != number.rounded(.down)
                ? String(format: "%.1f%@", number, unit) : "\(Int(number))\(unit)"
        }
        switch value {
        case ..<1000: return "\(max(0, value))"
        case ..<1_000_000: return short((Double(value) / 100).rounded(.down) / 10, "k")
        default: return short((Double(value) / 100_000).rounded(.down) / 10, "M")
        }
    }

    /// How long a goal has been worked on: "45 s", "12 min", "1 h 5 min".
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(0, seconds)) s" }
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// How long an agent has gone without a sign: "quiet 4 min".
    static func quiet(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes < 60 ? "quiet \(minutes) min" : "quiet \(minutes / 60) h \(minutes % 60) min"
    }

    /// Prompts waiting their turn: "2 queued".
    static func queued(_ count: Int) -> String { "\(count) queued" }

    /// The compact island's count and ring, read out: "2 agents at work, 40 percent done".
    static func background(agents: Int, fraction: Double?) -> String {
        var label = agents > 0 ? ChatGPTText.agents(agents) : ""
        if let fraction {
            let done = "\(Int((fraction * 100).rounded())) percent done"
            label = label.isEmpty ? done : label + ", " + done
        }
        return label
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Marks

/// The island's mark for what ChatGPT is doing: a speech bubble that breathes while it
/// works, still while only agents or a goal are at work, and while it waits on you, the bubble in
/// orange with a hand or a question mark at its corner, so it is never taken for Claude
/// Code's hand or question beside it. Ordinary symbols, never ChatGPT's logo, in the
/// island's ink or the accent.
struct ChatGPTMarkView: View {
    let mark: ChatGPTModel.Mark?
    var pointSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch mark {
            case .needsPermission?:
                badged("hand.raised.circle.fill")
            case .waitingForInput?:
                badged("questionmark.circle.fill")
            case .working?:
                if reduceMotion {
                    glyph("text.bubble.fill", .islandAccent(.chatGPT))
                } else {
                    ClaudeBreathingSymbol(name: "text.bubble.fill", pointSize: pointSize, ink: .accent(.chatGPT))
                        .transition(.opacity)
                }
            case .agents?, .goal?:
                glyph("text.bubble.fill", .islandAccent(.chatGPT))
            case nil:
                EmptyView()
            }
        }
        .frame(width: pointSize * 1.5, height: pointSize * 1.5)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: mark)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private func glyph(_ name: String, _ style: IslandStyle) -> some View {
        Image(systemName: name)
            .font(.system(size: pointSize, weight: .semibold))
            .foregroundStyle(style)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    /// The bubble with a badge at its lower right, cut clear of it by a ring the island
    /// shows through.
    private func badged(_ badge: String) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: pointSize * 0.92, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, pointSize * 0.06)
                .padding(.top, pointSize * 0.1)
            Circle()
                .frame(width: pointSize * 0.86, height: pointSize * 0.86)
                .blendMode(.destinationOut)
            Image(systemName: badge)
                .font(.system(size: pointSize * 0.64, weight: .bold))
                .frame(width: pointSize * 0.86, height: pointSize * 0.86)
        }
        .foregroundStyle(.islandHue(.warning))
        .compositingGroup()
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    private var label: String {
        switch mark {
        case .needsPermission?: "ChatGPT needs permission"
        case .waitingForInput?: "ChatGPT has a question"
        case .working?: "ChatGPT working"
        case .agents?: "ChatGPT agents at work"
        case .goal?: "ChatGPT working on a goal"
        case nil: ""
        }
    }
}

/// Agents at work: the Shortcuts spinner, in the accent, turned by Core Animation; still
/// with Reduce Motion on.
struct ChatGPTSpinner: View {
    var lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            ZStack {
                Circle().inset(by: lineWidth / 2)
                    .stroke(.islandDecorative(0.18), lineWidth: lineWidth)
                Circle().inset(by: lineWidth / 2)
                    .trim(from: 0, to: 0.3)
                    .stroke(.islandAccent(.chatGPT), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        } else {
            ShortcutSpinner(lineWidth: lineWidth, tint: .accent(.chatGPT))
        }
    }
}

/// How far the plan has got: a ring filling in the accent, round from the top. Never
/// quite empty, so it reads as a ring under way rather than an empty circle.
struct ChatGPTPlanRing: View {
    let fraction: Double
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().inset(by: lineWidth / 2)
                .stroke(.islandDecorative(0.22), lineWidth: lineWidth)
            Circle().inset(by: lineWidth / 2)
                .trim(from: 0, to: max(0.04, min(1, fraction)))
                .stroke(.islandAccent(.chatGPT), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut(duration: 0.5), value: fraction)
    }
}

// MARK: - Compact

/// Left of the notch: the mark.
struct ChatGPTCompactLeading: View {
    let model: ChatGPTModel

    var body: some View {
        ChatGPTMarkView(mark: model.mark, pointSize: ChatGPTLayout.compactSymbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Right of the notch: how long a session has been waiting on you; or while agents are
/// at work, how many, beside a ring filling as the sessions get on where there is a
/// measure of it, else a spinner; or else how long the turn on show has been going, or
/// a spinner while only a goal keeps it at work. Commands left running are listed only
/// when it is opened, as Claude Code's are: a server may run for days.
struct ChatGPTCompactTrailing: View {
    let model: ChatGPTModel

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let session = model.displayed {
                    let count = model.runningAgentCount
                    let fraction = model.fraction
                    if !session.state.needsYou, count > 0 {
                        HStack(spacing: 5) {
                            if fraction == nil || count > 1 {
                                Text("\(count)")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.islandText(0.6))
                                    .fixedSize()
                            }
                            Group {
                                if let fraction {
                                    ChatGPTPlanRing(fraction: fraction, lineWidth: 2.5)
                                } else {
                                    ChatGPTSpinner(lineWidth: 2.5)
                                }
                            }
                            .frame(width: ChatGPTLayout.compactSpinner, height: ChatGPTLayout.compactSpinner)
                        }
                        .padding(.trailing, ChatGPTLayout.trailingInset(rowHeight: proxy.size.height))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(ChatGPTText.background(agents: count, fraction: fraction))
                    } else if let start = ChatGPTText.timerStart(session) {
                        Text(start, style: .timer)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(ChatGPTText.style(session.state))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.trailing, 6)
                    } else {
                        ChatGPTSpinner(lineWidth: 2.5)
                            .frame(width: ChatGPTLayout.compactSpinner, height: ChatGPTLayout.compactSpinner)
                            .padding(.trailing, ChatGPTLayout.trailingInset(rowHeight: proxy.size.height))
                            .accessibilityElement()
                            .accessibilityLabel("Working on the goal")
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
    }
}

/// In the bubble, or folded into the island: the mark, inside a ring filling as the
/// sessions get on, while any has a measure of it: its plan or its agents.
struct ChatGPTMinimal: View {
    let model: ChatGPTModel

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let fraction = model.fraction
            ZStack {
                if let fraction {
                    ChatGPTPlanRing(fraction: fraction, lineWidth: 2)
                        .padding(side * ChatGPTLayout.minimalRingInset)
                        .transition(.opacity)
                }
                // A little smaller inside the ring, so the two do not touch.
                ChatGPTMarkView(mark: model.mark, pointSize: ChatGPTLayout.minimalSymbol)
                    .scaleEffect(fraction == nil ? 1 : ChatGPTLayout.minimalRingMark)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: - Expanded

/// Opened: a row per session, those waiting on you first. Clicking one brings forward
/// the app it runs in.
struct ChatGPTExpanded: View {
    let model: ChatGPTModel
    let open: (ChatGPTSession) -> Void
    @AppStorage(ChatGPTPrefs.showPrompt) private var showsText = true
    /// How deep the fade at the head of the rows is: as far as they are scrolled down,
    /// up to `ChatGPTLayout.topFade`.
    @State private var headFade: CGFloat = 0

    private static let listSpace = "chatGPTList"

    var body: some View {
        let sessions = model.shown
        let height = ChatGPTLayout.visibleHeight(sessions, showsText: showsText)
        let scrolls = ChatGPTLayout.listHeight(sessions, showsText: showsText) > height + 0.5
        let waiting = Set(sessions.filter(\.state.needsYou).map(\.id))

        // Always in a scroll view, so the list keeps its place as the rows refresh; its
        // foot fades while the rows overflow, as Claude Code's does.
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                rows(sessions)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        min(max(-proxy.frame(in: .named(Self.listSpace)).minY, 0), ChatGPTLayout.topFade)
                    } action: { headFade = $0 }
                    .padding(.bottom, scrolls ? ChatGPTLayout.scrollFade : 0)
            }
            .coordinateSpace(.named(Self.listSpace))
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .modifier(ChatGPTListFade(head: scrolls ? headFade : 0, foot: scrolls ? ChatGPTLayout.scrollFade : 0))
            // Those waiting on you are listed first: one starting to wait while the list
            // is scrolled down goes back to the top, at once.
            .onChange(of: waiting) { before, now in
                guard !now.subtracting(before).isEmpty, let first = sessions.first else { return }
                withAnimation(nil) { reader.scrollTo(first.id, anchor: .top) }
            }
        }
        .frame(height: height, alignment: .top)
        .padding(.top, ChatGPTLayout.topInset)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.islandMorph, value: sessions.map(\.id))
    }

    /// The rows at their own heights, which `ChatGPTLayout.rowHeight` works out.
    private func rows(_ sessions: [ChatGPTSession]) -> some View {
        VStack(spacing: ChatGPTLayout.sessionSpacing) {
            ForEach(sessions) { session in
                ChatGPTSessionRow(session: session, showsText: showsText) { open(session) }
                    .transition(.opacity)
            }
        }
    }
}

/// The rows' fades, at their head and foot, only while they scroll.
private struct ChatGPTListFade: ViewModifier {
    let head: CGFloat
    let foot: CGFloat

    func body(content: Content) -> some View {
        if head == 0 && foot == 0 {
            content
                .transition(.identity)
        } else {
            content
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: head)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: foot)
                    }
                }
                .transition(.identity)
        }
    }
}

private struct ChatGPTSessionRow: View {
    let session: ChatGPTSession
    let showsText: Bool
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        let host = ClaudeHostApps.name(for: session.record.hostApp)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Button(action: open) {
            HStack(alignment: .top, spacing: 9) {
                // The status beside the title says the same, in words.
                ChatGPTMarkView(mark: ChatGPTModel.Mark(session), pointSize: 12)
                    .frame(width: 18, height: ChatGPTLayout.titleHeight)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(ChatGPTText.title(session, showsText: showsText))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.islandPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        status
                    }
                    .frame(height: ChatGPTLayout.titleHeight)
                    .accessibilityElement(children: .combine)

                    if let detail = ChatGPTText.detail(session, showsText: showsText) {
                        Text(detail)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.islandText(0.5))
                            .lineLimit(1)
                            .frame(height: ChatGPTLayout.textHeight, alignment: .leading)
                    }

                    if let history = ChatGPTText.history(session) {
                        Text(history)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.islandText(0.45))
                            .lineLimit(1)
                            .frame(height: ChatGPTLayout.historyHeight, alignment: .leading)
                            .accessibilityLabel("Steps so far: \(history)")
                    }

                    if let goal = session.goal {
                        ChatGPTGoalRow(goal: goal)
                            .padding(.top, ChatGPTLayout.sectionTop)
                    }

                    if !session.plan.isEmpty {
                        ChatGPTPlanList(session: session)
                            .padding(.top, ChatGPTLayout.sectionTop)
                    }

                    if !session.agentsShown.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(session.agentsShown) { agent in
                                ChatGPTAgentRow(agent: agent)
                            }
                        }
                        .padding(.top, ChatGPTLayout.sectionTop)
                    }

                    if !session.terminals.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(session.terminals) { terminal in
                                ChatGPTTerminalRow(terminal: terminal)
                            }
                        }
                        .padding(.top, ChatGPTLayout.sectionTop)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, ChatGPTLayout.rowPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(shape.fill(.islandDecorative(isHovering && host != nil ? 0.08 : 0)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(host.map { "Go to \($0)" } ?? "")
    }

    private var status: some View {
        HStack(spacing: 0) {
            Text(ChatGPTText.status(session))
                .foregroundStyle(ChatGPTText.style(session.state))
            if session.queued > 0 {
                Text(" · ")
                    .foregroundStyle(.islandText(0.35))
                    .accessibilityHidden(true)
                Text(ChatGPTText.queued(session.queued))
                    .foregroundStyle(.islandText(0.55))
            }
            if let start = ChatGPTText.timerStart(session) {
                Text(" · ")
                    .foregroundStyle(.islandText(0.35))
                    .accessibilityHidden(true)
                Text(start, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(.islandText(0.55))
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }
}

/// The turn's plan as a checklist: a bar and how many steps are done, then a line a step,
/// a tick for each one done and a dotted ring for the one under way.
private struct ChatGPTPlanList: View {
    let session: ChatGPTSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ChatGPTProgressBar(fraction: session.planFraction ?? 0)
                    .frame(width: ChatGPTLayout.barWidth, height: 3)
                Text(ChatGPTText.planHeader(session))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.islandText(0.42))
            }
            .frame(height: ChatGPTLayout.planHeaderHeight, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Plan, \(ChatGPTText.planHeader(session))")
            ForEach(Array(session.plan.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 6) {
                    icon(step.status)
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 10, height: 10)
                    Text(ChatGPTText.oneLine(step.step))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.islandText(step.status == .completed ? 0.55 : 0.8))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                }
                .frame(height: ChatGPTLayout.planLineHeight)
                // The status in the label, not a value: the row's button runs its
                // children's values together apart from their labels.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(value(step.status)): \(ChatGPTText.oneLine(step.step))")
            }
        }
    }

    @ViewBuilder
    private func icon(_ status: ChatGPTPlanStep.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.islandGraphic(0.45))
        case .inProgress:
            Image(systemName: "circle.dotted").foregroundStyle(.islandAccent(.chatGPT))
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.islandGraphic(0.45))
        }
    }

    private func value(_ status: ChatGPTPlanStep.Status) -> String {
        switch status {
        case .pending: "To do"
        case .inProgress: "Under way"
        case .completed: "Done"
        }
    }
}

/// An agent the session has sent off: the task it was given, and for how long; under it,
/// what it is doing now and how many steps it has taken, or how far its own plan has got,
/// with a ring filling as it does. A tick once it has finished; a tag once it has gone
/// quiet.
private struct ChatGPTAgentRow: View {
    let agent: ChatGPTAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Group {
                    if agent.isRunning, let fraction = agent.planFraction {
                        ChatGPTPlanRing(fraction: fraction, lineWidth: 1.8)
                    } else if agent.isRunning {
                        ChatGPTSpinner(lineWidth: 1.5)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.islandGraphic(0.45))
                    }
                }
                .frame(width: 10, height: 10)
                Text(ChatGPTText.agent(agent))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.islandText(agent.isRunning ? 0.8 : 0.6))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if agent.isRunning, agent.firstSeen > .distantPast {
                    Text(agent.firstSeen, style: .timer)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.islandText(0.42))
                        .fixedSize()
                }
            }
            .frame(height: ChatGPTLayout.agentHeight)

            // The hook's files are read again every few seconds anyway; the clock only
            // moves the quiet time on while they stay the same.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 7) {
                    Text(ChatGPTText.agentDoing(agent))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.islandText(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let quiet = agent.quiet(at: context.date) {
                        ChatGPTTaskTag(text: ChatGPTText.quiet(quiet), style: .islandHueText(.warning))
                    }
                }
            }
            .padding(.leading, 16)
            .frame(height: ChatGPTLayout.agentDetailHeight, alignment: .top)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The thread's goal: its objective's first words, how it stands and how long it has
/// been worked on; under it, where it has a budget, a bar of how much is used.
private struct ChatGPTGoalRow: View {
    let goal: ChatGPTGoal

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: goal.status == .complete ? "checkmark.circle.fill" : "target")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.islandGraphic(0.45))
                    .frame(width: 10, height: 10)
                Text(goal.title.isEmpty ? "Goal" : goal.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.islandText(goal.status == .active ? 0.8 : 0.6))
                    .lineLimit(1)
                switch goal.status {
                case .active, .complete:
                    if !goal.title.isEmpty || goal.status == .complete {
                        Text(ChatGPTText.goalStatus(goal))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.islandText(0.35))
                            .fixedSize()
                    }
                case .paused, .blocked, .usageLimited, .budgetLimited:
                    ChatGPTTaskTag(text: ChatGPTText.goalStatus(goal), style: .islandHueText(.warning))
                }
                Spacer(minLength: 6)
                if goal.seconds > 0 {
                    Text(ChatGPTText.duration(goal.seconds))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.islandText(0.42))
                        .fixedSize()
                }
            }
            .frame(height: ChatGPTLayout.goalHeight)

            if let budget = goal.budget {
                HStack(spacing: 7) {
                    ChatGPTProgressBar(fraction: goal.fraction ?? 0)
                        .frame(width: ChatGPTLayout.barWidth, height: 3)
                    Text(ChatGPTText.tokens(goal.used, of: budget))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.islandText(0.42))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 16)
                .frame(height: ChatGPTLayout.goalDetailHeight, alignment: .top)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A command the chat left running: the program it runs, and for how long.
private struct ChatGPTTerminalRow: View {
    let terminal: ChatGPTShell

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.islandGraphic(0.45))
                .frame(width: 10, height: 10)
            Text(ChatGPTText.terminal(terminal))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.islandText(0.6))
                .lineLimit(1)
            Spacer(minLength: 6)
            ChatGPTTaskTimer(since: terminal.started)
        }
        .frame(height: ChatGPTLayout.terminalHeight)
        .accessibilityElement(children: .combine)
    }
}

/// How far a plan or a goal has got, as a thin bar in the accent.
private struct ChatGPTProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.islandDecorative(0.14))
                Capsule().fill(.islandAccent(.chatGPT))
                    .frame(width: max(proxy.size.height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .animation(.easeInOut(duration: 0.5), value: fraction)
    }
}

/// How long a task has been going, or nothing where that is not known.
private struct ChatGPTTaskTimer: View {
    let since: Date

    var body: some View {
        if since > .distantPast {
            Text(since, style: .timer)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.islandText(0.42))
                .fixedSize()
        }
    }
}

/// A word or two in colour on a task's line: an agent gone quiet, a goal held up.
private struct ChatGPTTaskTag: View {
    let text: String
    let style: IslandStyle

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(style)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Settings

struct ChatGPTSettingsView: View {
    let model: ChatGPTModel
    @AppStorage(ChatGPTPrefs.showPrompt) private var showPrompt = true
    @State private var copied = false

    var body: some View {
        Toggle(isOn: $showPrompt) {
            Text("Show what you asked")
            Text("Under each chat in the opened island, its latest prompt, or the start of ChatGPT's reply once it's done; a chat outside a project goes by its prompt. Off, chats show by project alone.")
        }

        LabeledContent {
            Button(copied ? "Copied" : "Copy Hooks") {
                ChatGPTHooks.copy()
                copied = true
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Text("Hooks")
            Text("Copy Scripts/chatgpt-hook.sh from Islet's source to ~/.codex/hooks/islet-notify.sh and add these hooks to ~/.codex/hooks.json, after any already there. ChatGPT runs them only once you trust them: in the ChatGPT app, Settings › Hooks (Reload hooks, then Trust beside each of Islet's), or with the /\u{2060}hooks command in Codex. If ChatGPT offers to import from Claude Code, leave its hooks out, or each chat shows twice. Islet never changes ~/.codex.")
            Text("Plan steps and a goal's title are ChatGPT's own words (or yours, for a goal you set), kept short and plain. Of each step only the program it runs, the file it changes or the tool it uses is kept, never the command, the change or what came back. Goals and queued follow-ups are read, read-only, from Codex's own files: a goal's title, state and use, and how many follow-ups wait, never their words.")
        }

        LabeledContent("Last heard from ChatGPT") {
            TimelineView(.everyMinute) { context in
                Text(Self.heard(model.lastHeard, now: context.date))
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func heard(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not yet: once the hooks are added, trust them in ChatGPT" }
        guard now.timeIntervalSince(date) >= 60 else { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
