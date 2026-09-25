import AppKit
import Observation

/// Spotify's queue and playlists, through the Spotify Web API.
///
/// Spotify only lends its API to apps registered by the people using them, so
/// there is no Islet-wide key: the person makes an app in Spotify's dashboard,
/// pastes its client ID into Settings and signs in once. Since February 2026 such
/// an app works only while its owner has Premium, and for at most five accounts.
///
/// Nothing here runs until the island asks for something, and nothing repeats.
@MainActor
@Observable
final class SpotifyLibrary: MediaLibrary {
    static let shared = SpotifyLibrary()
    static let clientIDKey = "nowPlaying.spotify.clientID"
    static let bundleIdentifier = "com.spotify.client"

    let bundleIdentifiers: Set<String> = [SpotifyLibrary.bundleIdentifier]
    let displayName = "Spotify"
    /// Jam has no public API; `openListeningTogether()` brings Spotify forward instead.
    let capabilities: MediaLibraryCapabilities = [.upNext, .playFromQueue, .playlists, .listeningTogether]

    /// As typed in Settings; used trimmed.
    var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: Self.clientIDKey) }
    }
    /// The client ID the stored sign-in was issued to, nil when signed out. It only
    /// counts while it matches the one in Settings: tokens cannot be renewed under
    /// another.
    private(set) var connectedClientID: String?
    /// The browser came back and the code is being exchanged.
    private(set) var isFinishingSignIn = false
    /// Why the last sign-in did not work, for Settings.
    private(set) var signInError: String?

    /// A sign-in waiting for the browser to come back. Its verifier never leaves here
    /// except to Spotify's token endpoint.
    private var pendingAuthorization: SpotifyAuthorization?
    private let api = SpotifyWebAPI()

    private init() {
        clientID = UserDefaults.standard.string(forKey: Self.clientIDKey) ?? ""
        // Reads only the item's account, which never shows a keychain prompt.
        connectedClientID = SpotifyKeychain().storedClientID()
    }

    var trimmedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Connect was clicked and the browser has not come back yet.
    var isWaitingForBrowser: Bool { pendingAuthorization != nil }

    /// A sign-in is kept on this Mac, whichever client ID it was for, so it can
    /// still be removed after the client ID has been changed or cleared.
    var isSignedIn: Bool { connectedClientID != nil }

    var state: MediaLibraryState {
        let clientID = trimmedClientID
        if clientID.isEmpty { return .unavailable(reason: "Add a Spotify client ID in Settings") }
        if connectedClientID != clientID { return .needsConnection(prompt: "Connect Spotify") }
        return .ready
    }

    // MARK: Signing in

    /// Opens Spotify's sign-in page in the default browser. It comes back through
    /// `islet://nowplaying/spotify-callback`, to `handle(_:)`.
    func connect() {
        let clientID = trimmedClientID
        guard !clientID.isEmpty else { return }
        let authorization = SpotifyAuthorization(clientID: clientID)
        guard let url = authorization.authorizeURL else { return }
        pendingAuthorization = authorization
        signInError = nil
        NSWorkspace.shared.open(url)
    }

    /// Forgets the sign-in on this Mac. Spotify keeps the grant until it is removed
    /// at spotify.com/account/apps, but without the tokens it is of no use.
    func disconnect() {
        pendingAuthorization = nil
        connectedClientID = nil
        signInError = nil
        Task { await api.signOut() }
    }

    func handle(_ url: URL) -> Bool {
        guard url.host()?.caseInsensitiveCompare("nowplaying") == .orderedSame,
              url.path().caseInsensitiveCompare("/spotify-callback") == .orderedSame else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        // Only the sign-in started last, from this launch, is accepted. Once
        // connected, a stray one (the browser page reloaded) is not worth a word.
        guard let authorization = pendingAuthorization, value("state") == authorization.state else {
            if state != .ready {
                signInError = "That sign-in has expired. Click Connect to try again."
            }
            return true
        }
        pendingAuthorization = nil
        guard let code = value("code") else {
            signInError = value("error") == "access_denied"
                ? "Spotify access wasn't allowed"
                : "Spotify didn't sign in (\(value("error") ?? "no code"))"
            return true
        }
        isFinishingSignIn = true
        Task {
            do {
                try await api.signIn(code: code, authorization: authorization)
                connectedClientID = authorization.clientID
                signInError = nil
            } catch {
                signInError = error.localizedDescription
            }
            isFinishingSignIn = false
        }
        return true
    }

    // MARK: Library

    func upNext() async throws -> [MediaItem] {
        try await call { try await $0.upNext() }
    }

    func playlists() async throws -> [MediaPlaylist] {
        try await call { try await $0.playlists() }
    }

    func play(_ playlist: MediaPlaylist) async throws {
        try await call { try await $0.play(contextURI: playlist.id) }
    }

    func playFromQueue(_ item: MediaItem, at index: Int) async throws {
        let uri = SpotifyQueue.uri(of: item)
        try await call { try await $0.skip(to: uri, near: index) }
    }

    /// Jam can only be started inside Spotify, so this brings Spotify forward,
    /// where it is a click away.
    func openListeningTogether() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
        else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Runs a request once signed in, and notices when the sign-in has gone.
    private func call<T: Sendable>(_ request: @Sendable (SpotifyWebAPI) async throws -> T) async throws -> T {
        switch state {
        case .ready: break
        case .needsConnection: throw MediaLibraryError(message: "Connect Spotify first")
        case .unavailable(let reason): throw MediaLibraryError(message: reason)
        }
        do {
            return try await request(api)
        } catch is SpotifyWebAPI.SignedOut {
            connectedClientID = nil
            throw MediaLibraryError(message: "Reconnect Spotify in Settings")
        }
    }
}
