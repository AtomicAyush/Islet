import Foundation

/// How browsers name a download while it is still arriving, and the words the island
/// uses for how much has come, how fast and how long is left.
///
/// Every browser writes a download under a name of its own until it is complete, then
/// gives it its real one: Safari and other WebKit browsers into a `.download` bundle
/// holding the file and a note of where it came from; Chrome, Arc, Edge, Brave and the
/// rest of Chromium into `.crdownload` (Opera once used `.opdownload`); Firefox into
/// `.part`, beside an empty file under the real name.
enum DownloadNames {
    static let partialExtensions: Set<String> = ["download", "crdownload", "opdownload", "part"]

    static func isPartial(_ url: URL) -> Bool {
        partialExtensions.contains(url.pathExtension.lowercased())
    }

    /// The partial item a URL is, or is directly inside (the file in Safari's bundle),
    /// or `nil` for a URL that is neither: a file an app writes under its real name.
    static func partialItem(containing url: URL) -> URL? {
        let url = url.standardizedFileURL
        if isPartial(url) { return url }
        let parent = url.deletingLastPathComponent()
        return isPartial(parent) ? parent : nil
    }

    /// Where the download will be once it is complete: the partial item's name without
    /// its extension, beside it. A URL that is not a partial item is the file itself.
    static func finalURL(for url: URL) -> URL {
        guard let partial = partialItem(containing: url) else { return url.standardizedFileURL }
        return partial.deletingPathExtension()
    }

    /// The finished file's name, which is what the island calls a download.
    static func displayName(for url: URL) -> String {
        finalURL(for: url).lastPathComponent
    }

    /// Whether two URLs are the same download: the same item, or one inside the other
    /// (Safari's bundle and the file in it).
    static func sameDownload(_ a: URL, _ b: URL) -> Bool {
        let a = a.standardizedFileURL.path, b = b.standardizedFileURL.path
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    // MARK: Words

    /// "12.4 MB", as Finder writes sizes.
    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, count))
    }

    /// "12.4 MB of 85.1 MB", or just "12.4 MB" while the size is not known.
    static func progress(received: Int64, total: Int64?) -> String {
        guard let total, total > 0 else { return bytes(received) }
        return "\(bytes(min(received, total))) of \(bytes(total))"
    }

    /// "3.2 MB/s".
    static func speed(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(bytesPerSecond.rounded())))/s"
    }

    /// "8 sec left", "3 min left", "1 hr, 20 min left": seconds only under a minute, and
    /// rounded up, so the last minute reads "1 min" until it is under one, and the last
    /// seconds never read "0 sec".
    static func timeLeft(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= 0, seconds < 100 * 3600 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        let wholeSeconds = max(1, seconds.rounded(.up))
        let rounded: TimeInterval
        if wholeSeconds < 60 {
            formatter.allowedUnits = [.second]
            rounded = wholeSeconds
        } else {
            let minutes = (wholeSeconds / 60).rounded(.up)
            formatter.allowedUnits = minutes < 60 ? [.minute] : [.hour, .minute]
            formatter.maximumUnitCount = 2
            rounded = minutes * 60
        }
        return formatter.string(from: rounded).map { "\($0) left" }
    }
}
