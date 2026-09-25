import AppKit

/// Where the menu bar's status items begin beside the island. On a MacBook they crowd
/// up against the notch, and the bubble would land on top of them; when it would not
/// fit in the gap, the island folds the second activity in instead.
enum MenuBarRoom {
    /// What a look along one display's menu bar found right of an edge.
    enum Finding: Equatable {
        /// The first status item at or right of the edge begins at this global x.
        case item(at: CGFloat)
        /// No status item at or right of the edge, or no menu bar on the display at all.
        case clear
        /// The display has a menu bar, but nothing could say where its items are.
        case unknown

        /// How far right of `center` the bubble may reach before it meets a status
        /// item. Not knowing counts as no room at all: folding the second activity
        /// into the island is always safe, and a bubble over the icons is not.
        func roomRight(of center: CGFloat) -> CGFloat {
            switch self {
            case .item(let x): x - center
            case .clear: .infinity
            case .unknown: 0
            }
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
    /// back with no size, in a corner of the screen.
    private static func isOnMenuBar(_ frame: CGRect, of screen: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0
            && frame.minX >= screen.minX && frame.minX < screen.maxX
            && frame.maxY > screen.minY && frame.minY < screen.minY + 24
    }

    private static func firstItem(among frames: [CGRect], rightOf edge: CGFloat) -> Finding {
        guard let x = frames.map(\.minX).filter({ $0 >= edge }).min() else { return .clear }
        return .item(at: x)
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

    /// Control Center draws the clock, Wi-Fi and the like, and SystemUIServer the
    /// older extras. They are asked whatever activation policy macOS gives them, which
    /// for a system agent is its own business.
    private static let systemOwners: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver"]
    /// How long one app may take to answer each question. The default is six seconds,
    /// and a single hung app would hold up the whole read.
    private static let timeout: Float = 0.1
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
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { app in
                // An XPC service (a browser's web content, say) keeps nothing in the
                // menu bar, and there can be dozens of them, most never answering.
                let isService = (app.executableURL ?? app.bundleURL)?.pathComponents.contains { $0.hasSuffix(".xpc") } ?? false
                return !isService && app.processIdentifier != ownPID
                    && (app.activationPolicy != .prohibited || systemOwners.contains(app.bundleIdentifier ?? ""))
            }
            .flatMap { extras(of: $0.processIdentifier) }
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

    /// The frames of one app's status items: none if it has none, or does not answer in time.
    private static func extras(of pid: pid_t) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = value(kAXExtrasMenuBarAttribute, of: app).flatMap(element),
              let children = value(kAXChildrenAttribute, of: bar) as? [CFTypeRef]
        else { return [] }
        return children.compactMap(element).compactMap(frame(of:))
    }

    private static func frame(of item: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(item, timeout)
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(item, attributes, AXCopyMultipleAttributeOptions(), &values) == .success,
              let pair = values as? [CFTypeRef], pair.count == 2,
              let position = axValue(pair[0]), let size = axValue(pair[1])
        else { return nil }
        // An attribute that failed comes back as an error value, which neither read accepts.
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    // Casts to Core Foundation types always succeed in Swift, so the type is checked first.

    private static func element(_ value: CFTypeRef) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? unsafeDowncast(value, to: AXUIElement.self) : nil
    }

    private static func axValue(_ value: CFTypeRef) -> AXValue? {
        CFGetTypeID(value) == AXValueGetTypeID() ? unsafeDowncast(value, to: AXValue.self) : nil
    }
}
