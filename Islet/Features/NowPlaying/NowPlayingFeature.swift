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
    private lazy var activity = NowPlayingActivity(model: model)
    /// `nil` when the adapter is missing from the bundle; then only previews work.
    private let adapter = NowPlayingAdapter()
    private var isRunning = false
    /// Tells the current stream's updates from any still queued from a stopped one.
    private var streamToken = 0
    private var homeWidgetShown = false
    private var hideWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?

    @AppStorage(NowPlayingPrefs.hideAfterPause) private var hideAfterPause = NowPlayingPrefs.hideAfterPauseDefault
    @AppStorage(NowPlayingPrefs.showSongChanges) private var showSongChanges = NowPlayingPrefs.showSongChangesDefault

    private static let songBannerID = "nowPlaying.song"
    /// The default compact wing beside a 32 pt notch, so the cover stays where it
    /// was when the banner takes over.
    private static let songBannerLeading: CGFloat = 44
    /// How long a preview holds the island before the real state returns.
    private static let previewLength: TimeInterval = 10
    /// The shortest hold after a pause. Players pause for a moment between tracks,
    /// and the activity should not blink out and back for that.
    private static let pauseGrace: TimeInterval = 1.5

    init() {
        model.send = { [weak self] command in self?.adapter?.perform(command) }
        model.onChange = { [weak self] in self?.sync() }
        model.onTrackChange = { [weak self] in self?.trackChanged() }
    }

    func start() {
        isRunning = true
        streamToken += 1
        let token = streamToken
        adapter?.startStream { [weak self] snapshot in
            MainActor.assumeIsolated { self?.receive(snapshot, token: token) }
        }
        sync()
    }

    func stop() {
        isRunning = false
        adapter?.stop()
        previewWork?.cancel()
        previewWork = nil
        cancelHide()
        model.reset()
        let center = ActivityCenter.shared
        center.end(id: activity.id)
        center.dismissBanner(id: Self.songBannerID)
        center.removeHomeWidget(id: id)
        homeWidgetShown = false
    }

    func settingsView() -> AnyView? {
        AnyView(NowPlayingSettings { [weak self] in self?.hideAfterPauseChanged() })
    }

    /// Each shows sample data for 10 seconds, then hands back to whatever is really
    /// playing. None of them touches a real player.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Sample song (playing)") { [weak self] in
                self?.preview(.midnightDrive(playing: true))
            },
            FeaturePreview(title: "Sample song (paused)") { [weak self] in
                self?.preview(.midnightDrive(playing: false))
            },
            FeaturePreview(title: "Song change") { [weak self] in
                self?.preview(.paperPlanes(playing: true))
                self?.presentSongBanner()
            },
        ]
    }

    /// `islet://nowPlaying/toggle`, `/next`, `/previous`.
    func handle(_ url: URL) -> Bool {
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

    /// Puts up or takes down the activity and the home tile to match the model.
    private func sync() {
        let center = ActivityCenter.shared
        let isPreviewing = model.isPreviewing
        let isActive = isRunning || isPreviewing

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
            if !center.isShowing(id: activity.id) { center.show(activity) }
        } else if center.isShowing(id: activity.id), hideWork == nil {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        let hold = hideAfterPause
        guard hold >= 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideWork = nil
                if !self.model.isPlaying { ActivityCenter.shared.end(id: self.activity.id) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(Self.pauseGrace, TimeInterval(hold)), execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    /// A new hold applies to a pause already on screen, counted from now; otherwise
    /// switching from "Never" would leave the island up until the next play or pause.
    private func hideAfterPauseChanged() {
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
        ActivityCenter.shared.present(IslandBanner(
            id: Self.songBannerID,
            style: .compact(leading: Self.songBannerLeading, trailing: 150),
            duration: 2.5,
            haptic: false,
            leading: AnyView(NowPlayingCompactLeading(model: model)),
            trailing: AnyView(NowPlayingSongBannerTrailing(model: model))
        ))
    }

    // MARK: Previews

    private func preview(_ sample: NowPlayingSnapshot) {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endPreview() }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewLength, execute: work)
        model.beginPreview(sample)
    }

    private func endPreview() {
        previewWork = nil
        ActivityCenter.shared.dismissBanner(id: Self.songBannerID)
        model.endPreview()
        // The preview put the activity up; a paused session would not have.
        if !(isRunning && model.isPlaying) {
            cancelHide()
            ActivityCenter.shared.end(id: activity.id)
        }
    }
}

@MainActor
final class NowPlayingActivity: IslandActivity {
    let id = "nowPlaying"
    let symbol = "music.note"
    let model: NowPlayingModel

    init(model: NowPlayingModel) { self.model = model }

    var expandedHeight: CGFloat { 132 }

    func compactLeading() -> AnyView { AnyView(NowPlayingCompactLeading(model: model)) }
    func compactTrailing() -> AnyView { AnyView(NowPlayingCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(NowPlayingMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(NowPlayingExpanded(model: model)) }
}

private extension NowPlayingSnapshot {
    static func midnightDrive(playing: Bool) -> NowPlayingSnapshot {
        sample(
            title: "Midnight Drive", artist: "Neon Harbour", album: "Coastal Lights",
            duration: 222, elapsed: 71, playing: playing, artwork: .sampleSunset
        )
    }

    /// Long enough to scroll in the opened island.
    static func paperPlanes(playing: Bool) -> NowPlayingSnapshot {
        sample(
            title: "Paper Planes Over Lisbon (Live from the Sunroom, 2026 Remaster)",
            artist: "Juniper & the Tides", album: "Sunroom Sessions",
            duration: 245, elapsed: 3, playing: playing, artwork: .sampleBay
        )
    }

    private static func sample(
        title: String, artist: String, album: String,
        duration: TimeInterval, elapsed: TimeInterval, playing: Bool, artwork: NowPlayingArtwork?
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            // Music is on every Mac, so the app badge has an icon to show.
            track: NowPlayingTrack(title: title, artist: artist, album: album, bundleID: "com.apple.Music"),
            isPlaying: playing,
            timing: NowPlayingTiming(elapsed: elapsed, timestamp: Date(), rate: playing ? 1 : 0, duration: duration),
            artwork: artwork
        )
    }
}
