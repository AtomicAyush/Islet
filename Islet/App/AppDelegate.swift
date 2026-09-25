import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so a URL that launched the app is not missed.
        URLRouter.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let registry = FeatureRegistry.shared
        Prefs.register(features: registry.features)

        IslandManager.shared.start()
        registry.startEnabled()
        statusItem = StatusItemController()
        welcomeOnFirstLaunch()
    }

    /// The island is easy to miss the first time — it looks like the notch. Say
    /// hello once, from the island itself.
    private func welcomeOnFirstLaunch() {
        let key = "hasWelcomed"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            ActivityCenter.shared.present(IslandBanner(
                id: "welcome",
                style: .card(width: 380, height: 58),
                duration: 7,
                content: AnyView(WelcomeCard())
            ))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        FeatureRegistry.shared.stopAll()
    }

    /// Opening the app again from Finder or Spotlight shows Settings, since there is
    /// no window to bring forward otherwise.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }
}
