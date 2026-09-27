import AppKit
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
            if let read {
                let image = NSImage(cgImage: read.image, size: CGSize(width: read.image.width, height: read.image.height))
                return Screenshot(url: url, thumbnail: image, pixelSize: read.pixelSize, place: place)
            }
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true,
               let image = await quickLookThumbnail(of: url) {
                return Screenshot(
                    url: url, thumbnail: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)),
                    pixelSize: nil, place: place
                )
            }
        }
        return nil
    }

    // MARK: Card actions

    /// Puts the picture on `pasteboard` as ⌃⇧⌘4 would have: the image itself, PNG and
    /// TIFF, not the file, so it pastes into a message or a document as a picture.
    @discardableResult
    static func copy(_ url: URL, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let item = NSPasteboardItem()
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .png) == true {
            item.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        } else if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
        } else {
            return false
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// Moves the screenshot to the Trash, where it can be put back from.
    static func trash(_ url: URL) -> Bool {
        (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }
}
