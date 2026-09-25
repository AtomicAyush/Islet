import SwiftUI

/// Focus — Do Not Disturb, Sleep, Work and the person's own — the way the iPhone's
/// island shows it: a word as a Focus turns on or off, and, while one is on, its
/// symbol beside the notch. The home page shows which is on and turns it on or off
/// through a shortcut, and a Focus can ask the island to keep minor alerts to itself.
///
/// macOS only says which Focus is on in its Focus database, behind Full Disk Access.
/// Nothing is ever asked for: without access the home tile says so, and Settings
/// offers the way to allow it.
@MainActor
final class FocusFeature: Feature {
    let id = "focus"
    let title = "Focus"
    let symbol = "moon.fill"
    let summary = "Announces Focus changes, and shows the Focus that is on beside the notch."

    /// Turning on, turning off and switching share one id, so a quick change of mind
    /// updates the banner already up rather than stacking another.
    private static let bannerID = "focus"
    private static let problemBannerID = "focus.shortcut"
    private static let bannerDuration: TimeInterval = 2.2

    private let model: FocusModel
    private let toggle = FocusToggle()
    private let shortcuts = FocusShortcutList()
    private var isRunning = false
    private var isTileShown = false
    private var defaultsObserver: NSObjectProtocol?

    /// `directory` is the Focus database's; tests point it at a folder of their own.
    init(directory: URL = FocusDatabase.defaultDirectory) {
        model = FocusModel(directory: directory)
        model.onChange = { [weak self] change in self?.changed(change) }
        toggle.onFailure = { [weak self] failure in
            self?.present(.problem(failure), id: Self.problemBannerID)
        }
    }

    func start() {
        isRunning = true
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        model.start()
        render()
    }

    func stop() {
        isRunning = false
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = nil
        // A shortcut still running is stopped, and says nothing more.
        toggle.cancel()
        model.stop()
        render()
        let center = ActivityCenter.shared
        center.dismissBanner(id: Self.bannerID)
        center.dismissBanner(id: Self.problemBannerID)
    }

    func settingsView() -> AnyView? {
        AnyView(FocusSettingsView(model: model, shortcuts: shortcuts))
    }

    /// Sample Focuses, not the person's: each announces itself, then stands in for the
    /// real state beside the notch and on the home page for eight seconds. Nothing is
    /// turned on or off.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Do Not Disturb on") { [weak self] in
                self?.preview(FocusState(mode: .sampleDoNotDisturb))
            },
            FeaturePreview(title: "Work on") { [weak self] in
                self?.preview(FocusState(mode: .sampleWork, until: Self.sampleEnd()))
            },
            FeaturePreview(title: "Focus off") { [weak self] in
                self?.preview(.off, turningOff: .sampleDoNotDisturb)
            },
        ]
    }

    /// `islet://focus/toggle` runs the shortcut chosen in Settings, as clicking the
    /// home tile does — or, with none chosen, opens Focus in System Settings.
    func handle(_ url: URL) -> Bool {
        guard url.path() == "/toggle" else { return false }
        toggleFocus()
        return true
    }

    // MARK: State

    private func changed(_ change: FocusModel.Change?) {
        render()
        guard let change, isRunning, FocusPrefs.bool(FocusPrefs.announce, default: true) else { return }
        // Straight from one Focus to another announces the new one.
        if let mode = change.to.mode {
            present(.focus(mode, isOn: true))
        } else if let mode = change.from.mode {
            present(.focus(mode, isOn: false))
        }
    }

    /// Puts the indicator, the home tile and the quiet for minor alerts in line with
    /// the model and the settings.
    private func render() {
        let center = ActivityCenter.shared
        let isPreviewing = model.preview != nil
        let real = model.access == .granted ? model.state : .off

        // Only the real Focus quiets anything: a preview is there to be looked at.
        let quiet = isRunning && real.mode != nil && FocusPrefs.bool(FocusPrefs.quietMinorAlerts, default: true)
        if center.silencesPassiveBanners != quiet { center.silencesPassiveBanners = quiet }

        // A preview shows the indicator whatever the setting: it is there to be seen.
        if let mode = model.shown?.mode, isPreviewing || (isRunning && FocusPrefs.bool(FocusPrefs.showIndicator, default: true)) {
            // Ahead of the camera and microphone dot: the Focus stays put while the dot
            // comes and goes at the island's end. On a display without a notch it
            // waits for the island to be up, rather than keep a pill there for hours
            // against the person's choice.
            center.setIndicator(StatusIndicator(
                id: id, color: mode.tint.color, order: -1, symbol: mode.symbol, keepsIslandShown: false
            ))
        } else {
            center.removeIndicator(id: id)
        }

        // Where Focus cannot be read at all, the feature quietly shows nothing.
        let wantsTile = isPreviewing
            || (isRunning && (model.access == .granted || model.access == .needsFullDiskAccess))
        guard wantsTile != isTileShown else { return }
        isTileShown = wantsTile
        if wantsTile {
            center.setHomeWidget(HomeWidget(
                id: id, order: 45, view: AnyView(FocusHomeTile(model: model, toggle: toggle) { [weak self] in
                    self?.tileClicked()
                })
            ))
        } else {
            center.removeHomeWidget(id: id)
        }
    }

    private func present(_ announcement: FocusAnnouncement, id: String? = nil) {
        let widths = FocusBannerLayout.widths(for: announcement)
        ActivityCenter.shared.present(IslandBanner(
            id: id ?? Self.bannerID,
            style: .compact(leading: widths.leading, trailing: widths.trailing),
            duration: Self.bannerDuration,
            leading: AnyView(FocusBannerLeading(announcement: announcement)),
            trailing: AnyView(FocusBannerTrailing(announcement: announcement))
        ))
    }

    // MARK: Toggling

    private func tileClicked() {
        // A sample is showing: clicking it changes nothing real.
        guard model.preview == nil else { return }
        if model.access == .needsFullDiskAccess {
            FocusSystemSettings.openFullDiskAccess()
        } else {
            toggleFocus()
        }
    }

    private func toggleFocus() {
        let name = UserDefaults.standard.string(forKey: FocusPrefs.shortcut) ?? ""
        if name.isEmpty {
            FocusSystemSettings.openFocus()
        } else {
            toggle.run(name)
        }
    }

    // MARK: Previews

    private func preview(_ sample: FocusState, turningOff previous: FocusMode? = nil) {
        if let mode = sample.mode {
            present(.focus(mode, isOn: true))
        } else if let previous {
            present(.focus(previous, isOn: false))
        }
        model.showPreview(sample)
    }

    /// An hour from now, on the hour or half hour, as Control Center's "For 1 hour"
    /// would read to someone glancing at it.
    private static func sampleEnd() -> Date {
        let end = Date().addingTimeInterval(60 * 60)
        let minutes = Calendar.current.component(.minute, from: end)
        return end.addingTimeInterval(TimeInterval(((minutes + 29) / 30 * 30 - minutes) * 60))
    }
}

/// The feature's preference keys, shared by the feature and its settings. Unset keys
/// read as their defaults, the same ones the settings toggles declare.
enum FocusPrefs {
    static let announce = "focus.announce"
    static let showIndicator = "focus.showIndicator"
    static let quietMinorAlerts = "focus.quietMinorAlerts"
    /// The name of the shortcut that toggles Focus; empty for none.
    static let shortcut = "focus.shortcut"

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

/// Sample Focuses for previews, set up as macOS ships them.
extension FocusMode {
    static let sampleDoNotDisturb = FocusMode(
        identifier: "com.apple.donotdisturb.mode.default", name: "Do Not Disturb", symbol: "moon.fill", tint: .indigo
    )
    static let sampleWork = FocusMode(
        identifier: "com.apple.focus.work", name: "Work", symbol: FocusMode.drawable("person.lanyardcard.fill"), tint: .teal
    )
}
