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
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        })

        fullScreen.onChange = { [weak self] in self?.applyFullScreen() }
        fullScreen.start()
    }

    /// Whether any island is open on the given page (an activity id, or "home").
    func isOpen(on focus: String) -> Bool {
        controllers.values.contains { $0.model.isExpanded && $0.model.resolvedFocus == focus }
    }

    /// The island on the screen the user is most likely looking at: the one under
    /// the pointer, else the first.
    var focusedController: IslandWindowController? {
        let point = NSEvent.mouseLocation
        return controllers.values.first { $0.screen.frame.contains(point) } ?? controllers.values.first
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
        applyFullScreen()
    }

    private func applyFullScreen() {
        let hide = Prefs.hideInFullScreen
        for controller in controllers.values {
            let suppressed = hide && fullScreen.isFullScreen(on: controller.screen)
            if controller.model.isSuppressed != suppressed {
                withAnimation(.islandMorph) { controller.model.isSuppressed = suppressed }
            }
        }
    }
}
