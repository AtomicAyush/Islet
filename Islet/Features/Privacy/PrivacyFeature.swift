import SwiftUI

/// The iPhone's camera and microphone indicators: a green dot beside the notch while
/// any camera is running, an orange one while only a microphone is. The home page
/// says what is in use, and, if asked, the island names the app for a moment when it
/// starts.
@MainActor
final class PrivacyFeature: Feature {
    let id = "privacy"
    let title = "Camera & Microphone"
    let symbol = "video.fill"
    let summary = "A green or orange dot beside the notch while the camera or microphone is in use."

    private static let bannerID = "privacy.start"

    private let monitor = PrivacyMonitor()
    private var defaultsObserver: NSObjectProtocol?

    init() {
        monitor.onChange = { [weak self] started in self?.changed(started) }
    }

    func start() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        applySettings()
    }

    func stop() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = nil
        monitor.stop()
        render()
        ActivityCenter.shared.dismissBanner(id: Self.bannerID)
    }

    func settingsView() -> AnyView? {
        AnyView(PrivacySettingsView())
    }

    /// Each stands in for the real readings for eight seconds, then clears.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Camera in use") { [monitor] in
                monitor.showPreview(PrivacyUsage(camera: true))
            },
            FeaturePreview(title: "Microphone in use") { [monitor] in
                monitor.showPreview(PrivacyUsage(microphone: true, apps: [.voiceMemos]))
            },
            FeaturePreview(title: "An app starts using the camera") { [weak self] in
                self?.announce(PrivacyMonitor.Start(sensor: .camera, app: .faceTime), cameraInUse: true)
                self?.monitor.showPreview(PrivacyUsage(camera: true, microphone: true, apps: [.faceTime]))
            },
        ]
    }

    private func applySettings() {
        monitor.watch(
            camera: PrivacyPrefs.bool(PrivacyPrefs.camera, default: true),
            microphone: PrivacyPrefs.bool(PrivacyPrefs.microphone, default: true)
        )
    }

    private func changed(_ started: PrivacyMonitor.Start?) {
        render()
        if let started, PrivacyPrefs.bool(PrivacyPrefs.sayWhichApp, default: false) {
            announce(started, cameraInUse: monitor.usage.camera)
        }
    }

    /// One dot, like the iPhone: green wins over orange.
    private func render() {
        let center = ActivityCenter.shared
        if let tint = monitor.usage.tint {
            center.setIndicator(StatusIndicator(id: id, color: tint))
            center.setHomeWidget(
                HomeWidget(id: id, order: 70, weight: 1, view: AnyView(PrivacyHomeTile(monitor: monitor)))
            )
        } else {
            center.removeIndicator(id: id)
            center.removeHomeWidget(id: id)
        }
    }

    /// Names what just started, in the colour its dot is about to be.
    private func announce(_ start: PrivacyMonitor.Start, cameraInUse: Bool) {
        let tint = cameraInUse ? privacyGreen : privacyOrange
        let widths = PrivacyBannerLayout.widths(for: start)
        ActivityCenter.shared.present(IslandBanner(
            id: Self.bannerID,
            style: .compact(leading: widths.leading, trailing: widths.trailing),
            duration: 2.5,
            leading: AnyView(PrivacyBannerLeading(start: start, tint: tint)),
            trailing: AnyView(PrivacyBannerTrailing(start: start, tint: tint))
        ))
    }
}

/// This feature's options. Unset keys read as their defaults, the same ones the
/// settings toggles declare.
enum PrivacyPrefs {
    static let camera = "privacy.camera"
    static let microphone = "privacy.microphone"
    static let sayWhichApp = "privacy.sayWhichApp"

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

/// Sample apps for previews. Both ship with macOS, so their icons are always there.
private extension PrivacyApp {
    static let faceTime = PrivacyApp(bundlePath: "/System/Applications/FaceTime.app")
    static let voiceMemos = PrivacyApp(bundlePath: "/System/Applications/VoiceMemos.app")
}
