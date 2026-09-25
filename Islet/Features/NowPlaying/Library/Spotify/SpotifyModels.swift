import Foundation

// The Web API's replies, decoded with `.convertFromSnakeCase` and only as far as
// the island needs them. Anything Spotify has been dropping or renaming (February
// 2026 took several fields away) is optional, so a reply missing it still decodes.

/// A list decoded one element at a time, dropping any that fail: Spotify has been
/// known to send `null` among a person's playlists, and one odd entry should not
/// cost the whole list.
struct SpotifyList<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        elements = try [Lenient](from: decoder).compactMap(\.value)
    }

    private struct Lenient: Decodable {
        let value: Element?
        init(from decoder: Decoder) { value = try? Element(from: decoder) }
    }
}

struct SpotifyImage: Decodable {
    var url: String
    /// Missing for some playlist covers.
    var width: Int?
}

extension [SpotifyImage] {
    /// The smallest image at least `pixels` wide, else the largest there is.
    /// Covers usually come at 640, 300 and 64 pixels.
    func url(fitting pixels: Int) -> URL? {
        let sized = filter { $0.width != nil }.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        let image = sized.first { ($0.width ?? 0) >= pixels } ?? sized.last ?? first
        return image.flatMap { URL(string: $0.url) }
    }
}

/// A track or a podcast episode, as the queue lists them.
struct SpotifyPlayable: Decodable {
    struct Artist: Decodable { var name: String }
    struct Album: Decodable { var images: [SpotifyImage]? }
    struct Show: Decodable {
        var name: String?
        var images: [SpotifyImage]?
    }

    /// Always there, even for local files, which have no id.
    var uri: String
    var name: String
    var durationMs: Int?
    /// Tracks.
    var artists: [Artist]?
    var album: Album?
    /// Episodes.
    var show: Show?
    var images: [SpotifyImage]?

    func mediaItem(id: String) -> MediaItem {
        let covers = [album?.images, images, show?.images].lazy.compactMap { $0 }.first { !$0.isEmpty }
        return MediaItem(
            id: id,
            title: name,
            subtitle: subtitle,
            artworkURL: covers?.url(fitting: SpotifyQueue.artworkPixels),
            duration: durationMs.map { TimeInterval($0) / 1000 }
        )
    }

    /// The artists, or the show for an episode.
    private var subtitle: String? {
        let names = (artists ?? []).map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? show?.name : names.joined(separator: ", ")
    }
}

/// `GET /me/player/queue`.
struct SpotifyQueue: Decodable {
    var currentlyPlaying: SpotifyPlayable?
    var queue: [SpotifyPlayable] = []

    /// Covers are shown list-sized; 96 pixels fills 48 points on a Retina screen,
    /// and picks Spotify's 300-pixel size over its 64.
    static let artworkPixels = 96

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentlyPlaying = try? container.decodeIfPresent(SpotifyPlayable.self, forKey: .currentlyPlaying)
        queue = try container.decodeIfPresent(SpotifyList<SpotifyPlayable>.self, forKey: .queue)?.elements ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case currentlyPlaying, queue
    }

    /// The queue as media items. A song can be queued twice, or come round again on
    /// repeat, so later copies get "#2", "#3" to keep every id unique.
    var upNext: [MediaItem] {
        var seen: [String: Int] = [:]
        return queue.map { entry in
            let copy = (seen[entry.uri] ?? 0) + 1
            seen[entry.uri] = copy
            return entry.mediaItem(id: copy == 1 ? entry.uri : "\(entry.uri)#\(copy)")
        }
    }

    /// The Spotify URI an `upNext` item was made from.
    static func uri(of item: MediaItem) -> String {
        guard let mark = item.id.lastIndex(of: "#"),
              Int(item.id[item.id.index(after: mark)...]) != nil else { return item.id }
        return String(item.id[..<mark])
    }
}

/// One of the person's playlists, from `GET /me/playlists`.
struct SpotifyPlaylist: Decodable {
    struct Owner: Decodable { var displayName: String? }
    struct Count: Decodable { var total: Int? }

    var uri: String
    var name: String
    var images: [SpotifyImage]?
    var owner: Owner?
    /// The number of songs: `items` since February 2026, which Spotify only fills in
    /// for the person's own playlists, and `tracks` before it.
    var count: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = try container.decode(String.self, forKey: .uri)
        name = try container.decode(String.self, forKey: .name)
        images = try? container.decodeIfPresent([SpotifyImage].self, forKey: .images)
        owner = try? container.decodeIfPresent(Owner.self, forKey: .owner)
        let items = try? container.decodeIfPresent(Count.self, forKey: .items)
        let tracks = try? container.decodeIfPresent(Count.self, forKey: .tracks)
        count = items?.total ?? tracks?.total
    }

    private enum CodingKeys: String, CodingKey {
        case uri, name, images, owner, items, tracks
    }

    /// Whether the player's context is this playlist. The player has been known to
    /// name a playlist the older way, `spotify:user:<owner>:playlist:<id>`, so the
    /// ids are what is compared.
    func isPlaying(context: String?) -> Bool {
        guard let context else { return false }
        if context == uri { return true }
        guard let id = Self.playlistID(in: context) else { return false }
        return id == Self.playlistID(in: uri)
    }

    private static func playlistID(in uri: String) -> Substring? {
        let parts = uri.split(separator: ":")
        guard parts.count >= 3, parts[parts.count - 2] == "playlist" else { return nil }
        return parts.last
    }

    /// Its URI serves as the id, which is what playing it needs.
    func mediaPlaylist(isCurrent: Bool) -> MediaPlaylist {
        MediaPlaylist(
            id: uri,
            name: name,
            detail: detail,
            artworkURL: images?.url(fitting: SpotifyQueue.artworkPixels),
            isCurrent: isCurrent
        )
    }

    /// "42 songs", or who made it when Spotify does not say how many.
    private var detail: String? {
        if let count { return count == 1 ? "1 song" : "\(count.formatted()) songs" }
        return owner?.displayName.map { "By \($0)" }
    }
}

struct SpotifyPage<Item: Decodable>: Decodable {
    var items: SpotifyList<Item>
}

/// `GET /me/player`, for the playlist (or album, or artist) playing now.
struct SpotifyPlayback: Decodable {
    struct Context: Decodable { var uri: String? }
    var context: Context?
}

/// Either of Spotify's error bodies: the Web API's `{"error": {"status", "message",
/// "reason"}}`, or the accounts service's `{"error": "invalid_grant",
/// "error_description": …}`.
struct SpotifyErrorBody: Decodable {
    var message: String?
    /// The Web API's reason ("NO_ACTIVE_DEVICE"), or the accounts service's code.
    var reason: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let detail = try? container.decode(Detail.self, forKey: .error) {
            message = detail.message
            reason = detail.reason
        } else {
            reason = try container.decode(String.self, forKey: .error)
            message = try? container.decodeIfPresent(String.self, forKey: .errorDescription)
        }
    }

    private struct Detail: Decodable {
        var message: String?
        var reason: String?
    }

    private enum CodingKeys: String, CodingKey {
        case error, errorDescription
    }
}
