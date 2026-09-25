import AppKit

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
