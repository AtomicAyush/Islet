import AppKit
import ApplicationServices

/// The apps whose slideshows count.
enum SlideshowApp: String, CaseIterable, Hashable, Sendable {
    case keynote
    case powerPoint

    var name: String {
        switch self {
        case .keynote: "Keynote"
        case .powerPoint: "PowerPoint"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .keynote: ["com.apple.iWork.Keynote", "com.apple.Keynote"]
        case .powerPoint: ["com.microsoft.Powerpoint"]
        }
    }

    init?(bundleIdentifier: String?) {
        guard let bundleIdentifier,
              let app = Self.allCases.first(where: { $0.bundleIdentifiers.contains(bundleIdentifier) })
        else { return nil }
        self = app
    }

    /// Whether a window's title is a slideshow's. PowerPoint calls its windows
    /// "PowerPoint Slide Show - <deck>" and "PowerPoint Presenter View - <deck>", in
    /// English; while a deck is edited its window takes the deck's name, which may well
    /// have "Slide Show" in it, so only the start counts. Keynote's gives nothing away,
    /// and is found by the others.
    func isSlideshowTitle(_ title: String) -> Bool {
        switch self {
        case .keynote: false
        case .powerPoint: ["PowerPoint Slide Show", "PowerPoint Presenter View"].contains { title.hasPrefix($0) }
        }
    }
}

/// What the watcher looks at, read afresh each time: which app is in front, and how it
/// has the screen. Only read in full while Keynote or PowerPoint is in front; nothing
/// of it is kept.
struct SlideshowSnapshot: Equatable, Sendable {
    /// The bundle identifier of the app in front.
    var frontmost: String?
    /// The presentation options in effect, which the app in front sets
    /// (`NSApplication.PresentationOptions`). A slideshow hides the menu bar and the
    /// Dock outright; a deck merely full screen only hides them until the pointer goes
    /// there.
    var options: UInt = 0
    /// Whether one of its windows covers a whole display from above the normal window
    /// level, as a slideshow's does, over the menu bar and the Dock.
    var coversDisplay = false
    /// Its focused window's title, where Accessibility lets that be read.
    var windowTitle: String?
}

/// Whether Keynote or PowerPoint is playing a slideshow, from a snapshot. None of this is
/// an interface either app offers: each sign is read loosely, and any one of them is
/// enough.
///
/// Asking the apps themselves (Keynote's scripting `playing`) would need permission to
/// send them Apple events, which macOS asks the person for, and would launch an app that
/// had just quit. What the window server and Accessibility say needs neither.
enum SlideshowDetector {
    static func playing(_ snapshot: SlideshowSnapshot) -> SlideshowApp? {
        guard let app = SlideshowApp(bundleIdentifier: snapshot.frontmost) else { return nil }
        let options = NSApplication.PresentationOptions(rawValue: snapshot.options)
        // The menu bar hidden outright, not merely hidden until the pointer reaches for
        // it as a full-screen window has it; or the Dock, outside full screen.
        if options.contains(.hideMenuBar) { return app }
        if options.contains(.hideDock), !options.contains(.fullScreen) { return app }
        if snapshot.coversDisplay { return app }
        if let title = snapshot.windowTitle, app.isSlideshowTitle(title) { return app }
        return nil
    }
}

extension SlideshowSnapshot {
    /// Reads the screen now. For any app but Keynote and PowerPoint, only which app is
    /// in front. The cheapest sign is read first, and the rest only while nothing read
    /// so far says a slideshow is playing: the presentation options, then the window
    /// list, then, for PowerPoint, its window's title, which asks the app itself.
    @MainActor
    static func current() -> SlideshowSnapshot {
        let front = NSWorkspace.shared.frontmostApplication
        var snapshot = SlideshowSnapshot(frontmost: front?.bundleIdentifier)
        guard let front, let app = SlideshowApp(bundleIdentifier: snapshot.frontmost) else { return snapshot }
        snapshot.options = NSApp.currentSystemPresentationOptions.rawValue
        if SlideshowDetector.playing(snapshot) != nil { return snapshot }
        snapshot.coversDisplay = raisedWindowCoversDisplay(pid: front.processIdentifier)
        if SlideshowDetector.playing(snapshot) != nil { return snapshot }
        if app == .powerPoint, AXIsProcessTrusted() {
            snapshot.windowTitle = focusedWindowTitle(pid: front.processIdentifier)
        }
        return snapshot
    }

    /// Whether a window of the process sits above the normal window level over the whole
    /// of a display. Window bounds and levels need no permission; titles are not read.
    private static func raisedWindowCoversDisplay(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let displays = NSScreen.screens.compactMap(\.displayID).map(CGDisplayBounds)
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let layer = window[kCGWindowLayer as String] as? Int, layer > 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { return false }
            return displays.contains { $0.equalTo(rect) }
        }
    }

    /// The focused window's title, asked with the menu bar's short timeout so an app that
    /// is busy never holds Islet up.
    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let value = MenuBarAccessibility.value(kAXFocusedWindowAttribute, of: app),
              let window = MenuBarAccessibility.element(value),
              let title = MenuBarAccessibility.value(kAXTitleAttribute, of: window),
              CFGetTypeID(title) == CFStringGetTypeID()
        else { return nil }
        let string = title as! String
        return string
    }
}

/// Notices Keynote or PowerPoint playing a slideshow. It looks whenever another app
/// comes to the front or the Space changes, and, while Keynote or PowerPoint is in
/// front, every second and a half as well, since a slideshow starts and ends with no
/// app changing. With any other app in front it only waits, and it stops looking while
/// the screen is locked or asleep, or another user has the Mac, keeping what it last
/// said until it can look again.
@MainActor
final class SlideshowWatcher {
    typealias Report = @MainActor (SlideshowApp?) -> Void

    static let pollInterval: TimeInterval = 1.5
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    private let read: @MainActor () -> SlideshowSnapshot
    private let notifications: NotificationCenter
    private let lockNotifications: NotificationCenter
    private var report: Report?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var last: SlideshowApp?
    private var hasReported = false
    /// Why it isn't looking: the screen locked, asleep, or the session given up.
    private var pauses: Set<String> = []

    /// Whether it is looking again and again, with Keynote or PowerPoint in front.
    var isPolling: Bool { timer != nil }
    /// Whether it has stopped looking for now, the screen locked or asleep.
    var isPaused: Bool { !pauses.isEmpty }

    /// `read`, `notifications` and `lockNotifications` stand in for the screen, the
    /// workspace and the screen lock's distributed notifications in tests.
    init(
        read: @escaping @MainActor () -> SlideshowSnapshot = { SlideshowSnapshot.current() },
        notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        lockNotifications: NotificationCenter = DistributedNotificationCenter.default()
    ) {
        self.read = read
        self.notifications = notifications
        self.lockNotifications = lockNotifications
    }

    /// Starts watching. `report` gets the first reading, then every change.
    func start(report: @escaping Report) {
        guard self.report == nil else { return }
        self.report = report
        hasReported = false
        pauses = []
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observe(name, on: notifications) { $0.refresh() }
        }
        let pausing: [(Notification.Name, NotificationCenter, String, Bool)] = [
            (Self.screenLocked, lockNotifications, "locked", true),
            (Self.screenUnlocked, lockNotifications, "locked", false),
            (NSWorkspace.screensDidSleepNotification, notifications, "asleep", true),
            (NSWorkspace.screensDidWakeNotification, notifications, "asleep", false),
            (NSWorkspace.sessionDidResignActiveNotification, notifications, "away", true),
            (NSWorkspace.sessionDidBecomeActiveNotification, notifications, "away", false),
        ]
        for (name, center, reason, isPausing) in pausing {
            observe(name, on: center) { $0.pause(reason, isPausing) }
        }
        refresh()
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        timer?.invalidate()
        timer = nil
        report = nil
        last = nil
        pauses = []
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter, _ action: @escaping @MainActor (SlideshowWatcher) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }))
    }

    private func pause(_ reason: String, _ isPausing: Bool) {
        if isPausing {
            pauses.insert(reason)
            timer?.invalidate()
            timer = nil
        } else if pauses.remove(reason) != nil, pauses.isEmpty {
            refresh()
        }
    }

    func refresh() {
        guard let report, pauses.isEmpty else { return }
        let snapshot = read()
        if SlideshowApp(bundleIdentifier: snapshot.frontmost) != nil {
            if timer == nil {
                let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                timer.tolerance = 0.5
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
        let playing = SlideshowDetector.playing(snapshot)
        guard !hasReported || playing != last else { return }
        hasReported = true
        last = playing
        report(playing)
    }
}
