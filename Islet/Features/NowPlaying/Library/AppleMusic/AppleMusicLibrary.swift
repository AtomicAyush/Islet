import Foundation

/// Placeholder until the Music app's library is implemented.
@MainActor
final class AppleMusicLibrary: MediaLibrary {
    static let shared = AppleMusicLibrary()

    let bundleIdentifiers: Set<String> = ["com.apple.Music"]
    let displayName = "Music"
    var state: MediaLibraryState { .unavailable(reason: "Not available yet") }
    var capabilities: MediaLibraryCapabilities { [] }

    func connect() {}
    func upNext() async throws -> [MediaItem] { [] }
    func playlists() async throws -> [MediaPlaylist] { [] }
    func play(_ playlist: MediaPlaylist) async throws {}
    func playFromQueue(_ item: MediaItem, at index: Int) async throws {}
}

import SwiftUI

/// Placeholder: the Music app's access, shown in Now Playing's settings.
struct AppleMusicSettingsView: View {
    var body: some View { EmptyView() }
}
