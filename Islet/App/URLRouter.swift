import AppKit

/// `islet://` URLs, for Shortcuts, scripts and the terminal:
///
///     islet://open                 open the island (on the screen under the pointer)
///     islet://open?focus=timer     open it on a particular activity, or "home"
///     islet://close
///     islet://settings?tab=activities
///     islet://preview?feature=battery&index=0
///     islet://<feature>/…          handed to that feature, e.g. islet://timer/start?minutes=5
@MainActor
enum URLRouter {
    /// URLs that arrived before launch finished (the one that launched Islet, say),
    /// held until there is an island to act on. `nil` once launch has finished.
    private static var pending: [URL]? = []

    static func install() {
        NSAppleEventManager.shared().setEventHandler(
            Handler.shared,
            andSelector: #selector(Handler.handle(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// Routes the held URLs; called once the islands and features are up.
    static func launchFinished() {
        let held = pending ?? []
        pending = nil
        held.forEach(route)
    }

    static func receive(_ url: URL) {
        if pending != nil {
            pending?.append(url)
        } else {
            route(url)
        }
    }

    static func route(_ url: URL) {
        guard url.scheme == "islet", let host = url.host() else { return }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        let island = IslandManager.shared.focusedController?.model

        switch host {
        case "open":
            #if DEBUG
            island?.isPinnedOpen = query["pin"] == "1"
            #endif
            island?.expand(focus: query["focus"])
        case "close":
            #if DEBUG
            island?.isPinnedOpen = false
            #endif
            island?.collapse()
        case "settings":
            if let tab = query["tab"] {
                UserDefaults.standard.set(tab, forKey: SettingsView.tabKey)
            }
            SettingsWindowController.shared.show()
        case "preview":
            guard let name = query["feature"], let feature = feature(named: name) else { return }
            let index = Int(query["index"] ?? "0") ?? 0
            if feature.previews.indices.contains(index) { feature.previews[index].run() }
        #if DEBUG
        case "debug":
            if url.path() == "/second" { DebugActivity.shared.toggle() }
        #endif
        default:
            _ = feature(named: host)?.handle(url)
        }
    }

    /// URL hosts are case-insensitive, and some launchers lower-case them.
    private static func feature(named name: String) -> (any Feature)? {
        FeatureRegistry.shared.features.first { $0.id.caseInsensitiveCompare(name) == .orderedSame }
    }

    private final class Handler: NSObject {
        static let shared = Handler()

        @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
                  let url = URL(string: string) else { return }
            MainActor.assumeIsolated { URLRouter.receive(url) }
        }
    }
}
