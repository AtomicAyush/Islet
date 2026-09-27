import SwiftUI

// MARK: - Panel

/// The song's lyrics in the opened player, in the library panel's place: timed lines
/// that light up as they are sung and follow along, or plain words to read, or what
/// stands in their way — loading, none found, an instrumental, no connection.
struct NowPlayingLyricsPanel: View {
    let model: NowPlayingModel
    let lyrics: NowPlayingLyricsModel

    var body: some View {
        VStack(spacing: 2) {
            LyricsPanelHeader(lyrics: lyrics)
                .padding(.horizontal, 8)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        switch lyrics.status {
        case .off:
            PanelMessage(text: "Lyrics are looked up on lrclib.net by the song’s title, artist, album and length.", button: "Show Lyrics") {
                lyrics.setEnabled(true)
            }
        case .unavailable:
            PanelMessage(text: model.isVideo ? "This video doesn’t look like a song" : "Nothing to look up lyrics for")
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .synced(let timeline):
            SyncedLyricsList(model: model, lyrics: lyrics, timeline: timeline)
        case .plain(let lines):
            PlainLyricsList(lines: lines)
        case .instrumental:
            LyricsNote(symbol: "music.note", text: "Instrumental")
        case .notFound:
            LyricsNote(symbol: "quote.bubble", text: "No lyrics found")
        case .failed(let failure):
            PanelMessage(text: failure.message, button: "Retry") { lyrics.retry() }
        }
    }
}

/// Over the lyrics: where they come from, "Not synced" for plain ones, and for timed
/// ones the offset's − and + and the microphone that puts the line being sung in the
/// island.
private struct LyricsPanelHeader: View {
    let lyrics: NowPlayingLyricsModel

    var body: some View {
        HStack(spacing: 8) {
            if case .plain = lyrics.status {
                Text("Not synced")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 7)
                    .frame(height: 16)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            if lyrics.status.hasLyrics {
                Text("LRCLIB")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .help("Lyrics from lrclib.net")
            }
            Spacer(minLength: 0)
            if case .synced = lyrics.status {
                LyricsOffsetControl(lyrics: lyrics)
                LyricsIslandToggle(isOn: lyrics.showsInIsland) {
                    lyrics.setShowsInIsland(!lyrics.showsInIsland)
                }
            }
        }
        .frame(height: 24)
    }
}

/// − and + for lyrics that run early or late, and how far they are moved.
private struct LyricsOffsetControl: View {
    let lyrics: NowPlayingLyricsModel

    var body: some View {
        HStack(spacing: 2) {
            LyricsHeaderButton(symbol: "minus", label: "Show lyrics earlier") { lyrics.nudge(later: false) }
            Text(Self.text(lyrics.offset))
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(lyrics.offset == 0 ? 0.4 : 0.85))
                .contentTransition(.numericText(value: lyrics.offset))
                .animation(.smooth(duration: 0.2), value: lyrics.offset)
                .frame(minWidth: 34)
                .help("Lines show early? Press + to show them later; late, press −.")
                .accessibilityLabel("Lyrics offset")
                .accessibilityValue(Self.text(lyrics.offset))
            LyricsHeaderButton(symbol: "plus", label: "Show lyrics later") { lyrics.nudge(later: true) }
        }
    }

    /// "0.0 s", "+0.5 s", "−1.0 s".
    static func text(_ offset: TimeInterval) -> String {
        let sign = offset > 0 ? "+" : (offset < 0 ? "−" : "")
        return sign + String(format: "%.1f s", abs(offset))
    }
}

private struct LyricsHeaderButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.75))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(isHovering ? 0.18 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The microphone: lit, like the library's buttons, while the island shows the line
/// being sung.
private struct LyricsIslandToggle: View {
    let isOn: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "music.mic")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(isOn ? Color.black : .white.opacity(isHovering ? 1 : 0.8))
                .frame(width: 22, height: 22)
                .background(Circle().fill(isOn ? Color.white : .white.opacity(isHovering ? 0.18 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.2), value: isOn)
        .help(isOn ? "Showing in the island" : "Show in island")
        .accessibilityLabel("Show in island")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A word or two, with a symbol, where there are no lyrics to show.
private struct LyricsNote: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.5))
    }
}

// MARK: - Timed lyrics

/// Timed lines, the current one bright and a little larger, those sung dim and those
/// to come between. The list keeps the current line in view, a third of the way
/// down, unless the person scrolls it, when it waits `resumeDelay` after they stop
/// before following again. A click on a line plays from there, where the controls
/// reach the player.
private struct SyncedLyricsList: View {
    let model: NowPlayingModel
    let lyrics: NowPlayingLyricsModel
    let timeline: LyricsTimeline
    /// The list is following the current line, rather than where the person left it.
    @State private var isFollowing = true
    /// Bumped as a scroll by hand ends, to start the wait before following again, and
    /// put back to 0 as another begins, which calls off a wait under way: the list
    /// never follows while a hand is on it.
    @State private var resumeToken = 0

    static let resumeDelay: TimeInterval = 3
    static let anchor = UnitPoint(x: 0.5, y: 0.34)

    var body: some View {
        let canSeek = model.canControl && model.timing.duration > 0
        ScrollViewReader { proxy in
            PanelList(isLazy: false) {
                ForEach(timeline.rows) { row in
                    LyricsRow(row: row, place: place(of: row), canSeek: canSeek) {
                        guard let time = lyrics.seekTime(forRow: row.id) else { return }
                        isFollowing = true
                        model.seek(to: time)
                    }
                    .id(row.id)
                }
            }
            .modifier(HandScrolling { scrolling in
                if scrolling {
                    isFollowing = false
                    resumeToken = 0
                } else if !isFollowing {
                    resumeToken += 1
                }
            })
            .onAppear { follow(proxy, animated: false) }
            .onChange(of: lyrics.currentRow) { follow(proxy, animated: true) }
            .onChange(of: isFollowing) { _, following in
                if following { follow(proxy, animated: true) }
            }
            .task(id: resumeToken) {
                guard resumeToken > 0 else { return }
                try? await Task.sleep(for: .seconds(Self.resumeDelay))
                guard !Task.isCancelled else { return }
                isFollowing = true
            }
        }
    }

    private func place(of row: LyricsTimeline.Row) -> LyricsRow.Place {
        guard let current = lyrics.currentRow else { return .upcoming }
        return row.id < current ? .sung : (row.id == current ? .current : .upcoming)
    }

    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        guard isFollowing else { return }
        let target = lyrics.currentRow ?? timeline.rows.first?.id
        guard let target else { return }
        if animated {
            withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo(target, anchor: Self.anchor) }
        } else {
            proxy.scrollTo(target, anchor: Self.anchor)
        }
    }
}

/// Tells when the person scrolls the list by hand, as against the list scrolling
/// itself: from the scroll's phases on macOS 15 and later, and before that from the
/// wheel and trackpad themselves (see `ScrollWheelWatcher`).
private struct HandScrolling: ViewModifier {
    let changed: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: changed(true)
                case .idle: changed(false)
                case .animating: break
                @unknown default: break
                }
            }
        } else {
            content.background(ScrollWheelWatcher(changed: changed))
        }
    }
}

/// Scroll events over the view it backs, for macOS 14, whose scroll views do not say
/// who moved them. A scroll the list makes itself sends no event, so any event over
/// it is a hand's; the hand counts as on it until the events, momentum included, have
/// stopped for `quiet`. It listens only while the list is in a window, and takes no
/// events of its own.
struct ScrollWheelWatcher: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.changed = changed
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
        view.stopWatching()
    }

    final class WatcherView: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var monitor: Any?
        private var quietWork: DispatchWorkItem?
        private(set) var isScrolling = false

        /// A wheel's clicks come further apart than a trackpad's events; this is more
        /// than either leaves between two.
        static let quiet: TimeInterval = 0.3

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopWatching() } else { startWatching() }
        }

        private func startWatching() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.scrolled(in: event.window, at: event.locationInWindow) }
                return event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            quietWork?.cancel()
            quietWork = nil
            isScrolling = false
        }

        /// A scroll event, in `window` at `location`: counted when it is over this view.
        func scrolled(in window: NSWindow?, at location: NSPoint) {
            guard let window, window === self.window, bounds.contains(convert(location, from: nil)) else { return }
            if !isScrolling {
                isScrolling = true
                changed(true)
            }
            quietWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isScrolling else { return }
                    self.quietWork = nil
                    self.isScrolling = false
                    self.changed(false)
                }
            }
            quietWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.quiet, execute: work)
        }
    }
}

/// One line, or a note for an instrumental break.
private struct LyricsRow: View {
    enum Place { case sung, current, upcoming }

    let row: LyricsTimeline.Row
    let place: Place
    let canSeek: Bool
    let action: () -> Void
    @State private var isHovering = false

    /// How much larger the current line is drawn. The others leave that much room at
    /// their end, so a line wraps the same way whichever it is.
    static let currentScale: CGFloat = 1.1

    var body: some View {
        Button(action: action) {
            Group {
                if let text = row.text {
                    Text(text)
                        .font(.system(size: 14, weight: .bold))
                        .multilineTextAlignment(row.isRightToLeft ? .trailing : .leading)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 12, weight: .bold))
                        .accessibilityLabel("Instrumental")
                }
            }
            .foregroundStyle(.white.opacity(opacity))
            // A right-to-left line starts at the right, so it grows from there, and its
            // room to grow is at its left.
            .scaleEffect(place == .current ? Self.currentScale : 1, anchor: row.isRightToLeft ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: row.isRightToLeft ? .trailing : .leading)
            .padding(row.isRightToLeft ? .leading : .trailing, 40)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(isHovering && canSeek ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .allowsHitTesting(canSeek)
        .animation(.smooth(duration: 0.35), value: place)
        .accessibilityAddTraits(place == .current ? .isSelected : [])
    }

    private var opacity: Double {
        switch place {
        case .sung: 0.32
        case .current: 1
        case .upcoming: 0.62
        }
    }
}

// MARK: - Plain lyrics

/// Words without times: to read, not to follow.
private struct PlainLyricsList: View {
    let lines: [String]

    var body: some View {
        PanelList(isLazy: false) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.isEmpty {
                    Color.clear.frame(height: 8)
                } else {
                    let rightToLeft = LyricsText.isRightToLeft(line)
                    Text(line)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(rightToLeft ? .trailing : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                }
            }
        }
        .textSelection(.enabled)
    }
}

// MARK: - Island

/// The karaoke row's measurements.
enum NowPlayingKaraokeLayout {
    /// The volume row's height, so the island keeps its height as the one gives way
    /// to the other.
    static var rowHeight: CGFloat { SystemHUDLayout.rowHeight }
    /// Room for a usual line whole. On a notch's island the row is wider anyway; on a
    /// display without one, the island widens to this, evenly either side.
    static let rowWidth: CGFloat = 260
    /// Room between the words and the island's edges, clear of its rounded corners.
    static let inset: CGFloat = 16
    static let font = Font.system(size: 12.5, weight: .semibold)
}

/// Under the compact island while a song plays: the line being sung, centred on the
/// notch. Each line fades in as the one before fades out; a long one scrolls across,
/// once, in the time it is sung. The row itself comes and goes with the words (see
/// `NowPlayingLyricsModel.singingRow`); this only draws them.
struct NowPlayingKaraokeRow: View {
    let lyrics: NowPlayingLyricsModel

    var body: some View {
        ZStack {
            if case .synced(let timeline) = lyrics.status, let index = lyrics.singingRow,
               timeline.rows.indices.contains(index), let text = timeline.rows[index].text {
                KaraokeLine(
                    text: text.replacingOccurrences(of: "\n", with: " · "),
                    duration: lyrics.singingDuration,
                    started: lyrics.singingStart,
                    isRightToLeft: timeline.rows[index].isRightToLeft
                )
                .id(index)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 4)),
                    removal: .opacity.combined(with: .offset(y: -4))
                ))
            }
        }
        .padding(.horizontal, NowPlayingKaraokeLayout.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.4), value: lyrics.singingRow)
        .clipped()
    }
}

/// How a long line crosses the island's row: still for `hold` so its first words
/// can be read, then across at `speed`, or faster where that would not finish before
/// the next line is due.
enum KaraokeScroll {
    static let hold: TimeInterval = 0.8
    /// Points a second: slow enough to read as it goes.
    static let speed: Double = 28

    /// The scroll for a line `overflow` points wider than the row, sung for `duration`
    /// seconds (0 when not known), drawn `elapsed` seconds after it started: how far
    /// across it already is (0 to 1), and how long is left of the hold and of the
    /// crossing. A line drawn afresh partway through takes up where it had got to.
    static func plan(overflow: CGFloat, duration: TimeInterval, elapsed: TimeInterval)
        -> (from: CGFloat, hold: TimeInterval, travel: TimeInterval) {
        let full = max(0, Double(overflow)) / speed
        let budget = duration > 0 ? max(1, duration * 0.85 - hold) : full
        let travel = min(full, budget)
        let elapsed = max(0, elapsed)
        guard elapsed > hold else { return (0, hold - elapsed, travel) }
        guard travel > 0 else { return (1, 0, 0) }
        let from = min(1, (elapsed - hold) / travel)
        return (CGFloat(from), 0, travel * (1 - from))
    }
}

/// A line in the island: whole where it fits, a touch smaller where that is enough,
/// and otherwise scrolled across once (see `KaraokeScroll`), from its first word to
/// its last, which for Hebrew or Arabic is from right to left. With Reduce Motion it
/// is cut short instead.
private struct KaraokeLine: View {
    let text: String
    /// Seconds the line is sung for; 0 when not known.
    let duration: TimeInterval
    /// When it started, for a line drawn partway through; `nil` for now.
    let started: Date?
    let isRightToLeft: Bool
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    /// How far across the line has scrolled, 0 to 1.
    @State private var progress: CGFloat = 0
    /// The end the line starts from is softened: its first words have gone by.
    @State private var fadesStart = false
    /// The end the line runs to is softened: more is still to come.
    @State private var fadesEnd = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The smallest a line is drawn to fit it whole, rather than scroll.
    static let smallest: CGFloat = 0.88
    static let fade: CGFloat = 10
    /// How long an edge takes to soften or sharpen.
    static let edgeTime: TimeInterval = 0.2

    var body: some View {
        let overflow = textWidth - boxWidth
        let scrolls = boxWidth > 0 && textWidth * Self.smallest > boxWidth && !reduceMotion
        // Left to right, the line starts with its left end showing and moves left;
        // right to left, the other way about.
        let direction: CGFloat = isRightToLeft ? -1 : 1
        ZStack {
            if scrolls {
                Text(text)
                    .font(NowPlayingKaraokeLayout.font)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: direction * (overflow / 2 - progress * overflow))
                    .frame(width: boxWidth)
                    .mask(edges)
            } else {
                Text(text)
                    .font(NowPlayingKaraokeLayout.font)
                    .lineLimit(1)
                    .minimumScaleFactor(Self.smallest)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
        .background {
            Text(text)
                .font(NowPlayingKaraokeLayout.font)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
        }
        .task(id: scrolls) {
            guard scrolls else { return }
            await scroll(overflow: overflow)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// Sets the line where it should be by now, then sends it the rest of the way.
    /// The edges soften and sharpen on their own, briefly, as the scroll sets off and
    /// arrives, rather than over the whole of it.
    private func scroll(overflow: CGFloat) async {
        let elapsed = started.map { Date().timeIntervalSince($0) } ?? 0
        let plan = KaraokeScroll.plan(overflow: overflow, duration: duration, elapsed: elapsed)
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            progress = plan.from
            fadesStart = plan.from > 0
            fadesEnd = plan.from < 1
        }
        guard plan.from < 1 else { return }
        // A frame for the starting point to be drawn, for the scroll to set off from it.
        try? await Task.sleep(for: .milliseconds(20))
        guard !Task.isCancelled else { return }
        let hold = max(0, plan.hold - 0.02)
        withAnimation(.linear(duration: plan.travel).delay(hold)) { progress = 1 }
        if !fadesStart {
            withAnimation(.easeOut(duration: Self.edgeTime).delay(hold)) { fadesStart = true }
        }
        let arrival = hold + max(0, plan.travel - Self.edgeTime)
        withAnimation(.easeIn(duration: Self.edgeTime).delay(arrival)) { fadesEnd = false }
    }

    /// Softens each end the line runs past: its start, on the left for a line read
    /// left to right, and its end, on the right.
    private var edges: some View {
        let left = isRightToLeft ? fadesEnd : fadesStart
        let right = isRightToLeft ? fadesStart : fadesEnd
        return HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: left ? Self.fade : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: right ? Self.fade : 0)
        }
    }
}

// MARK: - Settings

/// Under Now Playing in Settings: lyrics on or off, and what they cover.
struct NowPlayingLyricsSettings: View {
    /// Lets the feature pick up a change straight away.
    let onChange: () -> Void
    @AppStorage(NowPlayingPrefs.lyrics) private var isOn = false
    @AppStorage(NowPlayingPrefs.lyricsInIsland) private var inIsland = false
    @AppStorage(NowPlayingPrefs.lyricsForVideos) private var videos = false

    var body: some View {
        Toggle(isOn: $isOn) {
            Text("Lyrics")
            Text("Looks up the song’s title, artist, album and length on lrclib.net")
        }
        Toggle("Show the line being sung in the island", isOn: $inIsland)
            .disabled(!isOn)
        Toggle(isOn: $videos) {
            Text("Look up music videos too")
            Text("For videos titled like “Artist - Song”, and songs from an artist’s “Topic” channel.")
        }
        .disabled(!isOn)
        .onChange(of: isOn) { onChange() }
        .onChange(of: inIsland) { onChange() }
        .onChange(of: videos) { onChange() }
    }
}
