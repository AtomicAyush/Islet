import AppKit

/// One status item in the menu bar, as Accessibility reports it: where it is, which
/// process answers for it, what it says about itself, and the element that stands for
/// it, to open its menu with.
///
/// Positions come in the top-left global coordinates `CGDisplayBounds` uses.
struct MenuBarItem: @unchecked Sendable {
    var element: AXUIElement
    /// The process that answers for the item: the app that put it there, or, for the
    /// clock, Wi-Fi and the like, the system process that draws them.
    var pid: pid_t
    /// `nil` when the item would not say.
    var frame: CGRect?
    /// A system item's name for itself, `com.apple.menuextra.wifi` say. Apps' items
    /// seldom have one.
    var identifier: String?
    var title: String?
    var description: String?
    var help: String?
    /// Whether the item says it is hidden. None has been seen saying so, but it would
    /// be the plainest answer of all.
    var isHidden = false
    var isEnabled = true
}

/// The questions Islet asks Accessibility about the menu bar's status items, for the
/// island's own layout (`MenuBarRoom`) and for the icons the notch hides
/// (`HiddenMenuBarIconsFeature`).
///
/// Each item belongs to its app's extras menu bar, as VoiceOver finds it. Every
/// question goes across to the app that owns the element and waits for its main thread,
/// so each is given `timeout` to answer rather than the default six seconds: a single
/// hung app would otherwise hold up the whole read. None of this may be asked of Islet's
/// own process off the main thread (see `MenuExtras.ownExtras`).
enum MenuBarAccessibility {
    /// How long one app may take to answer each question, asked one app after another
    /// as the island's layout asks them.
    static let timeout: Float = 0.1
    /// How long, asked side by side (`allItems`). An app's first answer to a process
    /// is the slow one: a busy app, asked for the first time, can take more than a
    /// tenth of a second, and its items would go missing from that read. Side by side,
    /// the wait is only as long as the slowest app's.
    static let readTimeout: Float = 0.5
    /// macOS 27's menu bar process. It draws the whole menu bar, and its own extras
    /// bar holds the system items.
    static let menuBarAgent = "com.apple.MenuBarAgent"
    /// Control Center draws the clock, Wi-Fi and the like, and SystemUIServer the
    /// older extras; on macOS 27 MenuBarAgent draws them all. They are asked whatever
    /// activation policy macOS gives them, which for a system agent is its own business.
    static let systemOwners: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver", menuBarAgent]

    /// The running apps that usually keep items in the menu bar, Islet apart: those
    /// with a place in the Dock or a menu bar of their own, and the system's. Asked one
    /// after another, as the island's layout asks them, every app more costs time.
    static func owners() -> [NSRunningApplication] {
        itemOwners().filter { app in
            app.activationPolicy != .prohibited || systemOwners.contains(app.bundleIdentifier ?? "")
        }
    }

    /// Every running app that may keep an item in the menu bar, Islet apart, whatever
    /// its activation policy: a helper that runs out of sight (Creative Cloud's, say)
    /// keeps one as often as an app in the Dock does. Asked side by side (`allItems`),
    /// the extra ones cost little.
    static func itemOwners() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            // An XPC service (a browser's web content, say) keeps nothing in the
            // menu bar, and there can be dozens of them, most never answering.
            let isService = (app.executableURL ?? app.bundleURL)?.pathComponents.contains { $0.hasSuffix(".xpc") } ?? false
            return !isService && app.processIdentifier != ownPID
        }
    }

    /// The elements in one app's extras menu bar: none if it has none, or does not
    /// answer in time.
    static func extras(of pid: pid_t, timeout: Float = timeout) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = value(kAXExtrasMenuBarAttribute, of: app, timeout: timeout).flatMap(element),
              let children = value(kAXChildrenAttribute, of: bar, timeout: timeout) as? [CFTypeRef]
        else { return [] }
        return children.compactMap(element)
    }

    static func frame(of item: AXUIElement, timeout: Float = timeout) -> CGRect? {
        AXUIElementSetMessagingTimeout(item, timeout)
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(item, attributes, AXCopyMultipleAttributeOptions(), &values) == .success,
              let pair = values as? [CFTypeRef], pair.count == 2
        else { return nil }
        return frame(position: pair[0], size: pair[1])
    }

    static func value(_ attribute: String, of element: AXUIElement, timeout: Float = timeout) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// The actions an element offers (`AXPress`, `AXShowMenu`), asked afresh.
    static func actions(of element: AXUIElement, timeout: Float = readTimeout) -> [String] {
        AXUIElementSetMessagingTimeout(element, timeout)
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    // Casts to Core Foundation types always succeed in Swift, so the type is checked first.

    static func element(_ value: CFTypeRef) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? unsafeDowncast(value, to: AXUIElement.self) : nil
    }

    static func axValue(_ value: CFTypeRef) -> AXValue? {
        CFGetTypeID(value) == AXValueGetTypeID() ? unsafeDowncast(value, to: AXValue.self) : nil
    }

    /// An attribute that failed comes back as an error value, which neither read accepts.
    private static func frame(position: CFTypeRef, size: CFTypeRef) -> CGRect? {
        guard let position = axValue(position), let size = axValue(size) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func string(_ value: CFTypeRef) -> String? {
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        let string = (value as! String).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private static func bool(_ value: CFTypeRef) -> Bool? {
        guard CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}

// MARK: - Every item, in full

extension MenuBarAccessibility {
    /// Every status item every app reports, with all it says about itself, wherever
    /// macOS has put it: in the menu bar, under the notch, or parked off it. Asks the
    /// apps side by side, since each answers only from its main thread: one after
    /// another, a Mac with fifty apps open takes most of a second the first time (each
    /// app's first answer is the slow one), and a few milliseconds after. Blocks until
    /// every app has answered or run out of time (`readTimeout`), so it belongs off the
    /// main thread. Islet's own item is left out.
    static func allItems() -> [MenuBarItem] {
        let pids = itemOwners().map(\.processIdentifier)
        let lock = NSLock()
        var found: [Int: [MenuBarItem]] = [:]
        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            let items = items(of: pids[index])
            guard !items.isEmpty else { return }
            lock.withLock { found[index] = items }
        }
        // In the order the apps were listed, so a read gives the same order each time.
        return found.keys.sorted().flatMap { found[$0] ?? [] }
    }

    /// The frames of an app's own menus (the Apple menu, its name, File and on), to
    /// measure how far along the menu bar they reach: none if it does not answer in
    /// time. Never Islet's own, off the main thread.
    static func menus(of pid: pid_t, timeout: Float = readTimeout) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = value(kAXMenuBarAttribute, of: app, timeout: timeout).flatMap(element),
              let children = value(kAXChildrenAttribute, of: bar, timeout: timeout) as? [CFTypeRef]
        else { return [] }
        return children.compactMap(element).compactMap { frame(of: $0, timeout: timeout) }
    }

    /// One app's status items, in the order its extras bar lists them.
    static func items(of pid: pid_t, timeout: Float = readTimeout) -> [MenuBarItem] {
        extras(of: pid, timeout: timeout).compactMap { child in
            // macOS 27's menu bar process wraps each system item in a group of its own,
            // framing the slot; the item inside is the one that names itself and opens.
            let inner = isGroup(child, timeout: timeout) ? firstMenuBarItem(in: child, timeout: timeout) : nil
            let item = inner ?? child
            return details(of: item, pid: pid, timeout: timeout)
        }
    }

    /// How deep in a group its item may sit.
    private static let groupDepth = 3

    private static func isGroup(_ element: AXUIElement, timeout: Float) -> Bool {
        (value(kAXRoleAttribute, of: element, timeout: timeout) as? String) == kAXGroupRole
    }

    private static func firstMenuBarItem(in group: AXUIElement, timeout: Float) -> AXUIElement? {
        var level = [group]
        for _ in 0..<groupDepth where !level.isEmpty {
            var next: [AXUIElement] = []
            for node in level {
                let children = value(kAXChildrenAttribute, of: node, timeout: timeout) as? [CFTypeRef] ?? []
                for child in children.compactMap(element) {
                    let role = value(kAXRoleAttribute, of: child, timeout: timeout) as? String
                    if role == kAXMenuBarItemRole || role == kAXButtonRole { return child }
                    next.append(child)
                }
            }
            level = next
        }
        return nil
    }

    /// Everything the item says about itself, in one question. What it does not have
    /// comes back as an error value, which reads as nothing.
    private static func details(of item: AXUIElement, pid: pid_t, timeout: Float) -> MenuBarItem? {
        AXUIElementSetMessagingTimeout(item, timeout)
        let attributes = [
            kAXPositionAttribute, kAXSizeAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
            kAXDescriptionAttribute, kAXHelpAttribute, kAXEnabledAttribute, "AXHidden",
        ] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(item, attributes, AXCopyMultipleAttributeOptions(), &values) == .success,
              let answers = values as? [CFTypeRef], answers.count == 8
        else { return nil }
        var owner = pid
        if AXUIElementGetPid(item, &owner) != .success { owner = pid }
        return MenuBarItem(
            element: item,
            pid: owner,
            frame: frame(position: answers[0], size: answers[1]),
            identifier: string(answers[2]),
            title: string(answers[3]),
            description: string(answers[4]),
            help: string(answers[5]),
            isHidden: bool(answers[7]) ?? false,
            isEnabled: bool(answers[6]) ?? true
        )
    }
}

// MARK: - Opening an item

/// What became of a click passed on to a status item.
enum MenuBarPressResult: Equatable {
    /// The item took the action.
    case pressed
    /// The item took it, and its app is still busy with it: a menu it opened is up,
    /// and the app answers nothing else until it closes.
    case busy
    /// The item offers nothing to press or show a menu with.
    case unsupported
    /// The item is gone, or would not take the action.
    case failed
}

extension MenuBarAccessibility {
    /// How long a click on an item may wait for its app. A menu the press opens keeps
    /// the app busy, and the answer only comes once the menu closes; that the time ran
    /// out says nothing more.
    static let pressTimeout: Float = 1

    /// The action a click stands for: a press, as a click on the item is, or, for an
    /// item that offers only that, showing its menu.
    static func pressAction(among actions: [String]) -> String? {
        if actions.contains(kAXPressAction) { return kAXPressAction }
        if actions.contains(kAXShowMenuAction) { return kAXShowMenuAction }
        return nil
    }

    /// Opens the item's menu, as a click on it would. Only ever on a click of the
    /// person's own; blocks for up to `pressTimeout`, so it belongs off the main thread.
    static func press(_ item: AXUIElement) -> MenuBarPressResult {
        guard let action = pressAction(among: actions(of: item, timeout: readTimeout)) else { return .unsupported }
        AXUIElementSetMessagingTimeout(item, pressTimeout)
        switch AXUIElementPerformAction(item, action as CFString) {
        case .success: return .pressed
        case .cannotComplete: return .busy
        default: return .failed
        }
    }
}
