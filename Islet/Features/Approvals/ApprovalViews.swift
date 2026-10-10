import AppKit
import Observation
import SwiftUI

/// The sizes of the approval card.
enum ApprovalLayout {
    /// The most of the request shown before it scrolls: what the page leaves once the
    /// header, the buttons and a line of the session rows have their room. The row of
    /// requests waiting behind it takes its room from here (`bodyLimit`).
    static let bodyHeight: CGFloat = 120
    static let buttonHeight: CGFloat = 26
    static let spacing: CGFloat = 6
    static let headerHeight: CGFloat = 34
    /// The row of requests waiting behind the card.
    static let waitingHeight: CGFloat = 20
    /// The card while presenting: a line saying the agent asks, and the buttons.
    static let privateHeight: CGFloat = 20 + spacing + buttonHeight

    /// The width the body's lines are laid out to: the opened island's page.
    static var bodyWidth: CGFloat {
        IslandLayout.expandedWidth - IslandLayout.expandedInset.leading - IslandLayout.expandedInset.trailing
    }

    /// The most of the request shown with `waiting` requests behind it: the row saying so
    /// takes its room from the request, so the session rows below keep a line clear of
    /// their fade.
    static func bodyLimit(waiting: Int) -> CGFloat {
        waiting > 0 ? bodyHeight - waitingHeight - spacing : bodyHeight
    }

    /// How tall the request's body is drawn: all of it, up to `bodyLimit`.
    static func visibleBody(_ item: ApprovalItem, waiting: Int = 0) -> CGFloat {
        min(ApprovalLines.height(item.body.sections, width: bodyWidth), bodyLimit(waiting: waiting))
    }

    /// Whether the request is taller than the part of it drawn, so has to be scrolled.
    static func scrolls(_ item: ApprovalItem, waiting: Int = 0) -> Bool {
        ApprovalLines.height(item.body.sections, width: bodyWidth) > bodyLimit(waiting: waiting)
    }

    /// Where a click on "Scroll to read it all" takes a request scrolled `offset` down, of
    /// `content` with `shown` of it in view: a page further, less a line kept from the
    /// page before so none is passed over unseen, and no further than its end.
    static func pageDown(from offset: CGFloat, shown: CGFloat, content: CGFloat) -> CGFloat {
        let end = max(0, content - shown)
        return min(max(0, offset) + max(ApprovalLines.lineHeight, shown - ApprovalLines.lineHeight), end)
    }

    /// The card's height, for the page it sits on, with `waiting` requests behind it.
    static func height(for item: ApprovalItem, waiting: Int = 0, isPrivate: Bool = false) -> CGFloat {
        guard !isPrivate else { return privateHeight }
        return headerHeight + spacing + visibleBody(item, waiting: waiting) + spacing
            + (waiting > 0 ? waitingHeight + spacing : 0) + buttonHeight
    }
}

/// What Settings says of approvals for each agent.
enum ApprovalSettingsText {
    /// The approvals key's state, in a few words.
    static func key(_ status: ApprovalSigner.Status?, agent: ApprovalAgent) -> String {
        let folder = agent == .claude ? "~/.claude/hooks" : "~/.codex/hooks"
        switch status {
        case .notInstalled?, nil:
            return "Not set up: Set Up puts the key the hook checks Islet's answers with beside it, in \(folder)."
        case .unread?, .ready?: return "Set up. The hook takes only answers signed with this key."
        case .keyChanged?:
            return "Islet's key and the one beside the hooks differ: one changed outside Islet. Until you reset it, the island offers only Answer in \(agent.name)."
        case .noKey?: return "Keychain didn't give Islet the key. Answer in \(agent.name), or set it up again."
        }
    }
}

/// The front request's arming, as the card and its Allow see it.
@MainActor
@Observable
final class ApprovalCardState {
    private(set) var arming: ApprovalArming
    /// A word under the buttons after a click that did not count.
    var note: String?
    /// What moves the request down for "Scroll to read it all".
    @ObservationIgnored weak var pager: ApprovalPagerView?

    init(item: ApprovalItem, openedAt: TimeInterval?) {
        arming = ApprovalArming(id: item.id, digest: item.request.digest, openedByItself: openedAt != nil)
        if let openedAt { arming.finishedOpening(at: openedAt) }
    }

    /// Changes the arming, telling the card only when something changed.
    func update(_ change: (inout ApprovalArming) -> Void) {
        var next = arming
        change(&next)
        if next != arming { arming = next }
    }
}

/// The card on an agent's page: what is asked, every key of the tool's input drawn as
/// written; the requests waiting behind it; and Answer in the app, Deny and Allow. It
/// never takes the keyboard, and Allow has no key equivalent. While presenting, it
/// says only that the agent asks.
struct ApprovalBlock: View {
    let center: ApprovalCenter
    let item: ApprovalItem
    /// Set for a moment once answered from the island: the buttons are off, and it says
    /// what was answered.
    var decided: ApprovalDecision? = nil
    /// The git branch the asking session is on, beside the folder (`ApprovalBranch`);
    /// `nil` for none.
    var branch: String? = nil
    /// Brings the app that asked forward.
    let openHost: (ApprovalRequest) -> Void
    @State private var state: ApprovalCardState
    @Environment(\.islandTheme) private var theme
    @Environment(\.island) private var island

    private static let bodySpace = "approvalBody"

    init(center: ApprovalCenter, item: ApprovalItem, decided: ApprovalDecision? = nil, branch: String? = nil,
         openHost: @escaping (ApprovalRequest) -> Void) {
        self.center = center
        self.item = item
        self.decided = decided
        self.branch = branch
        self.openHost = openHost
        _state = State(initialValue: ApprovalCardState(item: item, openedAt: center.openedFor[item.id]))
    }

    private var request: ApprovalRequest { item.request }
    private var app: String { request.hostName.isEmpty ? request.agent.name : request.hostName }

    var body: some View {
        Group {
            if center.isPrivate {
                privateCard
            } else {
                card
            }
        }
        .onAppear {
            center.cardShown(item.id, true)
            state.update { $0.shown(true, at: ProcessInfo.processInfo.systemUptime) }
        }
        .onDisappear {
            center.cardShown(item.id, false)
            state.update { $0.shown(false, at: ProcessInfo.processInfo.systemUptime) }
            // Closed with the pointer still on the island, the queue's order stands again.
            if center.held[request.agent] == item.id { center.hold(nil, for: request.agent) }
        }
        .onChange(of: island?.isHovering ?? false, initial: true) { _, inside in
            // In the island, the card stays in front; the pointer coming in is what lets
            // a card the island opened by itself for be answered.
            if inside { state.update { $0.pointerEnteredIsland(at: ProcessInfo.processInfo.systemUptime) } }
            if decided == nil { center.hold(inside ? item.id : nil, for: request.agent) }
        }
    }

    // MARK: Card

    private var card: some View {
        let waiting = center.waiting(for: request.agent)
        let visible = ApprovalLayout.visibleBody(item, waiting: waiting.count)
        return VStack(alignment: .leading, spacing: ApprovalLayout.spacing) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ApprovalBodyText(sections: item.body.sections, width: ApprovalLayout.bodyWidth)
                    // The end of the request: once inside the part drawn, it has all been
                    // seen. The part drawn is the scroll view's own height, which a body drawn
                    // taller than laid out overflows.
                    Color.clear.frame(height: 1)
                        .onGeometryChange(for: Bool.self) { proxy in
                            proxy.frame(in: .named(Self.bodySpace)).maxY <= visible + 0.5
                        } action: { seen in
                            if seen { state.update { $0.seen(true) } }
                        }
                }
                .padding(ApprovalLines.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { ApprovalPager(state: state).accessibilityHidden(true) }
            }
            .coordinateSpace(.named(Self.bodySpace))
            .frame(height: visible)
            .background(RoundedRectangle(cornerRadius: 10).fill(.islandSurface(0.08)))
            if !waiting.isEmpty { waitingRow(waiting) }
            buttons
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ApprovalCenter.spoken(item, isPrivate: false))
        .accessibilityValue(Self.spokenBody(item))
        .accessibilityActions { accessibilityButtons }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(ClaudeCodePalette.attentionMark)
                Text(verbatim: item.body.headline).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(headlineStyle)
                Spacer(minLength: 0)
                let mine = center.items(for: request.agent)
                if mine.count > 1, let index = mine.firstIndex(where: { $0.id == item.id }) {
                    Text(verbatim: "\(index + 1) of \(mine.count)").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.islandText(0.6))
                }
            }
            placeLine
        }
        .frame(height: ApprovalLayout.headerHeight, alignment: .top)
    }

    /// Who asks and where, on one line. With a branch, the folder and the branch as a
    /// session's row shows them (`ApprovalPlaceLayout`): the app keeps its name, a
    /// subagent's name keeps its room before the folder and the branch give way in their
    /// middles, and it goes whole, never cut to a sliver, only when they would not
    /// otherwise stay readable.
    @ViewBuilder
    private var placeLine: some View {
        if let branch {
            let place = Self.placeParts(request)
            ApprovalPlaceLayout {
                Text(verbatim: place.host).truncationMode(.tail)
                Text(verbatim: place.agent.isEmpty ? "" : " · " + place.agent).truncationMode(.tail)
                Text(verbatim: " · ")
                FolderBranchLabel(folder: place.folder, branch: branch, size: .caption,
                                  isMarked: ApprovalBranch.isLookAlike(branch))
                Text(verbatim: item.session.isEmpty ? "" : " · " + item.session)
            }
            .font(.system(size: 11)).lineLimit(1)
            .foregroundStyle(.islandText(0.6))
        } else {
            Text(verbatim: Self.place(request, session: item.session)).font(.system(size: 11)).lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.islandText(0.6))
        }
    }

    /// Running outside the sandbox says so in the attention colour.
    private var headlineStyle: IslandStyle {
        request.input["dangerouslyDisableSandbox"] == .bool(true) ? ClaudeCodePalette.attentionText : .islandText(1)
    }

    /// Where it runs: the host, a subagent's name, the folder with `~`, and when the
    /// session started.
    static func place(_ request: ApprovalRequest, session: String = "") -> String {
        let place = placeParts(request)
        return ([place.host] + (place.agent.isEmpty ? [] : [place.agent]) + [place.folder]
            + (session.isEmpty ? [] : [session])).joined(separator: " · ")
    }

    /// Who asks (the host, and a subagent's name or "") and the folder with `~`.
    static func placeParts(_ request: ApprovalRequest) -> (host: String, agent: String, folder: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = request.cwd.hasPrefix(home + "/") ? "~" + request.cwd.dropFirst(home.count) : request.cwd
        let host = request.hostName.isEmpty ? request.agent.name : request.hostName
        let agent = request.agentType.isEmpty ? "" : "agent name \"\(request.agentType)\""
        return (host, agent, String(folder))
    }

    /// The requests behind this one, each brought forward by a click.
    private func waitingRow(_ waiting: [ApprovalItem]) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "+\(waiting.count) waiting").font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(.islandText(0.6)).fixedSize()
            ForEach(waiting.prefix(3)) { other in
                Button {
                    center.hold(other.id, for: other.request.agent)
                } label: {
                    Text(verbatim: other.body.headline).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(.islandText(0.85))
                        .padding(.horizontal, 8).frame(height: ApprovalLayout.waitingHeight)
                        .islandWashed(.text(1), wash: 0.12, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(decided != nil)
            }
            Spacer(minLength: 0)
        }
        .frame(height: ApprovalLayout.waitingHeight)
    }

    private var buttons: some View {
        let offersAllow = center.offersAllow(item)
        return HStack(spacing: 8) {
            if let decided {
                Label(decided == .allow ? "Allowed" : "Denied",
                      systemImage: decided == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.islandText(0.85))
            } else if let note = state.note {
                Text(verbatim: note).font(.system(size: 11)).foregroundStyle(.islandText(0.7)).lineLimit(1)
                    .truncationMode(.middle)
            } else if !offersAllow {
                Text(verbatim: Self.withheldWords(item, center: center)).font(.system(size: 11))
                    .foregroundStyle(.islandText(0.7)).lineLimit(1).truncationMode(.middle)
            } else if center.maybeAnswered.contains(item.id), request.agent == .claude {
                Text("Claude may have answered already").font(.system(size: 11)).foregroundStyle(.islandText(0.6))
            } else if request.isBlocking {
                countdown
            }
            Spacer(minLength: 0)
            Group {
                answerInApp
                // A Deny Islet cannot sign would do nothing.
                if center.canSign(for: request.agent) { deny }
                if offersAllow {
                    if state.arming.bodySeen { allow } else { scrollOn }
                }
            }
            .disabled(decided != nil)
            .opacity(decided != nil ? 0.4 : 1)
        }
        .frame(height: ApprovalLayout.buttonHeight)
    }

    private var answerInApp: some View {
        RoundButton(symbol: "arrow.up.forward.app", diameter: ApprovalLayout.buttonHeight) {
            center.answer(item.id, .pass)
            openHost(request)
        }
        .help("Answer in \(app)")
        .accessibilityLabel("Answer in \(app)")
    }

    private var deny: some View {
        Button {
            takeDeny()
        } label: {
            Text("Deny").font(.system(size: 12, weight: .semibold)).foregroundStyle(.islandText(1))
                .padding(.horizontal, 14).frame(height: ApprovalLayout.buttonHeight)
                .islandWashed(.text(1), wash: 0.2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func takeDeny() {
        guard state.arming.mayDeny(at: ProcessInfo.processInfo.systemUptime) else {
            state.note = "Hold on a moment"
            return
        }
        Haptics.tap()
        if case .failure = center.answer(item.id, .deny) {
            state.note = "Couldn't answer here; answer in \(request.agent.name)"
        }
    }

    /// How long until the app asks itself, for a blocking request.
    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(verbatim: Self.countdownWords(request, now: context.date)).font(.system(size: 11))
                .foregroundStyle(.islandText(0.6)).lineLimit(1).truncationMode(.middle).monospacedDigit()
        }
    }

    /// "Claude asks in Terminal in 0:30": the agent, and where it asks, short enough to
    /// sit beside the buttons whole. Beside them, a host's name too long for the room is
    /// cut in its middle, so the time stays.
    static func countdownWords(_ request: ApprovalRequest, now: Date) -> String {
        let agent = request.agent.name
        let host = request.hostName.isEmpty || request.hostName == agent ? "the app" : request.hostName
        let left = max(0, Int(request.deadline.timeIntervalSince(now).rounded(.up)))
        return "\(agent) asks in \(host) in \(left / 60):\(String(format: "%02d", left % 60))"
    }

    /// Why the card offers no Allow, in a few words.
    static func withheldWords(_ item: ApprovalItem, center: ApprovalCenter) -> String {
        let request = item.request
        let app = request.hostName.isEmpty ? request.agent.name : request.hostName
        let reasons = item.body.withheld
        if reasons.contains(.hiddenCharacters) { return "This holds hidden characters. Check it in \(app)." }
        for reason in reasons {
            if case .sensitivePath(let place) = reason { return "It changes \(place). Answer in \(app)." }
        }
        if reasons.contains(where: { if case .unknownKey = $0 { return true }; return false })
            || reasons.contains(where: { if case .unexpectedValue = $0 { return true }; return false }) {
            return "It has settings the island can't show. Answer in \(app)."
        }
        if reasons.contains(.patchNotUnderstood) { return "Check this change in \(app)." }
        if reasons.contains(.unclearAddress) { return "Its address could be read two ways. Check it in \(app)." }
        if reasons.contains(.hostNotListed) { return "Allow only in \(app)." }
        switch center.signer.status(for: request.agent) {
        case .noKey: return "Keychain didn't give Islet the key. Answer in \(app)."
        case .notInstalled: return "Approvals aren't set up for \(request.agent.name). Answer in \(app)."
        default: return "The approvals key changed outside Islet. Answer in \(app)."
        }
    }

    /// In Allow's place until the end of the request has been seen: each click takes it
    /// a page further down, the last to its end. It allows nothing. Allow comes in its
    /// place, at its width, once the end is in view: a new view under a pointer that has
    /// not come onto it, so that pointer has to leave Allow for a moment and come back
    /// before Allow arms (`ApprovalAllowView`). Neither the click that scrolled nor a
    /// second click of a double-click can take it, and nothing else moves under them.
    private var scrollOn: some View {
        Button {
            state.pager?.pageDown()
        } label: {
            scrollLabel.foregroundStyle(.islandText(1))
                .islandWashed(.text(1), wash: 0.2, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    /// As wide as the words alone, so the countdown and notes beside the buttons keep
    /// their room.
    private var scrollLabel: some View {
        Text("Scroll to read it all")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14).frame(height: ApprovalLayout.buttonHeight)
    }

    /// Allow: filled with the agent's colour once armed, dimmed until then. The click is
    /// taken by an AppKit view, which sees the events themselves (`ApprovalClickCheck`).
    private var allow: some View {
        let colours = theme.filledButton(request.agent == .claude ? .claudeCode : .chatGPT)
        return TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let readiness = state.arming.readiness(at: ProcessInfo.processInfo.systemUptime)
            // A request that scrolled had "Scroll to read it all" here: Allow keeps its
            // width, so neither Allow nor Deny comes under the pointer that clicked it.
            ZStack {
                if ApprovalLayout.scrolls(item, waiting: center.waiting(for: request.agent).count) {
                    scrollLabel.hidden()
                }
                Text("Allow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colours.label)
                    .padding(.horizontal, 14)
            }
            .frame(height: ApprovalLayout.buttonHeight)
            .background(Capsule().fill(colours.fill))
            .opacity(readiness == .armed ? 1 : 0.45)
        }
        .overlay {
            ApprovalAllowTarget(
                pointer: { on, time in state.update { $0.pointer(onAllow: on, at: time) } },
                under: { state.update { $0.pointerUnder() } },
                click: { click in take(click) })
        }
        .accessibilityHidden(true)
    }

    private func take(_ click: ApprovalClickCheck.Click) {
        guard decided == nil else { return }
        let time = ProcessInfo.processInfo.systemUptime
        switch state.arming.readiness(at: time) {
        case .unseen: state.note = "Scroll to read it all"
        case .early:
            // Holding arms Allow only for a pointer that came onto it once the card had
            // been on screen long enough; any other, such as one Allow came under, has to
            // leave it and come back.
            let arming = state.arming
            let holding = arming.onAllow && (arming.enteredAllowAt ?? 0) >= (arming.shownLongEnoughFrom() ?? .infinity)
            state.note = holding ? "Hold on Allow for a moment" : "Move off Allow, then back onto it"
        case .armed:
            guard let token = state.arming.take(click, at: time) else {
                state.note = "This click came from another app; answer in \(request.agent.name)"
                return
            }
            allow(with: token)
        }
    }

    private func allow(with token: ApprovalClick) {
        Haptics.tap()
        if case .failure = center.answer(item.id, .allow, click: token) {
            state.note = "Couldn't answer here; answer in \(request.agent.name)"
        }
    }

    // MARK: Accessibility

    /// The card's buttons for VoiceOver and Switch Control, which never reach the drawn
    /// Allow: theirs counts only with one of them on, and the card a second on screen.
    @ViewBuilder
    private var accessibilityButtons: some View {
        Button("Answer in \(app)") {
            center.answer(item.id, .pass)
            openHost(request)
        }
        Button("Deny") { takeDeny() }
        if center.offersAllow(item) {
            Button("Allow") {
                let assisted = NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
                guard decided == nil,
                      let token = state.arming.takeAssisted(at: ProcessInfo.processInfo.systemUptime, assistiveOn: assisted)
                else {
                    state.note = "Hold on a moment"
                    return
                }
                allow(with: token)
            }
        }
    }

    /// The whole request, read out as the card's value.
    static func spokenBody(_ item: ApprovalItem) -> String {
        item.body.sections.map { section in
            (section.label.map { $0 + ": " } ?? "") + section.text
        }.joined(separator: "\n")
    }

    // MARK: Presenting

    /// While presenting or captured: that the agent asks, and to answer in its app.
    private var privateCard: some View {
        VStack(alignment: .leading, spacing: ApprovalLayout.spacing) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(ClaudeCodePalette.attentionMark)
                Text(verbatim: "\(request.agent.name) needs permission · Answer in \(app)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.islandText(1)).lineLimit(1)
            }
            .frame(height: 20)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                answerInApp
            }
            .frame(height: ApprovalLayout.buttonHeight)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The line under a card's headline with a branch, from its five parts: the host, a
/// subagent's part (" · agent name …", or empty), " · ", the folder and branch, and when
/// the session started (" · since …", or empty). All at their own widths where they
/// fit. Where they don't, the separator and the session's part keep theirs; the host
/// keeps its name, up to a third of the rest; the subagent's part keeps all it can while
/// the folder and branch are left `labelLeast` (or all they need), and goes whole when
/// that leaves it less than `agentLeast`, so it is never cut to a sliver; the folder and
/// branch take what is left, each giving way in its middle.
struct ApprovalPlaceLayout: Layout {
    /// The least the folder and branch are left before a subagent's name gives way:
    /// room for the start and end of each.
    static let labelLeast: CGFloat = 200
    /// The least a subagent's part is drawn in: " · agent name" and a few letters.
    static let agentLeast: CGFloat = 96

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(for: proposal.width, subviews)
        let height = zip(subviews, widths).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: widths.reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(for: bounds.width, subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }

    /// Each part's width within `available`.
    private func widths(for available: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard ideal.count == 5, let available, ideal.reduce(0, +) > available else { return ideal }
        let (host, agent, separator, label, session) = (ideal[0], ideal[1], ideal[2], ideal[3], ideal[4])
        var rest = max(0, available - separator - session)
        let hostWidth = min(host, rest / 3)
        rest -= hostWidth
        var agentWidth = min(agent, max(0, rest - min(label, Self.labelLeast)))
        if agentWidth < min(agent, Self.agentLeast) { agentWidth = 0 }
        rest -= agentWidth
        return [hostWidth, agentWidth, separator, min(label, rest), session]
    }
}

/// A request's body, line by line: each real line numbered where there are several, an
/// edit's lines marked `−` and `+`, a soft wrap marked `↩`, and words that could pass
/// for others (a letter from another script among Latin ones) underlined in the
/// attention colour.
struct ApprovalBodyText: View {
    let sections: [ApprovalSection]
    let width: CGFloat
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ApprovalLines.sectionSpacing) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 0) {
                    if let label = section.label {
                        Text(verbatim: label).font(.system(size: 10, weight: .medium)).foregroundStyle(.islandText(0.5))
                            .frame(height: ApprovalLines.labelHeight, alignment: .bottomLeading)
                    }
                    let gutter = ApprovalLines.gutter(section)
                    let lookAlikes = ApprovalText.lookAlikeWords(in: section.text)
                    ForEach(Array(ApprovalLines.lines(section, width: width).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            if gutter > 0 {
                                Text(verbatim: mark(section, line))
                                    .foregroundStyle(markColour(section))
                                    .frame(width: CGFloat(gutter) * ApprovalLines.advance, alignment: .leading)
                            }
                            // Wrapped already: the text system is never left to wrap it again.
                            Text(styled(line.text, section, lookAlikes: lookAlikes)).lineLimit(1).fixedSize()
                            if line.wraps { Text(verbatim: "↩").foregroundStyle(.islandText(0.4)).fixedSize() }
                        }
                        .font(.system(size: ApprovalLines.fontSize, design: .monospaced))
                        .frame(height: line.height, alignment: .leading)
                    }
                }
            }
        }
        .textSelection(.disabled)
    }

    private func mark(_ section: ApprovalSection, _ line: ApprovalLine) -> String {
        guard let number = line.number else { return "" }
        switch section.style {
        case .removed: return "−"
        case .added: return "+"
        default: return String(number)
        }
    }

    private func markColour(_ section: ApprovalSection) -> Color {
        switch section.style {
        case .removed: theme.hue(.red, minimum: Contrast.text)
        case .added: theme.hue(.green, minimum: Contrast.text)
        default: theme.text(0.35)
        }
    }

    private func styled(_ text: String, _ section: ApprovalSection, lookAlikes: [String]) -> AttributedString {
        var styled = AttributedString(text)
        styled.foregroundColor = theme.text(section.style == .prose || section.style == .field ? 0.7 : 1)
        for host in section.bold {
            var from = styled.startIndex
            while let range = styled[from...].range(of: host) {
                styled[range].font = .system(size: ApprovalLines.fontSize, weight: .bold, design: .monospaced)
                from = range.upperBound
            }
        }
        for word in lookAlikes {
            var from = styled.startIndex
            while let range = styled[from...].range(of: word) {
                styled[range].foregroundColor = theme.fitted(ClaudeCodePalette.attention, minimum: Contrast.text).color
                styled[range].underlineStyle = .single
                from = range.upperBound
            }
        }
        return styled
    }
}

/// Left of the notch while an agent asks: the raised hand, with how many ask from two.
struct ApprovalCompactLeading: View {
    let center: ApprovalCenter
    let agent: ApprovalAgent

    var body: some View {
        let count = center.items(for: agent).count
        Image(systemName: "hand.raised.fill")
            .font(.system(size: ClaudeCodeLayout.compactSymbol, weight: .semibold))
            .foregroundStyle(ClaudeCodePalette.attentionMark)
            .overlay(alignment: .bottomTrailing) {
                if count > 1 {
                    Text(verbatim: "\(count)").font(.system(size: 9, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.islandText(1))
                        .padding(.horizontal, 3).frame(minWidth: 13, minHeight: 12)
                        .islandWashed(.text(1), wash: 0.3, in: Capsule())
                        .offset(x: 7, y: 5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(count > 1 ? "\(agent.name) asks \(count) permissions" : "\(agent.name) asks permission")
    }
}

/// Right of the notch while an agent asks: "Allow?" ("Answer?" where the card offers no
/// Allow), or for an app that asks itself once the island has waited, the seconds left.
struct ApprovalCompactTrailing: View {
    let center: ApprovalCenter
    let agent: ApprovalAgent

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let item = center.front(for: agent) {
                    if item.request.isBlocking {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(verbatim: "\(max(0, Int(item.request.deadline.timeIntervalSince(context.date).rounded(.up))))s")
                                .monospacedDigit()
                        }
                    } else {
                        Text(center.offersAllow(item) ? "Allow?" : "Answer?")
                    }
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(ClaudeCodePalette.attentionText)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.trailing, 6)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
    }
}

/// In the bubble, while the agent's activity holds none of the island: the hand.
struct ApprovalMinimal: View {
    var body: some View {
        Image(systemName: "hand.raised.fill")
            .font(.system(size: ClaudeCodeLayout.minimalSymbol, weight: .semibold))
            .foregroundStyle(ClaudeCodePalette.attentionMark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Opens the island on an agent's page by itself for a request just come, once, when
/// its Settings say to and the person can see it: the pointer away from an island with
/// nothing open, not presenting or locked, and the app that asks not in front. It
/// closes again after a while unless the pointer comes in.
@MainActor
enum ApprovalOpening {
    /// How long the island stays open by itself.
    static let stays: TimeInterval = 12
    /// How long the island takes to open.
    static let opening: TimeInterval = 0.4

    static func open(for item: ApprovalItem, page: String, center: ApprovalCenter) {
        guard center.takeOpening(item), let island = IslandManager.shared.focusedController?.model else { return }
        center.openedByItself(item.id, finishing: ProcessInfo.processInfo.systemUptime + opening)
        if !island.peek(focus: page, for: stays) { center.openedByItself(item.id, finishing: nil) }
    }
}

/// Laid behind the request in its scroll view, as tall as it, for "Scroll to read it all"
/// to move it: SwiftUI's ScrollView is an NSScrollView underneath, the one this view is
/// inside. It takes no clicks or scrolling, which go to the request as before.
private struct ApprovalPager: NSViewRepresentable {
    let state: ApprovalCardState

    func makeNSView(context: Context) -> ApprovalPagerView { ApprovalPagerView() }

    func updateNSView(_ view: ApprovalPagerView, context: Context) { state.pager = view }
}

final class ApprovalPagerView: NSView {
    /// The scroll view's clip view, followed for its height.
    private var watched: NSClipView?

    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Takes the request a page down (`ApprovalLayout.pageDown`), the last click to its
    /// end, at once, as Page Down does. It only scrolls: the end coming into view is what
    /// brings Allow. The scroll view's document is SwiftUI's and has no height of its
    /// own, so the request's is this view's.
    func pageDown() {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let y = ApprovalLayout.pageDown(from: clip.bounds.origin.y, shown: clip.bounds.height, content: bounds.height)
        guard y > clip.bounds.origin.y + 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        watch()
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        watch()
    }

    /// Follows the scroll view this view is in, once it is in one.
    private func watch() {
        let clip = enclosingScrollView?.contentView
        guard clip !== watched else { return }
        if let watched { NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: watched) }
        watched = clip
        guard let clip else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification,
                                               object: clip)
    }

    /// A request coming behind this one, or going, changes how much of it is drawn, and
    /// SwiftUI then puts the scroll view back to its top: this keeps the line the person
    /// had read down to at the top instead.
    @objc private func clipResized() {
        guard let clip = watched else { return }
        let y = clip.bounds.origin.y
        guard y > 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let scroll = self.enclosingScrollView, scroll.contentView === clip else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(y, max(0, self.bounds.height - clip.bounds.height))))
            scroll.reflectScrolledClipView(clip)
        }
    }
}

/// The view that takes clicks on Allow: it tells where the pointer is from mouse
/// movement, and hands on each release with the press before it. Hidden from
/// accessibility, so only a person's click reaches it.
private struct ApprovalAllowTarget: NSViewRepresentable {
    let pointer: (Bool, TimeInterval) -> Void
    let under: () -> Void
    let click: (ApprovalClickCheck.Click) -> Void

    func makeNSView(context: Context) -> ApprovalAllowView { ApprovalAllowView() }

    func updateNSView(_ view: ApprovalAllowView, context: Context) {
        view.pointer = pointer
        view.under = under
        view.click = click
    }
}

/// The pointer counts as coming onto Allow only once it has been off Allow for half a
/// second; back sooner, it is told as under Allow, as when Allow came beneath it. Allow
/// takes the place of "Scroll to read it all" under a hand clicking it, and a drift over
/// Allow's edge between those clicks is not a person moving to Allow.
final class ApprovalAllowView: NSView {
    var pointer: (Bool, TimeInterval) -> Void = { _, _ in }
    /// Allow was laid out where the pointer already is.
    var under: () -> Void = {}
    var click: (ApprovalClickCheck.Click) -> Void = { _ in }
    private var down: ApprovalClickCheck.Event?
    /// How long the pointer has to be off Allow before coming back onto it counts.
    static let away: TimeInterval = 0.5
    /// Since when the pointer has been off Allow; `nil` while it is on it or not yet known.
    private var offSince: TimeInterval?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        // Called as Allow comes and whenever it moves: where the pointer is then is
        // where it was, not where it went.
        guard let window else { return }
        if bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            offSince = nil
            under()
        } else {
            moved(onAllow: false, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Where mouse movement puts the pointer, told on with `away` applied.
    private func moved(onAllow now: Bool, at time: TimeInterval) {
        if !now {
            if offSince == nil { offSince = time }
            pointer(false, time)
        } else if let off = offSince, time - off >= Self.away {
            offSince = nil
            pointer(true, time)
        } else {
            offSince = nil
            under()
        }
    }

    override func isAccessibilityElement() -> Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Movement onto Allow counts; a card appearing under a still pointer does not.
    override func mouseMoved(with event: NSEvent) {
        guard event.deltaX != 0 || event.deltaY != 0 else { return }
        moved(onAllow: bounds.contains(convert(event.locationInWindow, from: nil)), at: event.timestamp)
    }

    override func mouseExited(with event: NSEvent) {
        moved(onAllow: false, at: event.timestamp)
    }

    override func mouseDown(with event: NSEvent) {
        down = ApprovalClickCheck.Event(event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { down = nil }
        guard let window else { return }
        let inWindow = convert(bounds, to: nil)
        // The whole panel stands for the card: any other app's window over it refuses.
        let screen = window.frame
        let height = NSScreen.screens.first?.frame.maxY ?? screen.maxY
        let quartz = CGRect(x: screen.minX, y: height - screen.maxY, width: screen.width, height: screen.height)
        click(ApprovalClickCheck.Click(
            up: ApprovalClickCheck.Event(event), down: down, panelWindow: window.windowNumber, allowFrame: inWindow,
            cardOnScreen: quartz, panelWindowID: CGWindowID(window.windowNumber)))
    }
}

/// Settings' row for an agent's approvals key: how it stands, and Set Up, or once set
/// up, Reset Key. Either one is the only way the key file beside a hook is written.
struct ApprovalKeyRow: View {
    let agent: ApprovalAgent
    var signer: ApprovalSigner = ApprovalCenter.shared.signer
    @State private var status: ApprovalSigner.Status?
    /// Islet's key is not the one beside another hook: only Reset Key goes on.
    @State private var differs = false
    @State private var asksReset = false
    @State private var failed = false

    var body: some View {
        LabeledContent {
            if !differs, status == .notInstalled || status == .noKey || status == nil {
                Button("Set Up") { act { signer.install(for: agent) } }
            } else {
                Button("Reset Key…") { asksReset = true }
            }
        } label: {
            Text("Approvals key")
            Text(failed ? Self.failedWords(agent) : ApprovalSettingsText.key(differs ? .keyChanged : status, agent: agent))
        }
        .onAppear {
            // Read now, so a key changed outside Islet shows before a request comes.
            signer.check()
            status = signer.status(for: agent)
            differs = signer.differsFromInstalled
        }
        .confirmationDialog("Reset the approvals key?", isPresented: $asksReset) {
            Button("Reset Key") { act { signer.reset() } }
        } message: {
            Text("Islet makes a new key and puts it beside each hook set up for approvals. Do this if the key changed outside Islet, or you think another program has it.")
        }
    }

    private func act(_ action: () -> Bool) {
        let done = action()
        status = signer.status(for: agent)
        differs = signer.differsFromInstalled
        // A key that differs from another hook's says so itself, with Reset Key.
        failed = !done && !differs
    }

    static func failedWords(_ agent: ApprovalAgent) -> String {
        let folder = agent == .claude ? "~/.claude/hooks" : "~/.codex/hooks"
        return "Couldn't set it up: copy the hook script into \(folder) first. If Keychain asked about Islet's key and you didn't expect it, deny it and use Reset Key."
    }
}
