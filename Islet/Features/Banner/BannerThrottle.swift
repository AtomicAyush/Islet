import Foundation

/// Keeps banners from outside to a pace a person can follow: no more than `limit` in
/// any `window`, and each at least `spacing` after the last, so it is on screen long
/// enough to be read before the next one takes its place.
///
/// A script caught in a loop, or a test runner reporting every file, then gets a
/// banner a second for five seconds and nothing more until ten have passed, rather
/// than an island that flickers for as long as it runs. The feature holds what arrives
/// in between, keeping only the newest, and shows that when the throttle next allows.
///
/// It keeps time by the clock tasks sleep by, which only goes forward. By the wall
/// clock, set back an hour (by hand, or by the network correcting a Mac that drifted),
/// the last banner would seem to have gone up an hour from now, and every banner after
/// it would wait out the hour.
struct BannerThrottle {
    typealias Instant = ContinuousClock.Instant

    let limit: Int
    let window: Duration
    let spacing: Duration
    /// When each banner in the current window went up, oldest first.
    private(set) var shown: [Instant] = []

    init(limit: Int = 5, window: Duration = .seconds(10), spacing: Duration = .seconds(1)) {
        self.limit = max(1, limit)
        self.window = window
        self.spacing = spacing
    }

    /// Whether a banner may go up at `now`. `nil` if it may, and it is counted as shown;
    /// otherwise the moment it could, when nothing else goes up in the meantime.
    mutating func admit(at now: Instant) -> Instant? {
        shown.removeAll { now - $0 >= window }
        var earliest = now
        if let last = shown.last {
            earliest = max(earliest, last + spacing)
        }
        if shown.count >= limit {
            earliest = max(earliest, shown[shown.count - limit] + window)
        }
        guard earliest <= now else { return earliest }
        shown.append(now)
        return nil
    }
}
