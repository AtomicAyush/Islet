import SwiftUI

/// What a music app offers beyond play and pause: what is coming up next, the
/// person's playlists, saving the song playing, and listening together. Each app
/// that can offer any of it has a library; the opened player asks the one for
/// whatever is playing.
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
    /// Queues an item to play after the current track and anything already queued
    /// (Spotify can only add to the end of what was queued), returning once the app
    /// lists it.
    func playNext(_ item: MediaItem) async throws
    /// Opens the app's listen-together feature (Spotify's Jam), as far as it allows.
    func openListeningTogether()
    /// `islet://nowplaying/…` URLs meant for this library (a sign-in callback, say).
    func handle(_ url: URL) -> Bool

    /// How the app words saving a song: Spotify's heart, Music's star.
    var saveStyle: MediaSaveStyle { get }
    /// Goes up with every sign-in, so whatever failed for want of one is tried again.
    var signInCount: Int { get }
    /// The song or episode playing now, if it is the one titled `title` that the
    /// island shows, and whether it is saved. nil when something else is playing, or
    /// something that cannot be saved (an advert, a local file).
    func playingItem(titled title: String) async throws -> MediaPlayingItem?
    /// Saves an item from `playingItem(titled:)`, or takes it out again. It is the
    /// item that was shown, so a song that has ended since is still the one changed.
    func setSaved(_ saved: Bool, _ item: MediaPlayingItem) async throws
    /// Adds an item from `playingItem(titled:)` to one of the playlists that can take it.
    func add(_ item: MediaPlayingItem, to playlist: MediaPlaylist) async throws -> MediaPlaylistAddition
}

extension MediaLibrary {
    func handle(_ url: URL) -> Bool { false }
    func openListeningTogether() {}
    func playNext(_ item: MediaItem) async throws {
        throw MediaLibraryError(message: "\(displayName) can't queue from here")
    }
    var saveStyle: MediaSaveStyle { .like }
    var signInCount: Int { 0 }
    func playingItem(titled title: String) async throws -> MediaPlayingItem? { nil }
    func setSaved(_ saved: Bool, _ item: MediaPlayingItem) async throws {
        throw MediaLibraryError(message: "\(displayName) can't save songs from here")
    }
    func add(_ item: MediaPlayingItem, to playlist: MediaPlaylist) async throws -> MediaPlaylistAddition {
        throw MediaLibraryError(message: "\(displayName) can't add to playlists from here")
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
    /// Liking the song playing (Spotify), or making it a favourite (Music).
    static let save = MediaLibraryCapabilities(rawValue: 1 << 5)
    /// Adding the song playing to one of the person's playlists.
    static let addToPlaylist = MediaLibraryCapabilities(rawValue: 1 << 6)
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
    /// The person may add songs to it: it is theirs, or one they make together with
    /// others. Anyone else's can only be played.
    var canAdd = false
}

/// The song or episode playing, as its app knows it, for saving it or adding it to a
/// playlist.
struct MediaPlayingItem: Equatable, Sendable {
    /// The app's own name for it: a Spotify URI, a Music persistent ID.
    var id: String
    var title: String
    var isSaved: Bool

    /// Whether the app's title and the island's are the same song's. They word it
    /// alike, but case, accents and stray spaces are not worth a mismatch.
    static func sameTitle(_ one: String, _ other: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        return one.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(other.trimmingCharacters(in: .whitespacesAndNewlines), options: options) == .orderedSame
    }
}

/// What adding to a playlist came to.
enum MediaPlaylistAddition: Equatable, Sendable {
    case added
    /// Islet added it before and the playlist has not changed since, so it was not
    /// added a second time.
    case alreadyThere
}

/// The words and symbol for saving a song, the way its app has them.
struct MediaSaveStyle: Equatable {
    var symbol: String
    var savedSymbol: String
    /// "Like", the button's name.
    var save: String
    /// "Add to Liked Songs", what a tap does.
    var saveHelp: String
    /// "Remove from Liked Songs", what a tap does once it is saved.
    var unsave: String

    static let like = MediaSaveStyle(
        symbol: "heart", savedSymbol: "heart.fill",
        save: "Like", saveHelp: "Add to Liked Songs", unsave: "Remove from Liked Songs"
    )
    static let favourite = MediaSaveStyle(
        symbol: "star", savedSymbol: "star.fill",
        save: "Favourite", saveHelp: "Add to Favourites", unsave: "Remove from Favourites"
    )
}

/// The sign-in works, but was given before Islet asked for what this needs, and only
/// signing in again grants it. `prompt` says so, as the island shows it.
struct MediaLibraryNeedsReconnect: LocalizedError {
    var prompt: String
    var errorDescription: String? { prompt }
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
