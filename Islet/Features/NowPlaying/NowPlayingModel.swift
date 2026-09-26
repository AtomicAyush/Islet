import AppKit
import Observation
import os

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

enum NowPlayingCommand: Equatable, Sendable {
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

/// Where the session on show comes from. Its controls go by its app instead (see
/// `NowPlayingRouting`).
enum NowPlayingSource: Equatable, Sendable {
    /// MediaRemote's now-playing session, the one it has elected, through the
    /// adapter's stream.
    case system
    /// MediaRemote's session for an app it has not elected, from the adapter's list of
    /// every session; by the app's bundle identifier.
    case session(String)
    /// A player's own notifications.
    case player(NowPlayingBroadcastPlayer)

    /// How the island hears of it, for the log.
    var origin: String {
        switch self {
        case .system: "MediaRemote"
        case .session: "MediaRemote, not elected"
        case .player: "own notifications"
        }
    }
}

/// A source's report, picked to be shown.
struct NowPlayingChoice {
    var source: NowPlayingSource
    /// `nil` when nothing is reporting.
    var snapshot: NowPlayingSnapshot?
}

/// A player with something loaded, as the switcher lists it: one per app, however
/// the island hears from it.
struct NowPlayingSession: Equatable, Identifiable {
    /// Where its reports come from.
    var source: NowPlayingSource
    /// `nil` only for an app MediaRemote does not name.
    var bundleID: String?
    var isPlaying: Bool

    /// The app. Only MediaRemote's can be unnamed, and it has one session at most.
    var id: String { bundleID ?? "" }
}

/// The person's latest move to another player: which way, and what was on show
/// before, for the compact cover to slide over from.
struct NowPlayingSwitch: Sendable {
    /// One more for each move; each move slides.
    var count = 0
    /// Towards the next player, as fingers moving left: the covers slide left.
    var forward = true
    var previousArtwork: NowPlayingArtwork?
    var previousWasVideo = false
}

/// The latest report from each source the island can follow, and the player the
/// person picked among them.
struct NowPlayingReports {
    /// `nil` while MediaRemote reports nothing.
    var system: NowPlayingSnapshot?
    /// MediaRemote's session for every app, the elected one's too, as the adapter last
    /// listed them.
    var mediaRemote: [String: NowPlayingSnapshot] = [:]
    /// The app the list says MediaRemote elected. The stream is the word on that, but
    /// it is silent for a moment when it hands over from one app to another.
    var listedElected: String?
    /// When each app's listed session was first seen paused, for `pauseGrace`.
    var pausedSince: [String: Date] = [:]
    /// Players that are playing or paused; one that stopped or quit has none.
    var players: [NowPlayingBroadcastPlayer: NowPlayingSnapshot] = [:]
    /// The session the person picked, by swiping or from the switcher. It is kept to
    /// while its app has one, however the others play; `nil` leaves the choice to the
    /// rules below.
    var picked: NowPlayingSession.ID?

    /// How long a session MediaRemote has not elected stays in the switcher once it
    /// pauses: long enough that a pause between two videos does not make its icon
    /// blink out, short enough that one the person has finished with goes. The island
    /// cannot control it (see `reaches`), so it has nothing to offer once it is not
    /// playing. MediaRemote's elected session stays however long it is paused, as do
    /// Spotify and Music while their own notifications say they have something
    /// loaded.
    static let pauseGrace: TimeInterval = 5

    /// Takes the adapter's new list of every session.
    mutating func list(_ listed: NowPlayingMediaRemoteSessions, at now: Date) {
        mediaRemote = listed.snapshots
        listedElected = listed.elected
        pausedSince = pausedSince.filter { listed.snapshots[$0.key]?.isPlaying == false }
        for (app, snapshot) in listed.snapshots where !snapshot.isPlaying && pausedSince[app] == nil {
            // Paused when it was last stamped, which is when MediaRemote heard of the
            // pause: a session already paused when the island first hears of it is
            // not new, and gets no grace.
            pausedSince[app] = min(now, snapshot.timing.timestamp)
        }
    }

    /// The app MediaRemote delivers commands to, as far as the island knows: the
    /// stream's, or while the stream is between apps, the list's.
    var electedApp: String? {
        system.map { $0.track.bundleID } ?? listedElected
    }

    /// Every player with something loaded, one per app, in an order that holds still
    /// as they play and pause: the apps only MediaRemote reports, by bundle identifier,
    /// so that they keep their places whichever of them it elects; then Spotify and
    /// Music, MediaRemote's elected one first as always, else Spotify first.
    ///
    /// An app's report is MediaRemote's session while it has one, which has the exact
    /// position and artwork: the elected one's from the stream, another's from the
    /// list (see `listed`). Spotify and Music have their own notifications for when it
    /// has none. A session MediaRemote has not elected is listed while it plays, and
    /// for `pauseGrace` after, unless the app's own notifications still report it.
    func sessions(at now: Date) -> [NowPlayingSession] {
        var sessions: [NowPlayingSession] = []
        if let system {
            sessions.append(NowPlayingSession(source: .system, bundleID: system.track.bundleID, isPlaying: system.isPlaying))
        }
        let systemApp = system.map { $0.track.bundleID }
        for app in mediaRemote.keys where app != systemApp {
            guard let snapshot = listed(app), listedUntil(app, snapshot) > now else { continue }
            sessions.append(NowPlayingSession(source: .session(app), bundleID: app, isPlaying: snapshot.isPlaying))
        }
        for player in NowPlayingBroadcastPlayer.allCases
        where player.bundleID != systemApp && !sessions.contains(where: { $0.bundleID == player.bundleID }) {
            if let report = players[player] {
                sessions.append(NowPlayingSession(source: .player(player), bundleID: player.bundleID, isPlaying: report.isPlaying))
            }
        }
        return sessions.sorted { rank($0) < rank($1) }
    }

    /// An unnamed app first (MediaRemote's elected one, the only kind), then the other
    /// apps by bundle identifier, then the players: MediaRemote's elected one, then the
    /// others in their order.
    private func rank(_ session: NowPlayingSession) -> (Int, String) {
        guard let app = session.bundleID else { return (0, "") }
        guard let player = NowPlayingBroadcastPlayer(bundleID: app),
              let index = NowPlayingBroadcastPlayer.allCases.firstIndex(of: player)
        else { return (1, app) }
        return (app == electedApp ? 2 : 3 + index, app)
    }

    /// What the island follows: the picked session while there is one; else
    /// MediaRemote's elected session while it plays; else another that is playing,
    /// even though MediaRemote reports another app's paused session; else the app
    /// already followed, now paused or playing on, rather than turn to something
    /// paused before it; else MediaRemote's elected session, paused or gone.
    ///
    /// Another that is playing is only turned to over MediaRemote's own paused session
    /// if the controls reach it (see `reaches`). The person may have paused that
    /// session from the island a moment ago, and turning to one whose controls are
    /// dimmed would take away the Play button that undoes it. Once the pause has
    /// outlasted its hold, the island turns there all the same (see
    /// `NowPlayingModel.forgetPick`).
    func choice(following followed: NowPlayingSession.ID?, at now: Date) -> NowPlayingChoice {
        let sessions = sessions(at: now)
        if let picked, let session = sessions.first(where: { $0.id == picked }) {
            return NowPlayingChoice(source: session.source, snapshot: report(from: session.source))
        }
        if let system, system.isPlaying { return NowPlayingChoice(source: .system, snapshot: system) }
        let others = sessions.filter { $0.source != .system }
        if let playing = others.first(where: {
            $0.isPlaying && (system == nil || reaches(.togglePlayPause, from: $0.source))
        }) {
            return NowPlayingChoice(source: playing.source, snapshot: report(from: playing.source))
        }
        if let followed, let paused = others.first(where: { $0.id == followed }) {
            return NowPlayingChoice(source: paused.source, snapshot: report(from: paused.source))
        }
        return NowPlayingChoice(source: .system, snapshot: system)
    }

    /// Lets go of the pick once its app has nothing loaded, so that the app coming
    /// back later does not take the island over again.
    mutating func dropLostPick(at now: Date) {
        if let picked, !sessions(at: now).contains(where: { $0.id == picked }) { self.picked = nil }
    }

    /// When the next paused session MediaRemote has not elected leaves the switcher,
    /// if one is still within its grace at `now`.
    func nextLapse(after now: Date) -> Date? {
        let systemApp = system.map { $0.track.bundleID }
        return mediaRemote.compactMap { app, snapshot -> Date? in
            guard app != systemApp else { return nil }
            let lapse = listedUntil(app, snapshot)
            return lapse > now && lapse != .distantFuture ? lapse : nil
        }.min()
    }

    /// Until when the listed session for `app`, which the stream is not reporting, is
    /// in the switcher: for good while it plays, while it is the list's elected one
    /// and the stream is silent, and while the app's own notifications still report
    /// it; otherwise until `pauseGrace` after it paused.
    private func listedUntil(_ app: String, _ snapshot: NowPlayingSnapshot) -> Date {
        let reportedByPlayer = NowPlayingBroadcastPlayer(bundleID: app).map { players[$0] != nil } ?? false
        if snapshot.isPlaying || reportedByPlayer || system == nil && app == listedElected { return .distantFuture }
        return pausedSince[app].map { $0.addingTimeInterval(Self.pauseGrace) } ?? .distantFuture
    }

    func report(from source: NowPlayingSource) -> NowPlayingSnapshot? {
        switch source {
        case .system: system
        case .session(let app): listed(app)
        case .player(let player): players[player]
        }
    }

    /// `app`'s session from MediaRemote's list; for Spotify and Music, playing or
    /// paused as their own notifications say when those are newer. Those arrive the
    /// moment the player changes, while the list waits for MediaRemote's next
    /// reading.
    func listed(_ app: String) -> NowPlayingSnapshot? {
        guard var snapshot = mediaRemote[app] else { return nil }
        if let player = NowPlayingBroadcastPlayer(bundleID: app), let own = players[player],
           own.isPlaying != snapshot.isPlaying, own.track.title == snapshot.track.title,
           own.timing.timestamp > snapshot.timing.timestamp {
            snapshot.timing = snapshot.timing.anchored(
                at: own.timing.timestamp, rate: own.isPlaying ? snapshot.speed : 0
            )
            snapshot.isPlaying = own.isPlaying
        }
        return snapshot
    }

    /// Whether `command` reaches the app heard of from `source`. MediaRemote delivers
    /// a command to the app it has elected and no other (see `NowPlayingRouting`);
    /// Spotify and Music take Apple Events besides, which carry play and pause, the
    /// skips and seeking, but not shuffle, repeat or a player's own 15-second jumps.
    /// Their own notifications report none of those three, so only a session from
    /// MediaRemote's list can be out of reach: wholly for an app that is neither the
    /// elected one nor one of those two, and for those two, in those three.
    func reaches(_ command: NowPlayingCommand, from source: NowPlayingSource) -> Bool {
        guard case .session(let app) = source, app != electedApp else { return true }
        return NowPlayingBroadcastPlayer(bundleID: app) != nil && NowPlayingPlayerControl.carries(command)
    }
}

/// The system's now-playing session, as the island shows it: the current track, or
/// the last one after its player went away. MediaRemote elects a single app, so its
/// other sessions, and Spotify's and Music's own notifications, are weighed against
/// it, and the island follows whichever is really playing (see `NowPlayingReports`) —
/// unless the person has picked one of them themselves.
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
    /// Every player with something loaded, in an order that holds still: the
    /// switcher's icons.
    private(set) var sessions: [NowPlayingSession] = []
    /// Which of `sessions` is on show; `nil` while the last session is kept after its
    /// player went away.
    private(set) var shownSession: NowPlayingSession.ID?
    private(set) var lastSwitch = NowPlayingSwitch()
    /// False while the island's controls cannot reach the app on show: one heard of
    /// through MediaRemote's list, which is not the app MediaRemote has elected and
    /// takes no Apple Events. MediaRemote would deliver its commands to the elected app
    /// instead (see `NowPlayingReports.reaches`), so they are shown disabled and send
    /// nothing; they come back once that app is elected, which it is when it next
    /// starts playing. Spotify and Music keep theirs, less the shuffle and repeat
    /// toggles and their own jumps, which only MediaRemote carries.
    private(set) var canControl = true

    /// Carries a command to the app on show, `nil` for one MediaRemote does not name,
    /// however the island heard of it (see `NowPlayingRouting`). `mayPrompt` is false
    /// for a command that did not come from a press in the island, which must not put
    /// up macOS's Automation prompt (see `NowPlayingPlayerControl`). Never called while
    /// a preview is shown.
    @ObservationIgnored var send: (NowPlayingCommand, _ app: String?, _ mayPrompt: Bool) -> Void = { _, _, _ in }
    /// Called after every change that could show or end the activity.
    @ObservationIgnored var onChange: () -> Void = {}
    /// Called when a playing session moves on to a different track.
    @ObservationIgnored var onTrackChange: () -> Void = {}
    /// Called after the person moved to another player.
    @ObservationIgnored var onSwitch: () -> Void = {}

    /// Sample data is on screen; the players' reports are kept but not shown.
    var isPreviewing: Bool { previewReports != nil }

    @ObservationIgnored private var reports = NowPlayingReports()
    /// A preview's made-up reports, chosen between as real ones are.
    @ObservationIgnored private var previewReports: NowPlayingReports?
    /// The app the island last followed other than through MediaRemote's elected
    /// session, so its pause does not hand the island back to a session paused
    /// before it.
    @ObservationIgnored private var followed: NowPlayingSession.ID?
    @ObservationIgnored private var lastSeen: NowPlayingChoice?
    /// Where what is shown came from.
    @ObservationIgnored private var source: NowPlayingSource = .system
    @ObservationIgnored private var speed: Double = 1
    @ObservationIgnored private var expectation: Expectation?
    @ObservationIgnored private var expectationWork: DispatchWorkItem?
    @ObservationIgnored private var modeExpectation: ModeExpectation?
    @ObservationIgnored private var modeExpectationWork: DispatchWorkItem?
    /// A track change seen while paused. Some players stop for a moment between
    /// tracks, so if playback follows straight away it is announced after all.
    @ObservationIgnored private var quietChangeAt: Date?
    /// Takes a paused session out of the switcher once its grace is up (see
    /// `NowPlayingReports.pauseGrace`).
    @ObservationIgnored private var graceWork: DispatchWorkItem?
    /// The switcher's apps and where each is heard from, as last logged.
    @ObservationIgnored private var loggedSources: [String] = []

    /// A source's new report, with the track it reported before: moving to a player
    /// is only a song change if that player has itself just moved on.
    private struct Update {
        let source: NowPlayingSource
        let previousTrack: NowPlayingTrack?
    }

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
        /// When each was last set, so that a refusal takes back only its own change,
        /// and not one made since.
        var shuffleIssued = Date.distantPast
        var repeatIssued = Date.distantPast
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

    /// A new reading from MediaRemote, or `nil` when nothing is playing.
    func ingest(_ snapshot: NowPlayingSnapshot?) {
        let before = reports.system?.track
        reports.system = snapshot
        refresh(announce: true, updates: [Update(source: .system, previousTrack: before)])
    }

    /// MediaRemote's new list of every app's session, the elected one's too.
    func ingest(sessions listed: NowPlayingMediaRemoteSessions) {
        let before = reports.mediaRemote
        reports.list(listed, at: Date())
        let updates = listed.snapshots.keys.compactMap { app in
            before[app].map { Update(source: .session(app), previousTrack: $0.track) }
        }
        refresh(announce: true, updates: updates)
    }

    /// A player's own report, or `nil` once it has stopped or quit.
    func ingest(_ snapshot: NowPlayingSnapshot?, from player: NowPlayingBroadcastPlayer) {
        let before = reports.players[player]?.track
        reports.players[player] = snapshot
        refresh(announce: true, updates: [Update(source: .player(player), previousTrack: before)])
    }

    /// Forgets everything, as if no player had ever reported.
    func reset() {
        reports = NowPlayingReports()
        previewReports = nil
        followed = nil
        lastSeen = nil
        quietChangeAt = nil
        graceWork?.cancel()
        graceWork = nil
        // The count stays, so a cover still on screen does not slide for a reset.
        lastSwitch = NowPlayingSwitch(count: lastSwitch.count)
        clearExpectation()
        clearModeExpectation()
        show(NowPlayingChoice(source: .system), announce: false)
    }

    // MARK: Previews

    /// Shows sample data, holding back the players' reports until `endPreview()`.
    /// `players` are made-up notifications from Spotify or Music, for the island to
    /// choose between as it would between real ones.
    func beginPreview(_ sample: NowPlayingSnapshot, players: [NowPlayingBroadcastPlayer: NowPlayingSnapshot] = [:]) {
        let reports = NowPlayingReports(system: sample, players: players)
        previewReports = reports
        clearExpectation()
        clearModeExpectation()
        show(reports.choice(following: nil, at: Date()), announce: false)
    }

    /// A new made-up reading from the preview's MediaRemote session, followed and
    /// announced as a real one would be.
    func previewReport(_ sample: NowPlayingSnapshot?) {
        guard var reports = previewReports else { return }
        let before = reports.system?.track
        let now = Date()
        reports.system = sample
        reports.dropLostPick(at: now)
        previewReports = reports
        show(
            reports.choice(following: shownOtherApp, at: now), announce: true,
            updates: [Update(source: .system, previousTrack: before)]
        )
    }

    func endPreview() {
        guard isPreviewing else { return }
        previewReports = nil
        clearExpectation()
        clearModeExpectation()
        refresh(announce: false)
    }

    // MARK: Switching

    /// Moves to the next or previous player with something loaded, wrapping round,
    /// and keeps to it (see `NowPlayingReports.picked`). False when there is no other
    /// to move to.
    @discardableResult
    func switchSession(forward: Bool) -> Bool {
        let count = sessions.count
        guard count > 1 else { return false }
        let target = sessions.firstIndex { $0.id == shownSession }
            .map { ($0 + (forward ? 1 : count - 1)) % count }
            ?? (forward ? 0 : count - 1)
        show(picked: sessions[target].id, forward: forward)
        return true
    }

    /// Shows the session picked from the switcher, and keeps to it.
    func pick(_ id: NowPlayingSession.ID) {
        guard id != shownSession, let target = sessions.firstIndex(where: { $0.id == id }) else { return }
        let here = sessions.firstIndex { $0.id == shownSession }
        show(picked: id, forward: here.map { target > $0 } ?? true)
    }

    /// Hands the island back to the automatic choice, as when a picked player's pause
    /// has outlasted its hold; that choice may be playing. Past MediaRemote's paused
    /// session, too, to one that plays on where the controls cannot reach it, which
    /// the automatic choice alone does not turn to (see `NowPlayingReports.choice`):
    /// with the pause's hold over, the island shows what plays rather than go dark.
    func forgetPick() {
        let now = Date()
        let playing = reports.system?.isPlaying == true ? nil
            : reports.sessions(at: now).first { $0.isPlaying && $0.source != .system }
        guard reports.picked != nil || playing != nil else { return }
        reports.picked = nil
        if let playing { followed = playing.id }
        refresh(announce: false)
    }

    /// Turning to a player is not a song change, even though its song differs.
    private func show(picked id: NowPlayingSession.ID, forward: Bool) {
        lastSwitch = NowPlayingSwitch(
            count: lastSwitch.count + 1, forward: forward, previousArtwork: artwork, previousWasVideo: isVideo
        )
        // What was waiting on the last player's word says nothing about this one.
        clearExpectation()
        clearModeExpectation()
        quietChangeAt = nil
        if var preview = previewReports {
            preview.picked = id
            previewReports = preview
            show(preview.choice(following: shownOtherApp, at: Date()), announce: false)
        } else {
            reports.picked = id
            refresh(announce: false)
        }
        onSwitch()
    }

    // MARK: Controls

    /// `mayPrompt` false for a command from a Shortcut or a script rather than the
    /// island's own buttons (see `send`); likewise for `next` and `previous`.
    func togglePlayPause(mayPrompt: Bool = true) {
        guard !refuses(.togglePlayPause) else { return }
        if hasSession {
            let playing = !isPlaying
            expect(playing: playing, timing: timing.anchored(at: Date(), rate: playing ? speed : 0))
        }
        issue(.togglePlayPause, mayPrompt: mayPrompt)
    }

    func next(mayPrompt: Bool = true) { skip(.next, mayPrompt: mayPrompt) }

    func previous(mayPrompt: Bool = true) { skip(.previous, mayPrompt: mayPrompt) }

    func seek(to seconds: TimeInterval) {
        guard hasSession, timing.duration > 0 else { return }
        let target = min(max(0, seconds), timing.duration)
        guard !refuses(.seek(target)) else { return }
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
        let command: NowPlayingCommand = (forward ? jumpsForward : jumpsBack)
            ? (forward ? .jumpForward : .jumpBack)
            : .seek(target)
        guard !refuses(command) else { return }
        var moved = timing
        moved.elapsed = target
        moved.timestamp = now
        expect(playing: isPlaying, timing: moved)
        issue(command)
    }

    /// A seek needs a known duration; the player's own jumps do not.
    func canJump(forward: Bool) -> Bool {
        hasSession && ((forward ? jumpsForward : jumpsBack) || timing.duration > 0)
    }

    /// On means shuffling songs, as the Music app's own button does.
    func toggleShuffle() {
        guard let shuffle else { return }
        let next: NowPlayingShuffle = shuffle == .off ? .tracks : .off
        guard !refuses(.shuffle(next)) else { return }
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
        guard !refuses(.repeatMode(next)) else { return }
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

    private func skip(_ command: NowPlayingCommand, mayPrompt: Bool) {
        guard !refuses(command) else { return }
        if hasSession {
            var restarted = timing
            restarted.elapsed = 0
            restarted.timestamp = Date()
            expect(playing: isPlaying, timing: restarted)
        }
        issue(command, mayPrompt: mayPrompt)
    }

    /// By the app on show rather than by `source`: MediaRemote's session is whichever
    /// app it elected when it last reported, and its commands go to whichever app it
    /// has elected when they arrive, which need not be the same one.
    private func issue(_ command: NowPlayingCommand, mayPrompt: Bool = true) {
        guard !isPreviewing else { return }
        NowPlayingRouting.log.notice("\(String(describing: command), privacy: .public): \(self.routingState, privacy: .public)")
        send(command, track?.bundleID, mayPrompt)
    }

    /// True, having sent nothing and changed nothing on screen, while `command` cannot
    /// reach the app on show (see `canControl`); a Shortcut's command is turned away
    /// the same as a press. Logged as a refused command would be.
    private func refuses(_ command: NowPlayingCommand) -> Bool {
        guard !isPreviewing, isLive, !reports.reaches(command, from: source) else { return false }
        NowPlayingRouting.log.notice(
            "\(String(describing: command), privacy: .public) not sent, the app on show is not MediaRemote's elected one: \(self.routingState, privacy: .public)"
        )
        return true
    }

    /// What a control is decided by, for the log: the app on show and how the island
    /// came to show it, against what each source last said. Bundle identifiers and
    /// play states only, and not the island's own play state, which the control has
    /// already changed optimistically.
    private var routingState: String {
        func app(_ bundleID: String?) -> String { bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "an unnamed app" }
        func state(_ snapshot: NowPlayingSnapshot) -> String { snapshot.isPlaying ? "playing" : "paused" }
        let system = reports.system.map { "\(app($0.track.bundleID)) \(state($0))" } ?? "nothing"
        let systemApp = reports.system.map { $0.track.bundleID }
        let others = reports.mediaRemote.keys.sorted().filter { $0 != systemApp }.compactMap { app in
            reports.mediaRemote[app].map { "\(app) \(state($0))" }
        }
        let players = NowPlayingBroadcastPlayer.allCases.compactMap { player in
            reports.players[player].map { "\(player.bundleID) \(state($0))" }
        }
        let from = switch source {
        case .system: "MediaRemote"
        case .session: "MediaRemote's list, not elected"
        case .player(let player): "\(player.bundleID)'s own notifications"
        }
        return "shows \(app(track?.bundleID)) from \(from), session \(shownSession.map(app) ?? "none (kept)"),"
            + " picked \(reports.picked.map(app) ?? "none"); MediaRemote reports \(system)"
            + (others.isEmpty ? "" : ", and not elected \(others.joined(separator: ", "))") + ";"
            + " players report \(players.isEmpty ? "nothing" : players.joined(separator: ", "))"
    }

    /// The player turned down `command`, sent at `sent`, or never got it (it quit,
    /// Islet may not control it, or MediaRemote would have delivered it to another
    /// app), so show what it last reported now rather than after the grace. Only that
    /// command's own change goes back — a shuffle's or a repeat's, or else the
    /// playback's — and not one issued since, whose result stays on screen.
    func commandFailed(_ command: NowPlayingCommand, sentAt sent: Date) {
        switch command {
        case .shuffle, .repeatMode:
            guard var expected = modeExpectation else { return }
            if case .shuffle = command, expected.shuffle != nil, expected.shuffleIssued <= sent {
                expected.shuffle = nil
            } else if case .repeatMode = command, expected.repeatMode != nil, expected.repeatIssued <= sent {
                expected.repeatMode = nil
            } else {
                return
            }
            if expected.shuffle == nil, expected.repeatMode == nil {
                clearModeExpectation()
            } else {
                modeExpectation = expected
            }
        case .togglePlayPause, .next, .previous, .seek, .jumpBack, .jumpForward:
            guard let expectation, expectation.issued <= sent else { return }
            clearExpectation()
        }
        refresh(announce: false)
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
        refresh(announce: false)
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
            let now = Date()
            if let shuffle {
                expected.shuffle = shuffle
                expected.shuffleIssued = now
            }
            if let repeatMode {
                expected.repeatMode = repeatMode
                expected.repeatIssued = now
            }
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
        refresh(announce: false)
    }

    private func clearModeExpectation() {
        modeExpectation = nil
        modeExpectationWork?.cancel()
        modeExpectationWork = nil
    }

    // MARK: Display

    /// Chooses what to follow from the latest reports, and shows it unless a preview
    /// is on screen.
    private func refresh(announce: Bool, updates: [Update] = []) {
        let now = Date()
        reports.dropLostPick(at: now)
        let choice = reports.choice(following: followed, at: now)
        followed = choice.source == .system ? nil : choice.snapshot?.track.bundleID
        if choice.snapshot != nil { lastSeen = choice }
        scheduleGraceLapse(after: now)
        guard !isPreviewing else { return }
        show(choice, announce: announce, updates: updates)
    }

    /// The app on show when it is not MediaRemote's elected session, for a preview's
    /// choice to follow as `refresh` follows the real one.
    private var shownOtherApp: NowPlayingSession.ID? {
        source == .system ? nil : track?.bundleID
    }

    /// Looks again when the next paused session's grace is up, so it leaves the
    /// switcher then, however long until the next report.
    private func scheduleGraceLapse(after now: Date) {
        graceWork?.cancel()
        graceWork = nil
        guard let lapse = reports.nextLapse(after: now) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.graceWork = nil
                self?.refresh(announce: false)
            }
        }
        graceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + lapse.timeIntervalSince(now) + 0.05, execute: work)
    }

    private func show(_ choice: NowPlayingChoice, announce: Bool, updates: [Update] = []) {
        let snapshot = choice.snapshot
        let kept = snapshot == nil && !isPreviewing ? lastSeen : nil
        let shown = snapshot ?? kept?.snapshot
        let newSource = kept?.source ?? choice.source
        let previousSource = source
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

        // A control MediaRemote would deliver to another app is dimmed, or for
        // shuffle, repeat and the player's own jumps, left out. The last session, kept
        // after its player stopped reporting, has its controls as it always had:
        // nothing says which app would take them now, and the adapter checks the app
        // before sending.
        func reaches(_ command: NowPlayingCommand) -> Bool {
            isPreviewing || snapshot == nil || reports.reaches(command, from: newSource)
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
        if !reaches(.shuffle(.off)) { shuffle = nil }
        if !reaches(.repeatMode(.off)) { repeatMode = nil }

        let newTrack = shown?.track
        if track != newTrack { track = newTrack }
        if isLive != (snapshot != nil) { isLive = snapshot != nil }
        if artwork != shown?.artwork { artwork = shown?.artwork }
        if previousTrack?.bundleID != newTrack?.bundleID {
            appIcon = Self.appIcon(for: newTrack?.bundleID)
        }
        let sessions = (previewReports ?? reports).sessions(at: Date())
        if self.sessions != sessions {
            self.sessions = sessions
            logSources()
        }
        let shownSession = snapshot == nil ? nil : sessions.first { $0.source == newSource }?.id
        if self.shownSession != shownSession { self.shownSession = shownSession }
        let reachable = reaches(.togglePlayPause)
        if canControl != reachable { canControl = reachable }
        let video = shown?.isVideo ?? false
        if isVideo != video { isVideo = video }
        if self.shuffle != shuffle { self.shuffle = shuffle }
        if self.repeatMode != repeatMode { self.repeatMode = repeatMode }
        let back = shown?.jumpsBack == true && reaches(.jumpBack)
        let forward = shown?.jumpsForward == true && reaches(.jumpForward)
        if jumpsBack != back { jumpsBack = back }
        if jumpsForward != forward { jumpsForward = forward }
        speed = shown?.speed ?? 1
        source = newSource
        setPlayback(playing: playing, timing: timing)

        if announce {
            // Turning to another player's song, which was playing all along, is not
            // a song change; that player moving on to a new one is. Nor is MediaRemote
            // taking over a song from the player's own notifications, however
            // differently the two word its artist or album.
            let sameSource = newSource == previousSource
            let moved = previousTrack != nil && newTrack != nil && previousTrack != newTrack
            let handedOver = previousTrack?.bundleID == newTrack?.bundleID && previousTrack?.title == newTrack?.title
            let changed = moved && (sameSource || !handedOver && updates.contains {
                $0.source == newSource && $0.previousTrack != nil && $0.previousTrack != newTrack
            })
            if playing {
                let followsQuietChange = sameSource
                    && quietChangeAt.map { Date().timeIntervalSince($0) < Self.quietChangeWindow } ?? false
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

    /// Each change to the switcher's apps, or to where the island hears of one, at
    /// debug level: bundle identifiers and sources only. Not for a preview's made-up
    /// players, nor for a player that only paused or played.
    private func logSources() {
        guard !isPreviewing else { return }
        let listed = sessions.map { "\($0.bundleID ?? "an unnamed app") (\($0.source.origin))" }
        guard listed != loggedSources else { return }
        loggedSources = listed
        NowPlayingRouting.log.debug(
            "Sources: \(listed.isEmpty ? "none" : listed.joined(separator: ", "), privacy: .public)"
        )
    }

    // MARK: Apps

    private static var apps: [String: (icon: NSImage?, name: String?)] = [:]

    static func appIcon(for bundleID: String?) -> NSImage? { app(bundleID)?.icon }

    static func appName(for bundleID: String?) -> String? { app(bundleID)?.name }

    /// Looked up once per app, found or not: LaunchServices is not free, and reports
    /// arrive often.
    private static func app(_ bundleID: String?) -> (icon: NSImage?, name: String?)? {
        guard let bundleID else { return nil }
        if let known = apps[bundleID] { return known }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let found = (
            icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) },
            name: url.map { FileManager.default.displayName(atPath: $0.path) }
                .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        )
        apps[bundleID] = found
        return found
    }
}
