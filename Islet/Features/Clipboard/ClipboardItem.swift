import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// One thing copied, as the history keeps it.
struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    var content: ClipboardContent
    /// The app it was copied from, when that could be told.
    var source: ClipboardSource?
    /// When it was last copied: the first time, or since, if it was copied again.
    var copiedAt: Date
    var isPinned = false

    init(id: UUID = UUID(), content: ClipboardContent, source: ClipboardSource?, copiedAt: Date, isPinned: Bool = false) {
        self.id = id
        self.content = content
        self.source = source
        self.copiedAt = copiedAt
        self.isPinned = isPinned
    }
}

/// What was copied. Only what it takes to put the copy back is kept: the plain text of
/// formatted text, a link's address and title, a picture's data, and where files are,
/// never the files themselves.
enum ClipboardContent: Equatable {
    case text(String)
    case link(URL, title: String?)
    case image(ClipboardImage)
    case files([URL])

    /// Whether `other` is this copied again. A link is the same link under another
    /// title; a picture is the same picture when its bytes are.
    func isSame(as other: ClipboardContent) -> Bool {
        switch (self, other) {
        case let (.text(a), .text(b)): a == b
        case let (.link(a, _), .link(b, _)): a == b
        case let (.image(a), .image(b)): a.digest == b.digest
        case let (.files(a), .files(b)): a.map(\.standardizedFileURL.path) == b.map(\.standardizedFileURL.path)
        default: false
        }
    }

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

/// The app something was copied from.
struct ClipboardSource: Equatable {
    var bundleIdentifier: String?
    var name: String

    init(bundleIdentifier: String?, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    init?(_ app: NSRunningApplication?) {
        guard let app else { return nil }
        self.init(bundleIdentifier: app.bundleIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "")
    }

    /// The app with this bundle identifier, named as Finder names it, for a source an
    /// app declares on the pasteboard rather than the app in front.
    init?(installedApp bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty else { return nil }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map {
            FileManager.default.displayName(atPath: $0.path)
        }
        self.init(
            bundleIdentifier: bundleIdentifier,
            name: name.map { ($0 as NSString).deletingPathExtension } ?? bundleIdentifier
        )
    }
}

/// A copied picture: the bytes that go back on the clipboard, and a small copy of it
/// for the list. Made once, off the main thread, and never changed, so it is shared
/// freely between threads.
final class ClipboardImage: Equatable, @unchecked Sendable {
    /// The picture as it goes back on the clipboard, in `type`.
    let data: Data
    let type: NSPasteboard.PasteboardType
    /// Its size in pixels, the right way up.
    let pixelSize: CGSize
    /// About twice the size a row draws it, for a Retina screen.
    let thumbnail: CGImage?
    /// SHA-256 of `data`, so a picture copied twice is kept once.
    let digest: String

    init(data: Data, type: NSPasteboard.PasteboardType, pixelSize: CGSize, thumbnail: CGImage?, digest: String) {
        self.data = data
        self.type = type
        self.pixelSize = pixelSize
        self.thumbnail = thumbnail
        self.digest = digest
    }

    static func == (a: ClipboardImage, b: ClipboardImage) -> Bool { a.digest == b.digest }

    /// The longest side of a thumbnail, in pixels.
    static let thumbnailPixels = 128

    /// Makes the kept copy of a picture read off the pasteboard, or `nil` when the
    /// bytes are not a picture ImageIO can read. TIFF, which apps put on the clipboard
    /// uncompressed (a Retina screenshot runs to 20 MB or more), is kept as PNG, which
    /// every app that takes a TIFF takes as well. Slow for a large picture: call it
    /// off the main thread.
    static func make(data: Data, type: NSPasteboard.PasteboardType) -> ClipboardImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }

        var kept = data
        var keptType = type
        if type == .tiff {
            guard let png = pngData(from: source) else { return nil }
            kept = png
            keptType = .png
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Orientations 5 to 8 turn the picture on its side.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let isTurned = (5...8).contains(orientation)

        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ] as CFDictionary)

        return ClipboardImage(
            data: kept,
            type: keptType,
            pixelSize: isTurned ? CGSize(width: height, height: width) : CGSize(width: width, height: height),
            thumbnail: thumbnail,
            digest: SHA256.hash(data: kept).map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func pngData(from source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
