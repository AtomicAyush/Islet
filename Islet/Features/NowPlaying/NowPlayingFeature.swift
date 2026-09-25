import SwiftUI

enum NowPlayingPrefs {
    /// Seconds a paused session keeps the island, or `neverHide`.
    static let hideAfterPause = "nowPlaying.hideAfterPause"
    static let tintWaveform = "nowPlaying.tintWaveform"
    static let showSongChanges = "nowPlaying.showSongChanges"

    static let hideAfterPauseDefault = 30
    static let tintWaveformDefault = true
    static let showSongChangesDefault = true
    static let neverHide = -1
}

/// Whatever the Mac is playing — Music, Spotify, a video in the browser — the way
/// the iPhone shows it: the cover and a waveform either side of the notch while it
/// plays, full controls when opened, and a moment's banner when the song changes.
@MainActor
final class NowPlayingFeature: Feature {
    let id = "nowPlaying"
    let title = "Now Playing"
    let symbol = "music.note"
    let summary = "Artwork and a live waveform while music or video plays, with controls when opened."

    private let model = NowPlayingModel()
    private let library = NowPlayingLibraryModel()
    private lazy var activity = NowPlayingActivity(model: model, library: library)
    /// `nil` when the adapter is missing from the bundle; then only previews and the
    /// players' own notifications work.
    private let adapter = NowPlayingAdapter()
    /// Spotify's and Music's own word on what they are playing, and their controls.
    private let broadcasts = NowPlayingBroadcasts()
    private var isRunning = false
    /// Tells the current stream's updates from any still queued from a stopped one.
    private var streamToken = 0
    private var homeWidgetShown = false
    private var hideWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?
    /// The moment within a preview when its made-up session changes.
    private var previewStepWork: DispatchWorkItem?
    /// The sample library a preview shows in place of the playing app's.
    private var previewLibrary: (any MediaLibrary)?
    /// The card height the island last took from the activity.
    private var publishedHeight: CGFloat?
    /// The track the library's panel last listed for.
    private var libraryTrack: NowPlayingTrack?

    @AppStorage(NowPlayingPrefs.hideAfterPause) private var hideAfterPause = NowPlayingPrefs.hideAfterPauseDefault
    @AppStorage(NowPlayingPrefs.showSongChanges) private var showSongChanges = NowPlayingPrefs.showSongChangesDefault

    private static let songBannerID = "nowPlaying.song"
    /// How long a preview holds the island before the real state returns.
    private static let previewLength: TimeInterval = 10
    /// Long enough to try the panel's lists.
    private static let libraryPreviewLength: TimeInterval = 20
    /// How long the video plays in the preview of another player playing on.
    private static let videoPauseDelay: TimeInterval = 4
    /// Long enough to move to the song, open the island and move back.
    private static let severalPlayersLength: TimeInterval = 13
    /// The shortest hold after a pause. Players pause for a moment between tracks,
    /// and the activity should not blink out and back for that.
    private static let pauseGrace: TimeInterval = 1.5

    init() {
        model.send = { [weak self] command, source in self?.send(command, to: source) }
        model.onChange = { [weak self] in self?.sync() }
        model.onTrackChange = { [weak self] in self?.trackChanged() }
        model.onSwitch = { [weak self] in self?.switched() }
        library.onPanelChange = { [weak self] in self?.republishIfResized() }
        broadcasts.onUpdate = { [weak self] player, snapshot in self?.model.ingest(snapshot, from: player) }
        broadcasts.onCommandFailed = { [weak self] sent in self?.model.commandFailed(sentAt: sent) }
    }

    func start() {
        isRunning = true
        streamToken += 1
        let token = streamToken
        adapter?.startStream { [weak self] snapshot in
            MainActor.assumeIsolated { self?.receive(snapshot, token: token) }
        }
        broadcasts.start()
        sync()
    }

    func stop() {
        isRunning = false
        adapter?.stop()
        broadcasts.stop()
        previewWork?.cancel()
        previewWork = nil
        previewStepWork?.cancel()
        previewStepWork = nil
        previewLibrary = nil
        cancelHide()
        model.reset()
        // Closes any panel and drops its requests.
        library.use(nil)
        libraryTrack = nil
        let center = ActivityCenter.shared
        center.end(id: activity.id)
        center.dismissBanner(id: Self.songBannerID)
        center.removeHomeWidget(id: id)
        homeWidgetShown = false
    }

    func settingsView() -> AnyView? {
        AnyView(NowPlayingSettings { [weak self] in self?.hideAfterPauseChanged() })
    }

    /// Each shows sample data for 10 seconds (the library's 20, several players' 13),
    /// then hands back to whatever is really playing. None of them touches a real
    /// player or library: the songs come with a sample library of their own.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Sample song (playing)") { [weak self] in
                self?.preview(.midnightDrive(playing: true), library: NowPlayingSampleLibrary())
            },
            FeaturePreview(title: "Sample song (paused)") { [weak self] in
                self?.preview(.midnightDrive(playing: false), library: NowPlayingSampleLibrary())
            },
            FeaturePreview(title: "Song change") { [weak self] in
                self?.preview(.paperPlanes(playing: true), library: NowPlayingSampleLibrary())
                self?.presentSongBanner()
            },
            FeaturePreview(title: "Sample video (playing)") { [weak self] in
                self?.preview(.dolomites(playing: true))
            },
            FeaturePreview(title: "Another player keeps playing") { [weak self] in
                self?.previewAnotherPlayer()
            },
            FeaturePreview(title: "Several players") { [weak self] in
                self?.previewSeveralPlayers()
            },
            FeaturePreview(title: "Up Next and playlists") { [weak self] in
                self?.previewLibraryPanel()
            },
        ]
    }

    /// `islet://nowPlaying/toggle`, `/next`, `/previous`.
    func handle(_ url: URL) -> Bool {
        // Sign-in callbacks and the like, for a music app's library.
        if MediaLibraries.handle(url) { return true }
        switch url.path() {
        case "/toggle": model.togglePlayPause()
        case "/next": model.next()
        case "/previous": model.previous()
        default: return false
        }
        return true
    }

    // MARK: State

    private func receive(_ snapshot: NowPlayingSnapshot?, token: Int) {
        guard isRunning, token == streamToken else { return }
        model.ingest(snapshot)
    }

    /// A control goes to whoever the island is showing: MediaRemote's app, or the
    /// player the island followed instead of it.
    private func send(_ command: NowPlayingCommand, to source: NowPlayingSource) {
        switch source {
        case .system: adapter?.perform(command)
        case .player(let player): broadcasts.perform(command, on: player)
        }
    }

    /// Puts up or takes down the activity and the home tile to match the model.
    private func sync() {
        let center = ActivityCenter.shared
        let isPreviewing = model.isPreviewing
        let isActive = isRunning || isPreviewing
        syncLibrary(isActive: isActive)

        if isActive, model.hasSession {
            if !homeWidgetShown {
                center.setHomeWidget(HomeWidget(
                    id: id, order: 10, weight: 2, view: AnyView(NowPlayingHomeTile(model: model))
                ))
                homeWidgetShown = true
            }
        } else if homeWidgetShown {
            center.removeHomeWidget(id: id)
            homeWidgetShown = false
        }

        guard isActive, model.isLive else {
            cancelHide()
            center.end(id: activity.id)
            return
        }
        if model.isPlaying || isPreviewing {
            cancelHide()
            if !center.isShowing(id: activity.id) { publish() }
        } else if center.isShowing(id: activity.id), hideWork == nil {
            scheduleHide()
        }
        republishIfResized()
    }

    private func publish() {
        publishedHeight = activity.expandedHeight
        ActivityCenter.shared.show(activity)
    }

    /// The island takes the card's height from the activity when it is published,
    /// so a change of shape — a video, the library's buttons, a panel opening —
    /// publishes it again. Only while running or previewing: when the feature stops,
    /// or a preview ends with it off, the panel closes on the way out of an activity
    /// that is about to end.
    private func republishIfResized() {
        guard isRunning || model.isPreviewing,
              ActivityCenter.shared.isShowing(id: activity.id),
              activity.expandedHeight != publishedHeight else { return }
        publish()
    }

    /// The playing app's library, or the preview's sample one for its songs, for the
    /// opened player; and a fresh list in its panel when the track moves on.
    private func syncLibrary(isActive: Bool) {
        if model.isPreviewing {
            library.use(model.isVideo ? nil : previewLibrary)
        } else if isActive, model.isLive {
            library.use(MediaLibraries.library(for: model.track?.bundleID))
        } else {
            library.use(nil)
        }
        if model.track != libraryTrack {
            libraryTrack = model.track
            library.trackChanged()
        }
    }

    private func scheduleHide(after delay: TimeInterval? = nil) {
        let hold = hideAfterPause
        guard hold >= 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideWork = nil
                guard !self.model.isPlaying else { return }
                if IslandManager.shared.isOpen(on: self.activity.id) {
                    // Never pull the player out from under the pointer; try again once
                    // the island has closed.
                    self.scheduleHide(after: Self.pauseGrace)
                    return
                }
                self.endActivityUnlessPlaying()
            }
        }
        hideWork = work
        let wait = delay ?? max(Self.pauseGrace, TimeInterval(hold))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    /// Takes the activity down unless it is running and playing. A player picked by
    /// hand gives way first to the automatic choice, which keeps the island if it
    /// plays: a pick that outlived the activity would leave the island dark while
    /// another player plays on.
    private func endActivityUnlessPlaying() {
        if !model.isPlaying { model.forgetPick() }
        guard !(isRunning && model.isPlaying) else { return }
        cancelHide()
        ActivityCenter.shared.end(id: activity.id)
    }

    /// A new hold applies to a pause already on screen, counted from now; otherwise
    /// switching from "Never" would leave the island up until the next play or pause.
    private func hideAfterPauseChanged() {
        cancelHide()
        sync()
    }

    /// A player the person moved to gets the whole hold if it is paused, counted from
    /// now; and a banner about another player's song is out of date.
    private func switched() {
        ActivityCenter.shared.dismissBanner(id: Self.songBannerID)
        cancelHide()
        sync()
    }

    // MARK: Song changes

    /// Only announced while the activity is already up: when it first appears, the
    /// island itself is the news. Nor while the player is open, which already shows
    /// the new song.
    private func trackChanged() {
        guard showSongChanges, isRunning, ActivityCenter.shared.isShowing(id: activity.id),
              !IslandManager.shared.isOpen(on: activity.id) else { return }
        presentSongBanner()
    }

    /// The same id every time, so skipping through several songs updates the banner
    /// in place instead of stacking them.
    private func presentSongBanner() {
        let wing = NowPlayingSongBannerLayout.wingWidth(
            title: model.title, artist: model.subtitle, isVideo: model.isVideo
        )
        ActivityCenter.shared.present(IslandBanner(
            id: Self.songBannerID,
            style: .compact(leading: wing, trailing: wing),
            duration: 2.5,
            haptic: false,
            interruption: model.isPreviewing ? .active : .passive,
            leading: AnyView(NowPlayingSongBannerLeading(model: model)),
            trailing: AnyView(NowPlayingSongBannerTrailing(model: model))
        ))
    }

    // MARK: Previews

    private func preview(
        _ sample: NowPlayingSnapshot, players: [NowPlayingBroadcastPlayer: NowPlayingSnapshot] = [:],
        library sampleLibrary: (any MediaLibrary)? = nil, for length: TimeInterval? = nil
    ) {
        previewWork?.cancel()
        previewStepWork?.cancel()
        previewStepWork = nil
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endPreview() }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (length ?? Self.previewLength), execute: work)
        previewLibrary = sampleLibrary
        model.beginPreview(sample, players: players)
    }

    /// A video in Safari plays while Spotify, heard only through its own
    /// notifications, plays a song too. When the video pauses, the island turns to the
    /// song, which never stopped: the activity stays up, and there is no song banner,
    /// since the song is not new.
    private func previewAnotherPlayer() {
        let video = NowPlayingSnapshot.dolomites(playing: true)
        preview(video, players: [.spotify: .midnightDrive(playing: true, in: NowPlayingBroadcastPlayer.spotify.bundleID)])
        previewSteps([
            (Self.videoPauseDelay, { [weak self] in self?.model.previewReport(video.paused(at: Date())) }),
        ])
    }

    /// A video in Safari and a song in Spotify, both playing, with the video on show
    /// as MediaRemote reports it. The island moves to the song as a swipe would, opens
    /// on the switcher, and goes back to the video as a click on its icon would.
    private func previewSeveralPlayers() {
        let video = NowPlayingSnapshot.dolomites(playing: true)
        preview(
            video,
            players: [.spotify: .midnightDrive(playing: true, in: NowPlayingBroadcastPlayer.spotify.bundleID)],
            library: NowPlayingSampleLibrary(), for: Self.severalPlayersLength
        )
        previewSteps([
            (2.5, { [weak self] in self?.model.switchSession(forward: true) }),
            (2, { [weak self] in
                guard let self else { return }
                IslandManager.shared.focusedController?.model.expand(focus: self.activity.id)
            }),
            (3, { [weak self] in
                if let app = video.track.bundleID { self?.model.pick(app) }
            }),
        ])
    }

    /// Runs a preview's steps in turn, each the given number of seconds after the
    /// one before.
    private func previewSteps(_ steps: ArraySlice<(delay: TimeInterval, run: @MainActor () -> Void)>) {
        guard let step = steps.first else {
            previewStepWork = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                step.run()
                self?.previewSteps(steps.dropFirst())
            }
        }
        previewStepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + step.delay, execute: work)
    }

    /// Opens the island on the sample song with its Up Next panel showing, as
    /// Spotify's would, Jam button and all.
    private func previewLibraryPanel() {
        preview(
            .midnightDrive(playing: true, in: "com.spotify.client"), library: NowPlayingSampleLibrary(),
            for: Self.libraryPreviewLength
        )
        IslandManager.shared.focusedController?.model.expand(focus: activity.id)
        library.open(.upNext)
    }

    private func endPreview() {
        previewWork = nil
        previewStepWork?.cancel()
        previewStepWork = nil
        previewLibrary = nil
        ActivityCenter.shared.dismissBanner(id: Self.songBannerID)
        model.endPreview()
        // The preview put the activity up; a paused session would not have.
        endActivityUnlessPlaying()
    }
}

@MainActor
final class NowPlayingActivity: IslandActivity {
    let id = "nowPlaying"
    let model: NowPlayingModel
    let library: NowPlayingLibraryModel

    init(model: NowPlayingModel, library: NowPlayingLibraryModel) {
        self.model = model
        self.library = library
    }

    var symbol: String { model.isVideo ? "play.rectangle.fill" : "music.note" }
    var appBundleIdentifier: String? { model.track?.bundleID }

    var expandedHeight: CGFloat {
        NowPlayingExpanded.height(
            isVideo: model.isVideo, hasButtons: library.hasButtons, isPanelOpen: library.panel != nil
        )
    }

    func compactLeading() -> AnyView { AnyView(NowPlayingCompactLeading(model: model)) }
    func compactTrailing() -> AnyView { AnyView(NowPlayingCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(NowPlayingMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(NowPlayingExpanded(model: model, library: library)) }

    /// Moves between the players that have something loaded; nothing to do with one.
    func swipe(_ direction: ActivitySwipe) -> Bool {
        model.switchSession(forward: direction == .next)
    }
}

private extension NowPlayingSnapshot {
    /// Music is on every Mac, so the app badge has an icon to show. Played in
    /// Spotify, which reports neither shuffle nor repeat, the song has no toggles.
    static func midnightDrive(playing: Bool, in bundleID: String = "com.apple.Music") -> NowPlayingSnapshot {
        var snapshot = sample(
            title: "Midnight Drive", artist: "Neon Harbour", album: "Coastal Lights", bundleID: bundleID,
            duration: 222, elapsed: 71, playing: playing, artwork: .sampleSunset
        )
        if bundleID == "com.apple.Music" {
            snapshot.shuffle = .off
            snapshot.repeatMode = .off
        }
        return snapshot
    }

    /// Long enough to scroll in the opened island.
    static func paperPlanes(playing: Bool) -> NowPlayingSnapshot {
        sample(
            title: "Paper Planes Over Lisbon (Live from the Sunroom, 2026 Remaster)",
            artist: "Juniper & the Tides", album: "Sunroom Sessions", bundleID: "com.apple.Music",
            duration: 245, elapsed: 3, playing: playing, artwork: .sampleBay
        )
    }

    /// A web video in Safari, which is on every Mac too, with a landscape
    /// thumbnail and no 15-second jumps of its own, so those are seeks.
    static func dolomites(playing: Bool) -> NowPlayingSnapshot {
        var snapshot = sample(
            title: "Walking the Dolomites at First Light", artist: "Alpine Diaries", album: "",
            bundleID: "com.apple.Safari", duration: 862, elapsed: 308, playing: playing, artwork: .sampleVideo
        )
        snapshot.isVideo = true
        return snapshot
    }

    /// The same session, paused where it had got to.
    func paused(at date: Date) -> NowPlayingSnapshot {
        var paused = self
        paused.isPlaying = false
        paused.timing = timing.anchored(at: date, rate: 0)
        return paused
    }

    private static func sample(
        title: String, artist: String, album: String, bundleID: String,
        duration: TimeInterval, elapsed: TimeInterval, playing: Bool, artwork: NowPlayingArtwork?
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            track: NowPlayingTrack(title: title, artist: artist, album: album, bundleID: bundleID),
            isPlaying: playing,
            timing: NowPlayingTiming(elapsed: elapsed, timestamp: Date(), rate: playing ? 1 : 0, duration: duration),
            artwork: artwork
        )
    }
}
