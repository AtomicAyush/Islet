import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An item as a drag carries it out of the island, in the kinds a copy puts back on the
/// clipboard (`ClipboardReader.write`), and nothing a copy would not: text as text; a
/// link as a link, with its address as text and its title beside it; a picture as a
/// file of its own kind, for Finder, Mail and upload fields, whose bytes are the
/// picture's data for an app that takes the data, and as TIFF for one that takes
/// nothing else; and files as the files themselves (`FileDrag`).
///
/// A drag from a row carries one thing, so of several files it carries the first still
/// there. A preview's made-up item carries nothing, as a click on it copies nothing,
/// and neither does an item whose files have all gone. Nothing is put on the clipboard.
@MainActor
enum ClipboardDrag {
    static func provider(for item: ClipboardItem, isSample: Bool, files: ClipboardDragFiles = .shared) -> NSItemProvider {
        guard !isSample, let content = carried(item.content) else { return NSItemProvider() }
        switch content {
        case .text(let text):
            return NSItemProvider(object: text as NSString)

        case .link(let url, let title):
            let provider = NSItemProvider(object: url as NSURL)
            provider.registerObject(url.absoluteString as NSString, visibility: .all)
            if let title {
                provider.registerDataRepresentation(forTypeIdentifier: ClipboardReader.urlName.rawValue, visibility: .all) { done in
                    done(Data(title.utf8), nil)
                    return nil
                }
            }
            provider.suggestedName = title
            return provider

        case .image(let image):
            let type = UTType(image.type.rawValue) ?? .png
            let name = pictureName(copiedAt: item.copiedAt, type: type)
            let provider = NSItemProvider()
            // The picture's own kind is a file: written only when the drop asks for it,
            // as the file or as its bytes, and read back for the bytes.
            provider.registerFileRepresentation(for: type, visibility: .all, openInPlace: false) { done in
                do {
                    done(try files.write(image.data, named: name), false, nil)
                } catch {
                    done(nil, false, error)
                }
                return nil
            }
            provider.registerDataRepresentation(for: .tiff, visibility: .all) { done in
                done(tiffData(image.data), nil)
                return nil
            }
            provider.suggestedName = name
            return provider

        case .files(let urls):
            return FileDrag.provider(for: urls[0])
        }
    }

    /// What a drag of `content` carries: the content as it is, but for files, of which
    /// the first still there, and `nil` when none is.
    nonisolated static func carried(_ content: ClipboardContent) -> ClipboardContent? {
        guard case .files(let urls) = content else { return content }
        return urls.first { FileManager.default.fileExists(atPath: $0.path) }.map { .files([$0]) }
    }

    /// "Image 2026-09-29 at 14.03.12.png": when it was copied, as a screenshot is named.
    nonisolated static func pictureName(copiedAt: Date, type: UTType) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Image \(formatter.string(from: copiedAt)).\(type.preferredFilenameExtension ?? "png")"
    }

    /// The picture as TIFF, for an app that takes pictures in no other kind.
    nonisolated static func tiffData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Pictures written out for drags that want a file. Each goes in a folder of its own,
/// so two drops of pictures copied in the same second do not meet, inside one only
/// this user can open, in the temporary folder. A picture is written only as the drop
/// asks for it, and removed `lifetime` later, by when the app it went to has long made
/// its own copy; any left behind when Islet quit go as the feature next starts or
/// stops.
final class ClipboardDragFiles: @unchecked Sendable {
    static let shared = ClipboardDragFiles(
        folder: FileManager.default.temporaryDirectory.appendingPathComponent("Islet Clipboard Drags", isDirectory: true)
    )

    let folder: URL
    let lifetime: TimeInterval
    private let queue = DispatchQueue(label: "com.ayush.Islet.clipboard.drags", qos: .utility)

    /// `folder` and `lifetime` are the tests'; Islet uses `shared`.
    init(folder: URL, lifetime: TimeInterval = 15 * 60) {
        self.folder = folder
        self.lifetime = lifetime
    }

    /// Writes `data` as `name`, readable only by this user, and returns where.
    func write(_ data: Data, named name: String) throws -> URL {
        let manager = FileManager.default
        let own = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: own, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Made before, perhaps by a copy of Islet that did not restrict it.
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let url = own.appendingPathComponent(name)
        guard manager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            try? manager.removeItem(at: own)
            throw CocoaError(.fileWriteUnknown)
        }
        queue.asyncAfter(deadline: .now() + lifetime) {
            try? manager.removeItem(at: own)
        }
        return url
    }

    /// Removes every picture written for a drag, off the main thread.
    func removeAll() {
        let folder = folder
        queue.async {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Waits for removals under way, for tests.
    func settle() {
        queue.sync {}
    }
}
