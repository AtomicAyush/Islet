import AppKit

/// Notices when an app is full screen on a display, so the island can get out of the
/// way of a video or a game.
///
/// The reliable signal is the display's current Space: a full-screen app gets a Space
/// of its own, of a different type, which the window server reports without any
/// permission. Window bounds cannot say it alone — under a notch a full-screen window
/// stops below the camera housing, exactly where a zoomed one does. They still catch
/// borderless "full screen" (games, some players) that stays in an ordinary Space:
/// a normal-level window covering a display's whole frame.
@MainActor
final class FullScreenWatcher {
    var onChange: () -> Void = {}
    /// Called each time the watcher has looked again after a change of Space, whether
    /// or not it found anything new (after `onChange`, when it did), for whatever waits
    /// to see where the Space went.
    var onSpaceSettled: () -> Void = {}

    private var observers: [NSObjectProtocol] = []
    private var fullScreenDisplays: Set<CGDirectDisplayID> = []

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            let isSpaceChange = name == NSWorkspace.activeSpaceDidChangeNotification
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // The space switch animation finishes after the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated {
                        self?.refresh()
                        if isSpaceChange { self?.onSpaceSettled() }
                    }
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
        fullScreenSpaces().union(coveredDisplays())
    }

    /// Displays whose current Space belongs to a full-screen app.
    private static func fullScreenSpaces() -> Set<CGDirectDisplayID> {
        guard let displays = ManagedSpaces.current() else { return [] }
        var result: Set<CGDirectDisplayID> = []
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any],
                  (current["type"] as? Int) == ManagedSpaces.fullScreenType
            else { continue }
            // "Main" when displays share Spaces; otherwise the display's UUID.
            let identifier = display["Display Identifier"] as? String
            for screen in NSScreen.screens {
                guard let id = screen.displayID else { continue }
                if identifier == "Main" || identifier == ManagedSpaces.uuid(of: id) {
                    result.insert(id)
                }
            }
        }
        return result
    }

    /// Displays with a normal-level window over their entire frame.
    private static func coveredDisplays() -> Set<CGDirectDisplayID> {
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

/// The window server's list of Spaces per display, through CoreGraphics' private
/// CGSCopyManagedDisplaySpaces. Read-only and needs no permission; looked up at run
/// time, so a release without it just loses this signal.
private enum ManagedSpaces {
    /// The Space type of a full-screen app's Space (ordinary desktops are 0).
    static let fullScreenType = 4

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let functions: (MainConnection, CopySpaces)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let connection = dlsym(handle, "CGSMainConnectionID"),
              let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces")
        else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self), unsafeBitCast(copy, to: CopySpaces.self))
    }()

    static func current() -> [[String: Any]]? {
        guard let (connection, copy) = functions else { return nil }
        return copy(connection())?.takeRetainedValue() as? [[String: Any]]
    }

    static func uuid(of display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
