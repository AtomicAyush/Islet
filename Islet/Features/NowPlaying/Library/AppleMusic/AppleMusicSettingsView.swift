import SwiftUI

/// Whether Islet may read and switch the Music app's playlists, and the way to let
/// it. Shown in Now Playing's settings.
struct AppleMusicSettingsView: View {
    private let library = AppleMusicLibrary.shared

    var body: some View {
        LabeledContent {
            switch library.access {
            case .allowed?:
                Text("On").foregroundStyle(.secondary)
            case .notAsked?:
                Button("Allow Access…") { library.connect() }
                    .disabled(library.isConnecting)
            case .denied?:
                Button("Open Privacy Settings…") { openAutomationSettings() }
            case .notRunning?:
                Button("Open Music") { openMusic() }
            case .failed?:
                Button("Try Again") { library.refresh() }
            case nil:
                ProgressView().controlSize(.small)
            }
        } label: {
            Text("Music playlists")
            Text(explanation)
        }
        .onAppear { library.refresh() }
    }

    private var explanation: String {
        switch library.access {
        case .allowed?:
            "Islet can show your Music playlists in the island and switch between them. Music keeps Up Next to itself."
        case .notAsked?:
            "To show your Music playlists in the island and switch between them, Islet needs permission to control Music."
        case .denied?:
            "Turn on Music under Islet in System Settings > Privacy & Security > Automation."
        case .notRunning?:
            "Open Music to see your playlists, or to let Islet control it."
        case .failed(let status)?:
            "Music can’t be reached right now (error \(status))."
        case nil:
            "Checking access to Music…"
        }
    }

    private func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppleMusicScripting.bundleIdentifier)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
