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
        // Marks restarts in the log, so a closed island can be told from a relaunch.
        IslandLog.app.notice("Islet launched")
        let registry = FeatureRegistry.shared
        Prefs.register(features: registry.features)

        IslandManager.shared.start()
        registry.startEnabled()
        statusItem = StatusItemController()
        welcomeOnFirstLaunch()
        URLRouter.launchFinished()
        // Now that there are features to stop: `pkill` and `killall` quit as the menu does.
        TerminationSignal.install { NSApp.terminate(nil) }
    }

    /// The island is easy to miss the first time — it looks like the notch. Say
    /// hello once, from the island itself, as soon as one is on screen to say it.
    private func welcomeOnFirstLaunch() {
        let key = "hasWelcomed"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            let islands = IslandManager.shared.controllers.values.map(\.model)
            // Hidden behind a full-screen app: try again shortly.
            guard islands.contains(where: { !$0.isSuppressed }) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.welcomeOnFirstLaunch() }
                return
            }
            UserDefaults.standard.set(true, forKey: key)
            let hasNotch = islands.contains { $0.metrics.hasNotch }
            ActivityCenter.shared.present(IslandBanner(
                id: "welcome",
                style: .card(width: 380, height: 58),
                duration: 7,
                content: AnyView(WelcomeCard(hasNotch: hasNotch))
            ))
        }
    }

    /// Pomodoro turns Focus on and off with a shortcut, which takes a moment, and would be
    /// ended with Islet mid-run: Islet waits, a few seconds at most, for a run under way,
    /// for one turning off the Focus of a focus paused, and for a Focus just turned on to
    /// show, so the next launch knows it as Pomodoro's.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let pomodoro = FeatureRegistry.shared.feature(PomodoroFeature.self), pomodoro.needsTimeToQuit else {
            return .terminateNow
        }
        let wait = QuitWait { sender.reply(toApplicationShouldTerminate: true) }
        Task {
            wait.began = true
            await pomodoro.settleBeforeQuitting(within: PomodoroFeature.quitGrace)
            wait.reply()
        }
        wait.arm(limit: PomodoroFeature.quitGrace + 1)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        FeatureRegistry.shared.stopAll()
        // Features stop their shortcuts gently, and follow up on a timer the app will
        // not live to fire; whatever is still running is ended now instead.
        ToolRun.terminateAll()
    }

    /// Opening the app again from Finder or Spotlight shows Settings, since there is
    /// no window to bring forward otherwise.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }
}

/// The reply to a quit that waits, given once, and given anyway if the wait cannot
/// start or runs long. Timers fire while AppKit waits for the reply even where the main
/// queue cannot: a quit asked for from inside one of the queue's blocks leaves the work
/// no way to begin, and Islet then goes at once, leaving what it owed to the next launch.
@MainActor
private final class QuitWait {
    var began = false
    private var replied = false
    private let send: @MainActor () -> Void

    init(send: @escaping @MainActor () -> Void) {
        self.send = send
    }

    func reply() {
        guard !replied else { return }
        replied = true
        send()
    }

    func arm(limit: TimeInterval) {
        let check = Timer(timeInterval: 0.5, repeats: false) { [self] _ in
            MainActor.assumeIsolated { if !began { reply() } }
        }
        let end = Timer(timeInterval: limit, repeats: false) { [self] _ in
            MainActor.assumeIsolated { reply() }
        }
        for timer in [check, end] { RunLoop.main.add(timer, forMode: .common) }
    }
}
