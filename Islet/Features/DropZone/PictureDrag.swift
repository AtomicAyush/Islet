import AppKit
import UniformTypeIdentifiers

/// A drop target that also takes pictures dragged out of web pages. They arrive as
/// image data, a file promise or a link rather than as files, and take a moment to
/// become files, so the target is handed the drag as it was read at the drop.
@MainActor
protocol PictureDropTarget: DropTarget {
    /// Pictures were dropped at `point` (top-left origin, in a page of `size`).
    func drop(_ pictures: PictureDrop, at point: CGPoint, in size: CGSize)
}

/// Pictures dragged out of a web page, read off the drag pasteboard the moment they
/// were dropped.
///
/// Safari and Chrome do not drag a picture as a file. Safari (WebKit's
/// `WebViewImpl::startDrag` from 2026 on) drags a file promise for the picture's
/// type, whose suggested name is on the pasteboard, and beside it the picture's own
/// bytes under that type, a TIFF, and the link and its title; earlier Safaris put the
/// same on with the older kind of promise. Chrome and the browsers built on it
/// (Chromium's `WebDragSource`) put the bytes, a Carbon-style promise, the link, its
/// title and the `<img>` markup on one item. Firefox does offer a file URL, so its
/// drags arrive the way Finder's do; but the file is one it only starts writing, into
/// the temporary folder, when the URL is read, so `DropZoneModel` turns it into a
/// picture made from a `file` source.
struct PictureDrop {
    var pictures: [DroppedPicture]
}

/// One picture from the drag: what it can be made from, best first, and what the
/// drag says it is called.
struct DroppedPicture {
    enum Source {
        /// The picture's bytes: the page's own file, or a TIFF the browser drew.
        case data(Data, UTType)
        /// A promise to write the picture as a file, called in when the drop is taken.
        case promise(FilePromise)
        /// A link to the picture, downloaded; a `data:` URL is decoded in place.
        case link(URL)
        /// A picture file another app is still writing, read once it is finished.
        case file(URL)
    }

    var sources: [Source]
    var names = PictureNames()
}

/// What a dragged picture is called, as far as the drag says. `PictureFiles` picks
/// the file name from these.
struct PictureNames {
    /// The file name the source app gave the picture: the promise's suggested name,
    /// or the name the server sent it under.
    var given: String?
    /// Where the picture came from: its own address first, then the link around it.
    var addresses: [URL] = []
    /// The link's title, which for a picture is usually its alt text.
    var title: String?
}

/// A file promise, called in only when a drop is taken; AppKit requires that to
/// happen before the drop returns. The file arrives later.
struct FilePromise {
    /// Asks the source for the file in `folder`. `done` gets the file, or `nil` if
    /// it could not be written, on a queue of AppKit's choosing.
    let callIn: @MainActor (_ folder: URL, _ done: @escaping @Sendable (URL?) -> Void) -> Void
}

/// Tells a picture dragged out of a web page from a link or text dragged out of one,
/// and reads the picture off the drag pasteboard when it is dropped.
@MainActor
enum PictureDrag {
    // MARK: Pasteboard types

    /// Written by `NSFilePromiseProvider`: the promise AppKit can call in by itself.
    static let promiseMetadata = NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")
    /// The type of file promised, by any kind of promise but the legacy one.
    static let promisedType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
    /// The name an `NSFilePromiseProvider` will give its file.
    static let promisedName = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name")
    /// "Apple files promise pasteboard type" as a pasteboard item lists it: the legacy
    /// promise, a list of the promised files' types. Safari 26 and earlier drag it.
    static let legacyPromise = NSPasteboard.PasteboardType("dyn.ah62d4rv4gu8yc6durvwwa3xmrvw1gkdusm1044pxqyuha2pxsvw0e55bsmwca7d3sbwu")
    /// The link's title, next to `public.url`.
    static let urlName = NSPasteboard.PasteboardType("public.url-name")
    /// Chromium's `<img>` markup, kept off `public.html` when image data is on the item.
    static let chromiumImageHTML = NSPasteboard.PasteboardType("org.chromium.image-html")
    /// The Content-Disposition header the picture was served with, from Chromium.
    static let chromiumContentDisposition = NSPasteboard.PasteboardType("org.chromium.content-disposition")

    /// Formatted text: a selection, which may carry a picture of itself (Office apps
    /// put one on), but is not a picture being dragged.
    private static let richText: Set<NSPasteboard.PasteboardType> = [
        .rtf, .rtfd, .init("com.apple.flat-rtfd"),
    ]

    /// Encodings a page serves pictures in, most common first. TIFF is not among
    /// them: browsers add one they drew themselves, so it is used only when nothing
    /// else is there, and is turned into a PNG.
    private static let encodings: [UTType] = [UTType.jpeg, .png, .gif, .webP, .heic, .heif]
        + ["public.avif", "public.jpeg-xl"].compactMap(UTType.init)
        + [.bmp, .ico, .svg]

    // MARK: Telling

    /// The last answer from `isPictureDrag`, so the island can ask on every move of a
    /// drag without making the source app provide the link again each time.
    private static var lastAnswer: (pasteboard: NSPasteboard.Name, changeCount: Int, isPicture: Bool)?

    /// Whether the pasteboard holds a picture dragged out of a web page (or out of
    /// Photos, which promises pictures the same way), rather than a link or text.
    /// Files are not asked about here: the island takes those anyway.
    static func isPictureDrag(_ pasteboard: NSPasteboard) -> Bool {
        let changeCount = pasteboard.changeCount
        if let last = lastAnswer, last.pasteboard == pasteboard.name, last.changeCount == changeCount {
            return last.isPicture
        }
        let isPicture = (pasteboard.pasteboardItems ?? []).contains { look(at: $0)?.isPicture == true }
        lastAnswer = (pasteboard.name, changeCount, isPicture)
        return isPicture
    }

    /// What an item offers, read from its types and a couple of short strings; no
    /// picture data is read. `nil` for an item carrying a file, which is not a
    /// picture from the web.
    private struct Look {
        /// An image the item promises, by any kind of promise.
        var promisedType: UTType?
        /// The promise is an `NSFilePromiseProvider`'s, which AppKit calls in reliably.
        /// The others are only relied on for what they say is coming.
        var canCallIn = false
        /// The item's own image types, best first, TIFF last.
        var imageTypes: [NSPasteboard.PasteboardType] = []
        var hasRichText = false
        /// The item's link, when it points at a picture.
        var pictureLink: URL?

        var isPicture: Bool {
            // A browser's promise says the drag is a picture even when the item also
            // declares formatted text, as Safari 26's does.
            if promisedType != nil, canCallIn || !imageTypes.isEmpty { return true }
            if hasRichText { return false }
            return !imageTypes.isEmpty || pictureLink != nil
        }
    }

    private static func look(at item: NSPasteboardItem) -> Look? {
        let types = item.types
        guard !types.contains(.fileURL) else { return nil }
        var look = Look()
        let present = Set(types)

        if present.contains(promisedType), let type = item.string(forType: promisedType).flatMap(UTType.init) {
            look.promisedType = type.conforms(to: .image) ? type : nil
            look.canCallIn = look.promisedType != nil && present.contains(promiseMetadata)
        } else if present.contains(legacyPromise),
                  let listed = item.propertyList(forType: legacyPromise) as? [String] {
            look.promisedType = listed.lazy.compactMap(UTType.init).first { $0.conforms(to: .image) }
        }

        let images = types.filter { UTType($0.rawValue)?.conforms(to: .image) == true }
        look.imageTypes = images.sorted { rank($0) < rank($1) }
        look.hasRichText = !present.isDisjoint(with: richText)
        if let link = link(of: item), isPictureLink(link) {
            look.pictureLink = link
        }
        return look
    }

    /// Where a type comes in `encodings`; TIFF and anything unlisted come after.
    private static func rank(_ type: NSPasteboard.PasteboardType) -> Int {
        guard let uti = UTType(type.rawValue) else { return .max }
        return encodings.firstIndex(of: uti) ?? (uti == .tiff ? encodings.count + 1 : encodings.count)
    }

    private static func link(of item: NSPasteboardItem) -> URL? {
        guard let string = item.string(forType: .URL)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty
        else { return nil }
        return URL(string: string)
    }

    /// A web address whose path ends in a picture's extension, or a `data:` URL of
    /// an image. Anything else is an ordinary link, and so is a page about a picture
    /// whose address merely ends in the picture's name.
    static func isPictureLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https":
            let pathExtension = url.pathExtension
            return !pathExtension.isEmpty
                && UTType(filenameExtension: pathExtension)?.conforms(to: .image) == true
                && !isPageAboutPicture(url)
        case "data":
            return url.absoluteString.prefix(11).lowercased() == "data:image/"
        default:
            return false
        }
    }

    /// The pages about a picture that are linked to most: a wiki's file page, whose
    /// namespace is set off by a colon in every language (`/wiki/File:Cat.jpg`,
    /// `/wiki/Datei:Katze.jpg`), and a code host's view of a file in a repository
    /// (GitHub's `/owner/repo/blob/main/logo.png`, GitLab's `/-/blob/…`). They serve
    /// HTML, so a link to one must not open the island only to fail on the drop.
    /// Pictures dragged from these pages are unaffected: they carry their bytes.
    private static func isPageAboutPicture(_ url: URL) -> Bool {
        url.lastPathComponent.contains(":") || url.pathComponents.contains("blob")
    }

    // MARK: Reading

    /// The pictures on the pasteboard, read as they are dropped. Their bytes are read
    /// here, because the drag pasteboard is only certain to hold them until the next
    /// drag; promises are made ready to call in. `nil` when there is no picture.
    static func read(_ pasteboard: NSPasteboard) -> PictureDrop? {
        let items = pasteboard.pasteboardItems ?? []
        var receivers: [Int: NSFilePromiseReceiver]?
        var pictures: [DroppedPicture] = []

        for (index, item) in items.enumerated() {
            guard let look = look(at: item), look.isPicture else { continue }
            var sources: [DroppedPicture.Source] = []

            let original = look.imageTypes.first { UTType($0.rawValue) != .tiff }
            if let original, let data = item.data(forType: original), !data.isEmpty,
               let type = UTType(original.rawValue) {
                // Exactly what the promise would write (both browsers promise these
                // same bytes, and its name is on the pasteboard already), without
                // waiting on the browser once the drop is over.
                sources.append(.data(data, type))
            } else {
                if look.canCallIn {
                    let found = receivers ?? promiseReceivers(on: pasteboard, items: items)
                    receivers = found
                    if let receiver = found[index] {
                        sources.append(.promise(FilePromise { folder, done in
                            receiver.receivePromisedFiles(
                                atDestination: folder, options: [:], operationQueue: PictureFiles.promiseQueue
                            ) { url, error in
                                done(error == nil ? url : nil)
                            }
                        }))
                    }
                }
                if look.imageTypes.contains(.tiff), let data = item.data(forType: .tiff), !data.isEmpty {
                    sources.append(.data(data, .tiff))
                }
            }
            if sources.isEmpty, let link = look.pictureLink {
                sources.append(.link(link))
            }
            guard !sources.isEmpty else { continue }
            pictures.append(DroppedPicture(sources: sources, names: names(of: item, look: look)))
        }
        return pictures.isEmpty ? nil : PictureDrop(pictures: pictures)
    }

    /// The pasteboard's promises by item. AppKit reads one receiver from each item
    /// that has a promise on it, in order.
    private static func promiseReceivers(on pasteboard: NSPasteboard, items: [NSPasteboardItem]) -> [Int: NSFilePromiseReceiver] {
        let readable = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        let promising = items.indices.filter { !Set(items[$0].types).isDisjoint(with: readable) }
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        guard receivers.count == promising.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(promising, receivers))
    }

    private static func names(of item: NSPasteboardItem, look: Look) -> PictureNames {
        var names = PictureNames()
        names.given = item.string(forType: promisedName)
            ?? item.string(forType: chromiumContentDisposition).flatMap(fileName(inContentDisposition:))
        if let html = item.string(forType: chromiumImageHTML) ?? item.string(forType: .html),
           let source = imageSource(inHTML: html) {
            names.addresses.append(source)
        }
        if let link = link(of: item) {
            names.addresses.append(link)
        }
        names.title = item.string(forType: urlName)
        return names
    }

    /// The `src` of the first `<img>` in the markup, as an absolute URL.
    static func imageSource(inHTML html: String) -> URL? {
        let pattern = #"<img\b[^>]*?\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
        else { return nil }
        let captured = [1, 2].lazy
            .compactMap { Range(match.range(at: $0), in: html) }
            .first
            .map { String(html[$0]) }
        guard let source = captured?.replacingOccurrences(of: "&amp;", with: "&"),
              let url = URL(string: source), url.scheme != nil
        else { return nil }
        return url
    }

    /// The file name in a Content-Disposition header: `filename*=UTF-8''…` when it
    /// has one, else `filename="…"`.
    static func fileName(inContentDisposition header: String) -> String? {
        var plain: String?
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            switch pair[0].lowercased() {
            case "filename*":
                // charset'language'percent-encoded
                let pieces = pair[1].split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if pieces.count == 3, let decoded = String(pieces[2]).removingPercentEncoding, !decoded.isEmpty {
                    return decoded
                }
            case "filename":
                let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !value.isEmpty { plain = value }
            default:
                continue
            }
        }
        return plain
    }
}
