import AppKit
import Carbon.HIToolbox

/// Sees Caps Lock turn on and off.
///
/// macOS posts no notification for Caps Lock, so this watches modifier-key events:
/// one arrives for each press of Shift, Control, Option, Command or Caps Lock, and for
/// nothing else, so at rest it costs nothing and nothing is polled. Seeing other apps'
/// events needs Accessibility (Device Control and Data Access from macOS 27), the same
/// access the volume and brightness keys need. The monitor for them goes in only once
/// macOS trusts Islet, so that it never brings up a permission prompt of its own; until
/// then only Islet's own windows are watched. Whether Caps Lock is on at any moment can
/// be read without any access, so the state at start is read directly, and read again
/// whenever keys may have been kept from Islet: after waking, as the screen unlocks
/// (the lock screen's password field has the keyboard to itself), and as another app
/// comes to the front (one of its password fields, or Terminal's Secure Keyboard Entry,
/// may have). Each is an event, not a poll.
@MainActor
final class CapsLockMonitor {
    /// Whether Caps Lock is on, as last seen.
    private(set) var isOn = false
    /// Whether other apps' key events reach the monitor, so `isOn` follows every change.
    var seesEveryChange: Bool { globalMonitor != nil }

    /// The Caps Lock key turned it on or off.
    var onToggle: (Bool) -> Void = { _ in }
    /// Caps Lock turned out to be on or off without the key being seen to do it: read
    /// again after waking, unlocking or an app switch, or carried by another modifier
    /// key's event after macOS kept keys from Islet for a while.
    var onResync: (Bool) -> Void = { _ in }
    /// `seesEveryChange` flipped: Accessibility was granted or taken away.
    var onAccessChange: () -> Void = {}

    private let readState: () -> Bool
    private let isTrusted: () -> Bool
    private let events: EventMonitors
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var resyncObservers: [NSObjectProtocol] = []
    private var unlockObserver: NSObjectProtocol?
    private var isRunning = false

    /// `readState`, `isTrusted` and `events` stand in for the system in tests, which
    /// never watch the real keyboard.
    init(
        readState: @escaping () -> Bool = CapsLockMonitor.systemState,
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        events: EventMonitors = .system
    ) {
        self.readState = readState
        self.isTrusted = isTrusted
        self.events = events
    }

    /// How modifier-key events are watched: AppKit's monitors in the app.
    struct EventMonitors {
        /// Watches events sent to other apps; `nil` if it could not.
        var addGlobal: (@escaping (NSEvent) -> Void) -> Any?
        /// Watches events sent to Islet's own windows.
        var addLocal: (@escaping (NSEvent) -> Void) -> Any?
        var remove: (Any) -> Void

        static let system = EventMonitors(
            addGlobal: { handler in NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) },
            addLocal: { handler in
                NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    handler(event)
                    return event
                }
            },
            remove: { NSEvent.removeMonitor($0) }
        )
    }

    /// Whether Caps Lock is on now, from the session's combined keyboard state, which
    /// any process may read.
    nonisolated static func systemState() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }

    /// Reads the state as it is, which is never announced: it was not just changed.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        isOn = readState()
        // Handed events on the main thread, as the global monitor's are.
        localMonitor = events.addLocal { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        syncGlobalMonitor()
        let center = NSWorkspace.shared.notificationCenter
        for name in Self.resyncNotifications {
            resyncObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resync() }
            })
        }
        // Undocumented, but long posted as the lock screen goes; an unlock without
        // sleep brings none of the notifications above.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.screenUnlocked, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resync() }
        }
    }

    /// When keys may have gone somewhere Islet could not see them.
    static let resyncNotifications = [
        NSWorkspace.didWakeNotification,
        NSWorkspace.screensDidWakeNotification,
        NSWorkspace.sessionDidBecomeActiveNotification,
        NSWorkspace.didActivateApplicationNotification,
    ]
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for monitor in [globalMonitor, localMonitor].compactMap({ $0 }) {
            events.remove(monitor)
        }
        globalMonitor = nil
        localMonitor = nil
        resyncObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        resyncObservers = []
        if let unlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockObserver)
        }
        unlockObserver = nil
    }

    /// Accessibility may have been granted or taken away: watch other apps' events if it
    /// allows, and catch up on anything missed without it.
    func accessMayHaveChanged() {
        resync()
    }

    /// Reads the state without being told of a change, and reports it if it differs.
    /// Access is checked again first, which is cheap: macOS says nothing when it is
    /// taken away (the notification the feature listens for is undocumented), and a
    /// monitor left in without it hears nothing, so the symbol beside the notch would
    /// go on trusting it.
    func resync() {
        guard isRunning else { return }
        syncGlobalMonitor()
        update(isOn: readState(), byCapsLockKey: false)
    }

    /// One modifier-key event's worth: whether Caps Lock is on after it, and whether it
    /// was the Caps Lock key. The key's own event is always announced, with the state it
    /// carries, even if that is the state already recorded: that record may be stale,
    /// if the last press went to a password field, and a press must never go unshown.
    /// A brush of the key too brief to toggle it should send no event; if one does, the
    /// banner repeats a state that is still true. Every other modifier's event carries
    /// the state too, but is only news when it differs from the last, and then quietly,
    /// so a change missed while keys were kept from Islet is not announced later, when
    /// Shift happens to be pressed.
    func update(isOn: Bool, byCapsLockKey: Bool) {
        if byCapsLockKey {
            self.isOn = isOn
            onToggle(isOn)
            return
        }
        guard isOn != self.isOn else { return }
        self.isOn = isOn
        onResync(isOn)
    }

    private func handle(_ event: NSEvent) {
        update(
            isOn: event.modifierFlags.contains(.capsLock),
            byCapsLockKey: event.keyCode == UInt16(kVK_CapsLock)
        )
    }

    /// The monitor for other apps in while Accessibility allows it, and out when not.
    /// It only goes in once macOS trusts Islet, so it never brings up a prompt.
    private func syncGlobalMonitor() {
        let saw = seesEveryChange
        if !isTrusted() {
            if let globalMonitor { events.remove(globalMonitor) }
            globalMonitor = nil
        } else if globalMonitor == nil {
            // Handed events on the main thread.
            globalMonitor = events.addGlobal { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        if seesEveryChange != saw { onAccessChange() }
    }
}
