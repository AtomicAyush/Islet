import SwiftUI

/// The iPhone's privacy indicators, and which app is behind each: a green dot beside
/// the notch while any camera is running, an orange one while only a microphone is,
/// a purple one while an app captures the screen or records what the Mac plays, and,
/// if asked for, an arrow while an app gets the Mac's location. The home page says
/// what is in use and by which apps, and, if asked, the island names the app for a
/// moment when it starts using the camera, a microphone or the screen.
///
/// Islet's own Sound Mixer records what the Mac plays too, which macOS marks with its
/// purple dot; Islet never marks it.
@MainActor
final class PrivacyFeature: Feature {
    let id = "privacy"
    let title = "Camera, Microphone & More"
    let symbol = "video.fill"
    let summary = "Dots beside the notch while the camera, microphone or screen is in use, and which app is using it."

    private static let bannerID = "privacy.start"
    /// The green or orange dot, the purple one and the location arrow.
    private static let dotID = "privacy"
    private static let captureID = "privacy.capture"
    private static let locationID = "privacy.location"

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
        AnyView(PrivacySettingsView(monitor: monitor))
    }

    /// Each stands in for the real readings for eight seconds, then clears. The apps
    /// are ones that ship with macOS, so their icons are always there.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Camera in use") { [monitor] in
                monitor.showPreview(PrivacyUsage(camera: .inUse()))
            },
            FeaturePreview(title: "Microphone in use") { [monitor] in
                monitor.showPreview(PrivacyUsage(microphone: .inUse(.voiceMemos)))
            },
            FeaturePreview(title: "An app starts using the camera") { [weak self] in
                self?.announce(PrivacyMonitor.Start(sensor: .camera, app: .faceTime), cameraInUse: true)
                self?.monitor.showPreview(PrivacyUsage(camera: .inUse(.faceTime), microphone: .inUse(.faceTime)))
            },
            FeaturePreview(title: "An app starts recording the screen") { [weak self] in
                self?.announce(PrivacyMonitor.Start(sensor: .screen, app: .quickTimePlayer), cameraInUse: false)
                self?.monitor.showPreview(PrivacyUsage(screen: .inUse(.quickTimePlayer)))
            },
            FeaturePreview(title: "Location in use") { [monitor] in
                monitor.showPreview(PrivacyUsage(location: .inUse(.maps)))
            },
            FeaturePreview(title: "Everything at once") { [monitor] in
                monitor.showPreview(PrivacyUsage(
                    camera: .inUse(.faceTime), microphone: .inUse(.faceTime),
                    screen: .inUse(.quickTimePlayer), location: .inUse(.maps), soundMixer: true
                ))
            },
        ]
    }

    private func applySettings() {
        monitor.watch(
            camera: PrivacyPrefs.bool(PrivacyPrefs.camera, default: true),
            microphone: PrivacyPrefs.bool(PrivacyPrefs.microphone, default: true),
            screen: PrivacyPrefs.bool(PrivacyPrefs.screen, default: true),
            location: PrivacyPrefs.bool(PrivacyPrefs.location, default: false)
        )
    }

    private func changed(_ started: PrivacyMonitor.Start?) {
        render()
        if let started, PrivacyPrefs.bool(PrivacyPrefs.sayWhichApp, default: false) {
            announce(started, cameraInUse: monitor.usage.camera.inUse)
        }
    }

    /// One dot for the camera and microphone, like the iPhone's (green wins over
    /// orange); a purple one beside it for the screen and the Mac's sound, as macOS
    /// has; and the location arrow after both, at the island's end, where it comes and
    /// goes without moving them: a single look-up lights it for a dozen seconds. For
    /// the same reason the arrow alone never brings up the island where it is hidden.
    private func render() {
        let center = ActivityCenter.shared
        let usage = monitor.usage

        if let tint = usage.dotTint {
            center.setIndicator(StatusIndicator(id: Self.dotID, color: tint, order: 1))
        } else {
            center.removeIndicator(id: Self.dotID)
        }
        if usage.capturesScreenOrSound {
            center.setIndicator(StatusIndicator(id: Self.captureID, color: privacyPurple, order: 2))
        } else {
            center.removeIndicator(id: Self.captureID)
        }
        if usage.location.inUse {
            center.setIndicator(StatusIndicator(
                id: Self.locationID, color: privacyBlue, order: 3, symbol: PrivacyMonitor.Sensor.location.symbol,
                keepsIslandShown: false
            ))
        } else {
            center.removeIndicator(id: Self.locationID)
        }

        let sensors = usage.sensorsInUse
        if sensors.isEmpty {
            center.removeHomeWidget(id: id)
        } else {
            center.setHomeWidget(HomeWidget(
                id: id, order: 70, weight: PrivacyHomeTile.weight(for: usage),
                view: AnyView(PrivacyHomeTile(monitor: monitor))
            ))
        }
    }

    /// Names what just started, in the colour its dot is about to be.
    private func announce(_ start: PrivacyMonitor.Start, cameraInUse: Bool) {
        let tint = start.sensor == .camera || start.sensor == .microphone
            ? (cameraInUse ? privacyGreen : privacyOrange)
            : start.sensor.tint
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
    /// The screen and the Mac's sound, which share macOS's purple dot.
    static let screen = "privacy.screen"
    /// Off until asked for: a single look-up keeps the arrow lit for a dozen seconds,
    /// and some apps look up often.
    static let location = "privacy.location"
    static let sayWhichApp = "privacy.sayWhichApp"

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

/// Sample apps for previews. All ship with macOS, so their icons are always there.
extension PrivacyApp {
    static let faceTime = PrivacyApp(bundlePath: "/System/Applications/FaceTime.app")
    static let voiceMemos = PrivacyApp(bundlePath: "/System/Applications/VoiceMemos.app")
    static let quickTimePlayer = PrivacyApp(bundlePath: "/System/Applications/QuickTime Player.app")
    static let maps = PrivacyApp(bundlePath: "/System/Applications/Maps.app")
}
