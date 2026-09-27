import Foundation

/// What a song's lyrics are looked up by: its title, artist and album as the player
/// reports them, and its length.
struct LyricsQuery: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    /// Seconds; 0 when the player does not know.
    var duration: TimeInterval

    /// What the cache keeps the song's lyrics under: its artist, title and length in
    /// whole seconds.
    var key: String {
        "\(LyricsMatch.folded(artist))|\(LyricsMatch.folded(title))|\(Int(duration.rounded()))"
    }

    /// Whether `other`, from a later report, is this song again, as a player
    /// re-reporting it might word it: the same artist and title, and a length within
    /// LRCLIB's own tolerance. A length that has just become known is news, since the
    /// first look-up had to do without. One that goes missing is not: players leave it
    /// out of a report now and then, and this song's lyrics stand.
    func isSameSong(as other: LyricsQuery) -> Bool {
        guard LyricsMatch.folded(title) == LyricsMatch.folded(other.title),
              LyricsMatch.folded(artist) == LyricsMatch.folded(other.artist)
        else { return false }
        guard other.duration > 0 else { return true }
        return duration > 0 && abs(duration - other.duration) <= LRCLIB.durationTolerance
    }

    /// The query for what the player reports, or `nil` when there is nothing worth
    /// looking up: no title or artist, an app for podcasts or audiobooks, or a video
    /// that does not look like music.
    ///
    /// A video is only looked up when the person asked for that, and then only if it
    /// looks like a song: titled "Artist - Song", as music videos usually are, or from
    /// one of the channels YouTube makes for an artist's music ("Artist - Topic"). What
    /// such titles add around the song ("(Official Video)", "[Lyrics]") is left out.
    static func make(track: NowPlayingTrack, duration: TimeInterval, isVideo: Bool, includesVideos: Bool) -> LyricsQuery? {
        guard !isSpokenWord(track.bundleID) else { return nil }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isVideo else {
            guard includesVideos, let song = LyricsMatch.videoSong(title: title, channel: artist) else { return nil }
            return LyricsQuery(title: song.title, artist: song.artist, album: "", duration: duration)
        }
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return LyricsQuery(
            title: title, artist: artist,
            album: track.album.trimmingCharacters(in: .whitespacesAndNewlines), duration: duration
        )
    }

    /// Whether what is playing is taken for a video: it is one, or it is a browser's
    /// media whose artwork has not come yet. A browser's media counts as video by its
    /// landscape artwork (see `NowPlayingVideo`), and a browser often sends the title
    /// a report or two before it, so until then it may yet be a video, and is not
    /// looked up as a song unless it proves to be music.
    static func takesForVideo(isVideo: Bool, bundleID: String?, hasArtwork: Bool) -> Bool {
        isVideo || !hasArtwork && bundleID.map(NowPlayingVideo.browsers.contains) == true
    }

    /// Whether `bundleID` is an app for podcasts or audiobooks. What they play is not a
    /// song, so it is never sent: an episode's title and its show, a chapter and its
    /// author, are nothing LRCLIB has words for, and not what the person agreed to
    /// share. Players report the spoken word as plain audio, so the app is all there is
    /// to go by; a podcast in a music app or a browser is looked up like a song.
    static func isSpokenWord(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return spokenWordApps.contains(bundleID) || spokenWordMakers.contains { bundleID.hasPrefix($0) }
    }

    private static let spokenWordApps: Set<String> = [
        "com.apple.podcasts",
        "com.apple.iBooksX",
    ]

    /// Makers whose every app is for podcasts or audiobooks: Audible, Overcast, Pocket
    /// Casts, Castro, BookPlayer, Libby.
    private static let spokenWordMakers = [
        "com.audible.", "fm.overcast.", "au.com.shiftyjelly.", "co.supertop.", "com.tortugapower.", "com.overdrive.",
    ]
}

/// What a look-up found.
enum LyricsResult: Equatable, Codable, Sendable {
    /// Timed lines, to follow along with.
    case synced([LyricsLine])
    /// Words without times, as lines; empty lines between verses.
    case plain([String])
    /// LRCLIB knows the song, and it has no words.
    case instrumental
    case notFound
}

/// Why a look-up got no answer. None of these is kept, so the next look-up tries
/// again.
enum LyricsFailure: Error, Equatable, Sendable {
    /// No connection, or LRCLIB's address could not be found.
    case offline
    /// LRCLIB took too long to answer.
    case timedOut
    /// LRCLIB asked for a moment (it answers 429 or 503 when it is overloaded).
    case busy
    /// Any other answer that was neither lyrics nor "not found".
    case server(Int)
    /// An answer that could not be read.
    case unreadable

    /// What the panel says about it.
    var message: String {
        switch self {
        case .offline: "Can’t reach LRCLIB. Check your connection."
        case .timedOut: "LRCLIB took too long to answer."
        case .busy: "LRCLIB is busy. Try again in a moment."
        case .server(let status): "LRCLIB couldn’t answer (error \(status))."
        case .unreadable: "LRCLIB’s answer couldn’t be read."
        }
    }
}

/// Finds a song's lyrics.
protocol LyricsProvider: Sendable {
    /// Throws `LyricsFailure`, or `CancellationError` once the task is cancelled.
    func lyrics(for query: LyricsQuery) async throws -> LyricsResult
}

/// Carries a GET request and brings back the body and the HTTP status. Only a test
/// replaces it.
protocol LyricsTransport: Sendable {
    func get(_ url: URL) async throws -> (data: Data, status: Int)
}

/// LRCLIB (lrclib.net), a free, open collection of lyrics that asks for no key.
///
/// A song is asked for exactly first — title, artist, album and length, which LRCLIB
/// matches within two seconds — and when it has no exact match, searched for by its
/// title (without the "Remastered" and "feat." a release adds) and artist. From the
/// search, only a song of that title and artist is taken, within
/// `searchTolerance` of the length where the player knows it: timed lyrics first,
/// then the closest length. Without a length, the exact look-up is skipped, since
/// LRCLIB then searches other sources itself and often says it is too busy to.
///
/// What is sent is only what is in the query. Nothing is sent until the person turns
/// lyrics on (see `NowPlayingLyricsModel`).
struct LRCLIB: LyricsProvider {
    static let base = URL(string: "https://lrclib.net/api/")!
    /// LRCLIB's own tolerance for the exact look-up.
    static let durationTolerance: TimeInterval = 2
    /// A little more for the search, which is only reached when the exact look-up
    /// found nothing: another release of the song can run a second or two longer,
    /// and the per-song offset can make up the difference.
    static let searchTolerance: TimeInterval = 3

    var transport: any LyricsTransport = LRCLIBSession()

    func lyrics(for query: LyricsQuery) async throws -> LyricsResult {
        if query.duration > 0 {
            var items = [
                URLQueryItem(name: "track_name", value: query.title),
                URLQueryItem(name: "artist_name", value: query.artist),
            ]
            if !query.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: query.album)) }
            items.append(URLQueryItem(name: "duration", value: String(Int(query.duration.rounded()))))
            let (data, status) = try await get("get", items)
            switch status {
            case 200:
                guard let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data) else {
                    throw LyricsFailure.unreadable
                }
                if let result = record.result { return result }
            case 404:
                break
            default:
                throw Self.failure(status)
            }
        }

        let (data, status) = try await get("search", [
            URLQueryItem(name: "track_name", value: LyricsMatch.searchTitle(query.title)),
            URLQueryItem(name: "artist_name", value: LyricsMatch.searchArtist(query.artist)),
        ])
        guard status == 200 else {
            if status == 404 { return .notFound }
            throw Self.failure(status)
        }
        guard let records = try? JSONDecoder().decode([LRCLIBRecord].self, from: data) else {
            throw LyricsFailure.unreadable
        }
        return Self.best(records, for: query) ?? .notFound
    }

    /// The search result to use: of those with anything to show that are this song
    /// (the same title and artist, and within `searchTolerance` of its length when
    /// that is known), timed lyrics before plain ones, then the closest in length,
    /// then LRCLIB's own order.
    static func best(_ records: [LRCLIBRecord], for query: LyricsQuery) -> LyricsResult? {
        let candidates = records.enumerated().compactMap { order, record -> (result: LyricsResult, synced: Bool, gap: TimeInterval, order: Int)? in
            guard LyricsMatch.sameTitle(record.trackName ?? record.name ?? "", query.title),
                  LyricsMatch.sameArtist(record.artistName ?? "", query.artist)
            else { return nil }
            let gap = query.duration > 0 ? abs((record.duration ?? .infinity) - query.duration) : 0
            guard gap <= searchTolerance, let result = record.result else { return nil }
            if case .synced = result { return (result, true, gap, order) }
            return (result, false, gap, order)
        }
        return candidates.min { a, b in
            if a.synced != b.synced { return a.synced }
            if a.gap != b.gap { return a.gap < b.gap }
            return a.order < b.order
        }?.result
    }

    private func get(_ endpoint: String, _ items: [URLQueryItem]) async throws -> (data: Data, status: Int) {
        var components = URLComponents(url: Self.base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = items
        do {
            return try await transport.get(components.url!)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? LyricsFailure.timedOut : LyricsFailure.offline
        }
    }

    private static func failure(_ status: Int) -> LyricsFailure {
        status == 429 || status == 503 ? .busy : .server(status)
    }
}

/// One of LRCLIB's songs. Every field may be missing or null.
struct LRCLIBRecord: Decodable, Equatable, Sendable {
    var id: Int?
    var name: String?
    var trackName: String?
    var artistName: String?
    var albumName: String?
    var duration: TimeInterval?
    var instrumental: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?

    /// The lyrics to show: timed where there are timed lines with words, else plain,
    /// else none for a song marked instrumental. `nil` when it has nothing at all.
    var result: LyricsResult? {
        let synced = LyricsText.synced(syncedLyrics ?? "")
        if synced.contains(where: { !$0.text.isEmpty }) { return .synced(synced) }
        let plain = LyricsText.plain(plainLyrics ?? syncedLyrics ?? "")
        if !plain.isEmpty { return .plain(plain) }
        return instrumental == true ? .instrumental : nil
    }
}

/// The real transport: a session of its own with no cookies and no cache (the
/// look-ups are cached by song, see `LyricsCache`), and short timeouts, so a look-up
/// that is not coming gives up rather than keep the panel's spinner going.
struct LRCLIBSession: LyricsTransport {
    /// LRCLIB asks every app to say who it is, and where to find it.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Islet \(version) (https://github.com/AtomicAyush/Islet)"
    }()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Telling whether two ways of writing a title or an artist are the same song.
enum LyricsMatch {
    /// Lowercased, without accents or apostrophes, and with only letters and digits,
    /// single-spaced: "Beyoncé" and "beyonce", "Don't" and "Dont" come out the same.
    static func folded(_ text: String) -> String {
        let simple = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var kept = String.UnicodeScalarView()
        for scalar in simple.unicodeScalars where !apostrophes.contains(scalar) {
            kept.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2019}", "`"]

    /// The title without what a release adds to it: "(Remastered 2011)", "[Live]",
    /// "- Radio Edit", "(feat. …)". Only for searching and comparing; the exact
    /// look-up sends the title as the player has it.
    static func searchTitle(_ title: String) -> String {
        var result = title
        // Anything in brackets.
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let start = result.range(of: open), let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        // " - Remastered 2011", " - Single Version", " - Live at …".
        for dash in [" - ", " – ", " — "] {
            if let range = result.range(of: dash) {
                let tail = folded(String(result[range.upperBound...]))
                if releaseWords.contains(where: { tail.hasPrefix($0) || tail.contains(" \($0)") }) {
                    result = String(result[..<range.lowerBound])
                }
            }
        }
        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? title : cleaned
    }

    /// The main artist, without who is featured.
    static func searchArtist(_ artist: String) -> String {
        var result = artist
        for marker in [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " with "] {
            if let range = result.range(of: marker, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words that, after a dash, name a release rather than being part of the title.
    private static let releaseWords = [
        "remaster", "remastered", "radio edit", "single version", "album version", "edit", "live", "mono",
        "stereo", "version", "mix", "remix", "demo", "acoustic", "bonus", "deluxe", "explicit", "clean",
    ]

    static func sameTitle(_ a: String, _ b: String) -> Bool {
        loosely(folded(searchTitle(a)), folded(searchTitle(b)))
    }

    /// Either names the other among others ("Artist" and "Artist & Friend"), so a
    /// duet listed under both matches either.
    static func sameArtist(_ a: String, _ b: String) -> Bool {
        loosely(folded(searchArtist(a)), folded(searchArtist(b)))
    }

    /// Equal, or one contained in the other as whole words.
    private static func loosely(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || " \(a) ".contains(" \(b) ") || " \(b) ".contains(" \(a) ")
    }

    // MARK: Videos

    /// The artist and song in a music video's title, or `nil` for a title that does
    /// not look like one: "Artist - Song (Official Video)", or a song on an artist's
    /// "Artist - Topic" channel. Only a dash counts: "How to fix a bike | Channel" and
    /// "Episode 12 | Some Show" are how other videos are titled, and are not sent.
    static func videoSong(title: String, channel: String) -> (artist: String, title: String)? {
        let cleanTitle = strippingVideoWords(title)
        for dash in [" - ", " – ", " — "] {
            if let range = cleanTitle.range(of: dash) {
                let artist = cleanTitle[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let song = cleanTitle[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !song.isEmpty { return (artist, song) }
            }
        }
        if channel.hasSuffix(" - Topic") {
            let artist = String(channel.dropLast(" - Topic".count)).trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !cleanTitle.isEmpty { return (artist, cleanTitle) }
        }
        return nil
    }

    /// Brackets that say what kind of video it is rather than what the song is:
    /// "(Official Music Video)", "[Lyrics]", "(Audio)", "(HD)".
    private static func strippingVideoWords(_ title: String) -> String {
        var result = title
        for (open, close) in [("(", ")"), ("[", "]"), ("【", "】")] {
            var searchFrom = result.startIndex
            while let start = result.range(of: open, range: searchFrom..<result.endIndex),
                  let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
                let inside = folded(String(result[start.upperBound..<end.lowerBound]))
                if videoWords.contains(where: { inside.split(separator: " ").contains(Substring($0)) }) {
                    // Counted, since changing the title invalidates its indices.
                    let at = result.distance(from: result.startIndex, to: start.lowerBound)
                    result.removeSubrange(start.lowerBound..<end.upperBound)
                    searchFrom = result.index(result.startIndex, offsetBy: at)
                } else {
                    searchFrom = end.upperBound
                }
            }
        }
        return result.split(separator: " ").joined(separator: " ")
    }

    private static let videoWords = [
        "official", "video", "lyric", "lyrics", "audio", "visualizer", "visualiser", "hd", "4k", "mv", "clip",
    ]
}
