import Foundation
import Observation
import os

extension NowPlayingPrefs {
    /// Lyrics are looked up, for every song as it plays. Off until the person taps the
    /// player's Lyrics button, or turns them on in Settings: nothing is sent to LRCLIB
    /// before then.
    static let lyrics = "nowPlaying.lyrics"
    /// The line being sung rides in a row under the compact island.
    static let lyricsInIsland = "nowPlaying.lyrics.inIsland"
    /// Music videos are looked up too, when their title names the artist and song.
    static let lyricsForVideos = "nowPlaying.lyrics.videos"
    /// How lyrics written in Devanagari are shown (`LyricsScript`).
    static let hindiLyrics = "nowPlaying.lyrics.hindi"

    /// Lyrics that are on are there to be seen: the line being sung shows under the
    /// island without the panel being opened, until the microphone turns it off.
    static let lyricsInIslandDefault = true
}

/// How Hindi lyrics, written in Devanagari, are shown: spelled out in Hinglish (see
/// `Hinglish`), as most people who listen to Hindi songs read and type them, or as
/// written. Lines in any other script are shown as they are either way.
enum LyricsScript: String, CaseIterable, Sendable {
    case hinglish
    case original

    static let `default` = LyricsScript.hinglish
}

/// The lyrics of what is playing, and where in them playback is: the line the panel
/// shows as current, and the line the island sings.
///
/// Once lyrics are on, each new song is looked up as soon as it plays (the cache
/// first, then LRCLIB once the song has held still for a moment), whether or not the
/// panel is open, so they are there the moment it opens; a look-up still under way
/// for the song before is cancelled, and its answer, should one come, dropped.
///
/// Lines written in Devanagari show in Hinglish unless Settings ask for the original
/// script (see `LyricsScript`). Lyrics are kept, and cached, as they were found, so a
/// change of mind shows them again at once, with nothing looked up.
///
/// Nothing ticks. The position comes from the player's timing, as the scrubber's does,
/// and a single timer is set for the next moment a line starts or is let go, set again
/// whenever the player reports a play, a pause, a seek or a new rate. Even that only
/// runs while someone is looking: the panel is open, or the island shows the line.
@MainActor
@Observable
final class NowPlayingLyricsModel {
    enum Status: Equatable {
        /// Lyrics are turned off.
        case off
        /// Nothing to look up: no song, one without an artist, or a video that does
        /// not look like music.
        case unavailable
        case loading
        case synced(LyricsTimeline)
        case plain([String])
        case instrumental
        case notFound
        case failed(LyricsFailure)

        /// There are words to show.
        var hasLyrics: Bool {
            switch self {
            case .synced, .plain: true
            default: false
            }
        }
    }

    private(set) var status = Status.off
    /// The panel's current row (see `LyricsTimeline.row(at:)`), kept up to date while
    /// the panel is open.
    private(set) var currentRow: Int?
    /// The line the island shows, while it shows lines: `nil` in a break, before the
    /// first line and after the last, and from a moment after a pause.
    private(set) var singingRow: Int?
    /// This song's lines are shown this many seconds late (early when negative), for
    /// lyrics timed to another release of it.
    private(set) var offset: TimeInterval = 0
    /// Sample lyrics are showing, for a preview.
    private(set) var isPreviewing = false
    /// Lyrics are on.
    private(set) var isEnabled = false
    /// The island shows the line being sung. During a preview, the preview's own
    /// choice, which leaves the setting as it was.
    var showsInIsland: Bool { isPreviewing ? previewShowsInIsland : storedShowsInIsland }

    /// Called when the status, the offset or the island's choice changes, or the
    /// island's line comes or goes: not for each new line.
    @ObservationIgnored var onChange: () -> Void = {}
    /// Only a test replaces these.
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var usesTimers = true
    @ObservationIgnored var deadline: TimeInterval = 20
    @ObservationIgnored var settle: TimeInterval = 1
    /// When the next line starts or is let go, while a timer is set for it.
    @ObservationIgnored private(set) var wake: Date?

    @ObservationIgnored private let provider: any LyricsProvider
    @ObservationIgnored private let cache: LyricsCache
    @ObservationIgnored private let defaults: UserDefaults
    private var storedShowsInIsland = false
    private var previewShowsInIsland = false
    @ObservationIgnored private var includesVideos = false
    @ObservationIgnored private var script = LyricsScript.default
    /// The lyrics as found, in the script they were written in, to show again in the
    /// other when Settings change. Set whenever `status` is set from lyrics.
    @ObservationIgnored private var found: LyricsResult?
    @ObservationIgnored private var watchesPanel = false
    @ObservationIgnored private var watchesIsland = false

    @ObservationIgnored private var track: NowPlayingTrack?
    @ObservationIgnored private var isVideo = false
    @ObservationIgnored private var timing = NowPlayingTiming()
    @ObservationIgnored private var isPlaying = false
    /// When playback last paused, for the island to let the line go a moment later;
    /// `nil` while it plays, and when it was already paused when the song came.
    @ObservationIgnored private var pausedAt: Date?

    /// The song whose lyrics are showing or being looked up.
    @ObservationIgnored private(set) var query: LyricsQuery?
    @ObservationIgnored private var lookup: Task<Void, Never>?
    /// Bumped for every look-up, so an answer for one since replaced is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wakeTimer: DispatchSourceTimer?

    /// How long after a pause the island keeps the line: long enough for a pause
    /// and play back, not so long that the row outstays the music.
    static let pauseHold: TimeInterval = 2
    /// The most the offset goes either way.
    static let maximumOffset: TimeInterval = 10
    /// Each press of − or +.
    static let offsetStep: TimeInterval = 0.5

    static let log = Logger(subsystem: "com.ayush.Islet", category: "Lyrics")

    /// `cache` is the shared one unless a test gives its own.
    init(provider: any LyricsProvider = LRCLIB(), cache: LyricsCache? = nil, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.cache = cache ?? .shared
        self.defaults = defaults
        reloadSettings()
    }

    // MARK: Settings

    /// Reads the settings again, after they changed in Settings.
    func reloadSettings() {
        let enabled = defaults.bool(forKey: NowPlayingPrefs.lyrics)
        let island = defaults.object(forKey: NowPlayingPrefs.lyricsInIsland) as? Bool ?? NowPlayingPrefs.lyricsInIslandDefault
        let videos = defaults.bool(forKey: NowPlayingPrefs.lyricsForVideos)
        let script = defaults.string(forKey: NowPlayingPrefs.hindiLyrics).flatMap(LyricsScript.init) ?? .default
        guard enabled != isEnabled || island != storedShowsInIsland || videos != includesVideos || script != self.script
        else { return }
        let rescripted = script != self.script
        isEnabled = enabled
        storedShowsInIsland = island
        includesVideos = videos
        self.script = script
        // The words on show again, in the other script: nothing is looked up again.
        if rescripted, status.hasLyrics, let found { apply(found) }
        refresh()
        onChange()
    }

    /// Turns lyrics on or off, as the Lyrics button's first tap does. Not during a
    /// preview, which never turns anything on.
    func setEnabled(_ enabled: Bool) {
        guard !isPreviewing, enabled != isEnabled else { return }
        defaults.set(enabled, forKey: NowPlayingPrefs.lyrics)
        reloadSettings()
    }

    /// The panel's microphone: the line being sung in the island, or not.
    func setShowsInIsland(_ shows: Bool) {
        if isPreviewing {
            previewShowsInIsland = shows
        } else {
            defaults.set(shows, forKey: NowPlayingPrefs.lyricsInIsland)
            storedShowsInIsland = shows
        }
        retime()
        onChange()
    }

    /// Who is looking: the panel, and the island's row. With neither, no timer runs.
    func watch(panel: Bool, island: Bool) {
        guard panel != watchesPanel || island != watchesIsland else { return }
        watchesPanel = panel
        watchesIsland = island
        retime()
    }

    // MARK: Following playback

    /// What is playing, as the player last reported it. Called on every report;
    /// anything but a new song, a new timing or a play or pause costs a comparison.
    func follow(track: NowPlayingTrack?, isVideo: Bool, timing: NowPlayingTiming, isPlaying: Bool) {
        let songChanged = track != self.track || isVideo != self.isVideo
        let playbackChanged = timing != self.timing || isPlaying != self.isPlaying
        guard songChanged || playbackChanged else { return }
        if isPlaying != self.isPlaying {
            pausedAt = isPlaying ? nil : now()
        }
        self.track = track
        self.isVideo = isVideo
        self.timing = timing
        self.isPlaying = isPlaying
        if songChanged {
            // A new song paused from the start has no line to hold on to.
            if !isPlaying { pausedAt = nil }
            refresh()
        } else if let query, !query.isSameSong(as: LyricsQuery(
            title: query.title, artist: query.artist, album: query.album, duration: timing.duration
        )) {
            // A length that has just become known (or has changed) makes a better
            // look-up. One missing from a single report is no news (see
            // `LyricsQuery.isSameSong(as:)`).
            refresh()
        }
        retime()
    }

    /// Looks the song up again, after a failure. Asked for, so at once.
    func retry() {
        guard case .failed = status, let query else { return }
        look(up: query, settles: false)
    }

    /// Moves this song's lines half a second later (`+`) or earlier (`−`), and keeps
    /// the offset for the next time it plays.
    func nudge(later: Bool) {
        guard case .synced = status else { return }
        let step = later ? Self.offsetStep : -Self.offsetStep
        let next = min(max(offset + step, -Self.maximumOffset), Self.maximumOffset)
        guard next != offset else { return }
        offset = (next * 10).rounded() / 10
        if !isPreviewing, let query { cache.setOffset(offset, for: query.key) }
        retime()
        onChange()
    }

    /// Where a row starts, in the song's own time, for a tap on it to seek to.
    func seekTime(forRow index: Int) -> TimeInterval? {
        guard case .synced(let timeline) = status, timeline.rows.indices.contains(index) else { return nil }
        return max(0, timeline.rows[index].time + offset)
    }

    /// How long the island's line lasts, in seconds of playback at its rate: for a
    /// long line to scroll across in the time it is sung.
    var singingDuration: TimeInterval {
        guard case .synced(let timeline) = status, let singingRow, timeline.rows.indices.contains(singingRow)
        else { return 0 }
        let row = timeline.rows[singingRow]
        let rate = timing.rate > 0 ? timing.rate : 1
        return max(0, row.end - row.time) / rate
    }

    /// When the island's line started, by the player's clock, for a line drawn afresh
    /// partway through (after the volume row has been in front, or at a new width) to
    /// take up its scroll where it had got to rather than start over.
    var singingStart: Date? {
        guard case .synced(let timeline) = status, let singingRow, timeline.rows.indices.contains(singingRow)
        else { return nil }
        let rate = timing.rate > 0 ? timing.rate : 1
        let now = now()
        let into = timing.position(at: now) - offset - timeline.rows[singingRow].time
        return now.addingTimeInterval(-max(0, into) / rate)
    }

    // MARK: Previews

    /// Shows `result` for the sample song, sending nothing and changing no setting.
    /// `inIsland` shows the lines in the island whatever the setting says.
    func beginPreview(_ result: LyricsResult, inIsland: Bool) {
        cancelLookup()
        isPreviewing = true
        previewShowsInIsland = inIsland
        offset = 0
        query = nil
        apply(result)
        onChange()
    }

    /// Ends a preview before the player's own does, so the sample song is never
    /// looked up: whatever is really playing is looked up afresh (from the cache,
    /// mostly) when the player next reports it.
    func endPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        previewShowsInIsland = false
        query = nil
        track = nil
        offset = 0
        refresh()
        onChange()
    }

    /// Stops everything: the look-up, the timer, the lyrics.
    func stop() {
        cancelLookup()
        cancelWake()
        isPreviewing = false
        previewShowsInIsland = false
        track = nil
        query = nil
        timing = NowPlayingTiming()
        isPlaying = false
        pausedAt = nil
        setStatus(isEnabled ? .unavailable : .off)
        setRows(current: nil, singing: nil)
    }

    // MARK: Looking up

    /// Looks up what should be showing, if it is not showing already.
    private func refresh() {
        guard !isPreviewing else { return }
        guard isEnabled else {
            cancelLookup()
            query = nil
            offset = 0
            setStatus(.off)
            return
        }
        guard let track, let next = LyricsQuery.make(
            track: track, duration: timing.duration, isVideo: isVideo, includesVideos: includesVideos
        ) else {
            cancelLookup()
            query = nil
            offset = 0
            setStatus(.unavailable)
            return
        }
        if let query, query.isSameSong(as: next), status != .off, status != .unavailable { return }
        look(up: next, settles: true)
    }

    /// Looks `query` up: in the cache at once, and on LRCLIB, when it is not there,
    /// once the song has held still for `settle`. A player often tells of a new song
    /// in pieces — the title first, the length and the artwork a report or two later,
    /// and it is the artwork that shows a browser's media to be a video — and skipping
    /// through songs passes several in a second. Each new piece starts the look-up
    /// over, so only the song as it settles is sent, and a video found out a moment
    /// late is never sent as a song.
    private func look(up query: LyricsQuery, settles: Bool) {
        cancelLookup()
        self.query = query
        offset = 0
        setStatus(.loading)
        let generation = generation
        let provider = provider
        let deadline = deadline
        let settle = settles ? settle : 0
        lookup = Task { [weak self, cache] in
            if let entry = await cache.entry(for: query.key) {
                guard let self, self.generation == generation else { return }
                Self.log.debug("Lyrics from the cache: \(entry.result.summary, privacy: .public)")
                self.found(entry.result, offset: entry.offset)
                return
            }
            if settle > 0 {
                try? await Task.sleep(for: .seconds(settle))
                guard !Task.isCancelled, let self, self.generation == generation else { return }
            }
            let outcome: Result<LyricsResult, Error>
            do {
                outcome = .success(try await Self.within(deadline) { try await provider.lyrics(for: query) })
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            switch outcome {
            case .success(let result):
                Self.log.debug("Lyrics from LRCLIB: \(result.summary, privacy: .public)")
                cache.store(result, for: query.key)
                self.found(result, offset: 0)
            case .failure(let error):
                let failure = error as? LyricsFailure ?? .unreadable
                Self.log.notice("Lyrics look-up failed: \(String(describing: failure), privacy: .public)")
                self.lookup = nil
                self.setStatus(.failed(failure))
                self.onChange()
            }
        }
    }

    private func found(_ result: LyricsResult, offset: TimeInterval) {
        lookup = nil
        self.offset = offset
        apply(result)
        onChange()
    }

    /// Shows `result`, in the script Settings ask for.
    private func apply(_ result: LyricsResult) {
        found = result
        switch result.shown(in: script) {
        case .synced(let lines):
            let timeline = LyricsTimeline(lines)
            setStatus(timeline.isEmpty ? .instrumental : .synced(timeline))
        case .plain(let lines): setStatus(.plain(lines))
        case .instrumental: setStatus(.instrumental)
        case .notFound: setStatus(.notFound)
        }
        retime()
    }

    /// Also makes way for the next look-up: an answer to this one is dropped.
    private func cancelLookup() {
        lookup?.cancel()
        lookup = nil
        generation += 1
    }

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        if case .synced = new { return }
        // No timed lines, so nothing to follow.
        cancelWake()
        setRows(current: nil, singing: nil)
    }

    /// Runs `body`, or gives up with `LyricsFailure.timedOut` after `seconds`.
    nonisolated static func within<T: Sendable>(
        _ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LyricsFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    // MARK: Timing

    /// Works out the current and sung lines for now, and sets the one timer for the
    /// next time either changes.
    private func retime() {
        cancelWake()
        guard case .synced(let timeline) = status, watchesPanel || watchesIsland else {
            setRows(current: nil, singing: nil)
            return
        }
        let now = now()
        let position = timing.position(at: now) - offset
        let current = timeline.row(at: position)
        var singing = watchesIsland && showsInIsland ? timeline.singing(at: position) : nil
        var next: Date?
        let ended = timing.duration > 0 && position + offset >= timing.duration
        if isPlaying {
            // Stalled (playing at no rate, as a stream buffering reports it) or at the
            // end, the lines stand as they are until the next report.
            if timing.rate > 0, !ended, let change = timeline.nextChange(after: position) {
                next = now.addingTimeInterval((change - position) / timing.rate + 0.005)
            }
        } else if let pausedAt, singing != nil, now < pausedAt.addingTimeInterval(Self.pauseHold) {
            // Paused a moment ago: the line stays, then goes.
            next = pausedAt.addingTimeInterval(Self.pauseHold)
        } else {
            singing = nil
        }
        setRows(current: current, singing: singing)
        schedule(next)
    }

    private func setRows(current: Int?, singing: Int?) {
        if currentRow != current { currentRow = current }
        guard singingRow != singing else { return }
        let cameOrWent = (singingRow == nil) != (singing == nil)
        singingRow = singing
        if cameOrWent { onChange() }
    }

    /// A timer source rather than `asyncAfter`, which allows a tenth of the wait as
    /// leeway: a line due eight seconds away would light up most of a second after the
    /// scrubber reached it, and nothing would put it right, since a player reports
    /// nothing while it simply plays on. Five milliseconds keep it to a blink.
    private func schedule(_ date: Date?) {
        wake = date
        guard let date, usesTimers else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            // Setting the next timer cancels this one.
            MainActor.assumeIsolated { self?.retime() }
        }
        // Never sooner than a frame away, so a line that ends as it starts cannot spin.
        let delay = max(date.timeIntervalSince(now()), 0.016)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(5))
        timer.resume()
        wakeTimer = timer
    }

    private func cancelWake() {
        wakeTimer?.cancel()
        wakeTimer = nil
        wake = nil
    }

    /// For a test: runs the timer's work now, as if it had fired.
    func fireWake() {
        retime()
    }
}

extension LyricsResult {
    /// The lyrics as they are shown in `script`: in Hinglish, each line with
    /// Devanagari in it spelled out, and the rest as they were.
    func shown(in script: LyricsScript) -> LyricsResult {
        guard script == .hinglish else { return self }
        switch self {
        case .synced(let lines):
            return .synced(lines.map { LyricsLine(time: $0.time, text: Hinglish.romanise($0.text)) })
        case .plain(let lines):
            return .plain(lines.map(Hinglish.romanise))
        case .instrumental, .notFound:
            return self
        }
    }

    /// What was found, without the words, for the log.
    var summary: String {
        switch self {
        case .synced(let lines): "\(lines.count) timed lines"
        case .plain(let lines): "\(lines.count) plain lines"
        case .instrumental: "instrumental"
        case .notFound: "none"
        }
    }
}
