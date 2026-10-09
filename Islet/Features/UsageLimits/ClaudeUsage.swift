import Foundation

/// Claude's limits, from two places, neither a sign-in of Islet's own.
///
/// The Claude app keeps its plan's usage in `plan-usage-history.json`, beside its other
/// files: a sample each time it asks Anthropic, every 15 minutes while it runs (every 5
/// for half an hour after it is used), kept for 30 days. Each sample has the time, the
/// organisation and how much of each window is used, but not when the windows reset; the
/// newest sample's organisation is the one shown. When the five-hour window resets is
/// worked out from the samples: it starts with the first use after it last emptied or
/// reset, so it resets at the latest five hours after the first sample to show any use.
/// The week likewise, or not at all where the samples cannot tell. The file is the app's
/// own and private to it: only version 2, the one read here, is understood, and anything
/// else shows nothing.
///
/// Quick Ask's runs of Claude's command line tool say the exact numbers and resets as
/// they answer (`rate_limit_event`), which win over the app's samples while newer; an
/// exact reset still to come replaces the worked-out one. Claude Code's StopFailure hook
/// says when a turn was turned away at the limit, though not which window's.
enum ClaudeUsage {
    static let fileName = "plan-usage-history.json"

    /// The Claude app's folder.
    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Claude", isDirectory: true)
    }

    /// The windows the samples name, by their keys: five hours, and the week.
    static let windows: [(key: String, minutes: Int)] = [("fh", 300), ("sd", 10080)]
    /// The longest gap between the last empty sample and the first in use that still
    /// says when a window began, as a share of its length.
    static let gapShare = 0.2
    /// How far a figure must fall to say its window reset, where nothing says when the
    /// window began: it can dip a few points within one.
    static let resetFall: Double = 5

    /// What the file says.
    enum History: Equatable, Sendable {
        /// No file: the Claude app is not installed, or has not yet asked.
        case missing
        /// A file of another version or shape.
        case unknownFormat
        case read(HistoryReading)

        var reading: HistoryReading? {
            if case .read(let reading) = self { return reading }
            return nil
        }
    }

    struct HistoryReading: Equatable, Sendable {
        /// The newest sample's time.
        var measured: Date
        var organisation: String?
        /// Shortest first; only those the newest sample has.
        var windows: [UsageWindow]
        var samples: Int
    }

    /// Reads the file at `url`. Called off the main thread.
    static func readHistory(_ url: URL) -> History {
        guard let data = try? Data(contentsOf: url) else {
            return FileStamp.isThere(url) ? .unknownFormat : .missing
        }
        return parseHistory(data)
    }

    static func parseHistory(_ data: Data) -> History {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int, version == 2,
              let list = object["samples"] as? [Any]
        else { return .unknownFormat }
        struct Sample {
            var time: Date
            var organisation: String?
            var values: [String: Double]
        }
        var samples: [Sample] = []
        for entry in list {
            guard let entry = entry as? [String: Any], let t = entry["t"] as? Double, t.isFinite,
                  let usage = entry["u"] as? [String: Any]
            else { continue }
            let organisation = entry["org"] as? String
            var values: [String: Double] = [:]
            for (key, value) in usage {
                if let number = value as? Double, number.isFinite { values[key] = number }
            }
            samples.append(Sample(time: Date(timeIntervalSince1970: t / 1000), organisation: organisation, values: values))
        }
        samples.sort { $0.time < $1.time }
        guard let newest = samples.last else { return .unknownFormat }
        let mine = samples.filter { $0.organisation == newest.organisation }
        var windows: [UsageWindow] = []
        for (key, minutes) in Self.windows {
            guard let percent = newest.values[key] else { continue }
            let series = mine.compactMap { sample in sample.values[key].map { (time: sample.time, value: $0) } }
            let resets = estimatedReset(series, length: TimeInterval(minutes) * 60)
            windows.append(UsageWindow(minutes: minutes, percent: percent, resets: resets, resetIsEstimate: resets != nil))
        }
        return .read(HistoryReading(measured: newest.time, organisation: newest.organisation, windows: windows,
                                    samples: samples.count))
    }

    /// When the window the newest sample is in resets, at the latest: its length after
    /// the first sample to show it in use. A window begins with the first use after one
    /// that showed it empty, or after the one before it reset, which a fall in the figure
    /// shows. The window before began after the sample ahead of its own first, so it
    /// cannot reset until its length after that; a fall before then is the figure
    /// dipping within it, as it can by a point or two. One that has run its whole length
    /// without a fall has reset unseen. Where nothing says when the window before began,
    /// only a fall of `resetFall` points or half the figure counts.
    ///
    /// `nil` while it is unused, where the samples begin in it, where too long passed
    /// unsampled to tell when it began, or where the answer would put the reset before
    /// the newest sample.
    static func estimatedReset(_ series: [(time: Date, value: Double)], length: TimeInterval) -> Date? {
        guard let last = series.last, last.value > 0 else { return nil }
        // The first sample in use of the window each sample is in, where it can be told.
        var first: Int?
        for index in series.indices.dropFirst() {
            let (time, value) = series[index]
            let previous = series[index - 1]
            guard value > 0 else {
                first = nil
                continue
            }
            if previous.value <= 0 {
                first = index
                continue
            }
            let fell = value < previous.value
            guard let begun = first else {
                if fell, value <= previous.value - resetFall || value <= previous.value / 2 { first = index }
                continue
            }
            // When the window `begun` is in can reset: after its length from the sample
            // before it, and by its length from `begun` itself.
            let earliest = series[begun - 1].time.addingTimeInterval(length)
            let latest = series[begun].time.addingTimeInterval(length)
            guard time > earliest else { continue }
            if fell || (time >= latest && previous.time <= earliest) {
                first = index
            } else if time >= latest {
                first = nil
            }
        }
        guard let first, first > 0,
              series[first].time.timeIntervalSince(series[first - 1].time) <= length * gapShare
        else { return nil }
        let resets = series[first].time.addingTimeInterval(length)
        return resets > last.time ? resets : nil
    }

    // MARK: Quick Ask

    /// What a `rate_limit_event` line of Claude's `stream-json` says: each window's use
    /// and reset where it names them, and whether the request was turned away.
    struct LimitEvent: Equatable, Sendable {
        var at: Date
        var windows: [UsageWindow]
        /// Turned away at the limit (`status` "rejected").
        var rejected: Bool
    }

    /// The windows a `rateLimitType` or `unifiedWindows` key stands for: the five hours
    /// and the week across every model. The per-model weeks are not shown.
    static let eventWindows = ["five_hour": 300, "seven_day": 10080]

    /// The event in a line already read as JSON, `nil` for any other line. Utilisation
    /// comes as a fraction, resets as seconds since 1970. Every window the line names,
    /// from `unifiedWindows` where it has them, else the one the event is about.
    static func limitEvent(_ object: [String: Any], at date: Date) -> LimitEvent? {
        guard object["type"] as? String == "rate_limit_event",
              let info = object["rate_limit_info"] as? [String: Any]
        else { return nil }
        func window(_ minutes: Int, _ fields: [String: Any]?, utilization: String, resets: String) -> UsageWindow? {
            guard let fields, let fraction = fields[utilization] as? Double, fraction.isFinite else { return nil }
            let seconds = fields[resets] as? Double
            // Rounded to a tenth, so 0.29 is 29%, not the 28.999… multiplying makes it.
            let percent = (fraction * 1000).rounded() / 10
            return UsageWindow(minutes: minutes, percent: min(100, max(0, percent)),
                               resets: seconds.map { Date(timeIntervalSince1970: $0) })
        }
        var windows: [UsageWindow] = []
        if let unified = info["unifiedWindows"] as? [String: Any] {
            for (key, minutes) in eventWindows.sorted(by: { $0.value < $1.value }) {
                if let found = window(minutes, unified[key] as? [String: Any], utilization: "utilization", resets: "resetsAt") {
                    windows.append(found)
                }
            }
        }
        if windows.isEmpty, let type = info["rateLimitType"] as? String, let minutes = eventWindows[type],
           let found = window(minutes, info, utilization: "utilization", resets: "resetsAt") {
            windows.append(found)
        }
        let rejected = info["status"] as? String == "rejected"
        guard !windows.isEmpty || rejected else { return nil }
        return LimitEvent(at: date, windows: windows, rejected: rejected)
    }

    // MARK: Together

    /// The reading the island shows as of `now`: the app's newest sample, with Quick
    /// Ask's numbers where they are newer and its resets where they are still to come,
    /// and the limit as last said reached. Where Quick Ask named only some windows, the
    /// reading stays as old as the sample, and those keep their own time. `nil` with
    /// nothing to go on, as once a limit said reached with no figures has lapsed.
    static func reading(history: HistoryReading?, event: LimitEvent?, limitHit: Date?, now: Date) -> UsageReading? {
        var windows = history?.windows ?? []
        var measured = history?.measured
        if let event {
            let newer = measured.map { event.at > $0 } ?? true
            for var told in event.windows {
                told.measured = event.at
                if let index = windows.firstIndex(where: { $0.span == told.span }) {
                    if newer {
                        windows[index] = told
                    } else if let resets = told.resets, let measured, resets > measured {
                        // Still the window the sample is in: its exact reset.
                        windows[index].resets = resets
                        windows[index].resetIsEstimate = false
                    }
                } else if newer {
                    windows.append(told)
                }
            }
            windows.sort { $0.minutes < $1.minutes }
            if newer, measured == nil || windows.allSatisfy({ $0.measured != nil }) { measured = event.at }
        }
        // A figure as old as the reading has no time of its own.
        for index in windows.indices where windows[index].measured.map({ $0 <= measured ?? $0 }) ?? false {
            windows[index].measured = nil
        }
        var limitSince = [limitHit, event.flatMap { $0.rejected ? $0.at : nil }].compactMap { $0 }.max()
        // A newer reading with room left in every window says the limit has lifted.
        if let since = limitSince, let measured, measured > since, !windows.isEmpty, windows.allSatisfy({ $0.percent < 100 }) {
            limitSince = nil
        }
        let holds = limitSince.map { now < $0.addingTimeInterval(UsageStatus.limitHold) } ?? false
        guard !windows.isEmpty || holds, let when = measured ?? limitSince else { return nil }
        return UsageReading(agent: .claude, measured: when, windows: windows, limitSince: limitSince)
    }
}
