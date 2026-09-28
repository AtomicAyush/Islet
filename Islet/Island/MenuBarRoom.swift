import AppKit

/// Where the menu bar's status items begin beside the island, and where the front app's
/// menus are, mostly on its other side. On a MacBook they crowd up against the notch,
/// and the bubbles would land on top of them; as many as fit in the gaps go there, and
/// the island folds the next activity in instead.
enum MenuBarRoom {
    /// What a look along one display's menu bar found right of an edge.
    enum Finding: Equatable {
        /// The first status item at or right of the edge begins at this global x.
        case item(at: CGFloat)
        /// No status item at or right of the edge, or no menu bar on the display at all.
        case clear
        /// The display has a menu bar, but nothing could say where its items are.
        case unknown

        /// How far right of `center` the bubbles may reach before they meet a status
        /// item. Not knowing counts as no room at all: folding an activity into the
        /// island is always safe, and a bubble over the icons is not.
        func roomRight(of center: CGFloat) -> CGFloat {
            switch self {
            case .item(let x): x - center
            case .clear: .infinity
            case .unknown: 0
            }
        }
    }

    /// What a look at the front app's menus (the Apple menu, its name, File and on)
    /// found along one display's menu bar (`findMenus`).
    struct Menus: Equatable {
        /// Their frames on the display's menu bar, in top-left global coordinates:
        /// none when nothing could tell, or with no menu bar.
        var frames: [CGRect]
        /// Whether the display has a menu bar at all.
        var hasMenuBar = true

        /// Nothing could tell where they are.
        static let unknown = Menus(frames: [])
        /// The display has no menu bar, so no menus to keep clear of.
        static let noMenuBar = Menus(frames: [], hasMenuBar: false)

        /// How far left of `center` the bubbles may reach before they meet the menus:
        /// to where the last of them ends. Not knowing counts as no room, and menus
        /// that run on past the notch, or a right-to-left menu bar's, end right of
        /// the island and leave none. With no menu bar, all the room there is.
        func roomLeft(of center: CGFloat) -> CGFloat {
            guard hasMenuBar else { return .infinity }
            guard let end = frames.map(\.maxX).max() else { return 0 }
            return center - end
        }

        /// How far right of `center` the bubbles may reach before they meet a menu:
        /// to where the first of those reaching past it begins, as when an app's menus
        /// are too many for the notch's left and go on past it, or a right-to-left
        /// menu bar's; less than nothing for one across `center` itself. With none
        /// there, or no telling, the status items alone decide the room right.
        func roomRight(of center: CGFloat) -> CGFloat {
            frames.filter { $0.maxX > center }.map(\.minX).min().map { $0 - center } ?? .infinity
        }
    }

    /// Where the first status item at or right of `edge` begins on the given display:
    /// from the window list, or, when that cannot tell, from Accessibility if Islet
    /// already has it (for the volume and brightness keys). It never asks for it: a
    /// permission prompt over a layout detail would be out of all proportion. Takes a
    /// few milliseconds, longer when it has to ask the apps, so it is best called off
    /// the main thread.
    ///
    /// `askedAt` is when the measurement was asked for. It usually follows a change
    /// in the menu bar, so an Accessibility read from well before then is not reused.
    static func find(
        rightOf edge: CGFloat, on display: CGDirectDisplayID, askedAt: ContinuousClock.Instant = .now
    ) -> Finding {
        let finding = windowListFinding(rightOf: edge, on: display)
        guard finding == .unknown else { return finding }
        guard hasMenuBar(display) else { return .clear }
        guard AXIsProcessTrusted() else { return finding }
        return accessibilityFinding(rightOf: edge, on: display, askedAt: askedAt)
    }

    /// Whether the display shows a menu bar at all. With "Displays have separate
    /// Spaces" switched off, macOS draws it on the main display only. The others have
    /// no status items for the bubble to cover, and an empty window list there says
    /// so rather than that it cannot tell.
    static func hasMenuBar(_ display: CGDirectDisplayID) -> Bool {
        NSScreen.screensHaveSeparateSpaces || display == CGMainDisplayID()
    }

    // MARK: Window list

    /// Reads the status items from the window list, which any app may do without
    /// permission.
    ///
    /// Up to macOS 26 each status item is a window at the status window level. The
    /// list puts its origin at the top left, but its x runs along the same axis as
    /// AppKit's, and a display's items sit at the top of its bounds. Islet's own item
    /// counts too: the bubble must not cover it either. Takes a few milliseconds (tens,
    /// the first time in a process).
    ///
    /// A menu bar always has some items (Control Center's clock at least), so when
    /// there are none at the top of the display the list cannot tell. Either the
    /// display has no menu bar, which `find` checks next, or this is macOS 27, which
    /// draws the whole menu bar as a single window, so its items are no longer windows
    /// of their own. A window half as wide as the display or more is a menu bar,
    /// however it is drawn, not an item.
    static func windowListFinding(rightOf edge: CGFloat, on display: CGDirectDisplayID) -> Finding {
        let screen = CGDisplayBounds(display)
        let level = Int(CGWindowLevelForKey(.statusWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let items = windows.compactMap { window -> CGRect? in
            guard window[kCGWindowLayer as String] as? Int == level,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  abs(frame.minY - screen.minY) < 1,
                  frame.minX >= screen.minX, frame.minX < screen.maxX,
                  frame.width < screen.width / 2
            else { return nil }
            return frame
        }
        return items.isEmpty ? .unknown : firstItem(among: items, rightOf: edge)
    }

    // MARK: Accessibility

    /// Reads the status items through Accessibility, as VoiceOver finds them: each
    /// app's extras menu bar. For when the window list cannot tell.
    ///
    /// Positions come in the same top-left global coordinates as `CGDisplayBounds`,
    /// and frame the item's button, a point or a few inside its slot. An item that
    /// is switched off can keep a stale frame along the top of the display; counting
    /// it only makes the island fold when it need not. Items found on other displays
    /// say nothing about this one's, so finding none here still cannot tell.
    static func accessibilityFinding(
        rightOf edge: CGFloat, on display: CGDirectDisplayID, askedAt: ContinuousClock.Instant = .now
    ) -> Finding {
        let screen = CGDisplayBounds(display)
        let items = MenuExtras.shared.frames(askedAt: askedAt).filter { isOnMenuBar($0, of: screen) }
        return items.isEmpty ? .unknown : firstItem(among: items, rightOf: edge)
    }

    /// Whether a frame lies along the top of the display, where its menu bar is. Every
    /// menu bar covers at least the top 24 points and centres its items in its height,
    /// so an item there overlaps that strip. One with no place in the menu bar comes
    /// back with no size, in a corner of the screen (before macOS 27), or with its size
    /// but parked at the bottom of the main display (macOS 27).
    private static func isOnMenuBar(_ frame: CGRect, of screen: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0
            && frame.minX >= screen.minX && frame.minX < screen.maxX
            && frame.maxY > screen.minY && frame.minY < screen.minY + 24
    }

    private static func firstItem(among frames: [CGRect], rightOf edge: CGFloat) -> Finding {
        guard let x = frames.map(\.minX).filter({ $0 >= edge }).min() else { return .clear }
        return .item(at: x)
    }

    /// What an island knows of the front app's menus on its display: which app's the
    /// room beside it was last set from, and what was last found of each app's, by
    /// process, so an app coming to the front has its menus kept clear of at once,
    /// while they are looked at again.
    struct MenusMemory {
        /// The app whose menus the room beside the island was last set from.
        private(set) var owner: pid_t?
        private var byOwner: [pid_t: Menus] = [:]
        /// Counts looks at the menus, so one that finishes late, or that looked at an
        /// app no longer in front, is not taken.
        private var generation = 0

        /// The menu bar shows `owner`'s menus now. When that is another app than
        /// before, returns what to keep clear of meanwhile: its menus as last found,
        /// or, for an app not looked at yet, no telling, so no bubble goes left of the
        /// island until they have been. `nil` for the same app as before.
        mutating func follow(_ owner: pid_t?) -> Menus? {
            guard owner != self.owner else { return nil }
            self.owner = owner
            generation &+= 1
            return owner.flatMap { byOwner[$0] } ?? .unknown
        }

        /// A look at the menus of the app in front is starting; returns its number,
        /// for `take`.
        mutating func begin() -> Int {
            generation &+= 1
            return generation
        }

        /// Look number `look` at `owner`'s menus found `found`: returns it, to keep clear
        /// of, unless another look has begun since or another app is in front by now.
        mutating func take(_ found: Menus, of owner: pid_t?, look: Int) -> Menus? {
            guard look == generation, owner == self.owner else { return nil }
            if let owner { byOwner[owner] = found }
            return found
        }

        /// Forgets every app's menus, and any look under way.
        mutating func forget() {
            owner = nil
            byOwner = [:]
            generation &+= 1
        }
    }

    // MARK: Menus

    /// Where the front app's menus are on the given display, for the bubbles either side
    /// of the island: `owner` is the app whose menus the menu bar shows
    /// (`menuBarOwner()`), Islet's own included. Read through Accessibility, only if
    /// Islet already has it, as for the status items. A display with no menu bar has no
    /// menus to keep clear of. Otherwise nothing found is no telling: no Accessibility,
    /// no owner, or no menus on this display's menu bar, as when they are on another
    /// display's. Asks one app, which takes a few milliseconds, or up to half a second
    /// if it is busy, so it is best called off the main thread.
    static func findMenus(
        on display: CGDirectDisplayID, owner: pid_t?,
        trusted: @autoclosure () -> Bool = AXIsProcessTrusted(),
        menus: (pid_t) -> [CGRect] = { MenuBarRoom.menus(of: $0) }
    ) -> Menus {
        guard hasMenuBar(display) else { return .noMenuBar }
        guard let owner, trusted() else { return .unknown }
        return menusOnMenuBar(of: CGDisplayBounds(display), among: menus(owner))
    }

    /// Those of the menus with these frames that are on the menu bar of a display with
    /// these bounds, all in top-left global coordinates.
    static func menusOnMenuBar(of screen: CGRect, among frames: [CGRect]) -> Menus {
        Menus(frames: frames.filter { isOnMenuBar($0, of: screen) })
    }

    /// An app's menus (`MenuBarAccessibility.menus(of:)`). Islet's own are asked about
    /// on the main thread, as its status item is, for the same reason (see
    /// `MenuExtras.ownExtras`); that takes next to no time.
    static func menus(of pid: pid_t) -> [CGRect] {
        guard pid == ProcessInfo.processInfo.processIdentifier, !Thread.isMainThread else {
            return MenuBarAccessibility.menus(of: pid)
        }
        return DispatchQueue.main.sync { MenuBarAccessibility.menus(of: pid) }
    }

    /// The app whose menus the menu bar shows, for `findMenus`: `nil` for nobody.
    @MainActor
    static func menuBarOwner() -> pid_t? {
        NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
    }
}

/// Every app's status items as Accessibility reports them. Each read asks every app,
/// so measurements asked for together share one: every display measures at the same
/// moment, and switching Space posts two notifications that each measure half a
/// second later. Displays measured together take turns, so the second uses the first
/// one's read. A measurement asked for any later reads again: it usually comes after
/// something changed (an app or Space switch, a display rearranged) that an older
/// read would miss.
private final class MenuExtras: @unchecked Sendable {
    static let shared = MenuExtras()

    /// macOS 27's menu bar process (`MenuBarAccessibility.menuBarAgent`). Its own
    /// extras bar holds the system items, and its window holds every item the menu bar
    /// shows, other apps' included, so one app answers what otherwise takes asking
    /// every running app (about a second).
    private static let menuBarAgent = MenuBarAccessibility.menuBarAgent
    /// How deep into the agent's window its item buttons sit, with room to spare.
    private static let agentDepth = 6
    /// How long before a measurement was asked for a read may have begun and still
    /// answer it. Long enough to cover two notifications posted a moment apart, and
    /// well short of the half second IslandManager waits after a switch before it
    /// measures, so a shared read never predates the switch.
    private static let sharing = Duration.milliseconds(250)

    private let lock = NSLock()
    private var cached: [CGRect] = []
    private var readAt: ContinuousClock.Instant?

    /// The frames of every status item found, on every display, in top-left global
    /// coordinates, from a read that began no earlier than just before `asked`.
    func frames(askedAt asked: ContinuousClock.Instant) -> [CGRect] {
        let others = lock.withLock {
            if let readAt, readAt >= asked - Self.sharing { return cached }
            let now = ContinuousClock.now
            cached = Self.otherAppsExtras()
            readAt = now
            return cached
        }
        return others + Self.ownExtras()
    }

    private static func otherAppsExtras() -> [CGRect] {
        if let agent = NSRunningApplication.runningApplications(withBundleIdentifier: menuBarAgent).first {
            let frames = agentItems(agent.processIdentifier)
            if !frames.isEmpty { return frames }
        }
        return MenuBarAccessibility.owners().flatMap { extras(of: $0.processIdentifier) }
    }

    /// Islet's own item, which the bubble must not cover either. Accessibility does
    /// not send a question about its own process across to that process's main
    /// thread, as it does for any other app: AppKit answers it at once on the asking
    /// thread, reading the status bar button's geometry, which only the main thread
    /// may touch. So it is asked from there, fresh each time since that is cheap, and
    /// outside the lock, so a read under way never waits for the main thread while
    /// the main thread waits for the lock.
    private static func ownExtras() -> [CGRect] {
        let pid = ProcessInfo.processInfo.processIdentifier
        if Thread.isMainThread { return extras(of: pid) }
        return DispatchQueue.main.sync { extras(of: pid) }
    }

    /// Every item macOS 27's menu bar shows: the system ones from the agent's extras
    /// bar, and the buttons in its window, which stand for other apps' items. Items
    /// with no place in the menu bar are parked off it, and `isOnMenuBar` drops them.
    private static func agentItems(_ pid: pid_t) -> [CGRect] {
        var frames = extras(of: pid)
        let app = AXUIElementCreateApplication(pid)
        let windows = (value(kAXWindowsAttribute, of: app) as? [CFTypeRef] ?? []).compactMap(element)
        var level = windows
        for _ in 0..<agentDepth where !level.isEmpty {
            var next: [AXUIElement] = []
            for item in level {
                if (value(kAXRoleAttribute, of: item) as? String) == kAXButtonRole, let frame = frame(of: item) {
                    frames.append(frame)
                } else {
                    next += (value(kAXChildrenAttribute, of: item) as? [CFTypeRef] ?? []).compactMap(element)
                }
            }
            level = next
        }
        return frames + wideFrames(in: app)
    }

    /// The items in `wideItems` that the agent shows, each widened by its bleed. The
    /// extras bar's own children are holders with no identifier; the item inside each
    /// has one, a level or two further down. Only the leftmost frame matters, so a
    /// widened copy beside the plain one is enough.
    private static func wideFrames(in app: AXUIElement) -> [CGRect] {
        var found: [CGRect] = []
        var level = [app]
        for _ in 0..<4 where !level.isEmpty {
            var next: [AXUIElement] = []
            for element in level {
                if let identifier = value("AXIdentifier", of: element) as? String,
                   let bleed = wideItems[identifier], let frame = frame(of: element) {
                    found.append(frame.insetBy(dx: -bleed, dy: 0))
                } else {
                    next += (value(kAXChildrenAttribute, of: element) as? [CFTypeRef] ?? []).compactMap(self.element)
                }
            }
            level = next
        }
        return found
    }

    /// Status items macOS draws wider than Accessibility says they are, by their
    /// identifier, and how far past the frame to keep clear. The camera and microphone
    /// item ("Audio and Video Controls") turns into a coloured capsule while either is
    /// in use, reaching about four points left of its frame; nine keeps a bubble the
    /// same seven points from the capsule as bubbles keep from each other.
    static let wideItems: [String: CGFloat] = ["com.apple.menuextra.audiovideo": 9]

    /// The frames of one app's status items: none if it has none, or does not answer in time.
    private static func extras(of pid: pid_t) -> [CGRect] {
        MenuBarAccessibility.extras(of: pid).compactMap { item in
            guard let frame = frame(of: item) else { return nil }
            guard let identifier = value("AXIdentifier", of: item) as? String,
                  let bleed = wideItems[identifier] else { return frame }
            return frame.insetBy(dx: -bleed, dy: 0)
        }
    }

    private static func frame(of item: AXUIElement) -> CGRect? {
        MenuBarAccessibility.frame(of: item)
    }

    private static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        MenuBarAccessibility.value(attribute, of: element)
    }

    private static func element(_ value: CFTypeRef) -> AXUIElement? {
        MenuBarAccessibility.element(value)
    }
}
