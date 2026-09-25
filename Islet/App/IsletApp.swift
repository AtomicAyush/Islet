import SwiftUI

@main
struct IsletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Islet has no main window. Settings open in their own window from the menu
        // bar item or the island, so this scene only satisfies `App`.
        Settings { EmptyView() }
    }
}
