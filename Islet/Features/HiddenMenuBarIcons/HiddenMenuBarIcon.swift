import AppKit

/// A menu bar icon as the island lists it: what to call it, what to draw, and where
/// macOS has put it. Worked out from a `MenuBarItem`, which stays with the model for
/// the click that opens it.
struct HiddenMenuBarIcon: Identifiable, Equatable {
    /// Where the icon is, as far as anyone can see it.
    enum Placement: Int, Comparable {
        /// Out of the menu bar for want of room: parked off it, with no size, or saying
        /// it is hidden, while the menu bar has no room left for it.
        case noRoom
        /// Drawn behind the camera housing.
        case underNotch
        /// In the menu bar, in sight.
        case shown
        /// Out of the menu bar while it has room to spare: switched off in System
        /// Settings › Menu Bar, or put away by its own app. Someone chose that, so the
        /// island never lists it.
        case switchedOff

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    enum Glyph: Equatable {
        /// The icon of the app that owns the item: an icon of its own is not to be had
        /// without recording the screen, and the app's is what people know it by.
        case app(pid_t)
        /// A system item (Wi-Fi, the clock), as the SF Symbol closest to its own.
        case symbol(String)
        /// A made-up app's icon, for previews: a symbol on a rounded square.
        case sample(symbol: String, hue: Double)
    }

    /// Stable across looks while the menu bar stays the same: a system item's
    /// identifier, or the owning app and the item's place among its items.
    var id: String
    /// Short: the app's name, or the system item's ("Wi-Fi").
    var name: String
    /// What the item says about itself, where that adds to its name, for the tooltip.
    var detail: String?
    var glyph: Glyph
    var placement: Placement
    /// Along the menu bar, for putting the icons in its order; `nil` for an icon with
    /// no place in it.
    var x: CGFloat?
    /// Whether the item says it can be clicked.
    var isEnabled = true

    /// Out of sight for want of room: what the island is for.
    var isHidden: Bool { placement == .noRoom || placement == .underNotch }
}

/// Where the menu bars and notches are, in the top-left global coordinates
/// Accessibility reports frames in, and whose menus the menu bar shows. Read on the
/// main thread, and handed to the look that runs off it.
struct MenuBarGeometry: Equatable, Sendable {
    /// Where an item's frame puts it, before anything is known of the room left.
    enum Place: Equatable {
        /// In no menu bar: parked off it, or with no size.
        case off
        /// Half or more of it behind a camera housing.
        case underNotch
        /// In a menu bar, in sight.
        case inBar
    }

    /// Each display that shows a menu bar (`MenuBarRoom.hasMenuBar`), whole.
    var displays: [CGRect]
    /// The camera housing on each display that has one.
    var notches: [CGRect]
    /// The app whose menus the menu bar shows, to measure how far along it they reach.
    /// `nil` for nobody, or for Islet, whose own elements may not be asked about off
    /// the main thread (see `MenuExtras.ownExtras`).
    var menuBarOwner: pid_t?

    @MainActor
    static func current() -> MenuBarGeometry {
        var geometry = MenuBarGeometry(displays: [], notches: [])
        let owner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
        geometry.menuBarOwner = owner == ProcessInfo.processInfo.processIdentifier ? nil : owner
        let screens = NSScreen.screens
        // AppKit's global coordinates rise from the foot of the first screen; the
        // top-left ones fall from its top.
        guard let top = screens.first?.frame.maxY else { return geometry }
        for screen in screens {
            guard let id = screen.displayID, MenuBarRoom.hasMenuBar(id) else { continue }
            geometry.displays.append(CGDisplayBounds(id))
            if screen.hasNotch {
                let notch = NotchMetrics.measure(screen).notchRect
                geometry.notches.append(
                    CGRect(x: notch.minX, y: top - notch.maxY, width: notch.width, height: notch.height)
                )
            }
        }
        return geometry
    }

    /// Where an item with this frame is: `nil` when there is no telling (no frame, or
    /// no display known to have a menu bar).
    ///
    /// An item counts as under the notch once half of it or more is behind the
    /// camera housing: less than that still shows enough of itself to be known and
    /// clicked.
    func place(of frame: CGRect?) -> Place? {
        guard let frame, !displays.isEmpty else { return nil }
        guard frame.width > 0, frame.height > 0, menuBar(holding: frame) != nil else { return .off }
        for notch in notches {
            let overlap = frame.intersection(notch)
            if !overlap.isNull, overlap.width >= frame.width / 2 { return .underNotch }
        }
        return .inBar
    }

    /// Which display's menu bar a frame lies in, as an index into `displays`.
    ///
    /// Every menu bar covers at least the top 24 points of its display, and centres its
    /// items in its height, so an item in one begins within that strip (a point or two
    /// above it at most). One parked across the foot of the display above, reaching
    /// into this one's strip, begins well above it, and does not count. While the menu
    /// bar is tucked away (a full-screen app, or "Automatically hide and show the menu
    /// bar"), it slides up out of sight, and so, presumably, do its items: within the
    /// height of a menu bar above the top of the display, and outside every display,
    /// they count as in it.
    func menuBar(holding frame: CGRect) -> Int? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.firstIndex { display in
            guard frame.minX >= display.minX, frame.minX < display.maxX else { return false }
            if frame.minY >= display.minY - 2, frame.minY < display.minY + 24 { return true }
            let tuckedAway = center.y < display.minY && center.y > display.minY - Self.tuckedAwayReach
            return tuckedAway && !displays.contains { $0.contains(center) }
        }
    }

    /// How much of the menu bar is free for an item out of it to come back to: from the
    /// notch's right edge (or the end of the front app's menus, where they reach past
    /// it or there is no notch) to the first status item in sight. Measured on the
    /// display whose menu bar holds the most of `items`, the frames of those in one.
    /// Less than nothing when some are under the notch.
    ///
    /// `nil` when there is no telling: no item in a menu bar, or the front app's
    /// menus unknown or on another display. The room is then taken to be none.
    func room(items: [CGRect], menus: [CGRect]) -> CGFloat? {
        var counts = Array(repeating: 0, count: displays.count)
        for item in items {
            if let index = menuBar(holding: item) { counts[index] += 1 }
        }
        guard let most = counts.max(), most > 0, let index = counts.firstIndex(of: most) else { return nil }
        let display = displays[index]
        guard let firstItem = items.filter({ menuBar(holding: $0) == index }).map(\.minX).min(),
              let menusEnd = menus.filter({ $0.width > 0 && menuBar(holding: $0) == index }).map(\.maxX).max()
        else { return nil }
        let notchEnd = notches.filter { display.contains(CGPoint(x: $0.midX, y: $0.midY)) }.map(\.maxX).max()
        return firstItem - max(menusEnd, notchEnd ?? display.minX)
    }

    /// How far above its display a tucked-away menu bar's items can be: the tallest
    /// menu bar, a notched MacBook's, and a little over.
    static let tuckedAwayReach: CGFloat = 40
}

/// The app that owns an item, as far as the island needs to know it.
struct MenuBarItemOwner: Equatable, Sendable {
    var bundleIdentifier: String?
    var name: String?

    /// The processes that draw the system's own items. Their icons say nothing about
    /// the item (Control Center's, or none), so the item's own name picks a symbol.
    static let systemBundleIdentifiers: Set<String> = MenuBarAccessibility.systemOwners
        .union(["com.apple.TextInputMenuAgent"])

    var isSystem: Bool { bundleIdentifier.map(Self.systemBundleIdentifiers.contains) ?? false }

    static func of(_ pid: pid_t) -> MenuBarItemOwner? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return MenuBarItemOwner(bundleIdentifier: app.bundleIdentifier, name: app.localizedName)
    }
}

/// What one look along the menu bar found: the icons, and the element behind each,
/// for the click that opens it.
struct MenuBarLook: @unchecked Sendable {
    var icons: [HiddenMenuBarIcon] = []
    var elements: [String: AXUIElement] = [:]
    /// The room the menu bar had left (`MenuBarGeometry.room`), for the live probe.
    var room: CGFloat?
    /// The icons known to be switched off, for the next look to go on from.
    var switchedOff: Set<String> = []
}

enum HiddenMenuBarIcons {
    /// What an item out of the menu bar needs to come back: its width, and the gap
    /// macOS leaves between items with as much again to spare. Too wide only keeps an
    /// icon listed that was switched off; too narrow would take one pushed out for
    /// switched off, and remember it so.
    static let roomSlack: CGFloat = 16

    /// The icons for a look's items, in the menu bar's own order, left to right: those
    /// with no room first (they are the ones pushed off its left end, by name since
    /// their places say nothing), then those under the notch, then those in sight.
    /// Items with no telling where they are are left out.
    ///
    /// An item out of the menu bar may have been pushed out, or switched off (in
    /// System Settings › Menu Bar, or by its app), and it says nothing to tell which.
    /// The room left does: macOS brings items back as soon as they fit, so while every
    /// item out of the menu bar would fit in the room, none of them is out for want of
    /// it. Such items are switched off, and remembered so (`switchedOff`, which the
    /// look returns updated) until they are seen in the menu bar again: once the menu
    /// bar fills up, the room says nothing more about them. The rest, with the menu bar
    /// full or no telling, have no room. An item with no size cannot be measured, and
    /// counts as having none, as before macOS 27 items with no place in the menu bar
    /// came back that way.
    static func look(
        at items: [MenuBarItem], menus: [CGRect] = [], geometry: MenuBarGeometry,
        switchedOff known: Set<String> = [], owner: (pid_t) -> MenuBarItemOwner?
    ) -> MenuBarLook {
        struct Found {
            var item: MenuBarItem
            var id: String
            var place: MenuBarGeometry.Place
            var owner: MenuBarItemOwner?
        }
        var seen: [String: Int] = [:]
        var found: [Found] = []
        for item in items {
            guard var place = geometry.place(of: item.frame) else { continue }
            if item.isHidden { place = .off }
            let owner = owner(item.pid)
            // An identifier names one item: seen again (from another process that
            // lists it too), it is the same one. Two items from one app without one
            // are told apart by their order.
            let base = item.identifier ?? "\(owner?.bundleIdentifier ?? String(item.pid))"
            let count = seen[base, default: 0]
            if count > 0, item.identifier != nil { continue }
            seen[base] = count + 1
            found.append(Found(item: item, id: count == 0 ? base : "\(base).\(count)", place: place, owner: owner))
        }

        let room = geometry.room(items: found.filter { $0.place != .off }.compactMap(\.item.frame), menus: menus)
        let outWidths = found.filter { $0.place == .off }.compactMap { $0.item.frame?.width }.filter { $0 > 0 }
        let hasRoom = room.map { room in outWidths.allSatisfy { $0 + roomSlack <= room } } ?? false

        var switchedOff = known
        var elements: [String: AXUIElement] = [:]
        let icons = found.map { found -> HiddenMenuBarIcon in
            let item = found.item
            let placement: HiddenMenuBarIcon.Placement
            switch found.place {
            case .underNotch, .inBar:
                placement = found.place == .inBar ? .shown : .underNotch
                switchedOff.remove(found.id)
            case .off:
                let width = item.frame?.width ?? 0
                if known.contains(found.id) {
                    placement = .switchedOff
                } else if hasRoom, width > 0 {
                    placement = .switchedOff
                    switchedOff.insert(found.id)
                } else {
                    placement = .noRoom
                }
            }
            elements[found.id] = item.element
            let x = found.place == .off ? nil : item.frame?.minX
            let isSystem = (found.owner?.isSystem ?? false)
                || item.identifier?.hasPrefix(SystemMenuExtras.identifierPrefix) == true
            if isSystem {
                let extra = SystemMenuExtras.match(item)
                return HiddenMenuBarIcon(
                    id: found.id,
                    name: extra?.name ?? SystemMenuExtras.fallbackName(item),
                    detail: nil,
                    glyph: .symbol(extra?.symbol ?? SystemMenuExtras.fallbackSymbol),
                    placement: placement, x: x, isEnabled: item.isEnabled
                )
            }
            let name = found.owner?.name ?? found.owner?.bundleIdentifier ?? "App"
            let said = item.description ?? item.title ?? item.help
            return HiddenMenuBarIcon(
                id: found.id,
                name: name,
                detail: said.flatMap { $0.caseInsensitiveCompare(name) == .orderedSame ? nil : $0 },
                glyph: .app(item.pid),
                placement: placement, x: x, isEnabled: item.isEnabled
            )
        }
        return MenuBarLook(icons: ordered(icons), elements: elements, room: room, switchedOff: switchedOff)
    }

    static func ordered(_ icons: [HiddenMenuBarIcon]) -> [HiddenMenuBarIcon] {
        icons.enumerated().sorted { a, b in
            let (i, p) = (a.element, b.element)
            if i.placement != p.placement { return i.placement < p.placement }
            if let x = i.x, let y = p.x, x != y { return x < y }
            if i.x == nil, p.x == nil {
                let byName = i.name.localizedStandardCompare(p.name)
                if byName != .orderedSame { return byName == .orderedAscending }
            }
            return a.offset < b.offset
        }
        .map(\.element)
    }
}

/// The system's own menu bar items, and the SF Symbol and name the island gives each.
/// Matched on the item's identifier (`com.apple.menuextra.wifi`) where it has one, and
/// otherwise on what it says about itself, lower-cased with spaces and punctuation
/// taken out, so "Wi‑Fi" and "wifi" meet. More particular entries come first:
/// Keyboard Brightness before anything about the keyboard or the display.
enum SystemMenuExtras {
    struct Extra: Equatable {
        var keywords: [String]
        var symbol: String
        var name: String
    }

    static let identifierPrefix = "com.apple.menuextra."
    static let fallbackSymbol = "menubar.rectangle"

    static let all: [Extra] = [
        Extra(keywords: ["keyboardbrightness"], symbol: "light.max", name: "Keyboard Brightness"),
        Extra(keywords: ["wifi"], symbol: "wifi", name: "Wi-Fi"),
        Extra(keywords: ["bluetooth"], symbol: "dot.radiowaves.left.and.right", name: "Bluetooth"),
        Extra(keywords: ["airdrop"], symbol: "dot.radiowaves.up.forward", name: "AirDrop"),
        Extra(keywords: ["battery"], symbol: "battery.75percent", name: "Battery"),
        Extra(keywords: ["sound", "volume"], symbol: "speaker.wave.2.fill", name: "Sound"),
        Extra(keywords: ["focus", "donotdisturb"], symbol: "moon.fill", name: "Focus"),
        Extra(keywords: ["nowplaying"], symbol: "play.fill", name: "Now Playing"),
        Extra(keywords: ["screenmirroring", "airplay"], symbol: "rectangle.on.rectangle", name: "Screen Mirroring"),
        Extra(keywords: ["controlcenter", "controlcentre", "bentobox"], symbol: "switch.2", name: "Control Center"),
        Extra(keywords: ["clock"], symbol: "clock", name: "Clock"),
        Extra(keywords: ["stagemanager"], symbol: "squares.leading.rectangle", name: "Stage Manager"),
        Extra(keywords: ["display", "brightness"], symbol: "sun.max.fill", name: "Display"),
        Extra(keywords: ["accessibility"], symbol: "accessibility", name: "Accessibility"),
        Extra(keywords: ["hearing"], symbol: "ear", name: "Hearing"),
        Extra(keywords: ["menuextrauser", "fastuserswitching"], symbol: "person.crop.circle", name: "User"),
        Extra(keywords: ["textinput", "inputsource", "inputmenu", "keyboard"], symbol: "keyboard", name: "Input Sources"),
        Extra(keywords: ["siri"], symbol: "siri", name: "Siri"),
        Extra(keywords: ["spotlight"], symbol: "magnifyingglass", name: "Spotlight"),
        Extra(keywords: ["timemachine"], symbol: "clock.arrow.circlepath", name: "Time Machine"),
        Extra(keywords: ["vpn"], symbol: "network.badge.shield.half.filled", name: "VPN"),
        Extra(keywords: ["gamemode"], symbol: "gamecontroller.fill", name: "Game Mode"),
        Extra(keywords: ["screensharing"], symbol: "rectangle.inset.filled.and.person.filled", name: "Screen Sharing"),
        Extra(keywords: ["hotspot"], symbol: "personalhotspot", name: "Personal Hotspot"),
        Extra(keywords: ["shortcuts"], symbol: "square.2.layers.3d.fill", name: "Shortcuts"),
        Extra(keywords: ["script"], symbol: "applescript", name: "Scripts"),
        Extra(keywords: ["weather"], symbol: "cloud.sun.fill", name: "Weather"),
        Extra(keywords: ["passwords"], symbol: "key.fill", name: "Passwords"),
    ]

    /// The entry for a system item: by its identifier first, since that is what it
    /// is, and then by what it says, which can name the state it is in as well.
    static func match(_ item: MenuBarItem) -> Extra? {
        if let identifier = item.identifier, let extra = match(text: identifier) { return extra }
        for text in [item.description, item.title, item.help].compactMap({ $0 }) {
            if let extra = match(text: text) { return extra }
        }
        return nil
    }

    static func match(text: String) -> Extra? {
        let folded = fold(text)
        guard !folded.isEmpty else { return nil }
        return all.first { $0.keywords.contains(where: folded.contains) }
    }

    /// A system item nothing above knows: what it says about itself, up to its first
    /// comma (the rest is usually its state), or failing that a plain description.
    static func fallbackName(_ item: MenuBarItem) -> String {
        let said = item.description ?? item.title ?? item.help
        let name = said?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? "Menu Bar Item"
    }

    /// A symbol the island can draw: this one, or, where this macOS does not have it
    /// (the table was checked on macOS 27, and Islet runs from 14), the generic one,
    /// rather than an empty plate. Looked up where the views draw it.
    @MainActor
    static func drawable(_ symbol: String) -> String {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? fallbackSymbol : symbol
    }

    private static func fold(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined()
    }
}
