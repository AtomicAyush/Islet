import SwiftUI

/// A self-contained source of island content — now playing, the battery, a timer.
/// Each lives in its own folder under Features/, owns its models and views, and
/// talks to the island only through `ActivityCenter`.
///
/// The registry starts a feature when it is enabled in Settings and stops it when
/// it is disabled; `stop()` must end every activity, banner and home widget the
/// feature put up, and release any observers, taps or processes it started.
@MainActor
protocol Feature: AnyObject {
    /// Stable identifier, used for the enabled-state preference key.
    var id: String { get }
    var title: String { get }
    /// SF Symbol shown beside the feature in Settings.
    var symbol: String { get }
    /// One sentence for Settings, saying what the island will show.
    var summary: String { get }
    var enabledByDefault: Bool { get }

    func start()
    func stop()

    /// Extra options, shown under the feature's toggle in Settings.
    func settingsView() -> AnyView?
    /// Settings search finds every feature by its title and summary, so a new one is
    /// found with nothing more. These add the labels of its settings and the other
    /// names people use for it ("dnd" for Focus); list them in
    /// Settings/SettingsSearchTerms.swift beside every other feature's.
    var searchTerms: SettingsSearchTerms { get }
    /// Ways to see the feature without waiting for the real event, listed in the
    /// menu bar's Preview submenu. They work whether or not the feature is enabled.
    var previews: [FeaturePreview] { get }

    /// Handles `islet://<id>/…` URLs addressed to this feature. Returns whether the
    /// URL was understood.
    func handle(_ url: URL) -> Bool

    /// The tile the feature puts on the home page, if it has one, with the id its
    /// `HomeWidget` is published under: listed to arrange (in Settings, and hidden ones
    /// in the island) whether or not it is showing.
    var homeTile: HomeTileInfo? { get }
    /// The live activity the feature puts in the island, if it has one, with the id its
    /// `IslandActivity` is published under: listed in Settings to put in the order the
    /// island takes them in, whether or not it is running.
    var islandActivity: IslandActivityInfo? { get }
}

extension Feature {
    var enabledByDefault: Bool { true }
    func settingsView() -> AnyView? { nil }
    var searchTerms: SettingsSearchTerms { SettingsSearchTerms() }
    var previews: [FeaturePreview] { [] }
    func handle(_ url: URL) -> Bool { false }
    var homeTile: HomeTileInfo? { nil }
    var islandActivity: IslandActivityInfo? { nil }
}

extension HomeTileInfo {
    /// `feature`'s tile, under the feature's own id, name and symbol, going at `order`
    /// until the person puts it somewhere else.
    @MainActor
    init(_ feature: any Feature, order: Int) {
        self.init(id: feature.id, title: feature.title, symbol: feature.symbol, order: order)
    }
}

struct FeaturePreview: Identifiable {
    var id: String { title }
    let title: String
    let run: @MainActor () -> Void
}

/// Owns every feature and keeps each one running exactly when it is enabled.
@MainActor
final class FeatureRegistry {
    static let shared = FeatureRegistry()

    let features: [any Feature] = [
        NowPlayingFeature(),
        MixerFeature(),
        TimerFeature(),
        PomodoroFeature(),
        KeepAwakeFeature(),
        BatteryFeature(),
        SystemHUDFeature(),
        CapsLockFeature(),
        BluetoothFeature(),
        InputDevicesFeature(),
        NetworkFeature(),
        CalendarFeature(),
        WeatherFeature(),
        PrivacyFeature(),
        MicMuteFeature(),
        FocusFeature(),
        PresentationFeature(),
        ShortcutsFeature(),
        BannerFeature(),
        ClaudeCodeFeature(),
        DropZoneFeature(),
        DownloadsFeature(),
        FileCopiesFeature(),
        ScreenshotsFeature(),
        ClipboardFeature(),
        HiddenMenuBarIconsFeature(),
    ]

    private var running: Set<String> = []
    private var observer: NSObjectProtocol?

    private init() {}

    func startEnabled() {
        sync()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func stopAll() {
        for feature in features where running.contains(feature.id) {
            feature.stop()
        }
        running.removeAll()
    }

    func feature<T: Feature>(_ type: T.Type) -> T? {
        features.lazy.compactMap { $0 as? T }.first
    }

    private func sync() {
        for feature in features {
            let wanted = Prefs.isEnabled(feature)
            let isRunning = running.contains(feature.id)
            if wanted && !isRunning {
                running.insert(feature.id)
                feature.start()
            } else if !wanted && isRunning {
                running.remove(feature.id)
                feature.stop()
            }
        }
        // The home page is arranged from the running features' tiles. Set only when they
        // change: this runs on every change to the defaults, arranging included.
        let arrangement = ActivityCenter.shared.homeArrangement
        let tiles = features.filter { running.contains($0.id) }.compactMap(\.homeTile)
        if arrangement.tiles != tiles { arrangement.tiles = tiles }
        // And the island's order from their live activities, likewise.
        let order = ActivityCenter.shared.islandArrangement
        let activities = features.filter { running.contains($0.id) }.compactMap(\.islandActivity)
        if order.activities != activities { order.activities = activities }
    }
}
