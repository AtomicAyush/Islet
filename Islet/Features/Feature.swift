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
    /// Ways to see the feature without waiting for the real event, listed in the
    /// menu bar's Preview submenu. They work whether or not the feature is enabled.
    var previews: [FeaturePreview] { get }

    /// Handles `islet://<id>/…` URLs addressed to this feature. Returns whether the
    /// URL was understood.
    func handle(_ url: URL) -> Bool
}

extension Feature {
    var enabledByDefault: Bool { true }
    func settingsView() -> AnyView? { nil }
    var previews: [FeaturePreview] { [] }
    func handle(_ url: URL) -> Bool { false }
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
        BatteryFeature(),
        SystemHUDFeature(),
        BluetoothFeature(),
        CalendarFeature(),
        PrivacyFeature(),
        FocusFeature(),
        ShortcutsFeature(),
        DropZoneFeature(),
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
    }
}
