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

    /// The accounts service turned down a code or a refresh token.
    private struct Refused: Error {
        var detail: String?
    }

    private static let apiBase = "https://api.spotify.com/v1/"
    private static let tokenEndpoint = "https://accounts.spotify.com/api/token"
    /// A 429 asking for longer than this is not waited out with someone watching.
    private static let longestRetryWait: TimeInterval = 10

    private let session: URLSession
    private let keychain = SpotifyKeychain()
    private let decoder: JSONDecoder

    private var tokens: SpotifyTokens?
    private var hasLoadedTokens = false
    /// Shared by every request that finds the token stale at once, so it is renewed
    /// once: Spotify may rotate the refresh token, and a second renewal with the old
    /// one would fail.
    private var renewal: Task<SpotifyTokens, Error>?
    /// Bumped by every sign-in and sign-out, so a renewal that finishes after one
    /// does not bring the old sign-in back.
    private var generation = 0

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
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
    }

    // MARK: Library

    func upNext() async throws -> [MediaItem] {
        try await queue().upNext
    }

    /// The first 50 playlists, marking the one playing now. What is playing is
    /// asked for alongside, and not knowing it is no reason to fail.
    func playlists() async throws -> [MediaPlaylist] {
        async let playing = playingContextURI()
        let page: SpotifyPage<SpotifyPlaylist>? = try await get("me/playlists?limit=50")
        let current = await playing
        return (page?.items.elements ?? []).map { $0.mediaPlaylist(isCurrent: $0.isPlaying(context: current)) }
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

    private func queue() async throws -> SpotifyQueue {
        try await get("me/player/queue") ?? SpotifyQueue()
    }

    private func playingContextURI() async -> String? {
        let playback: SpotifyPlayback? = try? await get("me/player")
        return playback?.context?.uri
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
    /// as long as Spotify asks, once.
    private func send(_ method: String, _ path: String, json: Data? = nil) async throws -> Data {
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
                throw failure(status: response.statusCode, data: data)
            }
        }
    }

    private func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
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

    /// Spotify's refusals, as the island says them.
    private func failure(status: Int, data: Data) -> MediaLibraryError {
        let body = try? decoder.decode(SpotifyErrorBody.self, from: data)
        let reason = body?.reason ?? ""
        let message = body?.message?.lowercased() ?? ""
        let text = switch status {
        case 403 where message.contains("registered"):
            // A development-mode app only answers the accounts on its allowlist.
            "Add your Spotify account under User Management in the Spotify dashboard"
        case 403 where reason == "PREMIUM_REQUIRED" || (reason.isEmpty && !message.contains("restriction")):
            "Spotify Premium is needed for this"
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
        return MediaLibraryError(message: text)
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
        return SpotifyTokens(response, clientID: stale.clientID, keeping: stale.refreshToken)
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
