import AppKit
import SwiftUI

/// Stands in for the system's volume and brightness overlay: the keys change the
/// level as macOS would, and the island shows it beside the notch.
///
/// Catching the keys needs Accessibility, so the feature is opt-in and never asks on
/// its own. Until access is granted every key reaches macOS as usual, and so does any
/// key this feature cannot act on (an output with no volume, no built-in display).
@MainActor
final class SystemHUDFeature: Feature {
    let id = "systemHUD"
    let title = "Volume & Brightness"
    let symbol = "speaker.wave.2.fill"
    let summary = "Replaces the system volume and brightness overlay with one in the island."
    let enabledByDefault = false

    enum Key {
        static let volume = "systemHUD.volume"
        static let brightness = "systemHUD.brightness"
        static let showPercentage = "systemHUD.showPercentage"
    }

    /// One id for volume and brightness alike, so held or alternating keys update
    /// the banner on screen instead of animating a new one in.
    static let bannerID = "systemHUD"

    private let model = SystemHUDModel()
    private let tap = MediaKeyTap()
    private let access = AccessibilityAccess()
    private var isRunning = false
    private var accessPoll: Timer?
    private var accessObserver: NSObjectProtocol?
    private var accessRecheck: DispatchWorkItem?
    private var previewTask: Task<Void, Never>?

    @AppStorage(Key.volume) private var handlesVolume = true
    @AppStorage(Key.brightness) private var handlesBrightness = true
    @AppStorage(Key.showPercentage) private var showsPercentage = false

    init() {
        tap.onKeyDown = { [weak self] key, event in
            self?.keyDown(key, event) ?? false
        }
        tap.onAccessLost = { [weak self] in self?.scheduleAccessRecheck() }
        access.onChange = { [weak self] in self?.syncTap() }
        model.onChange = { [weak self] in
            self?.previewTask?.cancel()
            self?.presentHUD()
        }
    }

    func start() {
        isRunning = true
        model.start()
        // Posted when the Accessibility list changes. It is undocumented, so it only
        // hurries things along: the poll still catches a grant, and Settings checks
        // again whenever it is shown.
        accessObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAccessRecheck() }
        }
        access.refresh()
        syncTap()
    }

    func stop() {
        isRunning = false
        tap.uninstall()
        pollAccess(false)
        accessRecheck?.cancel()
        accessRecheck = nil
        if let accessObserver {
            DistributedNotificationCenter.default().removeObserver(accessObserver)
        }
        accessObserver = nil
        previewTask?.cancel()
        previewTask = nil
        model.stop()
        ActivityCenter.shared.dismissBanner(id: Self.bannerID)
    }

    func settingsView() -> AnyView? {
        AnyView(SystemHUDSettings(access: access))
    }

    /// Made-up levels only: previews never touch the real volume or brightness.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Volume") { [weak self] in
                self?.playPreview((6...10).map { (.volume, Double($0) / 16, false) })
            },
            FeaturePreview(title: "Brightness") { [weak self] in
                self?.playPreview((5...10).map { (.brightness, Double($0) / 16, false) })
            },
            FeaturePreview(title: "Mute") { [weak self] in
                self?.playPreview([(.volume, 0.5, false), (.volume, 0.5, true)], interval: 0.7)
            },
        ]
    }

    /// `islet://systemHUD/volume` and `islet://systemHUD/brightness` show the
    /// current level without changing it.
    func handle(_ url: URL) -> Bool {
        switch url.path() {
        case "/volume": model.showVolume()
        case "/brightness": model.showBrightness()
        default: return false
        }
        return true
    }

    // MARK: Keys

    /// What a volume or brightness key does. Returning false hands it to macOS. The
    /// HUD follows through `model.onChange` once the change is made.
    private func keyDown(_ key: MediaKey, _ event: MediaKeyEvent) -> Bool {
        // With every island hidden (a full-screen app) or covered (the lock screen),
        // the system overlay is the only one that would be seen.
        guard islandIsVisible, !screenIsLocked else { return false }

        let flags = event.modifiers
        let fine = flags.contains([.option, .shift])
        // Option on its own opens Sound or Displays settings; macOS does that.
        if flags.contains(.option), !fine { return false }
        let step = fine ? SystemHUDModel.fineStep : SystemHUDModel.step

        switch key {
        case .volumeUp, .volumeDown:
            guard handlesVolume else { return false }
            return model.stepVolume(
                by: key == .volumeUp ? step : -step,
                playsFeedback: !event.isRepeat && playsFeedback(shift: flags.contains(.shift) && !fine)
            )
        case .mute:
            guard handlesVolume else { return false }
            // Held down, the mute key repeats; one press is one toggle.
            return event.isRepeat || model.toggleMute()
        case .brightnessUp, .brightnessDown:
            guard handlesBrightness else { return false }
            return model.stepBrightness(by: key == .brightnessUp ? step : -step)
        }
    }

    /// Follows "Play feedback when volume is changed" in Sound settings; holding
    /// Shift flips it, as it does for the system overlay.
    private func playsFeedback(shift: Bool) -> Bool {
        UserDefaults.standard.bool(forKey: "com.apple.sound.beep.feedback") != shift
    }

    private var islandIsVisible: Bool {
        IslandManager.shared.controllers.values.contains { !$0.model.isSuppressed }
    }

    /// The lock screen sits above every island. The session key is undocumented and
    /// only present while locked; should it ever go away, keys are just caught on the
    /// lock screen too.
    private var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: HUD

    private func presentHUD() {
        let showsPercentage = showsPercentage
        ActivityCenter.shared.present(IslandBanner(
            id: Self.bannerID,
            style: .compact(leading: 40, trailing: SystemHUDLevel.wingWidth(showsPercentage: showsPercentage)),
            duration: 1.6,
            haptic: false,
            leading: AnyView(SystemHUDIcon(model: model)),
            trailing: AnyView(SystemHUDLevel(model: model, showsPercentage: showsPercentage))
        ))
    }

    private func playPreview(
        _ frames: [(kind: SystemHUDModel.Kind, level: Double, muted: Bool)],
        interval: TimeInterval = 0.3
    ) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            for (index, frame) in frames.enumerated() {
                if index > 0 { try? await Task.sleep(for: .seconds(interval)) }
                guard let self, !Task.isCancelled else { return }
                self.model.display(frame.kind, level: frame.level, muted: frame.muted)
                self.presentHUD()
            }
        }
    }

    // MARK: Access

    /// Catches keys whenever access allows, and checks every couple of seconds for
    /// as long as it does not, so a grant in System Settings takes effect by itself.
    private func syncTap() {
        guard isRunning else { return }
        if access.isGranted {
            tap.install()
        } else {
            tap.uninstall()
        }
        pollAccess(!tap.isInstalled)
    }

    private func pollAccess(_ on: Bool) {
        guard on else {
            accessPoll?.invalidate()
            accessPoll = nil
            return
        }
        guard accessPoll == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.access.refresh()
                // Also retries the tap if access is granted but macOS refused it.
                self?.syncTap()
            }
        }
        timer.tolerance = 0.5
        accessPoll = timer
    }

    /// The answer can lag the switch in System Settings, so look a moment later.
    private func scheduleAccessRecheck() {
        accessRecheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.access.refresh()
                self?.syncTap()
            }
        }
        accessRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
