import AppKit
import CryptoKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A screenshot the island is showing: the file, and a small picture of it made as it
/// arrived, so the card never waits on a large image.
struct Screenshot: Equatable {
    var url: URL
    var thumbnail: NSImage
    /// The screenshot's size in pixels, when it could be read.
    var pixelSize: CGSize?
    /// Where it was saved, in a word: "Desktop". A sample says so instead.
    var place: String
    /// A made-up screenshot a preview put up: Delete leaves it be.
    var isSample = false
    /// The file as it was when the card was made, so Delete after Copying deletes only
    /// that file; `nil` when it could not be read.
    var file: ScreenshotFileStamp?
}

/// A screenshot's file as it was when its card was made: which file it is on its disk,
/// its size, when it was last changed, and the folder it is in. Delete after Copying
/// deletes a file only while all of these still hold, so a screenshot moved away,
/// replaced by another file or a symbolic link, or changed since, is left alone.
struct ScreenshotFileStamp: Equatable {
    var device: Int64
    var inode: UInt64
    var size: Int64
    var modified: TimeInterval
    /// The folder, with any symbolic links in its path followed.
    var folder: String

    /// `nil` for anything but a plain file: a folder, or a symbolic link, which is not
    /// followed.
    static func read(_ url: URL) -> ScreenshotFileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return ScreenshotFileStamp(
            device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            modified: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            folder: url.deletingLastPathComponent().resolvingSymlinksInPath().path
        )
    }
}

/// Recognising screenshots, and what the card does with one.
enum ScreenshotFiles {
    /// macOS tags every screenshot it saves with this attribute, which is where Spotlight
    /// reads `kMDItemIsScreenCapture` from; it holds a property list `true`.
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    /// Whether the file carries macOS's screenshot tag. The tag is written a moment
    /// after the file itself, so a file just made may not have it yet.
    static func isScreenCapture(_ url: URL) -> Bool {
        let path = url.path
        let length = getxattr(path, screenCaptureAttribute, nil, 0, 0, 0)
        guard length > 0, length < 4096 else { return false }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(path, screenCaptureAttribute, buffer.baseAddress, length, 0, 0)
        }
        guard read > 0,
              let value = try? PropertyListSerialization.propertyList(from: data.prefix(read), format: nil)
        else { return false }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    /// Whether the file is a picture macOS might have saved a screenshot as: PNG by
    /// default, or JPEG, HEIC, TIFF or PDF where the format has been changed.
    static func isPicture(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    /// Two copies of one screenshot (one dragged to another folder, say) share this: a
    /// copy keeps the original's creation date and size.
    static func identity(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]),
              let created = values.creationDate, let size = values.fileSize
        else { return nil }
        return "\(Int64((created.timeIntervalSinceReferenceDate * 1000).rounded()))-\(size)"
    }

    // MARK: Pictures

    /// A picture of the screenshot no wider or taller than `maxPixelSize`, and the
    /// screenshot's own size. `nil` for a file that cannot be read yet (still being
    /// written) or at all. Blocking: call it off the main thread.
    static func thumbnail(of url: URL, maxPixelSize: Int = 480) -> (image: CGImage, pixelSize: CGSize?)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        var pixelSize: CGSize?
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
            pixelSize = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        return (image, pixelSize)
    }

    /// Quick Look's picture of a file Image I/O cannot read: a screenshot saved as PDF.
    static func quickLookThumbnail(of url: URL, maxPixelSize: Int = 480) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: maxPixelSize, height: maxPixelSize), scale: 1,
            representationTypes: [.thumbnail]
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    /// Reads the screenshot into a `Screenshot`, trying again for a moment while it is
    /// still being written.
    static func load(_ url: URL, place: String, attempts: Int = 6, interval: TimeInterval = 0.3) async -> Screenshot? {
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(for: .seconds(interval)) }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let read = await Task.detached(priority: .userInitiated) { thumbnail(of: url) }.value
            // Read once the picture is: the file is whole by then.
            if let read {
                let image = NSImage(cgImage: read.image, size: CGSize(width: read.image.width, height: read.image.height))
                return Screenshot(url: url, thumbnail: image, pixelSize: read.pixelSize, place: place, file: .read(url))
            }
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true,
               let image = await quickLookThumbnail(of: url) {
                return Screenshot(
                    url: url, thumbnail: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)),
                    pixelSize: nil, place: place, file: .read(url)
                )
            }
        }
        return nil
    }

    // MARK: Card actions

    /// The picture as Copy puts it on the clipboard, as ⌃⇧⌘4 would have: the image
    /// itself, PNG and TIFF, not the file, so it pastes into a message or a document as a
    /// picture, and stays there once the file has gone.
    static func picture(of url: URL) -> [NSPasteboard.PasteboardType: Data]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var picture: [NSPasteboard.PasteboardType: Data] = [:]
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .png) == true {
            picture[.png] = data
            picture[.tiff] = NSImage(data: data)?.tiffRepresentation
        } else if let tiff = NSImage(data: data)?.tiffRepresentation {
            picture[.tiff] = tiff
            picture[.png] = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
        return picture.isEmpty ? nil : picture
    }

    /// Puts the picture on `pasteboard`, and returns what it put there; `nil` if it did
    /// not go.
    @discardableResult
    static func copy(_ url: URL, to pasteboard: NSPasteboard = .general) -> [NSPasteboard.PasteboardType: Data]? {
        guard let picture = picture(of: url) else { return nil }
        let item = NSPasteboardItem()
        for (type, data) in picture { item.setData(data, forType: type) }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item]) ? picture : nil
    }

    /// Each kind of the picture by its SHA-256 digest, to know it again on the clipboard
    /// with `holds(_:on:)`: kept in place of the picture, which can run to tens of
    /// megabytes.
    static func fingerprint(of picture: [NSPasteboard.PasteboardType: Data]) -> [NSPasteboard.PasteboardType: SHA256.Digest] {
        picture.mapValues { SHA256.hash(data: $0) }
    }

    /// Whether `pasteboard` holds the picture `fingerprint` was taken of, read back from
    /// it: each kind of it, byte for byte, as `copy` put it there.
    static func holds(_ fingerprint: [NSPasteboard.PasteboardType: SHA256.Digest], on pasteboard: NSPasteboard) -> Bool {
        !fingerprint.isEmpty && fingerprint.allSatisfy { type, digest in
            pasteboard.data(forType: type).map { SHA256.hash(data: $0) } == digest
        }
    }

    /// Moves the screenshot to the Trash, where it can be put back from.
    static func trash(_ url: URL) -> Bool {
        (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }

    /// Deletes the screenshot for good: not to the Trash, so it cannot be put back.
    /// Only a plain file: `unlink` refuses a folder, where FileManager's `removeItem`
    /// would empty one put in the file's place, and takes away a symbolic link rather
    /// than what it points to. Returns whether the file is gone.
    static func delete(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, unlink(url.path) == 0 else { return false }
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }
}
