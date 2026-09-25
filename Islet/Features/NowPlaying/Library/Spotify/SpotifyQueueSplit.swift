import Foundation

/// Where Spotify's queue turns from songs the person queued into the rest of what
/// is playing.
///
/// `GET /me/player/queue` gives both in one list, queued songs first, with nothing
/// to say where they end. The playlist or album playing does: past the split, the
/// queue is what follows in it. Songs Islet queued itself are a second clue, and
/// the only one when what is playing cannot be read.
struct SpotifyQueueSplit {
    /// A track of the playlist or album playing, as far as matching needs it.
    struct Track: Equatable {
        /// Its URI and, when Spotify has swapped in another release of it that plays
        /// here, the original's: the queue may give either.
        var uris: [String]
        /// Unplayable here, or a local file this Mac may not have, so the player may
        /// pass over it.
        var mayBeSkipped = false

        func matches(_ uri: String) -> Bool { uris.contains(uri) }
    }

    /// How what is playing plays.
    enum Order: Equatable {
        /// In its own order, starting again at the end when it `repeats`.
        case listed(repeats: Bool)
        /// Shuffled, in an order only Spotify knows.
        case shuffled
    }

    /// How much more of what is playing is worth reading.
    enum Reading: Equatable {
        case enough
        /// The likeliest split runs on into the part not read yet.
        case next
        /// Nothing found yet, or all of it is needed.
        case rest
    }

    struct Outcome: Equatable {
        /// How many songs at the head of the queue were queued; nil when it cannot
        /// be told.
        var queued: Int?
        var reading: Reading
    }

    /// The queue's URIs, in the order they will play.
    var queue: [String]
    /// What is playing now.
    var current: String?
    /// Songs Islet queued and has not seen play yet.
    var hinted: [String]

    /// The split going by the hints alone: songs Islet queued, at the head of the
    /// queue. nil when there are none there.
    var byHints: Int? {
        let count = hintedHead
        return count > 0 ? count : nil
    }

    /// The split going by `tracks`, which are all of what is playing when
    /// `isComplete` and otherwise its start; by the hints when they tell nothing.
    func split(by tracks: [Track], isComplete: Bool, order: Order) -> Outcome {
        guard !queue.isEmpty else { return Outcome(queued: nil, reading: .enough) }
        switch order {
        case .shuffled:
            guard isComplete else { return Outcome(queued: byHints, reading: .rest) }
            return Outcome(queued: byMembership(tracks) ?? byHints, reading: .enough)
        case .listed(let repeats):
            guard let best = byOrder(tracks, isComplete: isComplete, repeats: repeats) else {
                return Outcome(queued: byHints, reading: isComplete ? .enough : .rest)
            }
            return Outcome(queued: best.queued, reading: best.runsOn ? .next : .enough)
        }
    }

    /// How many copies of each URI there are, for matching copy by copy.
    static func counts(_ uris: some Sequence<String>) -> [String: Int] {
        uris.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    // MARK: Hints

    /// Songs at the head of the queue that Islet queued, counting the first copies
    /// of each, since a queued song plays before the playlist's own.
    private var hintedHead: Int {
        var left = Self.counts(hinted)
        var count = 0
        for uri in queue {
            guard let copies = left[uri], copies > 0 else { break }
            left[uri] = copies - 1
            count += 1
        }
        return count
    }

    // MARK: Shuffled

    /// Shuffled, the order is Spotify's secret, but queued songs still come first:
    /// the queue up to the first song of the playlist was queued, as was a song
    /// Islet queued though the playlist has it too. With nothing of the playlist
    /// after them they may as well be autoplay's, and it cannot be told.
    private func byMembership(_ tracks: [Track]) -> Int? {
        let listed = Set(tracks.flatMap(\.uris))
        var left = Self.counts(hinted)
        for (index, uri) in queue.enumerated() {
            if let copies = left[uri], copies > 0 {
                left[uri] = copies - 1
            } else if listed.contains(uri) {
                return index
            }
        }
        return nil
    }

    // MARK: In order

    private struct Candidate {
        /// Songs before the split.
        var queued: Int
        /// Songs of the queue it cannot find in the playlist (queued ones, and
        /// autoplay's past the end), plus any song Islet queued that it puts after
        /// the split: the lower, the likelier.
        var cost: Int
        /// It picks up right after the song playing, rather than where the playlist
        /// was left for a queued song that is playing now.
        var followsCurrent: Bool
        /// It runs on past the tracks read so far.
        var runsOn: Bool

        func isLikelier(than other: Candidate) -> Bool {
            if cost != other.cost { return cost < other.cost }
            if followsCurrent != other.followsCurrent { return followsCurrent }
            return queued < other.queued
        }
    }

    /// In order, the songs after the split are those that follow in the playlist:
    /// usually after the song playing, but while a queued song plays, after
    /// wherever the playlist was left, which only the queue itself shows. Of every
    /// reading, the one that finds most of the queue in the playlist wins, and on a
    /// tie the one that follows the song playing.
    ///
    /// Picking up anywhere else rests on the queue alone, and the queue's last song
    /// always matches itself, so it takes a run of two, or one song that ends the
    /// playlist before autoplay's: otherwise a playlist played in an order of the
    /// person's choosing (sorted by title, say, which the Web API does not say)
    /// would pass nearly all of its queue off as queued.
    private func byOrder(_ tracks: [Track], isComplete: Bool, repeats: Bool) -> Candidate? {
        var positions: [String: [Int]] = [:]
        for (index, track) in tracks.enumerated() {
            for uri in Set(track.uris) { positions[uri, default: []].append(index) }
        }
        let afterCurrent = Set((current.flatMap { positions[$0] } ?? []).map { $0 + 1 })
        let head = hintedHead
        var best: Candidate?
        for split in queue.indices {
            for start in afterCurrent.union(positions[queue[split]] ?? []).sorted() {
                let followsCurrent = afterCurrent.contains(start)
                guard let walk = follow(tracks, listed: positions, from: start, queueFrom: split, isComplete: isComplete, repeats: repeats),
                      walk.matched + walk.unread >= (followsCurrent || walk.endsPlaylist ? 1 : 2) else { continue }
                let candidate = Candidate(
                    queued: split,
                    // Songs not read yet count as found, so a reading is not
                    // passed over for running into them.
                    cost: queue.count - walk.matched - walk.unread + max(0, head - split),
                    followsCurrent: followsCurrent,
                    runsOn: walk.unread > 0
                )
                if best.map({ candidate.isLikelier(than: $0) }) ?? true { best = candidate }
            }
        }
        return best
    }

    private struct Walk {
        /// Songs of the queue found in the playlist.
        var matched: Int
        /// Songs of the queue past the tracks read so far.
        var unread: Int
        /// The playlist ends within the queue, and autoplay's songs follow.
        var endsPlaylist = false
    }

    /// Follows the queue from `split` through the tracks from `start`, passing over
    /// any the player may skip. nil when the two part ways. Running out of tracks
    /// is not parting: autoplay carries on after the end, and past what has been
    /// read, the rest is not known yet. `listed` holds every URI of the tracks.
    private func follow(
        _ tracks: [Track], listed: [String: [Int]], from start: Int, queueFrom split: Int, isComplete: Bool, repeats: Bool
    ) -> Walk? {
        var track = start
        var entry = split
        var matched = 0
        var laps = 0
        while entry < queue.count {
            if track == tracks.count {
                guard isComplete else { return Walk(matched: matched, unread: queue.count - entry) }
                // Repeating, it starts again. The lap count stops a list of
                // skippable tracks going round for ever.
                if repeats, laps < queue.count {
                    track = 0
                    laps += 1
                    continue
                }
                // Autoplay's songs are its own. Songs of the playlist after its end
                // mean it is not playing in this order.
                guard !queue[entry...].contains(where: { listed[$0] != nil }) else { return nil }
                return Walk(matched: matched, unread: 0, endsPlaylist: true)
            }
            if tracks[track].matches(queue[entry]) {
                matched += 1
                entry += 1
            } else if !tracks[track].mayBeSkipped {
                return nil
            }
            track += 1
        }
        return Walk(matched: matched, unread: 0)
    }
}

/// Songs Islet queued with Play Next this session, until they are seen to play: a
/// song Islet queued is queued, whatever the playlist says.
struct SpotifyQueueHints {
    /// A song just queued can be missing from the queue for a moment, while
    /// Spotify passes it on to the device playing.
    static let grace: TimeInterval = 10

    private var entries: [(uri: String, queuedAt: Date)] = []
    private var lastPlaying: String?

    /// Oldest first.
    var uris: [String] { entries.map(\.uri) }

    mutating func add(_ uri: String, at date: Date = .now) {
        entries.append((uri, date))
    }

    /// A song Islet queued that has started playing has left the queue. Only a
    /// change of song counts, so one queued while the same song was playing is not
    /// taken for it.
    mutating func notePlaying(_ uri: String?) {
        defer { lastPlaying = uri }
        guard let uri, uri != lastPlaying,
              let index = entries.firstIndex(where: { $0.uri == uri }) else { return }
        entries.remove(at: index)
    }

    /// Keeps the hints for songs among `queued`, the head of the queue, and those
    /// too new to show there yet.
    mutating func keep(queued: some Sequence<String>, now: Date = .now) {
        var left = SpotifyQueueSplit.counts(queued)
        entries = entries.filter { entry in
            if let copies = left[entry.uri], copies > 0 {
                left[entry.uri] = copies - 1
                return true
            }
            return now.timeIntervalSince(entry.queuedAt) < Self.grace
        }
    }
}

/// A playlist or album whose tracks Up Next can read: the person's own playlists
/// or ones they collaborate on (all a Development Mode app may read since
/// February 2026), and albums. An artist, a show or Liked Songs is not one.
enum SpotifyTrackSource: Equatable {
    case playlist(id: String)
    case album(id: String)

    /// From `spotify:playlist:<id>` (or the older `spotify:user:<owner>:playlist:<id>`)
    /// or `spotify:album:<id>`.
    init?(contextURI: String) {
        let parts = contextURI.split(separator: ":")
        guard parts.count >= 3, parts[0] == "spotify",
              let id = parts.last, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        switch parts[parts.count - 2] {
        case "playlist": self = .playlist(id: String(id))
        case "album": self = .album(id: String(id))
        default: return nil
        }
    }
}

/// What has been read of a playlist or album, kept for the session so opening Up
/// Next again reads nothing new unless the playlist has changed.
struct SpotifyTrackListing {
    /// One page of it.
    struct Page {
        var offset: Int
        var limit: Int
        var total: Int
        var tracks: [SpotifyQueueSplit.Track]
    }

    static let pageSize = 50
    /// Read no further: a longer playlist is split by its start, or by hints alone
    /// when shuffled, rather than costing dozens of requests.
    static let longest = 1_000

    var name: String?
    /// The playlist's version when read; albums do not change.
    var snapshot: String?
    /// False when Spotify will not list it: someone else's playlist, or one of its
    /// own mixes.
    var isReadable: Bool
    private(set) var tracks: [SpotifyQueueSplit.Track] = []
    private(set) var nextOffset = 0
    /// Entries in all, once a page has said.
    private(set) var total: Int?

    init(name: String?, snapshot: String? = nil, isReadable: Bool = true) {
        self.name = name
        self.snapshot = snapshot
        self.isReadable = isReadable
    }

    var isComplete: Bool { total.map { nextOffset >= $0 } ?? false }
    var canReadMore: Bool { isReadable && !isComplete && nextOffset < Self.longest }
    /// It is short enough to read all of, as far as is known yet.
    var fitsWhole: Bool { total.map { $0 <= Self.longest } ?? true }

    /// Where the next `count` pages start: only the next one while the length is
    /// not known.
    func nextPages(_ count: Int) -> [Int] {
        guard let total else { return [nextOffset] }
        return Array(stride(from: nextOffset, to: min(total, Self.longest), by: Self.pageSize).prefix(count))
    }

    /// Adds `page` if it is the one that comes next, and says whether it was.
    mutating func add(_ page: Page) -> Bool {
        guard page.offset == nextOffset else { return false }
        tracks += page.tracks
        nextOffset = page.offset + max(page.limit, 1)
        total = page.total
        return true
    }
}
