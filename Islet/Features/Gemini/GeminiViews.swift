import AppKit
import SwiftUI

extension FeatureTint {
    /// A soft violet blue, kept clear of the blue and the purple the island's privacy
    /// marks take. Never Google's colours or logo.
    static let gemini = FeatureTint.colour(RGB(bytes: 140, 128, 255))
}

enum GeminiLayout {
    /// Room right of the notch for the run's time, to an hour and past it (smaller), or
    /// for a ring filling as the task list gets done.
    static let trailingWidth: CGFloat = 58
    static let compactRing: CGFloat = 16
    static let compactSymbol: CGFloat = 15
    static let minimalSymbol: CGFloat = 12
    static let minimalRingInset: CGFloat = 0.1
    static let minimalRingMark: CGFloat = 0.75

    // The opened page: a row per conversation; under its title what it is working in,
    // the tools it has used so far and its task list.
    static let topInset: CGFloat = 4
    static let bottomInset: CGFloat = 2
    static let rowPadding: CGFloat = 5
    static let sessionSpacing: CGFloat = 4
    static let titleHeight: CGFloat = 18
    static let textHeight: CGFloat = 16
    static let historyHeight: CGFloat = 15
    static let sectionTop: CGFloat = 3
    static let tasksHeaderHeight: CGFloat = 15
    static let taskLineHeight: CGFloat = 16
    static let agentLineHeight: CGFloat = 16
    static let barWidth: CGFloat = 76
    /// The tallest the page grows before its rows scroll, as for ChatGPT.
    static let maxPageHeight: CGFloat = 244
    static let scrollFade: CGFloat = 18

    static func trailingInset(rowHeight: CGFloat) -> CGFloat {
        max(0, (IslandLayout.defaultSide(for: CGSize(width: 0, height: rowHeight)) - compactRing) / 2)
    }

    static func tasksHeight(_ session: GeminiSession) -> CGFloat {
        guard let tasks = GeminiText.tasks(session) else { return 0 }
        return sectionTop + tasksHeaderHeight + CGFloat(tasks.shown.count) * taskLineHeight
    }

    static func agentsHeight(_ session: GeminiSession) -> CGFloat {
        let count = GeminiText.agentLines(session).count
        return count == 0 ? 0 : sectionTop + CGFloat(count) * agentLineHeight
    }

    static func rowHeight(_ session: GeminiSession, showsText: Bool) -> CGFloat {
        var height = 2 * rowPadding + titleHeight
        if GeminiText.detail(session, showsText: showsText) != nil { height += textHeight }
        if GeminiText.history(session) != nil { height += historyHeight }
        return height + agentsHeight(session) + tasksHeight(session)
    }

    static func listHeight(_ sessions: [GeminiSession], showsText: Bool) -> CGFloat {
        guard !sessions.isEmpty else { return 2 * rowPadding + titleHeight }
        let rows = sessions.reduce(0) { $0 + rowHeight($1, showsText: showsText) }
        return rows + CGFloat(sessions.count - 1) * sessionSpacing
    }

    static func pageHeight(for sessions: [GeminiSession], showsText: Bool) -> CGFloat {
        min(topInset + listHeight(sessions, showsText: showsText) + bottomInset, maxPageHeight)
    }
}

/// The words the island uses for a conversation.
enum GeminiText {
    /// How much of a title names a conversation.
    static let titleLimit = 34
    /// How much of a tool's name its words take, so they leave the title room.
    static let stepNameLimit = 22
    static let historyNameLimit = 18

    /// Antigravity's title for the conversation, or the start of it, or a CLI session's
    /// latest prompt, while Settings shows what was asked; else its project; else the app.
    static func title(_ session: GeminiSession, showsText: Bool) -> String {
        let record = session.record
        if showsText, let words = record.isCLI ? firstWords(record.prompt)
            : firstWords(session.title) ?? firstWords(session.preview) { return words }
        if !record.project.isEmpty { return record.project }
        return record.isCLI ? "Gemini CLI" : "Antigravity"
    }

    /// Where the conversation runs, at the start of the line under the title: Antigravity,
    /// or the app a CLI session's terminal is ("Terminal", "iTerm").
    static func source(_ session: GeminiSession) -> String {
        let record = session.record
        guard record.isCLI else { return "Antigravity" }
        return GeminiCLIHost.appNames[record.hostApp] ?? "Terminal"
    }

    /// The line under the title: where it runs, then why it stopped, for one stopped by an
    /// error, where the error says more than the status does; else the project, where the
    /// title is not it, and the model.
    static func detail(_ session: GeminiSession, showsText: Bool) -> String? {
        let record = session.record
        let place = source(session)
        if session.state == .error {
            let error = oneLine(session.error)
            if !error.isEmpty { return place + " · " + error }
            return session.isQuota ? place + " · Until the quota resets" : place
        }
        var parts = [place]
        let title = title(session, showsText: showsText)
        if !record.project.isEmpty, record.project != title { parts.append(record.project) }
        if let model = model(session) { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    /// The model, where Antigravity names one other than its own choice.
    static func model(_ session: GeminiSession) -> String? {
        let model = oneLine(session.record.model)
        return model.isEmpty || model.lowercased() == "auto" ? nil : model
    }

    /// Where the branch goes, while Settings shows it and the hook found one: beside the
    /// title where the title is the project, or else beside the project in the line under
    /// it. `nil` where neither shows the project (a conversation stopped on an error says
    /// why there instead).
    static func branch(_ session: GeminiSession, showsText: Bool, showsBranch: Bool) -> (branch: String, inTitle: Bool)? {
        let record = session.record
        guard showsBranch, !record.project.isEmpty, !record.branch.isEmpty else { return nil }
        if title(session, showsText: showsText) == record.project { return (record.branch, true) }
        return session.state == .error ? nil : (record.branch, false)
    }

    /// How a conversation stands, in words.
    static func status(_ session: GeminiSession) -> String {
        switch session.state {
        case .working:
            if session.onlyAgents { return session.agents.count == 1 ? "Agent at work" : "Agents at work" }
            if let step = session.record.step { return doing(step) }
            return session.record.ended == .background ? "Background tasks" : "Working"
        case .needsInput:
            switch session.waiting {
            case .question?: return "Has a question"
            case .approval?: return session.record.isCLI ? "Needs permission" : "Waiting for approval"
            case .plan?: return "Has a plan for you"
            case .input?, nil: return "Needs your input"
            }
        case .error:
            if session.isQuota { return "Out of quota" }
            return session.failedAgent == nil ? "Stopped on an error" : "An agent stopped"
        case .idle: return "Done"
        }
    }

    /// The subagents to list under a conversation, `agentLimit` at most.
    static func agentLines(_ session: GeminiSession) -> [GeminiAgent] {
        Array(session.agents.prefix(agentLimit))
    }

    /// How many subagents are listed under a conversation, at most.
    static let agentLimit = 3

    /// A subagent's name, as words: "browser_subagent" as "browser subagent"; else
    /// "Subagent".
    static func agentName(_ agent: GeminiAgent) -> String {
        let name = GeminiToolWords.readable(oneLine(agent.record.agent))
        return name.isEmpty ? "Subagent" : middle(name, 28)
    }

    /// What a subagent is doing, in a few words.
    static func agentStatus(_ agent: GeminiAgent) -> String {
        status(GeminiSession(record: agent.record, state: agent.state, waiting: agent.waiting))
    }

    static func doing(_ step: GeminiStep) -> String {
        var step = step
        if step.name.count > stepNameLimit { step.name = String(step.name.prefix(stepNameLimit - 1)) + "…" }
        return GeminiToolWords.doing(step)
    }

    /// The words for how a conversation stands: the accent while it works, orange while
    /// it waits on the person or is out of quota, red for an error.
    static func style(_ session: GeminiSession) -> IslandStyle {
        switch session.state {
        case .working: .islandAccentText(.gemini)
        case .needsInput: .islandHueText(.warning)
        case .error: .islandHueText(session.isQuota ? .warning : .failure)
        case .idle: .islandText(0.5)
        }
    }

    /// What the timer beside a conversation counts from: the run's start while it works,
    /// the asking while it waits on the person; nothing once it has stopped.
    static func timerStart(_ session: GeminiSession) -> Date? {
        switch session.state {
        case .working: session.record.turnStart
        case .needsInput: session.waitingSince
        case .error, .idle: nil
        }
    }

    /// What a CLI session asks permission for, while it waits: "Asks to run npm".
    static func asking(_ session: GeminiSession) -> String? {
        guard session.record.isCLI, session.state == .needsInput, session.waiting == .approval,
              let step = session.record.asking
        else { return nil }
        let name = middle(oneLine(step.name), stepNameLimit)
        return switch step.kind {
        case .shell: name.isEmpty ? "Asks to run a command" : "Asks to run \(name)"
        case .edit: name.isEmpty ? "Asks to change a file" : "Asks to change \(name)"
        case .mcp: name.isEmpty ? "Asks to use a tool" : "Asks to use \(name)"
        case .web: "Asks to fetch from the web"
        default: name.isEmpty ? "Asks to use a tool" : "Asks to use \(GeminiToolWords.readable(name))"
        }
    }

    /// The run's tools so far, once it has used two or more: how many, and the latest
    /// programs and files among them, "14 steps · swift, Store.swift +2". For a CLI session
    /// asking permission, what for, and how many steps before it.
    static func history(_ session: GeminiSession) -> String? {
        if let asking = asking(session) {
            let steps = session.record.steps
            return steps > 0 ? asking + " · \(steps) step\(steps == 1 ? "" : "s") so far" : asking
        }
        let steps = session.record.steps
        guard !session.history.isEmpty, steps >= 2 else { return nil }
        var names: [String] = []
        for entry in session.history.reversed() {
            switch entry.kind {
            case .shell, .edit, .read, .mcp:
                let name = oneLine(entry.name)
                if !name.isEmpty, !names.contains(name) { names.append(name) }
            case .browser:
                if !names.contains("the browser") { names.append("the browser") }
            default: continue
            }
        }
        var line = "\(steps) steps"
        guard !names.isEmpty else { return line }
        line += " · " + names.prefix(3).map { middle($0, historyNameLimit) }.joined(separator: ", ")
        if names.count > 3 { line += " +\(names.count - 3)" }
        return line
    }

    /// The task list, while the agent works or waits on the person.
    static func tasks(_ session: GeminiSession) -> GeminiTaskList? {
        guard session.state == .working || session.state == .needsInput, let tasks = session.tasks,
              !tasks.items.isEmpty
        else { return nil }
        return tasks
    }

    /// "3 of 7 done".
    static func tasksHeader(_ tasks: GeminiTaskList) -> String {
        "\(tasks.done) of \(tasks.items.count) done"
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

    /// `text` cut to `limit` characters in its middle: "AVeryLong…Name.swift".
    static func middle(_ text: String, _ limit: Int) -> String {
        guard text.count > limit, limit > 2 else { return text }
        let head = (limit - 1) / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(limit - 1 - head))
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Marks

/// The island's mark for what Gemini is doing: a wand that breathes while an agent
/// works, and while one waits on the person or has stopped, the wand with a question
/// mark or a warning at its corner, in orange (or red, for an error). An ordinary
/// symbol, never Google's logo.
struct GeminiMarkView: View {
    let mark: GeminiModel.Mark?
    var pointSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch mark {
            case .needsInput?:
                badged("questionmark.circle.fill", .warning)
            case .quota?:
                badged("exclamationmark.circle.fill", .warning)
            case .error?:
                badged("exclamationmark.circle.fill", .failure)
            case .working?:
                if reduceMotion {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: pointSize, weight: .semibold))
                        .foregroundStyle(.islandAccent(.gemini))
                } else {
                    ClaudeBreathingSymbol(name: "wand.and.stars", pointSize: pointSize, ink: .accent(.gemini))
                        .transition(.opacity)
                }
            case nil:
                EmptyView()
            }
        }
        .frame(width: pointSize * 1.5, height: pointSize * 1.5)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: mark)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    /// The wand with a badge at its lower right, cut clear of it by a ring the island
    /// shows through.
    private func badged(_ badge: String, _ hue: SystemHue) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "wand.and.stars")
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
        .foregroundStyle(.islandHue(hue))
        .compositingGroup()
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    private var label: String {
        switch mark {
        case .needsInput?: "Gemini needs your input"
        case .quota?: "Gemini is out of quota"
        case .error?: "Gemini stopped on an error"
        case .working?: "Gemini working"
        case nil: ""
        }
    }
}

/// How far the task list has got: a ring filling in the accent, round from the top.
/// Never quite empty, so it reads as a ring under way rather than an empty circle.
struct GeminiTaskRing: View {
    let fraction: Double
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().inset(by: lineWidth / 2)
                .stroke(.islandDecorative(0.22), lineWidth: lineWidth)
            Circle().inset(by: lineWidth / 2)
                .trim(from: 0, to: max(0.04, min(1, fraction)))
                .stroke(.islandAccent(.gemini), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut(duration: 0.5), value: fraction)
    }
}

// MARK: - Compact

/// Left of the notch: the mark.
struct GeminiCompactLeading: View {
    let model: GeminiModel

    var body: some View {
        GeminiMarkView(mark: model.mark, pointSize: GeminiLayout.compactSymbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Right of the notch: how long a conversation has waited on the person; or, while one
/// works with a task list, a ring filling as it gets done; else how long the run has
/// been going; or a word for why it stopped.
struct GeminiCompactTrailing: View {
    let model: GeminiModel

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let session = model.displayed {
                    if session.state == .working, let fraction = model.fraction {
                        GeminiTaskRing(fraction: fraction, lineWidth: 2.5)
                            .frame(width: GeminiLayout.compactRing, height: GeminiLayout.compactRing)
                            .padding(.trailing, GeminiLayout.trailingInset(rowHeight: proxy.size.height))
                            .accessibilityElement()
                            .accessibilityLabel("\(Int((fraction * 100).rounded())) percent of its tasks done")
                    } else if let start = GeminiText.timerStart(session) {
                        Text(start, style: .timer)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(GeminiText.style(session))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.trailing, 6)
                    } else {
                        Text(session.isQuota ? "Quota" : "Error")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(GeminiText.style(session))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.trailing, 6)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
    }
}

/// In the bubble, or folded into the island: the mark, inside a ring filling as the task
/// lists get done, while any has one.
struct GeminiMinimal: View {
    let model: GeminiModel

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let fraction = model.needsYou ? nil : model.fraction
            ZStack {
                if let fraction {
                    GeminiTaskRing(fraction: fraction, lineWidth: 2)
                        .padding(side * GeminiLayout.minimalRingInset)
                        .transition(.opacity)
                }
                GeminiMarkView(mark: model.mark, pointSize: GeminiLayout.minimalSymbol)
                    .scaleEffect(fraction == nil ? 1 : GeminiLayout.minimalRingMark)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: - Expanded

/// Opened: a row per conversation, those waiting on the person first. Clicking one
/// brings Antigravity forward.
struct GeminiExpanded: View {
    let model: GeminiModel
    let open: (GeminiSession) -> Void
    @AppStorage(GeminiPrefs.showPrompt) private var showsText = true
    @AppStorage(GeminiPrefs.showBranch) private var showsBranch = true

    var body: some View {
        let sessions = model.shown
        let height = GeminiLayout.pageHeight(for: sessions, showsText: showsText) - GeminiLayout.topInset
            - GeminiLayout.bottomInset
        let scrolls = GeminiLayout.listHeight(sessions, showsText: showsText) > height + 0.5
        ScrollView(.vertical) {
            VStack(spacing: GeminiLayout.sessionSpacing) {
                ForEach(sessions) { session in
                    GeminiSessionRow(session: session, showsText: showsText, showsBranch: showsBranch) { open(session) }
                        .transition(.opacity)
                }
            }
            .padding(.bottom, scrolls ? GeminiLayout.scrollFade : 0)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        // The foot fades while the rows overflow, as ChatGPT's does.
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: scrolls ? GeminiLayout.scrollFade : 0)
            }
        }
        .frame(height: max(0, height), alignment: .top)
        .padding(.top, GeminiLayout.topInset)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.islandMorph, value: sessions.map(\.id))
    }
}

private struct GeminiSessionRow: View {
    let session: GeminiSession
    let showsText: Bool
    let showsBranch: Bool
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let branch = GeminiText.branch(session, showsText: showsText, showsBranch: showsBranch)

        Button(action: open) {
            HStack(alignment: .top, spacing: 9) {
                // The status beside the title says the same, in words.
                GeminiMarkView(mark: GeminiModel.Mark(session), pointSize: 12)
                    .frame(width: 18, height: GeminiLayout.titleHeight)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        if let branch, branch.inTitle {
                            FolderBranchLabel(folder: session.record.project, branch: branch.branch)
                        } else {
                            Text(GeminiText.title(session, showsText: showsText))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.islandPrimary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        status
                    }
                    .frame(height: GeminiLayout.titleHeight)
                    .accessibilityElement(children: .combine)

                    if let branch, !branch.inTitle {
                        // Where it runs, the project and its branch, then the model, kept whole.
                        HStack(spacing: 0) {
                            Text(verbatim: GeminiText.source(session) + " · ")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.islandText(0.5))
                                .lineLimit(1)
                                .fixedSize()
                            FolderBranchLabel(folder: session.record.project, branch: branch.branch, size: .detail)
                            if let model = GeminiText.model(session) {
                                Text(verbatim: " · " + model)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.islandText(0.5))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .frame(height: GeminiLayout.textHeight, alignment: .leading)
                    } else if let detail = GeminiText.detail(session, showsText: showsText) {
                        Text(detail)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.islandText(0.5))
                            .lineLimit(1)
                            .frame(height: GeminiLayout.textHeight, alignment: .leading)
                    }

                    if let history = GeminiText.history(session) {
                        Text(history)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.islandText(0.45))
                            .lineLimit(1)
                            .frame(height: GeminiLayout.historyHeight, alignment: .leading)
                            .accessibilityLabel(GeminiText.asking(session) == nil ? "Steps so far: \(history)" : history)
                    }

                    let agents = GeminiText.agentLines(session)
                    if !agents.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(agents) { agent in
                                GeminiAgentLine(agent: agent, more: agent.id == agents.last?.id
                                                ? session.agents.count - agents.count : 0)
                            }
                        }
                        .padding(.top, GeminiLayout.sectionTop)
                    }

                    if let tasks = GeminiText.tasks(session) {
                        GeminiTaskChecklist(tasks: tasks)
                            .padding(.top, GeminiLayout.sectionTop)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, GeminiLayout.rowPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(shape.fill(.islandDecorative(isHovering ? 0.08 : 0)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Go to \(GeminiText.source(session))")
    }

    private var status: some View {
        HStack(spacing: 0) {
            Text(GeminiText.status(session))
                .foregroundStyle(GeminiText.style(session))
            if let start = GeminiText.timerStart(session) {
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

/// A subagent the conversation sent off: its name, and what it is doing, with how many
/// more there are on the last line listed.
private struct GeminiAgentLine: View {
    let agent: GeminiAgent
    var more = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.islandGraphic(0.45))
                .frame(width: 10, height: 10)
            Text(GeminiText.agentName(agent))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.islandText(0.8))
                .lineLimit(1)
            if more > 0 {
                Text("+\(more)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.islandText(0.45))
            }
            Spacer(minLength: 6)
            Text(GeminiText.agentStatus(agent))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(GeminiText.style(GeminiSession(record: agent.record, state: agent.state)))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: GeminiLayout.agentLineHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subagent \(GeminiText.agentName(agent)), \(GeminiText.agentStatus(agent))"
                            + (more > 0 ? ", and \(more) more" : ""))
    }
}

/// The agent's task list as a checklist: a bar and how many items are done, then a line
/// an item, from where it has got to, a tick for each done and a dotted ring for the one
/// under way.
private struct GeminiTaskChecklist: View {
    let tasks: GeminiTaskList

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.islandDecorative(0.14))
                        Capsule().fill(.islandAccent(.gemini))
                            .frame(width: max(proxy.size.height, proxy.size.width * tasks.fraction))
                    }
                }
                .frame(width: GeminiLayout.barWidth, height: 3)
                .animation(.easeInOut(duration: 0.5), value: tasks.fraction)
                Text(GeminiText.tasksHeader(tasks))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.islandText(0.42))
            }
            .frame(height: GeminiLayout.tasksHeaderHeight, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tasks, \(GeminiText.tasksHeader(tasks))")
            ForEach(Array(tasks.shown.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    icon(item.status)
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 10, height: 10)
                    Text(item.text)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.islandText(item.status == .completed ? 0.55 : 0.8))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                }
                .frame(height: GeminiLayout.taskLineHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(value(item.status)): \(item.text)")
            }
        }
    }

    @ViewBuilder
    private func icon(_ status: GeminiTaskList.Item.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.islandGraphic(0.45))
        case .inProgress:
            Image(systemName: "circle.dotted").foregroundStyle(.islandAccent(.gemini))
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.islandGraphic(0.45))
        }
    }

    private func value(_ status: GeminiTaskList.Item.Status) -> String {
        switch status {
        case .pending: "To do"
        case .inProgress: "Under way"
        case .completed: "Done"
        }
    }
}

// MARK: - Settings

struct GeminiSettingsView: View {
    let model: GeminiModel
    @AppStorage(GeminiPrefs.showPrompt) private var showPrompt = true
    @AppStorage(GeminiPrefs.showBranch) private var showBranch = true
    @AppStorage(GeminiPrefs.skipDoneOnScreen) private var skipDoneOnScreen = true
    @State private var copied = false
    @State private var copiedCLI = false
    @State private var setup: GeminiHookSetup?
    @State private var cliSetup: GeminiCLIHookSetup?
    @State private var canReadTitles = AXIsProcessTrusted()

    var body: some View {
        Toggle(isOn: $showPrompt) {
            Text("Show what you asked")
            Text("Each conversation in the opened island goes by Antigravity's title for it, which says what you asked in a few words, and each Gemini CLI session by your latest prompt. Off, they show by workspace alone.")
        }

        Toggle(isOn: $showBranch) {
            Text("Show the git branch")
            Text("Beside each conversation's workspace, in the opened island and in its banners, the branch it's on, or the commit where none is checked out. The hook reads it at each event, so a checkout shows at the next. Off, the workspace alone.")
        }

        Toggle(isOn: $skipDoneOnScreen) {
            Text("Skip Done when the chat is on screen")
            Text(canReadTitles
                 ? "No banner when an agent finishes in the conversation Antigravity has in front; its row still updates. Islet reads Antigravity's window title to tell, and never changes anything in it. Off, every finish gets a banner."
                 : "No banner when an agent finishes in the conversation Antigravity has in front. Islet tells by Antigravity's window title, which needs Accessibility for Islet in System Settings › Privacy & Security; until then every finish gets a banner.")
            Text("For Gemini CLI, none when Gemini finishes in the Terminal or iTerm tab in front. Islet asks the terminal which tab that is only once you've let it select tabs, with a click on a session's row; until then, and in any other app, every finish gets a banner.")
        }

        LabeledContent {
            Button(copied ? "Copied" : "Copy Hooks") {
                GeminiHooks.copy()
                copied = true
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Text("Antigravity hooks")
            Text("Copy Scripts/antigravity-hook.sh from Islet's source to \(GeminiHooks.script) and add this to \(GeminiHooks.file), beside any hooks already there (it is a JSON object: put \"\(GeminiHooks.name)\" inside its braces). Antigravity reads it as it starts an agent. Islet never writes to ~/.gemini: you add the hook yourself.")
            Text(GeminiHooks.entryJSON)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
            Text("The hook only tells Islet what Antigravity does: it answers each event with the answer Antigravity's documentation gives for leaving things as they are, and it isn't on PreToolUse, so it is never asked about a tool before it runs. Of each tool only the program it runs, the file it touches or the tool's name is kept, never the command, the change or what came back. Titles, task lists and whether a question or a tool waits on you are read from Antigravity's own files; its list of conversations is read as any SQLite reader reads it, which marks the reader's place in that database's shared-memory index (its -shm file) and changes no data or setting.")
        }

        LabeledContent("Islet's hook") {
            Text(setup?.words ?? "Looking…")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .task {
            // Read again every few seconds while Settings shows it, so a hook just added
            // shows as set up.
            while !Task.isCancelled {
                setup = await Task.detached(priority: .utility) { GeminiHookSetup.check() }.value
                canReadTitles = AXIsProcessTrusted()
                try? await Task.sleep(for: .seconds(4))
            }
        }

        LabeledContent("Last heard from Gemini") {
            TimelineView(.everyMinute) { context in
                Text(Self.heard(model.lastHeard, now: context.date))
                    .foregroundStyle(.secondary)
            }
        }

        cli
    }

    /// Gemini CLI's hooks, their state, and when they were last heard from.
    @ViewBuilder
    private var cli: some View {
        LabeledContent {
            Button(copiedCLI ? "Copied" : "Copy Hooks") {
                GeminiCLIHooks.copy()
                copiedCLI = true
            }
            .task(id: copiedCLI) {
                guard copiedCLI else { return }
                try? await Task.sleep(for: .seconds(2))
                copiedCLI = false
            }
        } label: {
            Text("Gemini CLI hooks")
            Text("Copy Scripts/gemini-cli-hook.sh from Islet's source to \(GeminiCLIHooks.script) and add this to \(GeminiCLIHooks.file), inside its outer braces beside what is there (if it has \"hooks\" already, put each event in it). Gemini CLI reads it as a session starts, and runs hooks only in folders you trust. Islet never writes to ~/.gemini: you add the hooks yourself.")
            Text(GeminiCLIHooks.entryJSON)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
            Text("The hook only tells Islet what Gemini CLI does: it answers every event with {}, which Gemini CLI's documentation gives as the answer that changes nothing, and Gemini CLI gives a hook no way to allow a tool, so a permission it asks shows in the island and is answered in the terminal. Of each tool only the program it runs, the file it touches or the tool's name is kept, never the command, the change or what came back; of your prompt, its first line. The session's own file is read only for whether a turn ended on Gemini's reply and which model gave it.")
        }

        LabeledContent("Islet's Gemini CLI hook") {
            Text(cliSetup?.words ?? "Looking…")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .task {
            while !Task.isCancelled {
                cliSetup = await Task.detached(priority: .utility) { GeminiCLIHookSetup.check() }.value
                try? await Task.sleep(for: .seconds(4))
            }
        }

        LabeledContent("Last heard from Gemini CLI") {
            TimelineView(.everyMinute) { context in
                Text(Self.heard(model.lastHeardCLI, now: context.date, from: "start a session in a folder you trust"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func heard(_ date: Date?, now: Date, from start: String = "start an agent in Antigravity") -> String {
        guard let date else { return "Not yet: once the hook is added, \(start)" }
        guard now.timeIntervalSince(date) >= 60 else { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
