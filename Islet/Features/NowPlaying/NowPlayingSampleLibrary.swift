import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The library the previews show: made-up songs and playlists, handed over after a
/// moment as a real library's would be. It speaks for no app and never talks to
/// one; playing something only changes its own lists.
@MainActor
final class NowPlayingSampleLibrary: MediaLibrary {
    let bundleIdentifiers: Set<String> = []
    let displayName = "Sample"
    let state = MediaLibraryState.ready
    let capabilities: MediaLibraryCapabilities = [.upNext, .playFromQueue, .playlists, .listeningTogether]

    /// Each preview starts from the full lists.
    private var queue = NowPlayingSampleLibrary.sampleQueue
    private var lists = NowPlayingSampleLibrary.samplePlaylists

    /// Long enough to see the panel load.
    private static let delay = Duration.milliseconds(450)

    func connect() {}

    func upNext() async throws -> [MediaItem] {
        try await Task.sleep(for: Self.delay)
        return queue
    }

    func playlists() async throws -> [MediaPlaylist] {
        try await Task.sleep(for: Self.delay)
        return lists
    }

    func play(_ playlist: MediaPlaylist) async throws {
        try await Task.sleep(for: Self.delay)
        for index in lists.indices {
            lists[index].isCurrent = lists[index].id == playlist.id
        }
    }

    func playFromQueue(_ item: MediaItem, at index: Int) async throws {
        try await Task.sleep(for: Self.delay)
        queue.removeFirst(min(index + 1, queue.count))
    }

    // MARK: Samples

    /// Drawn once, the first time a preview asks.
    private static let sampleQueue: [MediaItem] = ([
        ("Harbour Lights", "Neon Harbour", 0.92, 204),
        ("Paper Planes Over Lisbon", "Juniper & the Tides", 0.52, 245),
        ("Slow Tram Home", "The Late Arrivals", 0.08, 188),
        ("Glasshouse", "Mara Vey", 0.33, 231),
        ("Northbound", "Neon Harbour", 0.62, 197),
        ("Tidal", "Juniper & the Tides", 0.47, 262),
        ("Afterglow Avenue", "Sunset Committee", 0.02, 215),
        ("Quiet Machines", "Mara Vey", 0.74, 179),
    ] as [(String, String, CGFloat, TimeInterval)]).enumerated().map { index, song in
        MediaItem(
            id: "sample.song.\(index)", title: song.0, subtitle: song.1,
            artworkURL: cover(hue: song.2), duration: song.3
        )
    }

    private static let samplePlaylists: [MediaPlaylist] = ([
        ("Night Drive", "32 songs", 0.8),
        ("Sunday Morning", "18 songs", 0.12),
        ("Deep Focus", "64 songs", 0.55),
        ("Running Club", "40 songs", 0.0),
        ("Liked Songs", "512 songs", 0.7),
        ("Road Trip 2026", "27 songs", 0.3),
    ] as [(String, String, CGFloat)]).enumerated().map { index, playlist in
        MediaPlaylist(
            id: "sample.playlist.\(index)", name: playlist.0, detail: playlist.1,
            artworkURL: cover(hue: playlist.2), isCurrent: index == 0
        )
    }

    /// A small two-tone cover as a `data:` URL, so the panel loads it the way it
    /// loads real artwork, with nothing on disk or on the network.
    private static func cover(hue: CGFloat) -> URL? {
        let side = 60
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.45, alpha: 1).cgColor
        guard let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: nil) else { return nil }
        let size = CGFloat(side)
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 0.28))
        context.fillEllipse(in: CGRect(x: size * 0.3, y: size * 0.3, width: size * 0.4, height: size * 0.4))

        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return URL(string: "data:image/png;base64," + (data as Data).base64EncodedString())
    }
}
