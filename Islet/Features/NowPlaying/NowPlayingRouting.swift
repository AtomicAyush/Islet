import Foundation
import os

/// One way a control can travel to the app the island shows.
enum NowPlayingRoute: Equatable, Sendable {
    /// Apple Events to Spotify or Music themselves, which reach them whatever macOS
    /// counts as now playing.
    case appleEvents(NowPlayingBroadcastPlayer)
    /// MediaRemote, but only if the app is the one it would deliver to: the adapter
    /// checks straight before sending, and sends nothing otherwise.
    case mediaRemote(onlyTo: String)
    /// MediaRemote, to whichever app it has elected.
    case mediaRemoteAnyApp
}

/// How a route went.
enum NowPlayingDelivery: Equatable, Sendable {
    /// The app took it.
    case delivered
    /// Not sent: this way cannot reach the app (Islet may not automate it, it is not
    /// running, or the route cannot carry the command), so the next way may.
    case unavailable
    /// Not sent: MediaRemote would have delivered it to another app, or to none.
    case elsewhere
    /// Not taken, and no other way may try: it was sent, or perhaps sent, so another
    /// way could apply it twice; or it could not even be checked, and the only way
    /// left could reach another app.
    case failed
}

/// Where a control goes. MediaRemote delivers a command to the app it has elected as
/// now playing: the one that most recently started playing, which it keeps while that
/// app is paused even as another plays on. A targeted send goes there too unless the
/// sender holds MediaRemote's private entitlement, which the adapter's perl does not,
/// or the target is Music, Podcasts or Books. The island can show another app — a
/// player's own notifications, the session the person picked, the last one kept
/// after it went quiet — so a control goes by the app on show, never simply to
/// whatever MediaRemote elected.
enum NowPlayingRouting {
    /// Each control, what decided its way and how it went, under the subsystem
    /// `com.ayush.Islet`, category `NowPlaying`; bundle identifiers only, no titles.
    /// The island's choice is otherwise invisible after the fact, and MediaRemote's
    /// own log only says where a command landed.
    static let log = Logger(subsystem: "com.ayush.Islet", category: "NowPlaying")

    /// The ways to try, in order, for a control on `app`'s session.
    ///
    /// Spotify and Music take Apple Events for what those can carry, whether the
    /// island heard of them through MediaRemote or their own notifications. Any app
    /// then gets MediaRemote, only if it is the elected one; and the plain
    /// MediaRemote send comes last, reached only when the adapter cannot tell which
    /// app is elected. An app MediaRemote does not name has only that plain send:
    /// such a session comes from MediaRemote alone, which is reporting it.
    static func routes(for command: NowPlayingCommand, to app: String?) -> [NowPlayingRoute] {
        guard let app else { return [.mediaRemoteAnyApp] }
        var routes: [NowPlayingRoute] = []
        if let player = NowPlayingBroadcastPlayer(bundleID: app), NowPlayingPlayerControl.carries(command) {
            routes.append(.appleEvents(player))
        }
        routes.append(.mediaRemote(onlyTo: app))
        routes.append(.mediaRemoteAnyApp)
        return routes
    }

    /// Tries `routes` in turn with `send` until one delivers. Only an unavailable way
    /// moves on: a command that reached a player, or that MediaRemote would have
    /// delivered to another app, must not go by another way. `completion` gets the
    /// last way's outcome, and the way itself (`nil` when there were none).
    @MainActor
    static func deliver(
        _ command: NowPlayingCommand, along routes: ArraySlice<NowPlayingRoute>,
        using send: @escaping @MainActor (NowPlayingRoute, NowPlayingCommand, @escaping @MainActor (NowPlayingDelivery) -> Void) -> Void,
        completion: @escaping @MainActor (NowPlayingDelivery, NowPlayingRoute?) -> Void
    ) {
        guard let route = routes.first else {
            completion(.unavailable, nil)
            return
        }
        send(route, command) { delivery in
            if delivery == .unavailable, routes.count > 1 {
                deliver(command, along: routes.dropFirst(), using: send, completion: completion)
            } else {
                completion(delivery, route)
            }
        }
    }
}

extension NowPlayingBroadcastPlayer {
    /// The player with this bundle identifier, if it is one of them.
    init?(bundleID: String) {
        guard let player = Self.allCases.first(where: { $0.bundleID == bundleID }) else { return nil }
        self = player
    }
}
