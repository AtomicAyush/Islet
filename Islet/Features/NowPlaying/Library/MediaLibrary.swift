import SwiftUI

/// What a music app offers beyond play and pause: what is coming up next, the
/// person's playlists, and listening together. Each app that can offer any of it has
/// a library; the opened player asks the one for whatever is playing.
///
/// Libraries do their own talking to their app — a web API, AppleScript — off the
/// main thread, and never ask for permission or sign-in except from `connect()`,
/// which is only called from a button.
@MainActor
protocol MediaLibrary: AnyObject {
    /// The apps this library speaks for (the now-playing bundle identifier).
    var bundleIdentifiers: Set<String> { get }
    /// "Spotify", "Music".
    var displayName: String { get }
    var state: MediaLibraryState { get }
    var capabilities: MediaLibraryCapabilities { get }

    /// Signs in or asks for permission. Only ever called from a button.
    func connect()
    /// What is coming up after the current track.
    func upNext() async throws -> MediaQueue
    /// The person's playlists.
    func playlists() async throws -> [MediaPlaylist]
    func play(_ playlist: MediaPlaylist) async throws
    /// Jumps ahead to an item from `upNext()`, at its position in `MediaQueue.all`.
    func playFromQueue(_ item: MediaItem, at index: Int) async throws
    /// Puts an item at the front of the queue, to play after the current track.
    func playNext(_ item: MediaItem) async throws
    /// Opens the app's listen-together feature (Spotify's Jam), as far as it allows.
    func openListeningTogether()
    /// `islet://nowplaying/…` URLs meant for this library (a sign-in callback, say).
    func handle(_ url: URL) -> Bool
}

extension MediaLibrary {
    func handle(_ url: URL) -> Bool { false }
    func openListeningTogether() {}
    func playNext(_ item: MediaItem) async throws {
        throw MediaLibraryError(message: "\(displayName) can't queue from here")
    }
}

/// What is coming up, split the way Spotify shows it: songs the person queued, which
/// play first, then the rest of the playlist or album that is playing.
struct MediaQueue: Equatable {
    /// "Next in queue": queued by the person.
    var queued: [MediaItem] = []
    /// "Next from …": the rest of what is playing.
    var upcoming: [MediaItem] = []
    /// What `upcoming` comes from ("My playlist #9"), when known.
    var sourceName: String?
    /// Whether the two could be told apart. When not, everything is in `upcoming`
    /// and it is shown as one list.
    var isSplit = false

    /// Everything, in the order it will play.
    var all: [MediaItem] { queued + upcoming }
}

enum MediaLibraryState: Equatable {
    /// Ready to use.
    case ready
    /// Needs a sign-in or a permission first; `prompt` says what `connect()` does.
    case needsConnection(prompt: String)
    /// Cannot be used, and why ("Set a Spotify client ID in Settings").
    case unavailable(reason: String)
}

struct MediaLibraryCapabilities: OptionSet {
    let rawValue: Int
    static let upNext = MediaLibraryCapabilities(rawValue: 1 << 0)
    static let playFromQueue = MediaLibraryCapabilities(rawValue: 1 << 1)
    static let playlists = MediaLibraryCapabilities(rawValue: 1 << 2)
    static let listeningTogether = MediaLibraryCapabilities(rawValue: 1 << 3)
    static let playNext = MediaLibraryCapabilities(rawValue: 1 << 4)
}

struct MediaItem: Identifiable, Hashable {
    var id: String
    var title: String
    /// Artist, or show.
    var subtitle: String?
    var artworkURL: URL?
    var duration: TimeInterval?
}

struct MediaPlaylist: Identifiable, Hashable {
    var id: String
    var name: String
    /// "42 songs", "By Spotify".
    var detail: String?
    var artworkURL: URL?
    var isCurrent = false
}

struct MediaLibraryError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Every library, and which one speaks for the app playing now.
@MainActor
enum MediaLibraries {
    /// Filled in by each provider's file; see `SpotifyLibrary` and `AppleMusicLibrary`.
    static let all: [any MediaLibrary] = [SpotifyLibrary.shared, AppleMusicLibrary.shared]

    static func library(for bundleIdentifier: String?) -> (any MediaLibrary)? {
        guard let bundleIdentifier else { return nil }
        return all.first { $0.bundleIdentifiers.contains(bundleIdentifier) }
    }

    /// Hands `islet://nowplaying/…` URLs to the library they are for.
    static func handle(_ url: URL) -> Bool {
        all.contains { $0.handle(url) }
    }
}
