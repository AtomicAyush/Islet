import AppKit

/// The history on disk: `clipboard.json` in Application Support/Islet, and the
/// pictures beside it in a `Clipboard` folder, one file each. Pinned items are always
/// written; the rest only when Settings asks for the history to be kept between
/// launches, and then pictures only up to `ClipboardLimits.savedPictureBytes`.
///
/// Readable by the person alone, and left out of Time Machine backups: what was
/// copied is nobody else's business, and no business of a backup's either. Reading and
/// writing happen on `queue`, away from the island's animations.
struct ClipboardArchive: Sendable {
    /// Application Support/Islet by default; tests use a folder of their own.
    let directory: URL

    static var standard: ClipboardArchive? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return ClipboardArchive(directory: support.appendingPathComponent("Islet", isDirectory: true))
    }

    /// Serial, so writes land in the order they were made.
    static let queue = DispatchQueue(label: "com.ayush.Islet.clipboard", qos: .utility)

    var fileURL: URL { directory.appendingPathComponent("clipboard.json") }
    var picturesFolder: URL { directory.appendingPathComponent("Clipboard", isDirectory: true) }

    /// One item as written. Flat, so a file from a later version with a kind this one
    /// does not know still reads, and that item is skipped.
    struct Record: Codable, Equatable {
        var id: UUID
        var kind: String
        var text: String?
        var url: String?
        var title: String?
        var paths: [String]?
        /// The picture's file name in `picturesFolder`.
        var picture: String?
        var pictureType: String?
        var sourceBundleIdentifier: String?
        var sourceName: String?
        var copiedAt: Date
        var isPinned: Bool
    }

    /// An item on its way to disk: its record and, for a picture, the bytes to write
    /// if its file is not there yet.
    struct Entry: Sendable {
        var record: Record
        var pictureData: Data?
    }

    /// The items to write, of those in `items`, as entries.
    static func entries(for items: [ClipboardItem], keepingAll: Bool) -> [Entry] {
        items.compactMap { item in
            guard item.isPinned || keepingAll else { return nil }
            var record = Record(
                id: item.id, kind: "", copiedAt: item.copiedAt, isPinned: item.isPinned
            )
            record.sourceBundleIdentifier = item.source?.bundleIdentifier
            record.sourceName = item.source?.name
            var data: Data?
            switch item.content {
            case .text(let text):
                record.kind = "text"
                record.text = text
            case .link(let url, let title):
                record.kind = "link"
                record.url = url.absoluteString
                record.title = title
            case .files(let urls):
                record.kind = "files"
                record.paths = urls.map(\.path)
            case .image(let image):
                guard item.isPinned || image.data.count <= ClipboardLimits.savedPictureBytes else { return nil }
                record.kind = "image"
                record.picture = "\(item.id.uuidString).\(fileExtension(for: image.type))"
                record.pictureType = image.type.rawValue
                data = image.data
            }
            return Entry(record: record, pictureData: data)
        }
    }

    private static func fileExtension(for type: NSPasteboard.PasteboardType) -> String {
        switch type.rawValue {
        case "public.jpeg": "jpg"
        case "public.heic": "heic"
        case "com.compuserve.gif": "gif"
        default: "png"
        }
    }

    // MARK: Writing

    /// Writes the entries, adds the pictures not yet written and deletes those no
    /// entry holds. With nothing to keep, nothing is left on disk.
    func save(_ entries: [Entry]) {
        let files = FileManager.default
        guard !entries.isEmpty else {
            try? files.removeItem(at: fileURL)
            try? files.removeItem(at: picturesFolder)
            return
        }
        makePrivateFolder(directory)
        let pictures = Set(entries.compactMap(\.record.picture))
        if !pictures.isEmpty { makePrivateFolder(picturesFolder) }
        for entry in entries {
            guard let name = entry.record.picture, let data = entry.pictureData else { continue }
            let file = picturesFolder.appendingPathComponent(name)
            guard !files.fileExists(atPath: file.path) else { continue }
            writePrivately(data, to: file)
        }
        let present = (try? files.contentsOfDirectory(atPath: picturesFolder.path)) ?? []
        for name in present where !pictures.contains(name) {
            try? files.removeItem(at: picturesFolder.appendingPathComponent(name))
        }
        if pictures.isEmpty { try? files.removeItem(at: picturesFolder) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries.map(\.record)) else { return }
        writePrivately(data, to: fileURL)
    }

    /// Deletes everything written.
    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: picturesFolder)
    }

    private func makePrivateFolder(_ folder: URL) {
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    /// Written whole or not at all, readable by the person alone, and kept out of backups.
    private func writePrivately(_ data: Data, to file: URL) {
        do {
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = file
            try url.setResourceValues(values)
        } catch {
            // A history that could not be written is simply not kept; nothing to tell.
        }
    }

    // MARK: Reading

    /// The saved items, pinned ones only unless `keepingAll`, with their pictures made
    /// again from their files. Files that have gone since are left out, as are
    /// pictures whose files have. Slow: call it on `queue`.
    func read(keepingAll: Bool) -> (items: [ClipboardItem], droppedAny: Bool) {
        guard let data = try? Data(contentsOf: fileURL) else { return ([], false) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([Record].self, from: data) else { return ([], true) }
        var loaded: [ClipboardItem] = []
        for record in records where record.isPinned || keepingAll {
            if let item = load(record) { loaded.append(item) }
        }
        return (loaded, loaded.count != records.count)
    }

    private func load(_ record: Record) -> ClipboardItem? {
        let content: ClipboardContent
        switch record.kind {
        case "text":
            guard let text = record.text, !text.isEmpty else { return nil }
            content = .text(text)
        case "link":
            guard let string = record.url, let url = URL(string: string) else { return nil }
            content = .link(url, title: record.title)
        case "files":
            let urls = (record.paths ?? []).map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return nil }
            content = .files(urls)
        case "image":
            guard let name = record.picture, let type = record.pictureType,
                  let data = try? Data(contentsOf: picturesFolder.appendingPathComponent(name)),
                  let image = ClipboardImage.make(data: data, type: NSPasteboard.PasteboardType(type))
            else { return nil }
            content = .image(image)
        default:
            return nil
        }
        return ClipboardItem(
            id: record.id,
            content: content,
            source: record.sourceName.map { ClipboardSource(bundleIdentifier: record.sourceBundleIdentifier, name: $0) },
            copiedAt: record.copiedAt,
            isPinned: record.isPinned
        )
    }
}
