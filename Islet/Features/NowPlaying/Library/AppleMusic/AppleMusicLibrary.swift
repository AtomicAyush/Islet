import AppKit
import Observation

/// The Music app's playlists, read and switched over AppleScript.
///
/// Music's scripting dictionary has no Up Next and no SharePlay, so playlists are
/// all it offers. Scripting it needs the person's permission, which macOS only
/// gives for an app that is running; `state` follows both, re-read when Music opens
/// or quits and when the person leaves System Settings, where the permission is
/// changed. Those notifications are all the library keeps running: they arrive only
/// when an app opens, quits or loses focus, and nothing is polled.
@MainActor
@Observable
final class AppleMusicLibrary: MediaLibrary {
    static let shared = AppleMusicLibrary()

    let bundleIdentifiers: Set<String> = [AppleMusicScripting.bundleIdentifier]
    let displayName = "Music"
    let capabilities: MediaLibraryCapabilities = .playlists

    /// `nil` until macOS has answered the first time.
    private(set) var access: AppleMusicAccess?
    /// The permission prompt is up.
    private(set) var isConnecting = false

    /// Tells the latest reading of `access` from older ones still on their way.
    @ObservationIgnored private var generation = 0

    private static let systemSettings = "com.apple.systempreferences"
    /// What can change `access`, by the app it happens to: Music opening or quitting,
    /// and the person leaving System Settings, where the permission is changed.
    /// Music merely losing focus changes nothing, so it is not worth a reading.
    private static let triggers: [NSNotification.Name: Set<String>] = [
        NSWorkspace.didLaunchApplicationNotification: [AppleMusicScripting.bundleIdentifier],
        NSWorkspace.didTerminateApplicationNotification: [AppleMusicScripting.bundleIdentifier, systemSettings],
        NSWorkspace.didDeactivateApplicationNotification: [systemSettings],
    ]

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        // The library lives as long as the app, so these are never removed.
        for (name, apps) in Self.triggers {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier,
                      apps.contains(app)
                else { return }
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    var state: MediaLibraryState {
        switch access {
        case .allowed?: .ready
        case .notAsked?: .needsConnection(prompt: "Allow Access to Music")
        case .denied?: .unavailable(reason: AppleMusicScripting.deniedAdvice)
        case .notRunning?: .unavailable(reason: "Open Music to see your playlists")
        case .failed(let status)?: .unavailable(reason: "Music can’t be reached right now (error \(status)).")
        case nil: .unavailable(reason: "Checking access to Music…")
        }
    }

    /// Reads again whether Music is open and whether Islet may control it.
    func refresh() {
        generation &+= 1
        let generation = generation
        // Straight away when Music is plainly closed; macOS's answer follows either way.
        if !AppleMusicScripting.isRunning { setAccess(.notRunning) }
        Task {
            let access = await AppleMusicScripting.access(askingUser: false)
            if generation == self.generation { setAccess(access) }
        }
    }

    /// Puts up macOS's prompt to let Islet control Music. Music has to be open for
    /// macOS to ask; while it is closed this only finds that out.
    func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        generation &+= 1
        let generation = generation
        Task {
            let access = await AppleMusicScripting.access(askingUser: true)
            isConnecting = false
            // A reading started while the prompt was up may have been taken before the
            // person answered, so rather than let it stand, read again.
            if generation == self.generation { setAccess(access) } else { refresh() }
        }
    }

    func upNext() async throws -> MediaQueue {
        throw MediaLibraryError(message: Self.noUpNext)
    }

    func playlists() async throws -> [MediaPlaylist] {
        do {
            return try await AppleMusicScripting.playlists()
        } catch {
            throw failure(error)
        }
    }

    func play(_ playlist: MediaPlaylist) async throws {
        do {
            try await AppleMusicScripting.play(playlistID: playlist.id)
        } catch {
            throw failure(error)
        }
    }

    func playFromQueue(_ item: MediaItem, at index: Int) async throws {
        throw MediaLibraryError(message: Self.noUpNext)
    }

    // MARK: Private

    private static let noUpNext = "Music doesn’t share Up Next with other apps."

    private func setAccess(_ access: AppleMusicAccess) {
        if self.access != access { self.access = access }
    }

    /// A script's failure in words, re-reading `state` when it suggests Music quit
    /// or the permission changed.
    private func failure(_ error: Error) -> Error {
        guard let error = error as? AppleMusicScriptError else { return error }
        if error.concernsAccess { refresh() }
        return MediaLibraryError(message: error.message)
    }
}
