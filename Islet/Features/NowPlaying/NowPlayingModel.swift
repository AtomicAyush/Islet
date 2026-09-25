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
}

enum NowPlayingCommand: Equatable {
    case togglePlayPause
    case next
    case previous
    case seek(TimeInterval)
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
        show(nil, announce: false)
    }

    // MARK: Previews

    /// Shows sample data, holding back the player's reports until `endPreview()`.
    func beginPreview(_ sample: NowPlayingSnapshot) {
        isPreviewing = true
        clearExpectation()
        show(sample, announce: false)
    }

    func endPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        clearExpectation()
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

        let newTrack = shown?.track
        if track != newTrack { track = newTrack }
        if isLive != (snapshot != nil) { isLive = snapshot != nil }
        if artwork != shown?.artwork { artwork = shown?.artwork }
        if previousTrack?.bundleID != newTrack?.bundleID {
            appIcon = Self.icon(for: newTrack?.bundleID)
        }
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
