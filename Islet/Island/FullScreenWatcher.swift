import AppKit

/// Notices when an app is full screen on a display, so the island can get out of the
/// way of a video or a game.
///
/// A full-screen app has a window at the normal level covering the display's entire
/// frame, menu bar included. Window bounds and layers are readable without Screen
/// Recording permission (only titles are withheld), so this needs no prompt.
@MainActor
final class FullScreenWatcher {
    var onChange: () -> Void = {}

    private var observers: [NSObjectProtocol] = []
    private var fullScreenDisplays: Set<CGDirectDisplayID> = []

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // The space switch animation finishes after the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated { self?.refresh() }
                }
            })
        }
        refresh()
    }

    func isFullScreen(on screen: NSScreen) -> Bool {
        guard let id = screen.displayID else { return false }
        return fullScreenDisplays.contains(id)
    }

    private func refresh() {
        let found = Self.scan()
        guard found != fullScreenDisplays else { return }
        fullScreenDisplays = found
        onChange()
    }

    private static func scan() -> Set<CGDirectDisplayID> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var result: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let bounds = CGDisplayBounds(id)
            let covered = info.contains { window in
                guard (window[kCGWindowLayer as String] as? Int) == 0,
                      (window[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                      let dict = window[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: dict) else { return false }
                return rect.equalTo(bounds)
            }
            if covered { result.insert(id) }
        }
        return result
    }
}
