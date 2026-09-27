import Foundation

/// What can turn Presentation Mode on by itself. Each has a setting, on at first.
enum PresentationTrigger: String, CaseIterable, Hashable, Sendable {
    /// Another app capturing the screen: sharing it in a call, recording it, mirroring it.
    case screen
    /// A call: the camera in use, or the microphone in a call app.
    case call
    /// Keynote or PowerPoint playing a slideshow.
    case slideshow
}

/// An app named as capturing the screen, and its bundle identifier where it has one,
/// so the card can offer never to turn on for it again.
struct PresentationApp: Hashable, Sendable {
    var name: String
    var bundleIdentifier: String?
}

/// Why Presentation Mode is on, in the words its card uses.
enum PresentationReason: Hashable, Sendable {
    /// Another app captures the screen: the apps, where they can be named.
    case screen(apps: [PresentationApp])
    /// A call app has the camera or the microphone.
    case call(app: String)
    /// The camera is in use by an app that is not a call app, or by one no one can name.
    case camera(app: String?)
    /// A slideshow is playing.
    case slideshow(SlideshowApp)
    /// Turned on from Islet: `islet://presentation/on`, or the Shortcuts action.
    case manual

    /// The trigger behind it; none for one turned on by hand.
    var trigger: PresentationTrigger? {
        switch self {
        case .screen: .screen
        case .call, .camera: .call
        case .slideshow: .slideshow
        case .manual: nil
        }
    }

    var text: String {
        switch self {
        case .screen(let apps) where apps.isEmpty: "Screen being shared"
        case .screen(let apps): "Screen shared by \(apps.map(\.name).formatted(.list(type: .and)))"
        case .call(let app): "On a call in \(app)"
        case .camera(let app?): "Camera in use by \(app)"
        case .camera(nil): "Camera in use"
        case .slideshow(let app): "Slideshow playing in \(app.name)"
        case .manual: "Turned on until you turn it off"
        }
    }
}

/// Reads a shared screen and a call from what the privacy monitor says is in use
/// (`PrivacyMonitor.readings`), leaving Islet itself out, and, for the screen, the apps
/// Settings say never to turn on for (`PresentationPrefs.ignoredScreenAppIDs`): those
/// that capture it all the time, as DisplayLink's driver does to drive a monitor on a
/// dock.
///
/// Islet records what the Mac plays, for the Sound Mixer and the waveform, which macOS
/// marks with the same purple dot as a screen being recorded. That is the Mac's sound,
/// though, never the screen: only WindowServer's flag, and the apps the log names for
/// it, count as the screen being captured, so Islet's own recording never turns this
/// on. Should Islet ever be named as capturing the screen, or using the camera or a
/// microphone, it is left out too; a use no one can name still counts, since it could
/// be anyone's.
enum PresentationSignals {
    /// Apps whose use of the microphone is a call, by bundle identifier. An app's
    /// helpers, whose identifiers sit under the app's, count as it.
    static let callApps: [String] = [
        "com.apple.FaceTime",
        "us.zoom.xos",
        "com.microsoft.teams2", "com.microsoft.teams",
        "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
        // A huddle.
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.skype.skype",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "org.whispersystems.signal-desktop",
        "ru.keepcoder.Telegram",
    ]

    /// Browsers. A call in Meet, or in Teams or Zoom on the web, records from the
    /// browser, and a browser cannot be asked which site has the microphone without
    /// reading its tabs, so any browser recording counts as a call.
    static let browsers: [String] = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.chromium.Chromium",
    ]

    /// Processes with no app of their own that record a call for one: FaceTime's calls
    /// run in `avconferenced`.
    static let callProcesses: Set<String> = ["avconferenced"]

    /// The screen captured by an app other than Islet or one ignored, and by whom where
    /// they can be named. `nil` while it is not.
    static func screen(
        in usage: PrivacyUsage, bundleID: (PrivacyApp) -> String? = \.bundleIdentifier,
        ignoring ignored: [String] = PresentationPrefs.ignoredScreenAppIDs
    ) -> PresentationReason? {
        guard usage.screen.inUse else { return nil }
        let others = usage.screen.apps.filter { app in
            !isOwn(app, bundleID: bundleID) && !PresentationPrefs.matches(bundleID(app), ignored)
        }
        if !usage.screen.apps.isEmpty, others.isEmpty { return nil }
        return .screen(apps: others.map { PresentationApp(name: $0.name, bundleIdentifier: bundleID($0)) })
    }

    /// A call: a call app on the camera or a microphone, the camera's first; failing
    /// that, the camera in use at all, by an app other than Islet. A microphone alone,
    /// in an app that is not a call app (a voice memo, dictation) or one no one can
    /// name, is no call. `nil` while there is none.
    static func call(
        in usage: PrivacyUsage, bundleID: (PrivacyApp) -> String? = \.bundleIdentifier
    ) -> PresentationReason? {
        let camera = usage.camera.inUse ? usage.camera.apps.filter { !isOwn($0, bundleID: bundleID) } : []
        let microphone = usage.microphone.inUse ? usage.microphone.apps.filter { !isOwn($0, bundleID: bundleID) } : []
        if let app = (camera + microphone).first(where: { isCallApp($0, bundleID: bundleID) }) {
            return .call(app: app.name)
        }
        guard usage.camera.inUse, usage.camera.apps.isEmpty || !camera.isEmpty else { return nil }
        return .camera(app: camera.first?.name)
    }

    static func isCallApp(_ app: PrivacyApp, bundleID: (PrivacyApp) -> String?) -> Bool {
        if let id = bundleID(app) {
            return (callApps + browsers).contains { id == $0 || id.hasPrefix($0 + ".") }
        }
        return app.bundlePath == nil && callProcesses.contains(app.name)
    }

    /// Whether an app is one people share or record the screen with on purpose: a call
    /// app, a browser, or one of Apple's (QuickTime Player, Screen Sharing, the
    /// Screenshot app's recording).
    static func isSharingApp(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier.hasPrefix("com.apple.")
            || PresentationPrefs.matches(bundleIdentifier, callApps + browsers)
    }

    static func isOwn(_ app: PrivacyApp, bundleID: (PrivacyApp) -> String?) -> Bool {
        guard let id = bundleID(app) else { return false }
        let own = PrivacyPrefs.ownBundleIdentifier
        return id == own || id.hasPrefix(own + ".")
    }
}
