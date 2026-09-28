import SwiftUI

/// Caps Lock turning on or off, the way the iPhone shows its Ring/Silent switch: a
/// moment's banner either side of the notch, the Caps Lock symbol and name on the left
/// and "On" or "Off" on the right. If asked for, its symbol also stays beside the
/// notch for as long as it is on.
///
/// Seeing the key pressed in other apps needs Accessibility, which Islet never asks
/// for on its own: Settings offers the way to allow it, and until then the island
/// shows nothing for Caps Lock pressed in other apps, only in Islet's own windows.
@MainActor
final class CapsLockFeature: Feature {
    let id = "capsLock"
    let title = "Caps Lock"
    let symbol = "capslock.fill"
    let summary = "A moment's banner as Caps Lock turns on or off."

    /// On and off share one id, so a quick double press updates the banner already up
    /// rather than animating a second one in.
    static let bannerID = "capsLock"
    /// Long enough to read one word, short enough to be gone before the next is typed.
    static let bannerDuration: TimeInterval = 1.2
    private static let previewDuration: TimeInterval = 8

    private let monitor: CapsLockMonitor
    private let access = AccessibilityAccess()
    private var isRunning = false
    private var accessObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var accessRecheck: DispatchWorkItem?
    /// While a preview runs, Caps Lock as the preview has it, in place of the real one.
    private var previewState: Bool?
    private var previewEnd: Task<Void, Never>?

    /// `monitor` stands in for the keyboard in tests.
    init(monitor: CapsLockMonitor? = nil) {
        let monitor = monitor ?? CapsLockMonitor()
        self.monitor = monitor
        monitor.onToggle = { [weak self] isOn in self?.toggled(isOn) }
        monitor.onResync = { [weak self] _ in self?.renderIndicator() }
        // The monitor found access gone (or back) before anything else said so.
        monitor.onAccessChange = { [weak self] in
            self?.access.refresh()
            self?.renderIndicator()
        }
        access.onChange = { [weak self] in
            self?.monitor.accessMayHaveChanged()
            self?.renderIndicator()
        }
    }

    func start() {
        isRunning = true
        access.refresh()
        monitor.start()
        // Posted when the Accessibility list changes. It is undocumented, so it only
        // hurries things along: coming back to Islet from System Settings, and Settings
        // appearing, check again too. Nothing is polled while access is missing.
        accessObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAccessRecheck() }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.access.refresh() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderIndicator() }
        }
        renderIndicator()
    }

    func stop() {
        isRunning = false
        monitor.stop()
        for observer in [activeObserver, defaultsObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        if let accessObserver {
            DistributedNotificationCenter.default().removeObserver(accessObserver)
        }
        accessObserver = nil
        activeObserver = nil
        defaultsObserver = nil
        accessRecheck?.cancel()
        accessRecheck = nil
        endPreview()
        renderIndicator()
        ActivityCenter.shared.dismissBanner(id: Self.bannerID)
    }

    func settingsView() -> AnyView? {
        AnyView(CapsLockSettings(access: access))
    }

    /// The banner as it would show, and, for "on", the symbol beside the notch for eight
    /// seconds whatever the setting says. Caps Lock itself is left alone.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Caps Lock on") { [weak self] in self?.preview(isOn: true) },
            FeaturePreview(title: "Caps Lock off") { [weak self] in self?.preview(isOn: false) },
        ]
    }

    // MARK: Events

    private func toggled(_ isOn: Bool) {
        guard isRunning else { return }
        // A real press ends a preview: what it pretended is now out of date.
        endPreview()
        renderIndicator()
        // Another feature's banner is left where it is. Caps Lock is pressed often and
        // often by the way, and a banner it replaced would never come back: a timer's
        // alert or a battery warning would be gone for good. The key's own light says
        // which way it went.
        if let current = ActivityCenter.shared.banner, current.id != Self.bannerID { return }
        announce(isOn)
    }

    /// Turning off goes unannounced if Settings asks; a banner still saying "On" is
    /// taken down instead, rather than left up to say the opposite of the truth.
    private func announce(_ isOn: Bool, always: Bool = false) {
        guard isOn || always || CapsLockPrefs.bool(CapsLockPrefs.announceOff, default: true) else {
            ActivityCenter.shared.dismissBanner(id: Self.bannerID)
            return
        }
        let widths = CapsLockBannerLayout.widths(isOn: isOn)
        ActivityCenter.shared.present(IslandBanner(
            id: Self.bannerID,
            style: .compact(leading: widths.leading, trailing: widths.trailing),
            duration: Self.bannerDuration,
            // Caps Lock is a key under the other hand: a tap on the trackpad from it
            // would be felt as something else.
            haptic: false,
            leading: AnyView(CapsLockBannerLeading(isOn: isOn)),
            trailing: AnyView(CapsLockBannerTrailing(isOn: isOn))
        ))
    }

    /// The symbol beside the notch while Caps Lock is on, if Settings asks for it and the
    /// monitor sees other apps' keys (without them it would be left up whenever Caps Lock
    /// went off elsewhere). A password field may still keep a press to itself; the
    /// monitor reads the state again as the screen unlocks and another app comes to the
    /// front, so the symbol is not wrong for long. It waits for the island to be up where
    /// there is no notch, as the Focus symbol does: it is a reminder, not an alarm.
    private func renderIndicator() {
        let center = ActivityCenter.shared
        let isOn = previewState
            ?? (isRunning && monitor.seesEveryChange && monitor.isOn
                && CapsLockPrefs.bool(CapsLockPrefs.showIndicator, default: false))
        if isOn {
            // After the Focus symbol, which stays put for hours, and before the camera
            // and microphone dot at the island's end. In the island's ink rather than
            // the key's green: a green mark beside the notch means the camera is on.
            center.setIndicator(StatusIndicator(
                id: id, color: .text(0.9), order: 0, symbol: "capslock.fill",
                keepsIslandShown: false, label: "Caps Lock on"
            ))
        } else {
            center.removeIndicator(id: id)
        }
    }

    // MARK: Access

    /// The answer can lag the switch in System Settings, so look a moment later.
    private func scheduleAccessRecheck() {
        accessRecheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.access.refresh() }
        }
        accessRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Previews

    private func preview(isOn: Bool) {
        announce(isOn, always: true)
        endPreview()
        guard isOn else {
            renderIndicator()
            return
        }
        previewState = true
        renderIndicator()
        previewEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.previewDuration))
            guard !Task.isCancelled, let self else { return }
            self.previewEnd = nil
            self.previewState = nil
            self.renderIndicator()
        }
    }

    private func endPreview() {
        previewEnd?.cancel()
        previewEnd = nil
        guard previewState != nil else { return }
        previewState = nil
        renderIndicator()
    }
}

/// The feature's preference keys, shared by the feature and its settings. Unset keys
/// read as their defaults, the same ones the settings toggles declare.
enum CapsLockPrefs {
    static let announceOff = "capsLock.announceOff"
    static let showIndicator = "capsLock.showIndicator"

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

/// Under the feature's toggle: the permission it needs, and what it shows.
private struct CapsLockSettings: View {
    let access: AccessibilityAccess
    @AppStorage(CapsLockPrefs.announceOff) private var announceOff = true
    @AppStorage(CapsLockPrefs.showIndicator) private var showIndicator = false

    var body: some View {
        LabeledContent {
            if access.isGranted {
                Label {
                    Text("Allowed")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
            } else {
                Button("Grant Access…") { access.request() }
            }
        } label: {
            Text(AccessibilityAccess.paneName)
            Text(access.isGranted
                 ? "Islet sees the Caps Lock key pressed in other apps, though a password field may keep it to itself."
                 : "Needed to see the Caps Lock key pressed in other apps. Until then, the island shows nothing for a press there.")
            if !access.isGranted {
                // The trap Volume & Brightness explains too: macOS keeps the permission
                // for the exact copy of the app it was given to, and still shows it
                // switched on for a newer one.
                Text("Already switched on in System Settings? That permission belongs to an earlier copy of Islet. Select Islet in the \(AccessibilityAccess.paneName) list, remove it with −, then click Grant Access again.")
            }
        }
        .onAppear { access.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access.refresh()
        }

        Toggle("Show when it turns off", isOn: $announceOff)
        Toggle(isOn: $showIndicator) {
            Text("Show while on")
            Text("The Caps Lock symbol beside the notch.")
        }
    }
}
