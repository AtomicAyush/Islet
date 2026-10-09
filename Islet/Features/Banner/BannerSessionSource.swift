import AppKit

/// A feature whose hooks' banners name its sessions (`CustomBanner.sessionID`): Claude
/// Code, ChatGPT and Gemini. Anything on the Mac can open the URL a banner comes by, so the
/// name is all a banner gives: the feature looks it up in its own records, and only a
/// session found there is opened, in the app and at the chat those records say.
@MainActor
protocol BannerSessionSource: AnyObject {
    /// Brings forward the app the session runs in, at its chat where the app can be
    /// asked for one, as a click on its row does. Returns whether it did: `false`, having
    /// done nothing, for a name the feature has no session by (one never heard of, one
    /// that has ended, another activity's), or an app that is not running.
    func openSession(_ id: String) -> Bool
    /// Whether Settings asks for no banner when a reply finishes in a chat in front of
    /// the person, and the session's chat is in front of them now. `false` whenever that
    /// cannot be told: a banner left up is better than one missed.
    func skipsDone(for id: String) -> Bool
}

/// What the screen shows of an app, at the moment a reply finishes: whether it is in
/// front, since when, and whether the person can see it.
struct ChatScreenLook: Equatable, Sendable {
    /// The frontmost app's bundle id, or "".
    var frontmost = ""
    /// Since when it has been in front; `nil` when it already was as Islet started
    /// watching, and that cannot be told.
    var frontSince: Date?
    /// The display awake and the screen unlocked.
    var isAwake = true
    /// The frontmost app has a window on screen: not every one minimised or hidden.
    var hasWindow = true

    /// Whether the person can be looking at `bundleID`'s window now.
    func shows(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && frontmost == bundleID && isAwake && hasWindow
    }
}

/// Follows which app is in front, and since when, for `ChatScreenLook`. Started by the
/// features that ask it, and left running: one observer of the workspace.
@MainActor
final class AppInFront {
    static let shared = AppInFront()

    private var frontmost = ""
    private var since: Date?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        since = nil
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier ?? ""
            MainActor.assumeIsolated {
                guard let self, id != self.frontmost else { return }
                self.frontmost = id
                self.since = Date()
            }
        }
    }

    /// The screen as it is now, for whether `bundleID` can be in sight. The windows on
    /// screen are listed only while that app is in front; read only as a reply finishes.
    func look(for bundleID: String) -> ChatScreenLook {
        let app = NSWorkspace.shared.frontmostApplication
        let id = app?.bundleIdentifier ?? ""
        return ChatScreenLook(
            frontmost: id,
            frontSince: id == frontmost && observer != nil ? since : nil,
            isAwake: CGDisplayIsAsleep(CGMainDisplayID()) == 0 && !ApprovalConditionWatch.screenIsLocked(),
            hasWindow: id == bundleID && app.map { Self.hasWindowOnScreen($0.processIdentifier) } == true
        )
    }

    /// Whether the process has an ordinary window on screen of a size to read in. The
    /// window server tells any app where others' windows are, if not what they show.
    static func hasWindowOnScreen(_ pid: pid_t) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return false }
            return rect.width >= 200 && rect.height >= 150
        }
    }
}
