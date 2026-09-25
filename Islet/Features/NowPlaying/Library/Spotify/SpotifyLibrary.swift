import Foundation

/// Placeholder until Spotify's library is implemented.
@MainActor
final class SpotifyLibrary: MediaLibrary {
    static let shared = SpotifyLibrary()

    let bundleIdentifiers: Set<String> = ["com.spotify.client"]
    let displayName = "Spotify"
    var state: MediaLibraryState { .unavailable(reason: "Not available yet") }
    var capabilities: MediaLibraryCapabilities { [] }

    func connect() {}
    func upNext() async throws -> [MediaItem] { [] }
    func playlists() async throws -> [MediaPlaylist] { [] }
    func play(_ playlist: MediaPlaylist) async throws {}
    func playFromQueue(_ item: MediaItem, at index: Int) async throws {}
}
