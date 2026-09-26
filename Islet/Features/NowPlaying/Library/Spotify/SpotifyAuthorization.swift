import CryptoKit
import Foundation

/// One sign-in on its way through the browser: what Islet sent to Spotify's
/// authorise page, kept until the redirect comes back with a code.
///
/// Authorisation Code with PKCE, which needs no client secret: a desktop app
/// could not keep one secret anyway. The verifier stays here; Spotify only ever
/// sees its hash until the code is exchanged.
struct SpotifyAuthorization: Sendable {
    /// Registered by the person in their Spotify app's settings, so it must never change.
    static let redirectURI = "islet://nowplaying/spotify-callback"
    /// A sign-in keeps the scopes it was given, so one made before Liked Songs and
    /// adding to playlists were asked for has to connect again for them. Spotify
    /// says which it granted with every token, and `SpotifyTokens` keeps them.
    static let scopes = firstScopes + libraryScopes + playlistScopes

    /// Asked for since Islet first connected to Spotify, so every sign-in has them.
    static let firstScopes = [
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
        "playlist-read-private",
        "playlist-read-collaborative",
    ]
    /// Reading and changing Liked Songs.
    static let libraryScopes = ["user-library-read", "user-library-modify"]
    /// Adding to playlists: public ones need the first, private and collaborative
    /// ones the second.
    static let playlistScopes = ["playlist-modify-public", "playlist-modify-private"]

    let clientID: String
    /// 64 URL-safe random characters (RFC 7636 allows 43 to 128).
    let verifier: String
    /// Echoed back by Spotify, so a callback Islet did not ask for is refused.
    let state: String

    init(clientID: String) {
        self.clientID = clientID
        verifier = Self.randomString(bytes: 48)
        state = Self.randomString(bytes: 16)
    }

    /// The S256 challenge: the verifier's SHA-256, base64url without padding.
    var challenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    var authorizeURL: URL? {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.percentEncodedQuery = Self.formEncoded([
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", Self.redirectURI),
            ("scope", Self.scopes.joined(separator: " ")),
            ("state", state),
            ("code_challenge_method", "S256"),
            ("code_challenge", challenge),
        ])
        return components?.url
    }

    /// Form encoding that escapes everything but RFC 3986's unreserved characters,
    /// for both the authorise query and the token request's body.
    static func formEncoded(_ fields: [(String, String)]) -> String {
        fields.map { "\(escaped($0.0))=\(escaped($0.1))" }.joined(separator: "&")
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func escaped(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// `SystemRandomNumberGenerator` is the system's cryptographic source on Apple
    /// platforms, and unlike `SecRandomCopyBytes` it cannot fail.
    private static func randomString(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A sign-in: the hour-long access token, the refresh token that renews it, the
/// client ID both were issued to (a refresh has to name the same one), and the
/// scopes it was given.
struct SpotifyTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var clientID: String
    /// The scopes Spotify said it granted, space-separated. nil for a sign-in kept by
    /// an earlier Islet, which did not store them, or when Spotify did not say.
    var scope: String?

    /// Renewed a minute early, so no request sets off with a token about to lapse.
    var isFresh: Bool { expiresAt.timeIntervalSinceNow > 60 }

    /// Whether the sign-in was given every one of `needed`, or nil when that is not
    /// known. A list without even the scopes every sign-in has had is not one to go
    /// by: Spotify would then be saying something else, and its refusal is left to
    /// tell.
    func grants(_ needed: [String]) -> Bool? {
        guard let scope else { return nil }
        let granted = Set(scope.split(separator: " ").map(String.init))
        guard granted.isSuperset(of: SpotifyAuthorization.firstScopes) else { return nil }
        return granted.isSuperset(of: needed)
    }
}

extension SpotifyTokens {
    /// From a token response. A refresh may or may not bring a new refresh token, or
    /// say the scopes again; without them, the old ones stay.
    init(_ response: SpotifyTokenResponse, clientID: String, keeping refreshToken: String, scope: String? = nil) {
        accessToken = response.accessToken
        self.refreshToken = response.refreshToken ?? refreshToken
        expiresAt = Date().addingTimeInterval(response.expiresIn)
        self.clientID = clientID
        self.scope = response.scope ?? scope
    }
}

/// The accounts service's reply to a code exchange or a refresh.
struct SpotifyTokenResponse: Decodable {
    var accessToken: String
    var expiresIn: TimeInterval
    var refreshToken: String?
    /// What the sign-in was granted, space-separated.
    var scope: String?
}
