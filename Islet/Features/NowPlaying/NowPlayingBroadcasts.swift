import AppKit

/// A player that announces its own state to anyone listening, besides telling
/// MediaRemote. macOS reports a single now-playing app, and keeps reporting a paused
/// browser video while Spotify plays on; the players' own word lets the island
/// follow whichever is really playing.
///
/// Listed in order of preference, for when more than one is playing.
enum NowPlayingBroadcastPlayer: CaseIterable, Sendable {
    case spotify
    case music

    var bundleID: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        }
    }

    /// Posted on every play, pause and change of track.
    var notification: Notification.Name {
        switch self {
        case .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged")
        case .music: Notification.Name("com.apple.Music.playerInfo")
        }
    }

    /// Where a track's cover can be looked up, since neither player puts one in its
    /// notification. Spotify's public oEmbed endpoint describes any track or episode
    /// without a sign-in. Music's tracks have no such page, so they keep the
    /// placeholder rather than a guessed cover.
    func coverPage(for report: NowPlayingBroadcastReport) -> URL? {
        guard self == .spotify, report.hasArtwork, let uri = report.trackID else { return nil }
        // "spotify:track:<id>"; local files and adverts have no page.
        let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track" || parts[1] == "episode",
              !parts[2].isEmpty, parts[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        var components = URLComponents(string: "https://open.spotify.com/oembed")
        components?.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/\(parts[1])/\(parts[2])")]
        return components?.url
    }
}

/// One of a player's notifications, as it worded it. Players put what they like in
/// these, so everything but the state may be missing.
struct NowPlayingBroadcastReport: Sendable {
    enum State: Sendable {
        case playing
        case paused
        case stopped
    }

    var state: State
    var title: String
    var artist: String
    var album: String
    /// Seconds; `nil` when the player did not say.
    var duration: TimeInterval?
    /// Seconds in, as of `date`; `nil` when the player did not say (Music does not).
    var position: TimeInterval?
    /// Tells a track from another of the same name: Spotify's track URI, Music's
    /// persistent ID.
    var trackID: String?
    /// Spotify says so when a track has no cover (a local file), and then none is
    /// looked up.
    var hasArtwork: Bool
    /// When the notification arrived, which is when `position` held: players post
    /// the position as of posting, and it arrives straight away.
    var date: Date

    /// `nil` for a notification that names no player state, which says nothing usable.
    init?(_ userInfo: [AnyHashable: Any]?, from player: NowPlayingBroadcastPlayer, at date: Date) {
        guard let info = userInfo else { return nil }
        switch info["Player State"] as? String {
        case "Playing": state = .playing
        case "Paused": state = .paused
        case "Stopped": state = .stopped
        default: return nil
        }
        title = info["Name"] as? String ?? ""
        artist = info["Artist"] as? String ?? ""
        album = info["Album"] as? String ?? ""
        switch player {
        case .spotify:
            duration = seconds(info["Duration"], scale: 1000)
            position = seconds(info["Playback Position"])
            trackID = info["Track ID"] as? String
        case .music:
            duration = seconds(info["Total Time"], scale: 1000)
            position = seconds(info["Player Position"])
            trackID = (info["PersistentID"] ?? info["Persistent ID"]).map { "\($0)" }
        }
        hasArtwork = info["Has Artwork"] as? Bool ?? true
        self.date = date
    }

    /// What the island shows for this notification, or `nil` once the player has
    /// stopped. A player that leaves the position out carries on from wherever the
    /// last report of the same track had got to, or starts a new track at the top.
    /// Shuffle, repeat and 15-second jumps are left out: neither player reports them.
    func snapshot(from player: NowPlayingBroadcastPlayer, after previous: NowPlayingBroadcastState?) -> NowPlayingSnapshot? {
        guard state != .stopped, !title.isEmpty else { return nil }
        let track = NowPlayingTrack(title: title, artist: artist, album: album, bundleID: player.bundleID)
        let carried = previous.flatMap { $0.trackID == trackID && $0.snapshot.track == track ? $0.snapshot.timing : nil }
        let playing = state == .playing
        return NowPlayingSnapshot(
            track: track,
            isPlaying: playing,
            timing: NowPlayingTiming(
                elapsed: position ?? carried?.position(at: date) ?? 0,
                timestamp: date,
                rate: playing ? 1 : 0,
                duration: duration ?? carried?.duration ?? 0
            )
        )
    }
}

/// A player's latest notification, as the island shows it.
struct NowPlayingBroadcastState {
    var trackID: String?
    var snapshot: NowPlayingSnapshot
}

/// A non-negative, finite number of seconds from a notification's value, which may
/// come as a number or as text; `scale` converts from milliseconds.
private func seconds(_ value: Any?, scale: Double = 1) -> TimeInterval? {
    let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    guard let number, number.isFinite, number >= 0 else { return nil }
    return number / scale
}

/// Listens to Spotify's and Music's own notifications, looks up Spotify's covers,
/// and carries the island's controls to either of them when it shows it.
///
/// Nothing polls: the players post on every play, pause and change of track, and
/// until one does after launch, nothing is known about it.
@MainActor
final class NowPlayingBroadcasts {
    /// A player's new state, or `nil` once it has stopped or quit.
    var onUpdate: (NowPlayingBroadcastPlayer, NowPlayingSnapshot?) -> Void = { _, _ in }

    private var states: [NowPlayingBroadcastPlayer: NowPlayingBroadcastState] = [:]
    private var observer: BroadcastObserver?
    private var quitObserver: NSObjectProtocol?
    /// Bumped by `stop()`, so a notification, cover or reply still on its way from
    /// before is dropped.
    private var generation = 0
    /// Never invalidated: a cover load cancelled by `stop()` may not have made its
    /// request yet, and a request on an invalidated session raises an exception.
    /// Cancelling the loads is what stops their requests.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()
    private var covers: [String: NowPlayingArtwork] = [:]
    /// The tracks in `covers`, oldest first.
    private var coverOrder: [String] = []
    private var coverLoads: [String: Task<Void, Never>] = [:]

    /// Enough to go back and forth through an album without looking anything up again.
    private static let coversKept = 16

    func start() {
        let generation = self.generation
        let observer = BroadcastObserver { [weak self] player, report in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.receive(report, from: player)
                }
            }
        }
        for player in NowPlayingBroadcastPlayer.allCases {
            // AppKit holds distributed notifications back while an app is inactive,
            // and an agent app almost always is.
            DistributedNotificationCenter.default().addObserver(
                observer, selector: #selector(BroadcastObserver.received(_:)), name: player.notification,
                object: nil, suspensionBehavior: .deliverImmediately
            )
        }
        self.observer = observer

        // A player that quits mid-song may not say it stopped.
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.playerQuit(bundleID) }
        }
    }

    func stop() {
        generation += 1
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        if let quitObserver { NSWorkspace.shared.notificationCenter.removeObserver(quitObserver) }
        quitObserver = nil
        coverLoads.values.forEach { $0.cancel() }
        coverLoads.removeAll()
        covers.removeAll()
        coverOrder.removeAll()
        states.removeAll()
    }

    // MARK: Notifications

    private func receive(_ report: NowPlayingBroadcastReport, from player: NowPlayingBroadcastPlayer) {
        let previous = states[player]
        guard var snapshot = report.snapshot(from: player, after: previous) else {
            states[player] = nil
            if previous != nil { onUpdate(player, nil) }
            return
        }
        if let page = player.coverPage(for: report), let trackID = report.trackID {
            if let cover = covers[trackID] {
                snapshot.artwork = cover
            } else {
                loadCover(from: page, for: trackID, of: player)
            }
        }
        states[player] = NowPlayingBroadcastState(trackID: report.trackID, snapshot: snapshot)
        onUpdate(player, snapshot)
    }

    private func playerQuit(_ bundleID: String?) {
        guard let player = NowPlayingBroadcastPlayer.allCases.first(where: { $0.bundleID == bundleID }),
              states[player] != nil else { return }
        states[player] = nil
        onUpdate(player, nil)
    }

    // MARK: Covers

    /// Fetched as soon as a track is announced, so the cover is ready if the island
    /// turns to the player later in the song. A failure is not remembered: the
    /// track's next notification tries again.
    private func loadCover(from page: URL, for trackID: String, of player: NowPlayingBroadcastPlayer) {
        guard coverLoads[trackID] == nil else { return }
        let generation = self.generation
        let session = self.session
        coverLoads[trackID] = Task { [weak self] in
            let cover = await Self.fetchCover(describedAt: page, session: session)
            guard let self, self.generation == generation else { return }
            coverLoads[trackID] = nil
            if let cover { coverLoaded(cover, for: trackID, of: player) }
        }
    }

    private func coverLoaded(_ cover: NowPlayingArtwork, for trackID: String, of player: NowPlayingBroadcastPlayer) {
        covers[trackID] = cover
        coverOrder.append(trackID)
        if coverOrder.count > Self.coversKept { covers[coverOrder.removeFirst()] = nil }
        guard var state = states[player], state.trackID == trackID else { return }
        state.snapshot.artwork = cover
        states[player] = state
        onUpdate(player, state.snapshot)
    }

    /// Reads the thumbnail's address from the oEmbed answer, downloads it, and
    /// decodes it the way MediaRemote's artwork is, tint and all. Off the main thread.
    nonisolated private static func fetchCover(describedAt page: URL, session: URLSession) async -> NowPlayingArtwork? {
        guard let described = try? await session.data(from: page),
              (described.1 as? HTTPURLResponse)?.statusCode == 200,
              let fields = try? JSONSerialization.jsonObject(with: described.0) as? [String: Any],
              let address = fields["thumbnail_url"] as? String,
              let image = URL(string: address), image.scheme == "https",
              let downloaded = try? await session.data(from: image),
              (downloaded.1 as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return NowPlayingArtwork.decode(data: downloaded.0)
    }

    // MARK: Controls

    /// Sends a control to the player, and `completion` how it went, on the main
    /// queue; `mayPrompt` as `NowPlayingPlayerControl` takes it. A player announces
    /// plays, pauses and new tracks, which confirm those commands, but not a move
    /// within a track, so a seek or a restart it accepted is taken as done from when
    /// it was sent — unless it has posted since, which knows better.
    func perform(
        _ command: NowPlayingCommand, on player: NowPlayingBroadcastPlayer, mayPrompt: Bool,
        completion: @escaping @MainActor (NowPlayingDelivery) -> Void
    ) {
        let sent = Date()
        let generation = self.generation
        NowPlayingPlayerControl.send(command, to: player, mayPrompt: mayPrompt) { [weak self] delivery in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if delivery == .delivered, let self, self.generation == generation {
                        self.moved(player, by: command, sentAt: sent)
                    }
                    completion(delivery)
                }
            }
        }
    }

    private func moved(_ player: NowPlayingBroadcastPlayer, by command: NowPlayingCommand, sentAt sent: Date) {
        let target: TimeInterval
        switch command {
        case .seek(let seconds): target = seconds
        case .previous: target = 0
        default: return
        }
        guard var state = states[player], state.snapshot.timing.timestamp < sent else { return }
        state.snapshot.timing.elapsed = target
        state.snapshot.timing.timestamp = sent
        states[player] = state
        onUpdate(player, state.snapshot)
    }
}

/// Receives the players' notifications, on whichever thread they arrive, and hands
/// them on parsed and stamped with their arrival.
private final class BroadcastObserver: NSObject {
    private let handler: @Sendable (NowPlayingBroadcastPlayer, NowPlayingBroadcastReport) -> Void

    init(handler: @escaping @Sendable (NowPlayingBroadcastPlayer, NowPlayingBroadcastReport) -> Void) {
        self.handler = handler
    }

    @objc func received(_ notification: Notification) {
        let date = Date()
        guard let player = NowPlayingBroadcastPlayer.allCases.first(where: { $0.notification == notification.name }),
              let report = NowPlayingBroadcastReport(notification.userInfo, from: player, at: date)
        else { return }
        handler(player, report)
    }
}
