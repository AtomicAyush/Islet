import AppKit
import Observation

/// Which menu bar icons are out of sight, and the way to open each one's menu.
///
/// It looks as an island opens (and as the feature starts, or Islet comes to the
/// front), through Accessibility, off the main thread, and not again for a couple of
/// seconds; nothing is watched in between. Which icons fit changes with the app in
/// front (on a notched MacBook, a long menu takes room from them), and opening the
/// island switches no app, so a look then sees the menu bar as it is. Without
/// Accessibility nothing can be read: the model says so, and never asks.
@MainActor
@Observable
final class HiddenMenuBarIconsModel {
    enum Access: Equatable {
        /// Not looked yet.
        case unknown
        case granted
        /// Islet is not in the Accessibility list.
        case missing
    }

    /// Where the look gets its answers. Tests pass their own.
    struct Source {
        var isTrusted: () -> Bool
        /// Where the menu bars and notches are; on the main thread.
        var geometry: @MainActor () -> MenuBarGeometry
        /// Every status item. Called off the main thread, and may take a while.
        var read: @Sendable () -> [MenuBarItem]
        /// The frames of an app's own menus. Called off the main thread.
        var menus: @Sendable (pid_t) -> [CGRect]
        var owner: @Sendable (pid_t) -> MenuBarItemOwner?
        /// Opens an item's menu. Called off the main thread.
        var press: @Sendable (AXUIElement) -> MenuBarPressResult

        static let system = Source(
            isTrusted: { AXIsProcessTrusted() },
            geometry: { MenuBarGeometry.current() },
            read: { MenuBarAccessibility.allItems() },
            menus: { MenuBarAccessibility.menus(of: $0) },
            owner: { MenuBarItemOwner.of($0) },
            press: { MenuBarAccessibility.press($0) }
        )
    }

    /// How long a look answers for. An island opened again straight after it closed
    /// (the pointer slipping off and back) shows what was found a moment ago.
    static let freshness: TimeInterval = 2

    /// Every icon the last look found, in sight or not, in the menu bar's order.
    private(set) var icons: [HiddenMenuBarIcon] = []
    private(set) var access = Access.unknown
    /// Whether a look has come back since the model started.
    private(set) var hasLooked = false
    /// Made-up icons standing in for the real ones while a preview is up.
    private(set) var sample: [HiddenMenuBarIcon]?
    /// Whether the icons in sight are listed too, after the hidden ones.
    var includesIconsInView = false {
        didSet { if includesIconsInView != oldValue { onChange() } }
    }

    /// Called whenever what the island shows may have changed.
    @ObservationIgnored var onChange: () -> Void = {}
    /// Called as an icon is clicked, before its menu is asked for, so the island can
    /// close out of the menu's way.
    @ObservationIgnored var onPress: () -> Void = {}
    /// Called when an icon's menu could not be opened.
    @ObservationIgnored var onFailure: (HiddenMenuBarIcon) -> Void = { _ in }

    @ObservationIgnored private let source: Source
    @ObservationIgnored private let queue: DispatchQueue
    @ObservationIgnored private let pressQueue: DispatchQueue
    @ObservationIgnored private var elements: [String: AXUIElement] = [:]
    /// The icons found out of the menu bar while it had room for them, which stay
    /// switched off once it fills up (`HiddenMenuBarIcons.look`).
    @ObservationIgnored private var switchedOff: Set<String> = []
    @ObservationIgnored private var lookedAt: Date?
    @ObservationIgnored private var isLooking = false
    /// A look was asked for while one was under way, which began too early to answer it.
    @ObservationIgnored private var looksAgain = false
    /// Bumped by `reset`, so a look under way as the feature stops is dropped.
    @ObservationIgnored private var generation = 0

    /// Looks and presses have a queue each: a press only sends the item it was given
    /// one message, and should not wait behind a look held up by a slow app.
    init(source: Source = .system) {
        self.source = source
        queue = DispatchQueue(label: "com.ayush.Islet.hiddenMenuBarIcons", qos: .userInitiated)
        pressQueue = DispatchQueue(label: "com.ayush.Islet.hiddenMenuBarIcons.press", qos: .userInteractive)
    }

    /// What the island lists: every icon out of sight, and those in it too if asked.
    /// Icons someone switched off are never listed.
    var listed: [HiddenMenuBarIcon] {
        (sample ?? icons).filter { $0.isHidden || (includesIconsInView && $0.placement == .shown) }
    }

    /// Whether the list waits on Accessibility. A preview's icons need none.
    var needsAccess: Bool { sample == nil && access == .missing }

    // MARK: Looking

    /// Looks along the menu bar, unless a look from the last couple of seconds already
    /// answers (`force` looks regardless). Returns at once; the icons follow.
    func look(force: Bool = false) {
        refreshAccess()
        guard access == .granted else { return }
        if isLooking {
            if force { looksAgain = true }
            return
        }
        if !force, let lookedAt, Date().timeIntervalSince(lookedAt) < Self.freshness { return }
        isLooking = true
        lookedAt = Date()
        let geometry = source.geometry()
        let source = source
        let generation = generation
        let switchedOff = switchedOff
        queue.async { [weak self] in
            let items = source.read()
            let menus = geometry.menuBarOwner.map(source.menus) ?? []
            let found = HiddenMenuBarIcons.look(
                at: items, menus: menus, geometry: geometry, switchedOff: switchedOff, owner: source.owner
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(found, generation: generation) }
            }
        }
    }

    private func finish(_ found: MenuBarLook, generation: Int) {
        guard generation == self.generation else { return }
        isLooking = false
        elements = found.elements
        switchedOff = found.switchedOff
        let changed = icons != found.icons || !hasLooked
        icons = found.icons
        hasLooked = true
        if changed { onChange() }
        if looksAgain {
            looksAgain = false
            look(force: true)
        }
    }

    /// Checks Accessibility again. Losing it forgets what was found, which can no
    /// longer be opened.
    func refreshAccess() {
        let next: Access = source.isTrusted() ? .granted : .missing
        guard next != access else { return }
        access = next
        if next == .missing {
            icons = []
            elements = [:]
            switchedOff = []
            lookedAt = nil
            hasLooked = false
        }
        onChange()
    }

    /// Forgets everything, for the feature stopping.
    func reset() {
        generation &+= 1
        isLooking = false
        looksAgain = false
        icons = []
        elements = [:]
        switchedOff = []
        lookedAt = nil
        hasLooked = false
        access = .unknown
    }

    // MARK: Opening

    /// Opens the icon's menu, as a click on it in the menu bar would: only ever on a
    /// click of the person's own. A preview's icons open nothing.
    func press(_ icon: HiddenMenuBarIcon) {
        guard icon.isEnabled, sample == nil, let element = elements[icon.id] else { return }
        onPress()
        // What the menu does may change the menu bar; the next open looks afresh.
        lookedAt = nil
        let source = source
        let item = PressedItem(element: element)
        pressQueue.async { [weak self] in
            let result = source.press(item.element)
            guard result == .failed || result == .unsupported else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onFailure(icon) }
            }
        }
    }

    /// An element on its way to the queue that presses it. Accessibility elements may
    /// be used from any thread; Swift does not know that.
    private struct PressedItem: @unchecked Sendable {
        let element: AXUIElement
    }

    // MARK: Previews

    func showSample(_ icons: [HiddenMenuBarIcon]) {
        sample = icons
        onChange()
    }

    func endSample() {
        guard sample != nil else { return }
        sample = nil
        onChange()
    }
}
