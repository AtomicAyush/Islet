import AppKit

/// `islet://` URLs, for Shortcuts, scripts and the terminal:
///
///     islet://open                 open the island (on the screen under the pointer)
///     islet://open?focus=timer     open it on a particular activity, or "home"
///     islet://close
///     islet://preview?feature=battery&index=0
///     islet://<feature>/…          handed to that feature, e.g. islet://timer/start?minutes=5
@MainActor
enum URLRouter {
    static func install() {
        NSAppleEventManager.shared().setEventHandler(
            Handler.shared,
            andSelector: #selector(Handler.handle(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
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
            island?.expand(focus: query["focus"])
        case "close":
            island?.collapse()
        case "preview":
            guard let feature = FeatureRegistry.shared.features.first(where: { $0.id == query["feature"] })
            else { return }
            let index = Int(query["index"] ?? "0") ?? 0
            if feature.previews.indices.contains(index) { feature.previews[index].run() }
        #if DEBUG
        case "debug":
            if url.path() == "/second" { DebugActivity.shared.toggle() }
        #endif
        default:
            FeatureRegistry.shared.features.first { $0.id == host }.map { _ = $0.handle(url) }
        }
    }

    private final class Handler: NSObject {
        static let shared = Handler()

        @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
                  let url = URL(string: string) else { return }
            MainActor.assumeIsolated { URLRouter.route(url) }
        }
    }
}
