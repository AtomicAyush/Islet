import AppIntents

/// Islet's App Shortcuts: its actions, ready in the Shortcuts app and Spotlight without
/// being set up first, and to Siri by name. An app has only one provider, so every
/// feature's actions are listed here.
struct IsletShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowInIsletIntent(),
            phrases: [
                "Show a banner in \(.applicationName)",
                "Show in \(.applicationName)",
            ],
            shortTitle: "Show in Islet",
            systemImageName: "bell.badge"
        )
        AppShortcut(
            intent: KeepAwakeIntent(),
            phrases: [
                "Keep my Mac awake with \(.applicationName)",
                "Keep awake with \(.applicationName)",
            ],
            shortTitle: "Keep Mac Awake",
            systemImageName: "cup.and.saucer.fill"
        )
        AppShortcut(
            intent: StopKeepAwakeIntent(),
            phrases: [
                "Stop keeping my Mac awake with \(.applicationName)",
                "Stop Keep Awake in \(.applicationName)",
            ],
            shortTitle: "Stop Keeping Awake",
            systemImageName: "cup.and.saucer"
        )
        AppShortcut(
            intent: MuteMicrophoneIntent(),
            phrases: [
                "Mute or unmute the microphone with \(.applicationName)",
                "Toggle microphone mute in \(.applicationName)",
            ],
            shortTitle: "Mute Microphone",
            systemImageName: "mic.slash.fill"
        )
        AppShortcut(
            intent: JoinMeetingIntent(),
            phrases: [
                "Join my next meeting with \(.applicationName)",
                "Join the meeting in \(.applicationName)",
            ],
            shortTitle: "Join Meeting",
            systemImageName: "video.fill"
        )
    }
}
