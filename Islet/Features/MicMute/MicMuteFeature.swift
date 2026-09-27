import SwiftUI

/// A mute for the Mac's microphone that every app obeys, for calls: a button on the
/// home page, another on the microphone's line of the privacy card while an app is
/// using it, `islet://micMute/…` and the Mute Microphone action in Shortcuts, which
/// can be given a key there. While it is muted, a red crossed-out microphone stays
/// beside the notch, on the resting island too, and clicked, offers Unmute.
///
/// It mutes the Mac's input from Sound settings, the microphone apps record from
/// unless they pick one of their own, and follows it to another microphone, muting
/// that one and putting the last back. How, and what happens when the microphone is
/// unmuted elsewhere or cannot be muted at all, is `MicMuteEngine`'s to say. Stopping
/// the feature, or quitting Islet, unmutes; what an Islet that crashed while muted left
/// behind is put back as it next starts.
@MainActor
final class MicMuteFeature: Feature {
    let id = "micMute"
    let title = "Mic Mute"
    let symbol = "mic.slash.fill"
    let summary = "A button that mutes the microphone for every app, with a red mark beside the notch while it is muted."

    /// Where the tile goes on the home page, until the person puts it somewhere else.
    static let tileOrder = 46
    var homeTile: HomeTileInfo? { HomeTileInfo(self, order: Self.tileOrder) }

    /// Muting, unmuting and the rest share one id, so a quick change of mind updates
    /// the banner already up rather than stacking another.
    static let bannerID = "micMute"
    /// Long enough to read two words. A warning, which nobody asked for, stays longer.
    private static let bannerDuration: TimeInterval = 1.6
    private static let warningDuration: TimeInterval = 3.5

    let model: MicMuteModel
    private var isRunning = false
    private var isTileShown = false
    private var defaultsObserver: NSObjectProtocol?

    /// `model` stands in for the microphone in tests.
    init(model: MicMuteModel? = nil) {
        let model = model ?? MicMuteModel()
        self.model = model
        model.onChange = { [weak self] event, source in self?.changed(event, from: source) }
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
        model.stop()
        model.endPreview()
        render()
        ActivityCenter.shared.dismissBanner(id: Self.bannerID)
    }

    func settingsView() -> AnyView? {
        AnyView(MicMuteSettingsView(model: model))
    }

    /// A sample microphone, not the Mac's: each announces itself, and "muted" stands in
    /// for the real state beside the notch and on the home page for eight seconds.
    /// Nothing is muted or unmuted.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Microphone muted") { [weak self] in
                self?.announce(.muted)
                self?.model.showPreview(MicMuteSnapshot(isMuted: true, microphone: .sampleBuiltIn))
            },
            FeaturePreview(title: "Microphone unmuted") { [weak self] in
                self?.model.endPreview()
                self?.announce(.unmuted)
            },
            FeaturePreview(title: "A microphone that can't be muted") { [weak self] in
                self?.model.endPreview()
                self?.announce(.cannotMute(MicMuteSnapshot.Microphone.sampleUSB.name))
            },
        ]
    }

    /// `islet://micMute/toggle`, `/mute` and `/unmute`, which announce what they did.
    func handle(_ url: URL) -> Bool {
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard let action = MicMuteAction(rawValue: path) else { return false }
        model.perform(action, from: .elsewhere)
        return true
    }

    /// What `MuteMicrophoneIntent` runs, announced as a URL's is: `nil` while the
    /// feature is off.
    func perform(_ action: MicMuteAction) async -> MicMuteEvent? {
        await model.perform(action, from: .elsewhere)
    }

    // MARK: State

    private func changed(_ event: MicMuteEvent?, from source: MicMuteSource?) {
        render()
        guard isRunning, let event else { return }
        // A click in the island has its answer in front of it; anything else is said,
        // and so is a microphone that could not be muted, wherever it was asked.
        if source != .island {
            announce(event)
        } else if case .cannotMute = event {
            announce(event)
        }
    }

    /// The red mark beside the notch while muted, and the home tile.
    private func render() {
        let center = ActivityCenter.shared
        let isPreviewing = model.preview != nil

        if (isRunning || isPreviewing), model.shown.isMuted {
            // Beside the camera and microphone dot, which an app keeps lit while it has
            // the microphone open, hearing silence. It keeps the island up where there
            // is no notch, as that dot does: a muted microphone must be seen to be.
            center.setIndicator(StatusIndicator(
                id: id, color: MicMutePalette.muted, order: 1, symbol: "mic.slash.fill", keepsIslandShown: true,
                label: "Microphone muted",
                detail: IndicatorDetail(id: id, title: "Microphone", maxWidth: MicMuteIndicatorCard.maxWidth) { [model] in
                    AnyView(MicMuteIndicatorCard(model: model))
                }
            ))
        } else {
            center.removeIndicator(id: id)
        }

        let wantsTile = isPreviewing || (isRunning && MicMutePrefs.bool(MicMutePrefs.showTile, default: true))
        guard wantsTile != isTileShown else { return }
        isTileShown = wantsTile
        if wantsTile {
            center.setHomeWidget(HomeWidget(id: id, order: Self.tileOrder, view: AnyView(MicMuteHomeTile(model: model))))
        } else {
            center.removeHomeWidget(id: id)
        }
    }

    private func announce(_ event: MicMuteEvent) {
        let announcement = MicMuteAnnouncement(event)
        let widths = MicMuteBannerLayout.widths(for: announcement)
        ActivityCenter.shared.present(IslandBanner(
            id: Self.bannerID,
            style: .compact(leading: widths.leading, trailing: widths.trailing),
            duration: announcement.isWarning ? Self.warningDuration : Self.bannerDuration,
            // Asked for from a key, a tap on the trackpad would be felt as something
            // else; one the person did not ask for is worth feeling.
            haptic: announcement.isWarning,
            leading: AnyView(MicMuteBannerLeading(announcement: announcement)),
            trailing: AnyView(MicMuteBannerTrailing(announcement: announcement))
        ))
    }
}

/// The feature's preference keys, shared by the feature and its settings. Unset keys
/// read as their defaults, the same ones the settings toggles declare.
enum MicMutePrefs {
    static let showTile = "micMute.showTile"

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

/// Sample microphones for previews, named as macOS names the kinds.
extension MicMuteSnapshot.Microphone {
    static let sampleBuiltIn = MicMuteSnapshot.Microphone(name: "MacBook Pro Microphone", way: .mute)
    static let sampleUSB = MicMuteSnapshot.Microphone(name: "USB Audio Device", way: nil)
}
