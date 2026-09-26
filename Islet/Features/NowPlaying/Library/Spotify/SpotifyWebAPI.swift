import Foundation

/// Spotify's Web API and accounts service, spoken off the main thread.
///
/// Holds the sign-in, loading it from the keychain on first use rather than at
/// launch and renewing the access token as it runs out, and turns Spotify's
/// errors into sentences the island can show.
actor SpotifyWebAPI {
    /// The sign-in is gone for good: revoked, past the six months Spotify now
    /// allows, or refused even when freshly renewed. Connecting again is the fix.
    struct SignedOut: Error {}

    /// The sign-in works but was not given the scope this request needs: it was
    /// made before Islet asked for it. Connecting again grants it. Known from the
    /// scopes Spotify said it granted, before anything is asked; failing that, from
    /// Spotify's refusal.
    struct MissingScope: Error {}

    /// How a request reaches Spotify and its reply comes back: a URLSession in the
    /// app, a stand-in in tests, which must never reach the real Spotify.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The accounts service turned down a code or a refresh token.
    private struct Refused: Error {
        var detail: String?
    }

    /// The Web API answered with something other than success; `message` says it
    /// the way the island shows it.
    private struct APIError: LocalizedError {
        var status: Int
        var message: String
        var errorDescription: String? { message }

        /// Asking again would get the same answer: not a stale token, a timeout or
        /// a rate limit, and not Spotify having a bad moment.
        var isRefusal: Bool { (400..<500).contains(status) && ![401, 408, 429].contains(status) }
    }

    /// Spotify will not list a playlist or album for Up Next's split.
    private struct Unlisted: Error {}

    private static let apiBase = "https://api.spotify.com/v1/"
    private static let tokenEndpoint = "https://accounts.spotify.com/api/token"
    /// A 429 asking for longer than this is not waited out with someone watching.
    private static let longestRetryWait: TimeInterval = 10

    private let transport: Transport
    private let keychain: any SpotifyTokenStore
    private let decoder: JSONDecoder
    /// How long Spotify's player is given to catch up with a change of song.
    private let catchUpDelay: Duration

    private var tokens: SpotifyTokens?
    private var hasLoadedTokens = false
    /// Shared by every request that finds the token stale at once, so it is renewed
    /// once: Spotify may rotate the refresh token, and a second renewal with the old
    /// one would fail.
    private var renewal: Task<SpotifyTokens, Error>?
    /// Bumped by every sign-in and sign-out, so a renewal that finishes after one
    /// does not bring the old sign-in back.
    private var generation = 0

    /// What has been read of each playlist or album played, by context URI.
    private var listings: [String: SpotifyTrackListing] = [:]
    /// Songs queued from Islet, which tell queued songs apart when the playlist
    /// cannot.
    private var hints = SpotifyQueueHints()

    /// A sign-in stored without its scopes has been renewed once to learn them, so
    /// it is not renewed early again when Spotify does not say.
    private var hasAskedForScopes = false

    /// The person's Spotify id, once asked for: whose playlists are their own.
    private var userID: String?
    /// Each playlist's version as last listed, or as adding to it left it.
    private var snapshots: [String: String] = [:]
    /// What Islet has added to each playlist while it has not otherwise changed, by
    /// playlist URI, so a second tap does not add the song twice.
    private var additions: [String: PlaylistAdditions] = [:]

    /// The songs Islet added to a playlist, and every version of it those adds went
    /// through: the one it was listed at, then the one each add made, the latest
    /// last. Spotify's listing can trail its writes, and a listing still at one of
    /// these is behind Islet's adds rather than a sign of a change made elsewhere.
    private struct PlaylistAdditions {
        var uris: Set<String> = []
        var versions: [String] = []
    }

    init(
        keychain: any SpotifyTokenStore = SpotifyKeychain(),
        transport: Transport? = nil,
        catchUpDelay: Duration = .seconds(1)
    ) {
        self.keychain = keychain
        self.catchUpDelay = catchUpDelay
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: configuration)
            self.transport = { try await session.data(for: $0) }
        }
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    // MARK: Signing in

    /// Trades the code from the browser for tokens, and keeps them.
    func signIn(code: String, authorization: SpotifyAuthorization) async throws {
        let response: SpotifyTokenResponse
        do {
            response = try await tokenRequest([
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", SpotifyAuthorization.redirectURI),
                ("client_id", authorization.clientID),
                ("code_verifier", authorization.verifier),
            ])
        } catch let refused as Refused {
            let detail = refused.detail.map { " (\($0))" } ?? ""
            throw MediaLibraryError(message: "Spotify turned down the sign-in\(detail). Check the client ID and redirect URI.")
        }
        guard let refreshToken = response.refreshToken else {
            throw MediaLibraryError(message: "Spotify didn't finish signing in. Try again.")
        }
        let fresh = SpotifyTokens(response, clientID: authorization.clientID, keeping: refreshToken)
        try keychain.save(fresh)
        forget()
        tokens = fresh
    }

    func signOut() {
        forget()
        keychain.delete()
    }

    private func forget() {
        generation += 1
        renewal?.cancel()
        renewal = nil
        tokens = nil
        hasLoadedTokens = true
        listings = [:]
        hints = SpotifyQueueHints()
        userID = nil
        snapshots = [:]
        additions = [:]
        hasAskedForScopes = false
    }

    // MARK: Library

    /// The first 50 playlists, marking the one playing now and the ones the person
    /// can add to. What is playing, and who the person is, are asked for alongside,
    /// and not knowing either is no reason to fail.
    func playlists() async throws -> [MediaPlaylist] {
        async let playing = playingContextURI()
        async let user = currentUserID()
        let page: SpotifyPage<SpotifyPlaylist>? = try await get("me/playlists?limit=50")
        let current = await playing
        let me = await user
        let playlists = page?.items.elements ?? []
        for playlist in playlists {
            if let listed = playlist.snapshotId, additions[playlist.uri]?.versions.contains(listed) == true {
                // Behind or level with Islet's own adds: nothing has changed elsewhere.
                continue
            }
            snapshots[playlist.uri] = playlist.snapshotId
        }
        return playlists.map {
            $0.mediaPlaylist(isCurrent: $0.isPlaying(context: current), canAdd: $0.canAdd(asUser: me))
        }
    }

    /// Asked for once per sign-in. nil when Spotify could not say, which only costs
    /// the person's own playlists their add buttons until the next listing.
    private func currentUserID() async -> String? {
        if let userID { return userID }
        let generation = generation
        let user: SpotifyUser? = try? await get("me")
        if generation == self.generation, let id = user?.id { userID = id }
        return user?.id
    }

    func play(contextURI: String) async throws {
        let body = try JSONEncoder().encode(["context_uri": contextURI])
        _ = try await send("PUT", "me/player/play", json: body)
    }

    /// Skips forward until `uri` plays; there is no call to jump into the queue.
    ///
    /// The queue is read again first, since it moves on by itself as songs end and
    /// a count taken from the list on screen could land a song or two off. The
    /// copy nearest where it was shown is the one meant.
    func skip(to uri: String, near index: Int) async throws {
        let queue = try await queue()
        let matches = queue.queue.indices.filter { queue.queue[$0].uri == uri }
        guard let position = matches.min(by: { abs($0 - index) < abs($1 - index) }) else {
            if queue.currentlyPlaying?.uri == uri { return }
            throw MediaLibraryError(message: "That song has left the queue")
        }
        for _ in 0...position {
            _ = try await send("POST", "me/player/next")
        }
    }

    /// Adds a song to the queue. Spotify puts it after any songs already queued;
    /// its API has no way to put one first.
    func addToQueue(_ uri: String) async throws {
        _ = try await send("POST", "me/player/queue?" + SpotifyAuthorization.formEncoded([("uri", uri)]))
        hints.add(uri)
    }

    // MARK: Saving

    /// The track or episode playing, if it is the one titled `title` and one that
    /// can be saved, with whether it is in the person's library. Spotify's player
    /// takes a moment to catch up with a change of song, so when it names another,
    /// it is asked once more after that moment; if it still does, something else is
    /// playing (on another device, say), and nil comes back rather than the wrong song.
    func playingItem(titled title: String) async throws -> MediaPlayingItem? {
        try await requireScopes(["user-library-read"])
        var item = try await playingSavable()
        if item.map({ !MediaPlayingItem.sameTitle($0.name, title) }) ?? true {
            try await Task.sleep(for: catchUpDelay)
            item = try await playingSavable()
        }
        guard let item, MediaPlayingItem.sameTitle(item.name, title) else { return nil }
        let saved: [Bool]? = try await get("me/library/contains?" + SpotifyAuthorization.formEncoded([("uris", item.uri)]))
        return MediaPlayingItem(id: item.uri, title: item.name, isSaved: saved?.first == true)
    }

    private func playingSavable() async throws -> SpotifyCurrentlyPlaying.Item? {
        let playing: SpotifyCurrentlyPlaying? = try await get("me/player/currently-playing?additional_types=track,episode")
        return playing?.savable
    }

    /// Saves to Liked Songs (or Your Episodes), or removes from it.
    func setSaved(_ saved: Bool, uri: String) async throws {
        try await requireScopes(["user-library-modify"])
        _ = try await send(saved ? "PUT" : "DELETE", "me/library?" + SpotifyAuthorization.formEncoded([("uris", uri)]))
    }

    /// Adds a track or episode to the end of a playlist. Spotify would add a second
    /// copy of a song already there, and seeing whether it is means reading the
    /// whole playlist; instead Islet remembers what it added, and while the playlist
    /// is unchanged since, as far as its last listing says, adding the same song
    /// again does nothing.
    func add(_ uri: String, toPlaylist playlistURI: String) async throws -> MediaPlaylistAddition {
        guard let id = SpotifyPlaylist.playlistID(in: playlistURI) else {
            throw MediaLibraryError(message: "Spotify couldn't find that playlist")
        }
        try await requireScopes(SpotifyAuthorization.playlistScopes)
        let listed = snapshots[playlistURI]
        let known = additions[playlistURI].flatMap { $0.versions.last == listed ? $0 : nil }
        if known?.uris.contains(uri) == true { return .alreadyThere }
        let generation = generation
        let body = try JSONEncoder().encode(["uris": [uri]])
        // Spotify turns down a playlist the person may not change (one they only
        // follow, say) without giving a reason, and here that is not about Premium.
        let data = try await send(
            "POST", "playlists/\(id)/items", json: body, refusal: "Spotify won't let you add to this playlist"
        )
        let reply = data.isEmpty ? nil : try? decoder.decode(SpotifySnapshot.self, from: data)
        if generation == self.generation, let snapshot = reply?.snapshotId {
            // Only what Islet added since the playlist last changed elsewhere counts.
            var record = known ?? PlaylistAdditions(versions: listed.map { [$0] } ?? [])
            record.uris.insert(uri)
            record.versions.append(snapshot)
            additions[playlistURI] = record
            snapshots[playlistURI] = snapshot
        }
        return .added
    }

    /// Throws `MissingScope` before anything is asked when the sign-in was not given
    /// `needed`. A sign-in kept by an earlier Islet does not say what it was given,
    /// so it is renewed early, once, since Spotify says with every token; and when
    /// Spotify still does not say, the request goes ahead and its refusal tells.
    private func requireScopes(_ needed: [String]) async throws {
        _ = try await accessToken()
        if tokens?.scope == nil, !hasAskedForScopes {
            _ = try await renewedTokens()
            hasAskedForScopes = true
        }
        if tokens?.grants(needed) == false { throw MissingScope() }
    }

    private func queue() async throws -> SpotifyQueue {
        try await get("me/player/queue") ?? SpotifyQueue()
    }

    private func playingContextURI() async -> String? {
        let playback: SpotifyPlayback? = try? await get("me/player")
        return playback?.context?.uri
    }

    // MARK: Up Next

    /// What is coming up, split the way Spotify shows it. Not being able to split
    /// it never fails Up Next: the queue is then shown whole.
    func upNext() async throws -> MediaQueue {
        async let playing: SpotifyPlayback? = try? get("me/player")
        let queue = try await queue()
        let uris = queue.queue.map(\.uri)
        hints.notePlaying(queue.currentlyPlaying?.uri)
        let split = SpotifyQueueSplit(queue: uris, current: queue.currentlyPlaying?.uri, hinted: hints.uris)
        var queued = split.byHints
        var source: String?
        if let playback = await playing, !uris.isEmpty,
           let contextURI = playback.context?.uri, let origin = SpotifyTrackSource(contextURI: contextURI) {
            (queued, source) = try await splitByContext(split, origin: origin, contextURI: contextURI, order: playback.queueOrder)
        }
        hints.keep(queued: uris.prefix(queued ?? 0))

        let items = queue.upNext
        guard let queued else { return MediaQueue(upcoming: items, sourceName: source) }
        return MediaQueue(
            queued: Array(items.prefix(queued)),
            upcoming: Array(items.dropFirst(queued)),
            sourceName: source,
            isSplit: true
        )
    }

    /// Splits the queue by the playlist or album playing, reading only as much of
    /// it as that takes, and names it.
    private func splitByContext(
        _ split: SpotifyQueueSplit, origin: SpotifyTrackSource, contextURI: String, order: SpotifyQueueSplit.Order?
    ) async throws -> (queued: Int?, source: String?) {
        // Smart shuffle goes by the hints alone, and without them is shown whole,
        // with no name to show, so there is nothing to ask for.
        if order == nil, split.byHints == nil { return (nil, nil) }
        guard var listing = try await listing(of: origin, contextURI: contextURI) else { return (split.byHints, nil) }
        defer { listings[contextURI] = listing }
        guard listing.isReadable, let order else { return (split.byHints, listing.name) }
        while true {
            let outcome = split.split(by: listing.tracks, isComplete: listing.isComplete, order: order)
            // Shuffled, only all of it will do, so one too long to read whole is left.
            let isWorthReading = order != .shuffled || listing.fitsWhole
            guard outcome.reading != .enough, listing.canReadMore, isWorthReading,
                  try await readMore(of: origin, into: &listing, pages: outcome.reading == .next ? 1 : 4)
            else { return (outcome.queued, listing.name) }
        }
    }

    /// What is known of the playlist or album: kept from before while the playlist
    /// is unchanged, else started afresh. nil when Spotify could not be asked.
    private func listing(of origin: SpotifyTrackSource, contextURI: String) async throws -> SpotifyTrackListing? {
        let kept = listings[contextURI]
        if let kept, !kept.isReadable { return kept }
        do {
            switch origin {
            case .album(let id):
                if let kept { return kept }
                guard let album: SpotifyAlbum = try await readForSplit("albums/\(id)?market=from_token") else { return nil }
                var listing = SpotifyTrackListing(name: album.name)
                _ = listing.add(album.tracks.page)
                return listing
            case .playlist(let id):
                // A cheap look at the version, so an unchanged playlist is not read again.
                guard let version: SpotifyPlaylistVersion = try await readForSplit("playlists/\(id)?fields=name,snapshot_id")
                else { return kept }
                if var kept, kept.snapshot == version.snapshotId {
                    kept.name = version.name
                    return kept
                }
                return SpotifyTrackListing(name: version.name, snapshot: version.snapshotId)
            }
        } catch is Unlisted {
            return SpotifyTrackListing(name: nil, isReadable: false)
        }
    }

    /// Reads the next pages of `listing`, together when there are several. False
    /// when Spotify did not answer, which leaves the rest for another time.
    private func readMore(of origin: SpotifyTrackSource, into listing: inout SpotifyTrackListing, pages: Int) async throws -> Bool {
        let offsets = listing.nextPages(pages)
        let read: [SpotifyTrackListing.Page]
        do {
            read = try await withThrowingTaskGroup(of: SpotifyTrackListing.Page?.self) { group in
                for offset in offsets {
                    group.addTask { try await self.page(of: origin, at: offset) }
                }
                return try await group.reduce(into: []) { pages, page in
                    if let page { pages.append(page) }
                }
            }
        } catch is Unlisted {
            listing.isReadable = false
            return false
        }
        var added = 0
        for page in read.sorted(by: { $0.offset < $1.offset }) {
            guard listing.add(page) else { break }
            added += 1
        }
        return added == offsets.count
    }

    private func page(of origin: SpotifyTrackSource, at offset: Int) async throws -> SpotifyTrackListing.Page? {
        let size = SpotifyTrackListing.pageSize
        let path = switch origin {
        case .playlist(let id):
            "playlists/\(id)/items?offset=\(offset)&limit=\(size)&market=from_token&additional_types=track,episode"
        case .album(let id):
            "albums/\(id)/tracks?offset=\(offset)&limit=\(size)&market=from_token"
        }
        let page: SpotifyTrackPage? = try await readForSplit(path)
        return page?.page
    }

    /// A read for the split, which must never fail Up Next: nil when Spotify could
    /// not be reached or replied oddly, to be tried again next time, and `Unlisted`
    /// when it turned the request down, which is remembered.
    private func readForSplit<T: Decodable>(_ path: String) async throws -> T? {
        do {
            return try await get(path)
        } catch let error as APIError where error.isRefusal {
            throw Unlisted()
        } catch let error where error is SignedOut || error is CancellationError {
            throw error
        } catch {
            return nil
        }
    }

    // MARK: Requests

    /// Decoded, or nil for 204 No Content, which the player endpoints send when
    /// nothing is playing anywhere.
    private func get<T: Decodable>(_ path: String) async throws -> T? {
        let data = try await send("GET", path)
        return data.isEmpty ? nil : try decode(T.self, from: data)
    }

    /// Sends a request with the current access token and returns the body of a
    /// successful reply. A 401 renews the token and tries once more; a 429 waits
    /// as long as Spotify asks, once. `refusal` is what a 403 that gives no reason
    /// means for this request.
    private func send(
        _ method: String, _ path: String, json: Data? = nil, refusal: String = SpotifyWebAPI.premiumNeeded
    ) async throws -> Data {
        guard let url = URL(string: Self.apiBase + path) else {
            throw MediaLibraryError(message: "Spotify couldn't do that")
        }
        var token = try await accessToken()
        var renewed = false
        var waited = false
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if method != "GET" {
                // Always a body, if an empty one, so a PUT or POST carries a
                // Content-Length; servers may turn one away without (411).
                request.httpBody = json ?? Data()
                if json != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            }
            let (data, response) = try await load(request)
            switch response.statusCode {
            case 204:
                return Data()
            case 200..<300:
                return data
            case let status where [401, 403].contains(status) && isMissingScope(data):
                // Before a 401's renewal: a new token has the same scopes, and a
                // second 401 would sign out a sign-in that works.
                throw MissingScope()
            case 401 where !renewed:
                renewed = true
                token = try await renewedAccessToken(replacing: token)
            case 401:
                signOut()
                throw SignedOut()
            case 429 where !waited:
                waited = true
                try await waitOut(response)
            default:
                throw failure(status: response.statusCode, data: data, refusal: refusal)
            }
        }
    }

    private func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else {
                throw MediaLibraryError(message: "Can't reach Spotify")
            }
            return (data, http)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet: throw MediaLibraryError(message: "You're offline")
            default: throw MediaLibraryError(message: "Can't reach Spotify")
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw MediaLibraryError(message: "Spotify replied with something Islet can't read")
        }
    }

    private func waitOut(_ response: HTTPURLResponse) async throws {
        let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 1
        guard seconds <= Self.longestRetryWait else {
            throw MediaLibraryError(message: "Spotify is busy. Try again in a few minutes")
        }
        try await Task.sleep(for: .seconds(max(0, seconds)))
    }

    /// Spotify says "Insufficient client scope" (403), or on some endpoints
    /// "Permissions missing" (401), when the sign-in was not given what a request
    /// needs.
    private func isMissingScope(_ data: Data) -> Bool {
        guard let message = (try? decoder.decode(SpotifyErrorBody.self, from: data))?.message?.lowercased()
        else { return false }
        return message.contains("scope") || message.contains("permissions missing")
    }

    /// Most of what Islet asks is player control, which Spotify keeps for Premium,
    /// and it has been known to refuse without saying so.
    private static let premiumNeeded = "Spotify Premium is needed for this"

    /// Spotify's refusals, as the island says them; `refusal` stands for a 403 that
    /// gives no reason.
    private func failure(status: Int, data: Data, refusal: String = SpotifyWebAPI.premiumNeeded) -> APIError {
        let body = try? decoder.decode(SpotifyErrorBody.self, from: data)
        let reason = body?.reason ?? ""
        let message = body?.message?.lowercased() ?? ""
        let text = switch status {
        case 403 where message.contains("registered"):
            // A development-mode app only answers the accounts on its allowlist.
            "Add your Spotify account under User Management in the Spotify dashboard"
        case 403 where reason == "PREMIUM_REQUIRED":
            Self.premiumNeeded
        case 403 where reason.isEmpty && !message.contains("restriction"):
            refusal
        case 403:
            "Spotify won't allow that right now"
        case 404 where reason == "NO_ACTIVE_DEVICE" || message.contains("no active device"):
            "Start playing in Spotify first"
        case 404:
            "Spotify couldn't find that"
        case 429:
            "Spotify is busy. Try again in a moment"
        case 500...:
            "Spotify isn't responding. Try again in a moment"
        default:
            "Spotify couldn't do that"
        }
        return APIError(status: status, message: text)
    }

    // MARK: Tokens

    private func accessToken() async throws -> String {
        if !hasLoadedTokens {
            tokens = keychain.load()
            hasLoadedTokens = true
        }
        guard let tokens else { throw SignedOut() }
        return tokens.isFresh ? tokens.accessToken : try await renewedTokens().accessToken
    }

    /// After a 401. Another request may already have renewed the token that failed.
    private func renewedAccessToken(replacing stale: String) async throws -> String {
        if let tokens, tokens.accessToken != stale, tokens.isFresh { return tokens.accessToken }
        return try await renewedTokens().accessToken
    }

    private func renewedTokens() async throws -> SpotifyTokens {
        guard let current = tokens else { throw SignedOut() }
        let generation = generation
        let task = renewal ?? Task { try await refresh(current) }
        renewal = task
        let result = await task.result
        guard generation == self.generation else {
            // Signed out, or in again, while this was on its way.
            guard let tokens else { throw SignedOut() }
            return tokens
        }
        renewal = nil
        do {
            let fresh = try result.get()
            if fresh != tokens {
                tokens = fresh
                // Kept in memory regardless; a failed save only costs a sign-in
                // after the next launch.
                try? keychain.save(fresh)
            }
            return fresh
        } catch is Refused {
            signOut()
            throw SignedOut()
        }
    }

    private func refresh(_ stale: SpotifyTokens) async throws -> SpotifyTokens {
        let response = try await tokenRequest([
            ("grant_type", "refresh_token"),
            ("refresh_token", stale.refreshToken),
            ("client_id", stale.clientID),
        ])
        return SpotifyTokens(response, clientID: stale.clientID, keeping: stale.refreshToken, scope: stale.scope)
    }

    /// A form POST to the accounts service. A 400 or 401 there means the code or
    /// refresh token is no good (expired, revoked, or for another client ID).
    private func tokenRequest(_ fields: [(String, String)]) async throws -> SpotifyTokenResponse {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw MediaLibraryError(message: "Can't reach Spotify")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(SpotifyAuthorization.formEncoded(fields).utf8)
        let (data, response) = try await load(request)
        switch response.statusCode {
        case 200..<300:
            return try decode(SpotifyTokenResponse.self, from: data)
        case 400, 401:
            let body = try? decoder.decode(SpotifyErrorBody.self, from: data)
            throw Refused(detail: body?.message ?? body?.reason)
        default:
            throw failure(status: response.statusCode, data: data)
        }
    }
}
