import AppKit
import SwiftUI

/// Keeps one island window on each screen the Displays preference asks for, and
/// rebuilds them as displays come, go or change resolution.
@MainActor
final class IslandManager {
    static let shared = IslandManager()

    private(set) var controllers: [CGDirectDisplayID: IslandWindowController] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pendingRebuild: DispatchWorkItem?
    private let fullScreen = FullScreenWatcher()
    /// The activities after the first, to notice one arriving, leaving or moving.
    private var otherIDs: [String] = []
    /// Re-measures the menu bar while there is more than one activity: status items
    /// come and go without telling anyone.
    private var roomTimer: Timer?
    /// Measures the menu bar again as soon as an item comes or goes there, the pill
    /// macOS shows while the screen is shared say, while there is more than one activity.
    private let menuBarChanges = MenuBarChanges()
    /// Watches which app's menus the menu bar shows, which the bubbles left of the
    /// island stop short of.
    private var menuBarOwnerObservation: NSKeyValueObservation?

    private init() {}

    func start() {
        rebuild()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        })
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        })

        // After sleep, a lock or a fast user switch the panels can be gone from the
        // screen even though nothing about the displays changed.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRebuild() }
            })
        }
        // Switching app or space can hide or reveal status items, once the menu bar
        // has caught up: the switch finishes after the notification.
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated { self?.measureMenuBars() }
                }
            })
        }
        // The menu bar showing another app's menus: each island keeps clear of those at
        // once, as last found, and looks at them again (`measureMenus`).
        menuBarOwnerObservation = NSWorkspace.shared.observe(\.menuBarOwningApplication) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.controllers.values.forEach { $0.measureMenus() } }
            }
        }
        // A change of Space at once ends any wait on the notch of an island hidden for
        // a full-screen app. Whether an island open over the app closes waits until the
        // watcher has seen where the Space went (`onSpaceSettled`, below): leaving full
        // screen is a change of Space too.
        observers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controllers.values.forEach { $0.model.spaceDidChange() }
            }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        })
        // The Mac going to sleep, its screens with it, locking or another user taking
        // over lets go of any page kept open, and cancels a card's question: whoever
        // comes back has moved on.
        let away: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controllers.values.forEach {
                    $0.model.endKeepingOpen()
                    $0.model.cancelQuestion()
                }
            }
        }
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main, using: away))
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: away
        ))

        fullScreen.onChange = { [weak self] in self?.applyFullScreen() }
        fullScreen.onSpaceSettled = { [weak self] in
            self?.controllers.values.forEach { $0.model.spaceDidSettle() }
        }
        fullScreen.start()
        watchSecondary()
    }

    /// Whether any island is open on the given page (an activity id, or "home").
    func isOpen(on focus: String) -> Bool {
        controllers.values.contains { $0.model.isExpanded && $0.model.resolvedFocus == focus }
    }

    /// The island on the screen the user is most likely looking at: the one under
    /// the pointer, else the first.
    var focusedController: IslandWindowController? {
        let point = NSEvent.mouseLocation
        // Mouse coordinates run over (minY, maxY], so a pointer parked at the very top
        // edge — where it rests for a notch app — belongs to that screen.
        return controllers.values.first { NSMouseInRect(point, $0.screen.frame, false) } ?? controllers.values.first
    }

    // MARK: Typing

    /// Typing begins in `island`, which takes the keyboard (`IslandViewModel.beginTyping`).
    /// Only one island has it: typing in any other ends first.
    func beginTyping(on island: IslandViewModel, in place: TypingPlace, client: TypingClient) {
        Self.beginTyping(on: island, in: place, client: client, among: controllers.values.map(\.model))
    }

    static func beginTyping(
        on island: IslandViewModel, in place: TypingPlace, client: TypingClient, among islands: [IslandViewModel]
    ) {
        for other in islands where other !== island { other.endTyping(.otherIsland) }
        island.beginTyping(in: place, client: client)
    }

    // MARK: Screens

    private var wantedScreens: [NSScreen] {
        let screens = NSScreen.screens
        switch Prefs.displays {
        case .all:
            return screens
        case .main:
            return Array(screens.prefix(1))
        case .notched:
            if let notched = screens.first(where: \.hasNotch) { return [notched] }
            return Array(screens.prefix(1))
        }
    }

    private func scheduleRebuild() {
        // Display changes arrive in bursts (mirroring, wake, lid); settle first.
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func rebuild() {
        var wanted: [CGDirectDisplayID: NSScreen] = [:]
        for screen in wantedScreens {
            if let id = screen.displayID { wanted[id] = screen }
        }

        for (id, controller) in controllers where wanted[id] == nil {
            controller.invalidate()
            controllers[id] = nil
        }
        for (id, screen) in wanted {
            if let existing = controllers[id] {
                existing.update(screen: screen)
            } else {
                controllers[id] = IslandWindowController(screen: screen)
            }
        }
        applyPreferences()
        applyFullScreen()
    }

    private var lastDisplayChoice = Prefs.displays

    private func applyPreferences() {
        if Prefs.displays != lastDisplayChoice {
            lastDisplayChoice = Prefs.displays
            scheduleRebuild()
        }
        let idlePill = Prefs.idlePillOnPlainDisplays
        for controller in controllers.values where controller.model.showsIdlePill != idlePill {
            controller.model.showsIdlePill = idlePill
        }
        let fromNotch = Prefs.openFromNotchInFullScreen
        for controller in controllers.values where controller.model.opensFromNotchInFullScreen != fromNotch {
            controller.model.opensFromNotchInFullScreen = fromNotch
        }
        // Back to both sides, the menus are looked at afresh; right side only, what was
        // found of them is forgotten (`IslandWindowController.measureMenus`).
        let placement = Prefs.bubblePlacement
        for controller in controllers.values where controller.model.bubblePlacement != placement {
            withAnimation(.islandMorph) { controller.model.bubblePlacement = placement }
            controller.measureMenus()
        }
        let ringWidth = Prefs.islandRing?.thickness.width ?? 0
        for controller in controllers.values where controller.model.ringWidth != ringWidth {
            controller.model.ringWidth = ringWidth
        }
        applyFullScreen()
    }

    // MARK: Menu bar

    /// How many further activities' bubbles fit beside each island depends on where
    /// the menu bar's status items begin, so they are measured again whenever the
    /// activities after the first change, as soon as an item comes or goes while there
    /// are any, and every 20 seconds besides, for the changes nothing tells of.
    private func watchSecondary() {
        let ids = withObservationTracking {
            ActivityCenter.shared.activities.dropFirst().map(\.id)
        } onChange: { [weak self] in
            // Called as the change is about to happen; look again once it has.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.watchSecondary() }
            }
        }
        guard ids != otherIDs else { return }
        otherIDs = ids
        measureMenuBars()

        if ids.isEmpty {
            roomTimer?.invalidate()
            roomTimer = nil
            menuBarChanges.stop()
        } else if roomTimer == nil {
            roomTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.measureMenuBars(listening: true) }
            }
            roomTimer?.tolerance = 5
            listenForMenuBarChanges()
        }
    }

    /// Measures each island's menu bar. `listening` also picks up a menu bar process
    /// started again since, or Accessibility granted since (`MenuBarChanges.start`).
    private func measureMenuBars(listening: Bool = false) {
        if listening { listenForMenuBarChanges() }
        for controller in controllers.values { controller.measureMenuBarRoom() }
    }

    private func listenForMenuBarChanges() {
        menuBarChanges.start { [weak self] in self?.measureMenuBars() }
    }

    private func applyFullScreen() {
        let hide = Prefs.hideInFullScreen
        for controller in controllers.values {
            let suppressed = hide && fullScreen.isFullScreen(on: controller.screen)
            if controller.model.isSuppressed != suppressed {
                // Back from full screen, the island shows keeping clear of the menus of
                // whichever app is in front now, as last found, and looks at them again
                // once the menu bar has come back.
                if !suppressed { controller.followMenuBarOwner() }
                withAnimation(.islandMorph) { controller.model.isSuppressed = suppressed }
                if !suppressed {
                    // Where the status items are may have changed meanwhile too.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak controller] in
                        MainActor.assumeIsolated { controller?.measureMenuBarRoom() }
                    }
                }
            }
        }
    }
}
