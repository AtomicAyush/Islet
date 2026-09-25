import AppKit
import SwiftUI

/// Connecting Spotify, in Now Playing's settings: the client ID of the person's
/// own Spotify app, how to make one, and Connect. Rows for a grouped `Form`.
struct SpotifySettingsView: View {
    @Bindable private var library = SpotifyLibrary.shared
    @State private var copied = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if library.state != .ready {
                    Button("Connect…") { library.connect() }
                        .disabled(library.trimmedClientID.isEmpty || library.isFinishingSignIn)
                }
                // Offered whenever a sign-in is kept, even one for a client ID that has
                // since been changed or cleared, so the tokens can always be removed.
                if library.isSignedIn {
                    Button("Disconnect") { library.disconnect() }
                        .disabled(library.isFinishingSignIn)
                }
            }
        } label: {
            Text("Spotify")
            Text(status)
            if let error = library.signInError {
                Text(error).foregroundStyle(.red)
            }
        }

        TextField("Client ID", text: $library.clientID, prompt: Text("From your app in Spotify's dashboard"))
            .autocorrectionDisabled()

        if library.state != .ready {
            instructions
        }
    }

    private var status: String {
        switch library.state {
        case .ready: "Connected. The opened island shows what's up next and your playlists."
        case .unavailable: "Not set up. Follow the steps below."
        case .needsConnection:
            if library.isFinishingSignIn {
                "Connecting…"
            } else if library.isWaitingForBrowser {
                "Waiting for you to allow access in your browser…"
            } else if library.isSignedIn {
                "Signed in with a different client ID. Connect again to use this one."
            } else {
                "Not connected"
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1) {
                Text("Create an app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard), ticking Web API.")
            }
            step(2) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add this redirect URI to the app:")
                    HStack(spacing: 8) {
                        Text(SpotifyAuthorization.redirectURI)
                            .font(.callout.monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SpotifyAuthorization.redirectURI, forType: .string)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .controlSize(.small)
                    }
                }
            }
            step(3) { Text("Paste the app's Client ID above.") }
            step(4) { Text("Click Connect and allow access in your browser.") }
            Text("Spotify only lets an app like this work while its owner has Spotify Premium, and for up to five accounts added under User Management.")
                .font(.caption)
                .padding(.top, 2)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func step(_ number: Int, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .frame(width: 16, alignment: .trailing)
            content()
        }
    }
}
