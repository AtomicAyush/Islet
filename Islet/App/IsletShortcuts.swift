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
    }
}
