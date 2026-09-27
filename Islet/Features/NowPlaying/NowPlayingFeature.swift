import os
import SwiftUI

enum NowPlayingPrefs {
    /// Seconds a paused session keeps the island, or `neverHide`.
    static let hideAfterPause = "nowPlaying.hideAfterPause"
    static let tintWaveform = "nowPlaying.tintWaveform"
    static let showSongChanges = "nowPlaying.showSongChanges"
    /// The waveform follows the playing app's sound, where macOS lets Islet hear it.
    static let followMusic = "nowPlaying.waveformFollowsMusic"

    static let hideAfterPauseDefault = 30
    static let tintWaveformDefault = true
    static let showSongChangesDefault = true
    static let followMusicDefault = true
    static let neverHide = -1
}

/// Whatever the Mac is playing — Music, Spotify, a video in the browser — the way
/// the iPhone shows it: the cover and a waveform either side of the notch while it
/// plays, full controls when opened, and a moment's banner when the song changes.
/// Once lyrics are on, the song's lyrics too: in a panel of the opened player, and if
/// asked, the line being sung in a row under the compact island.
@MainActor
final class NowPlayingFeature: Feature {
    let id = "nowPlaying"
    let title = "Now Playing"
    let symbol = "music.note"
    let summary = "Artwork and a live waveform while music or video plays, with controls when opened."

    private let model = NowPlayingModel()
    private let library = NowPlayingLibraryModel()
    /// Where the sound plays, for the player's output button.
    private let outputs = OutputPickerModel()
    /// The song's lyrics, for the lyrics panel and the island's karaoke row.
    private let lyrics = NowPlayingLyricsModel()
    private lazy var activity = NowPlayingActivity(model: model, library: library, outputs: outputs, lyrics: lyrics)
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
    /// The karaoke row standing under the activity.
    private static let karaokeID = "nowPlaying.lyrics"
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
        // Made now, before the mixer makes any tap, so the waveform can listen in on
        // the mixer's taps rather than make its own.
        _ = NowPlayingLevels.shared
        model.send = { [weak self] command, app, mayPrompt in self?.send(command, to: app, mayPrompt: mayPrompt) }
        model.onChange = { [weak self] in self?.sync() }
        model.onTrackChange = { [weak self] in self?.trackChanged() }
        model.onSwitch = { [weak self] in self?.switched() }
        library.onPanelChange = { [weak self] in self?.panelChanged() }
        lyrics.onChange = { [weak self] in self?.lyricsChanged() }
        broadcasts.onUpdate = { [weak self] player, snapshot in self?.model.ingest(snapshot, from: player) }
    }

    func start() {
        isRunning = true
        streamToken += 1
        let token = streamToken
        adapter?.startStream(
            onUpdate: { [weak self] snapshot in
                MainActor.assumeIsolated { self?.receive(snapshot, token: token) }
            },
            onSessions: { [weak self] sessions in
                MainActor.assumeIsolated { self?.receive(sessions, token: token) }
            }
        )
        broadcasts.start()
        outputs.start()
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
        // Stopped first, so ending a preview of the outputs starts nothing real.
        outputs.stop()
        outputs.endPreview()
        cancelHide()
        lyrics.stop()
        model.reset()
        NowPlayingLevels.shared.show(nil, playing: false)
        // Closes any panel, the outputs' too, which no library change closes, and
        // drops the library's requests.
        library.close()
        library.use(nil)
        libraryTrack = nil
        let center = ActivityCenter.shared
        center.removeStandingAttachment(id: Self.karaokeID)
        center.end(id: activity.id)
        center.dismissBanner(id: Self.songBannerID)
        center.removeHomeWidget(id: id)
        homeWidgetShown = false
    }

    func settingsView() -> AnyView? {
        AnyView(NowPlayingSettings(
            onHideAfterPauseChange: { [weak self] in self?.hideAfterPauseChanged() },
            onLyricsChange: { [weak self] in self?.lyrics.reloadSettings() }
        ))
    }

    /// Each shows sample data for 10 seconds (the library's, outputs' and lyrics' 20,
    /// several players' 13), then hands back to whatever is really playing. None of
    /// them touches a real player, library or output, or looks anything up: the songs
    /// come with a sample library and made-up lyrics of their own, and the output
    /// picker with sample outputs.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Sample song (playing)") { [weak self] in
                self?.preview(
                    .midnightDrive(playing: true), library: NowPlayingSampleLibrary(), lyrics: NowPlayingLyricsSamples.midnightDrive
                )
            },
            FeaturePreview(title: "Sample song (paused)") { [weak self] in
                self?.preview(
                    .midnightDrive(playing: false), library: NowPlayingSampleLibrary(), lyrics: NowPlayingLyricsSamples.midnightDrive
                )
            },
            FeaturePreview(title: "Song change") { [weak self] in
                self?.preview(.paperPlanes(playing: true), library: NowPlayingSampleLibrary(), lyrics: NowPlayingLyricsSamples.paperPlanes)
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
            FeaturePreview(title: "Output picker") { [weak self] in
                self?.previewOutputPicker()
            },
            FeaturePreview(title: "Lyrics") { [weak self] in
                self?.previewLyrics()
            },
            FeaturePreview(title: "Karaoke in the island") { [weak self] in
                self?.previewKaraoke()
            },
        ]
    }

    /// `islet://nowPlaying/toggle`, `/next`, `/previous`. They come from Shortcuts and
    /// scripts, often with nobody watching, so they never put up macOS's Automation
    /// prompt: where Islet has not yet been allowed to control Spotify or Music, they
    /// go through MediaRemote, if the player is the app it has elected.
    func handle(_ url: URL) -> Bool {
        // Sign-in callbacks and the like, for a music app's library.
        if MediaLibraries.handle(url) { return true }
        switch url.path() {
        case "/toggle": model.togglePlayPause(mayPrompt: false)
        case "/next": model.next(mayPrompt: false)
        case "/previous": model.previous(mayPrompt: false)
        default: return false
        }
        return true
    }

    // MARK: State

    private func receive(_ snapshot: NowPlayingSnapshot?, token: Int) {
        guard isRunning, token == streamToken else { return }
        model.ingest(snapshot)
    }

    private func receive(_ sessions: NowPlayingMediaRemoteSessions, token: Int) {
        guard isRunning, token == streamToken else { return }
        model.ingest(sessions: sessions)
    }

    /// A control goes to the app the island shows and to no other (see
    /// `NowPlayingRouting`). One that does not get there puts back what the player
    /// last reported.
    private func send(_ command: NowPlayingCommand, to app: String?, mayPrompt: Bool) {
        let sent = Date()
        NowPlayingRouting.deliver(
            command, along: NowPlayingRouting.routes(for: command, to: app)[...],
            using: { [weak self] route, command, completion in
                guard let self else { return completion(.unavailable) }
                self.send(command, by: route, mayPrompt: mayPrompt, completion: completion)
            },
            completion: { [weak self] delivery, route in
                let way = route.map { String(describing: $0) } ?? "no way"
                NowPlayingRouting.log.notice(
                    "\(String(describing: command), privacy: .public) for \(app ?? "an unnamed app", privacy: .public) by \(way, privacy: .public): \(String(describing: delivery), privacy: .public)"
                )
                if delivery != .delivered { self?.model.commandFailed(command, sentAt: sent) }
            }
        )
    }

    private func send(
        _ command: NowPlayingCommand, by route: NowPlayingRoute, mayPrompt: Bool,
        completion: @escaping @MainActor (NowPlayingDelivery) -> Void
    ) {
        switch route {
        case .appleEvents(let player):
            broadcasts.perform(command, on: player, mayPrompt: mayPrompt, completion: completion)
        case .mediaRemote(let app):
            perform(command, onlyTo: app, completion: completion)
        case .mediaRemoteAnyApp:
            perform(command, onlyTo: nil, completion: completion)
        }
    }

    private func perform(
        _ command: NowPlayingCommand, onlyTo app: String?,
        completion: @escaping @MainActor (NowPlayingDelivery) -> Void
    ) {
        guard let adapter else { return completion(.unavailable) }
        adapter.perform(command, onlyTo: app) { delivery in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(delivery) } }
        }
    }

    /// Puts up or takes down the activity and the home tile to match the model.
    private func sync() {
        let center = ActivityCenter.shared
        let isPreviewing = model.isPreviewing
        let isActive = isRunning || isPreviewing
        syncLibrary(isActive: isActive)
        // Once the activity is up or down, for the karaoke row to go with it.
        defer { syncLyrics() }
        // Only a real session's app is listened to: a preview's bars are canned.
        let listened = isRunning && !isPreviewing && model.isLive ? model.track?.bundleID : nil
        NowPlayingLevels.shared.show(listened, playing: model.isPlaying)

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

    // MARK: Lyrics

    /// The lyrics follow the song on show while it is live, and during a preview the
    /// sample song, with its made-up lyrics; nothing else. A preview's song is never
    /// looked up, nor the last session kept after its player went.
    private var lyricsFollowSong: Bool {
        model.isPreviewing ? lyrics.isPreviewing : isRunning && model.isLive
    }

    private func syncLyrics() {
        lyrics.follow(
            track: lyricsFollowSong ? model.track : nil, isVideo: lyricsTakesForVideo, timing: model.timing,
            isPlaying: model.isPlaying
        )
        lyricsChanged()
    }

    /// Video, or perhaps video (see `LyricsQuery.takesForVideo`).
    private var lyricsTakesForVideo: Bool {
        LyricsQuery.takesForVideo(isVideo: model.isVideo, bundleID: model.track?.bundleID, hasArtwork: model.artwork != nil)
    }

    /// The Lyrics button, who is looking at the lyrics, and the karaoke row, to match
    /// the lyrics. Every song has the button, the way in to turning lyrics on; a video
    /// only once lyrics have been found for it; a podcast or an audiobook never.
    private func lyricsChanged() {
        library.offersLyrics = lyricsFollowSong && model.hasSession && !LyricsQuery.isSpokenWord(model.track?.bundleID)
            && (!lyricsTakesForVideo || lyrics.status.hasLyrics)
        let isUp = ActivityCenter.shared.isShowing(id: activity.id)
        lyrics.watch(panel: library.panel == .lyrics, island: isUp && lyrics.showsInIsland)
        syncKaraoke()
        republishIfResized()
    }

    /// The line being sung stands in a row under the compact activity while there is
    /// one: the row goes in a break, before the first line and after the last, and a
    /// moment after a pause, and comes back with the next line.
    private func syncKaraoke() {
        let center = ActivityCenter.shared
        let wanted = (isRunning || model.isPreviewing) && center.isShowing(id: activity.id)
            && lyrics.showsInIsland && lyrics.singingRow != nil
        let shown = center.standingAttachment?.attachment.id == Self.karaokeID
        if wanted, !shown {
            center.setStandingAttachment(IslandAttachment(
                id: Self.karaokeID,
                height: NowPlayingKaraokeLayout.rowHeight,
                width: NowPlayingKaraokeLayout.rowWidth,
                content: AnyView(NowPlayingKaraokeRow(lyrics: lyrics))
            ), under: activity.id)
        } else if !wanted, shown {
            center.removeStandingAttachment(id: Self.karaokeID)
        }
    }

    /// The panel opened or closed. The Lyrics button's first tap is what turns lyrics
    /// on, and with them the look-ups; a preview's never does.
    private func panelChanged() {
        if library.panel == .lyrics, !model.isPreviewing { lyrics.setEnabled(true) }
        lyricsChanged()
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

    /// `lyrics` are the sample song's; `inIsland` shows its line in the island
    /// whatever Settings say.
    private func preview(
        _ sample: NowPlayingSnapshot, players: [NowPlayingBroadcastPlayer: NowPlayingSnapshot] = [:],
        library sampleLibrary: (any MediaLibrary)? = nil, lyrics sampleLyrics: LyricsResult = .notFound,
        inIsland: Bool = false, for length: TimeInterval? = nil
    ) {
        previewWork?.cancel()
        previewStepWork?.cancel()
        previewStepWork = nil
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endPreview() }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (length ?? Self.previewLength), execute: work)
        // The output picker's own preview puts its samples back after this.
        endOutputPreview()
        previewLibrary = sampleLibrary
        // Before the song, so the lyrics never follow the sample song for real.
        lyrics.beginPreview(sampleLyrics, inIsland: inIsland)
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

    /// Opens the island on the sample song with the output panel showing, over
    /// sample outputs: speakers, AirPods Pro with their battery, a display. The song
    /// has no library, so no row of library buttons takes the room: the three outputs
    /// show in full, with the AirPlay row just under them, a scroll away.
    private func previewOutputPicker() {
        preview(.midnightDrive(playing: true), for: Self.libraryPreviewLength)
        outputs.beginPreview()
        IslandManager.shared.focusedController?.model.expand(focus: activity.id)
        library.open(.output)
    }

    /// Opens the island on the sample song with its lyrics following along, a third of
    /// the way in: the line being sung bright, a long one wrapping, the chorus above.
    private func previewLyrics() {
        preview(
            .midnightDrive(playing: true), library: NowPlayingSampleLibrary(), lyrics: NowPlayingLyricsSamples.midnightDrive,
            for: Self.libraryPreviewLength
        )
        IslandManager.shared.focusedController?.model.expand(focus: activity.id)
        library.open(.lyrics)
    }

    /// The sample song in the compact island with its lines in a row underneath, one
    /// after another, a long one scrolling across.
    private func previewKaraoke() {
        preview(
            .midnightDrive(playing: true), lyrics: NowPlayingLyricsSamples.midnightDrive, inIsland: true,
            for: Self.libraryPreviewLength
        )
    }

    /// Hands the output picker back to the real outputs, closing its panel first if
    /// it was listing the samples: a click meant for them must not move the Mac's
    /// sound. A panel opened on the real outputs during a song's preview stays open.
    private func endOutputPreview() {
        guard outputs.isPreviewing else { return }
        if library.panel == .output { library.close() }
        outputs.endPreview()
    }

    private func endPreview() {
        previewWork = nil
        previewStepWork?.cancel()
        previewStepWork = nil
        previewLibrary = nil
        endOutputPreview()
        ActivityCenter.shared.dismissBanner(id: Self.songBannerID)
        // Before the song, so the sample song is never looked up.
        lyrics.endPreview()
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
    let outputs: OutputPickerModel
    let lyrics: NowPlayingLyricsModel

    init(model: NowPlayingModel, library: NowPlayingLibraryModel, outputs: OutputPickerModel, lyrics: NowPlayingLyricsModel) {
        self.model = model
        self.library = library
        self.outputs = outputs
        self.lyrics = lyrics
    }

    var symbol: String { model.isVideo ? "play.rectangle.fill" : "music.note" }
    var appBundleIdentifier: String? { model.track?.bundleID }

    var expandedHeight: CGFloat {
        NowPlayingExpanded.height(
            isVideo: model.isVideo, hasButtons: library.hasButtons, isPanelOpen: library.panel != nil,
            hasControlsHint: !model.canControl
        )
    }

    func compactLeading() -> AnyView { AnyView(NowPlayingCompactLeading(model: model)) }
    func compactTrailing() -> AnyView { AnyView(NowPlayingCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(NowPlayingMinimal(model: model)) }
    func expanded() -> AnyView {
        AnyView(NowPlayingExpanded(model: model, library: library, outputs: outputs, lyrics: lyrics))
    }

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
