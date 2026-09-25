import AppKit
import Observation

/// What is playing, independent of how far through it is.
struct NowPlayingTrack: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    /// The app that owns the media: the browser rather than its helper process for
    /// web media.
    var bundleID: String?
}

/// Where playback is, as a reference point to extrapolate from, so nothing has to
/// tick to keep the position current.
struct NowPlayingTiming: Equatable, Sendable {
    /// Position at `timestamp`.
    var elapsed: TimeInterval = 0
    var timestamp: Date = .distantPast
    /// Seconds of media per second; 0 while paused.
    var rate: Double = 0
    /// 0 when the player does not know (live streams, some web media).
    var duration: TimeInterval = 0

    func position(at date: Date) -> TimeInterval {
        let position = elapsed + max(0, date.timeIntervalSince(timestamp)) * rate
        return duration > 0 ? min(max(0, position), duration) : max(0, position)
    }

    /// The same position, re-anchored at `date` and moving at `rate`.
    func anchored(at date: Date, rate: Double) -> NowPlayingTiming {
        NowPlayingTiming(elapsed: position(at: date), timestamp: date, rate: rate, duration: duration)
    }
}

/// One complete reading of the player's state.
struct NowPlayingSnapshot: Sendable {
    var track: NowPlayingTrack
    var isPlaying: Bool
    var timing: NowPlayingTiming
    /// The rate playback runs at when playing, to resume at optimistically.
    var speed: Double = 1
    var artwork: NowPlayingArtwork?
    /// A film, an episode or a web video rather than music.
    var isVideo = false
    /// `nil` when the player does not report it, and then there is no toggle for it.
    var shuffle: NowPlayingShuffle?
    var repeatMode: NowPlayingRepeat?
    /// The player has its own 15-second jumps; without them the island seeks.
    var jumpsBack = false
    var jumpsForward = false
}

/// Shuffle, numbered as MediaRemote and the adapter number it.
enum NowPlayingShuffle: Int, Sendable {
    case off = 1
    case albums = 2
    case tracks = 3
}

/// Repeat, numbered as MediaRemote and the adapter number it.
enum NowPlayingRepeat: Int, Sendable {
    case off = 1
    case one = 2
    case all = 3
}

enum NowPlayingCommand: Equatable {
    case togglePlayPause
    case next
    case previous
    case seek(TimeInterval)
    /// The player's own 15-second jumps.
    case jumpBack
    case jumpForward
    case shuffle(NowPlayingShuffle)
    case repeatMode(NowPlayingRepeat)
}

/// Whether what is playing is video. Players that say so are believed; apps that
/// only play video are taken at their word; and a browser, which rarely says, is
/// playing video when its artwork is a landscape thumbnail rather than a square
/// cover (YouTube Music in a tab stays music).
enum NowPlayingVideo {
    static let players: Set<String> = [
        "com.apple.TV",
        "com.apple.QuickTimePlayerX",
        "com.colliderli.iina",
        "org.videolan.vlc",
    ]

    static let browsers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
    ]

    /// Width over height from which artwork counts as a video thumbnail: 4:3 and
    /// wider.
    static let landscape: CGFloat = 1.3

    static func isVideo(mediaType: String?, bundleID: String?, artworkAspect: CGFloat?) -> Bool {
        if mediaType?.contains("Video") == true { return true }
        guard let bundleID else { return false }
        if players.contains(bundleID) { return true }
        return browsers.contains(bundleID) && (artworkAspect ?? 0) >= landscape
    }
}

/// The system's now-playing session, as the island shows it: the current track, or
/// the last one after its player went away.
///
/// Controls act optimistically: a command changes what is shown at once, and the
/// player's own report confirms or corrects it a moment later.
@MainActor
@Observable
final class NowPlayingModel {
    private(set) var track: NowPlayingTrack?
    private(set) var isPlaying = false
    private(set) var timing = NowPlayingTiming()
    private(set) var artwork: NowPlayingArtwork?
    /// The source app's icon, for the badge on the artwork.
    private(set) var appIcon: NSImage?
    /// A player is reporting right now. False while `track` is the last session,
    /// kept for the home page after its player stopped reporting.
    private(set) var isLive = false
    /// Video rather than music: the island shows a thumbnail and a progress ring
    /// instead of a cover and a waveform.
    private(set) var isVideo = false
    /// `nil` while the player does not report it.
    private(set) var shuffle: NowPlayingShuffle?
    private(set) var repeatMode: NowPlayingRepeat?
    /// The player jumps 15 seconds itself; otherwise a jump is a seek.
    private(set) var jumpsBack = false
    private(set) var jumpsForward = false

    /// Carries a command to the player. Never called while a preview is shown.
    @ObservationIgnored var send: (NowPlayingCommand) -> Void = { _ in }
    /// Called after every change that could show or end the activity.
    @ObservationIgnored var onChange: () -> Void = {}
    /// Called when a playing session moves on to a different track.
    @ObservationIgnored var onTrackChange: () -> Void = {}

    /// Sample data is on screen; the player's reports are kept but not shown.
    @ObservationIgnored private(set) var isPreviewing = false

    @ObservationIgnored private var latest: NowPlayingSnapshot?
    @ObservationIgnored private var lastSeen: NowPlayingSnapshot?
    @ObservationIgnored private var speed: Double = 1
    @ObservationIgnored private var expectation: Expectation?
    @ObservationIgnored private var expectationWork: DispatchWorkItem?
    @ObservationIgnored private var modeExpectation: ModeExpectation?
    @ObservationIgnored private var modeExpectationWork: DispatchWorkItem?
    /// A track change seen while paused. Some players stop for a moment between
    /// tracks, so if playback follows straight away it is announced after all.
    @ObservationIgnored private var quietChangeAt: Date?

    /// What a command should lead to, shown until the player confirms it.
    private struct Expectation {
        let isPlaying: Bool
        let timing: NowPlayingTiming
        let track: NowPlayingTrack?
        let issued: Date
    }

    /// Shuffle and repeat as last set from the island, each shown until the player
    /// reports it. Kept apart from `Expectation`, so toggling one does not undo a
    /// play or a seek still waiting to be confirmed.
    private struct ModeExpectation {
        var shuffle: NowPlayingShuffle?
        var repeatMode: NowPlayingRepeat?
    }

    /// How long an unconfirmed command's result is shown before the player's last
    /// report is trusted again.
    private static let expectationGrace: TimeInterval = 2.5
    /// How soon playback must follow a quiet track change for it to be announced.
    private static let quietChangeWindow: TimeInterval = 2

    var hasSession: Bool { track != nil }

    func position(at date: Date = Date()) -> TimeInterval {
        timing.position(at: date)
    }

    // MARK: Player reports

    /// A new reading from the player, or `nil` when nothing is playing.
    func ingest(_ snapshot: NowPlayingSnapshot?) {
        latest = snapshot
        if let snapshot { lastSeen = snapshot }
        guard !isPreviewing else { return }
        show(snapshot, announce: true)
    }

    /// Forgets everything, as if no player had ever reported.
    func reset() {
        latest = nil
        lastSeen = nil
        quietChangeAt = nil
        isPreviewing = false
        clearExpectation()
        clearModeExpectation()
        show(nil, announce: false)
    }

    // MARK: Previews

    /// Shows sample data, holding back the player's reports until `endPreview()`.
    func beginPreview(_ sample: NowPlayingSnapshot) {
        isPreviewing = true
        clearExpectation()
        clearModeExpectation()
        show(sample, announce: false)
    }

    func endPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        clearExpectation()
        clearModeExpectation()
        show(latest, announce: false)
    }

    // MARK: Controls

    func togglePlayPause() {
        if hasSession {
            let playing = !isPlaying
            expect(playing: playing, timing: timing.anchored(at: Date(), rate: playing ? speed : 0))
        }
        issue(.togglePlayPause)
    }

    func next() { skip(.next) }

    func previous() { skip(.previous) }

    func seek(to seconds: TimeInterval) {
        guard hasSession, timing.duration > 0 else { return }
        let target = min(max(0, seconds), timing.duration)
        var moved = timing
        moved.elapsed = target
        moved.timestamp = Date()
        expect(playing: isPlaying, timing: moved)
        issue(.seek(target))
    }

    /// Fifteen seconds back or on: the player's own jump where it has one, otherwise
    /// a seek.
    func jump(forward: Bool) {
        guard canJump(forward: forward) else { return }
        let now = Date()
        let position = timing.position(at: now) + (forward ? 15 : -15)
        let target = timing.duration > 0 ? min(max(0, position), timing.duration) : max(0, position)
        var moved = timing
        moved.elapsed = target
        moved.timestamp = now
        expect(playing: isPlaying, timing: moved)
        if forward ? jumpsForward : jumpsBack {
            issue(forward ? .jumpForward : .jumpBack)
        } else {
            issue(.seek(target))
        }
    }

    /// A seek needs a known duration; the player's own jumps do not.
    func canJump(forward: Bool) -> Bool {
        hasSession && ((forward ? jumpsForward : jumpsBack) || timing.duration > 0)
    }

    /// On means shuffling songs, as the Music app's own button does.
    func toggleShuffle() {
        guard let shuffle else { return }
        let next: NowPlayingShuffle = shuffle == .off ? .tracks : .off
        expect(shuffle: next)
        issue(.shuffle(next))
    }

    /// Off, then the whole list, then the one song, as the Music app cycles.
    func cycleRepeat() {
        guard let repeatMode else { return }
        let next: NowPlayingRepeat = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        expect(repeat: next)
        issue(.repeatMode(next))
    }

    /// Brings the app that is playing to the front.
    func openSourceApp() {
        guard !isPreviewing, let bundleID = track?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func skip(_ command: NowPlayingCommand) {
        if hasSession {
            var restarted = timing
            restarted.elapsed = 0
            restarted.timestamp = Date()
            expect(playing: isPlaying, timing: restarted)
        }
        issue(command)
    }

    private func issue(_ command: NowPlayingCommand) {
        guard !isPreviewing else { return }
        send(command)
    }

    /// Shows a command's result straight away. A preview has no player to confirm
    /// it, so there the result simply stands.
    private func expect(playing: Bool, timing: NowPlayingTiming) {
        if !isPreviewing {
            expectation = Expectation(isPlaying: playing, timing: timing, track: track, issued: Date())
            expectationWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.expectationLapsed() }
            }
            expectationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.expectationGrace, execute: work)
        }
        setPlayback(playing: playing, timing: timing)
        onChange()
    }

    /// The player never confirmed the command (nothing was listening, or it said
    /// no), so go back to what it last reported.
    private func expectationLapsed() {
        expectationWork = nil
        guard expectation != nil else { return }
        expectation = nil
        show(latest, announce: false)
    }

    private func clearExpectation() {
        expectation = nil
        expectationWork?.cancel()
        expectationWork = nil
    }

    /// Shows a shuffle or repeat change straight away, as `expect(playing:timing:)`
    /// does for playback.
    private func expect(shuffle: NowPlayingShuffle? = nil, repeat repeatMode: NowPlayingRepeat? = nil) {
        if !isPreviewing {
            var expected = modeExpectation ?? ModeExpectation()
            if let shuffle { expected.shuffle = shuffle }
            if let repeatMode { expected.repeatMode = repeatMode }
            modeExpectation = expected
            modeExpectationWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.modeExpectationLapsed() }
            }
            modeExpectationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.expectationGrace, execute: work)
        }
        if let shuffle, self.shuffle != shuffle { self.shuffle = shuffle }
        if let repeatMode, self.repeatMode != repeatMode { self.repeatMode = repeatMode }
    }

    /// The player never took up the new mode (Spotify, for one, ignores it), so
    /// show what it last reported.
    private func modeExpectationLapsed() {
        modeExpectationWork = nil
        guard modeExpectation != nil else { return }
        modeExpectation = nil
        show(latest, announce: false)
    }

    private func clearModeExpectation() {
        modeExpectation = nil
        modeExpectationWork?.cancel()
        modeExpectationWork = nil
    }

    // MARK: Display

    private func show(_ snapshot: NowPlayingSnapshot?, announce: Bool) {
        let shown = snapshot ?? (isPreviewing ? nil : lastSeen)
        let previousTrack = track
        var playing = snapshot?.isPlaying ?? false
        var timing = shown?.timing ?? NowPlayingTiming()
        if snapshot == nil {
            // The last session stands still.
            timing = timing.anchored(at: Date(), rate: 0)
        }

        if let expected = expectation {
            // A report counts once it is about a different track, or carries the
            // expected state with a timestamp newer than the command. Older ones
            // were already on their way and would make the controls flicker back.
            let confirms = snapshot.map {
                $0.track != expected.track
                    || ($0.isPlaying == expected.isPlaying
                        && $0.timing.timestamp >= expected.issued.addingTimeInterval(-0.05))
            } ?? true
            if confirms {
                clearExpectation()
            } else {
                playing = expected.isPlaying
                timing = expected.timing
            }
        }

        var shuffle = shown?.shuffle
        var repeatMode = shown?.repeatMode
        if var expected = modeExpectation {
            // Each mode is confirmed once the player reports it. Once the player
            // has gone there is nothing left to wait for.
            if let snapshot {
                if expected.shuffle == snapshot.shuffle { expected.shuffle = nil }
                if expected.repeatMode == snapshot.repeatMode { expected.repeatMode = nil }
            } else {
                expected = ModeExpectation()
            }
            if expected.shuffle == nil, expected.repeatMode == nil {
                clearModeExpectation()
            } else {
                modeExpectation = expected
                shuffle = expected.shuffle ?? shuffle
                repeatMode = expected.repeatMode ?? repeatMode
            }
        }

        let newTrack = shown?.track
        if track != newTrack { track = newTrack }
        if isLive != (snapshot != nil) { isLive = snapshot != nil }
        if artwork != shown?.artwork { artwork = shown?.artwork }
        if previousTrack?.bundleID != newTrack?.bundleID {
            appIcon = Self.icon(for: newTrack?.bundleID)
        }
        let video = shown?.isVideo ?? false
        if isVideo != video { isVideo = video }
        if self.shuffle != shuffle { self.shuffle = shuffle }
        if self.repeatMode != repeatMode { self.repeatMode = repeatMode }
        let back = shown?.jumpsBack ?? false, forward = shown?.jumpsForward ?? false
        if jumpsBack != back { jumpsBack = back }
        if jumpsForward != forward { jumpsForward = forward }
        speed = shown?.speed ?? 1
        setPlayback(playing: playing, timing: timing)

        if announce {
            let changed = previousTrack != nil && newTrack != nil && previousTrack != newTrack
            if playing {
                let followsQuietChange = quietChangeAt.map { Date().timeIntervalSince($0) < Self.quietChangeWindow } ?? false
                if changed || followsQuietChange { onTrackChange() }
                quietChangeAt = nil
            } else if changed {
                quietChangeAt = Date()
            }
        }
        onChange()
    }

    private func setPlayback(playing: Bool, timing: NowPlayingTiming) {
        if isPlaying != playing { isPlaying = playing }
        if self.timing != timing { self.timing = timing }
    }

    // MARK: App icons

    private static var icons: [String: NSImage] = [:]

    /// Looked up once per app: LaunchServices is not free, and reports arrive often.
    private static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}
