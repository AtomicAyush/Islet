import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Makes files of dropped pictures, each in a folder of its own inside the folder it
/// is given, so pictures of the same name never collide and each keeps the name it
/// came with.
///
/// File promises are called in by `begin`, during the drop, as AppKit requires. The
/// rest (checking, converting, downloading, waiting for another app's file and
/// writing) happens when the files are awaited, away from the main thread.
enum PictureFiles {
    /// The most a picture may weigh, decoded or downloaded.
    static let largestPicture = 50 * 1024 * 1024
    /// How long a promise, or a file another app is writing, is waited for before
    /// the next way of making the picture is tried.
    static let promiseTimeout: Duration = .seconds(20)

    /// Where file promises report back. Their readers only note what arrived.
    static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.ayush.Islet.picture-promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Never invalidated, like Now Playing's: a download cancelled by a stop may not
    /// have made its request yet.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    // MARK: Making

    /// A drop's pictures on their way to becoming files.
    struct Making {
        fileprivate enum Step {
            case data(Data, UTType)
            case promise(PromisedFile)
            case link(URL)
            case file(URL)
        }

        fileprivate struct Job {
            var folder: URL
            var steps: [Step]
            var names: PictureNames
        }

        fileprivate var jobs: [Job]
        fileprivate var promiseTimeout: Duration
        fileprivate var date: Date

        var count: Int { jobs.count }

        /// The files made, in the order the pictures were dropped. A picture that could
        /// not be made is left out, and its folder removed; so is every picture once the
        /// task awaiting them is cancelled.
        func files() async -> [URL] {
            var made: [URL] = []
            for job in jobs {
                if !Task.isCancelled,
                   let file = await PictureFiles.make(job, promiseTimeout: promiseTimeout, date: date) {
                    made.append(file)
                } else {
                    try? FileManager.default.removeItem(at: job.folder)
                }
            }
            return made
        }
    }

    /// Starts turning `drop` into files in `folder`, calling in its promises now.
    @MainActor
    static func begin(_ drop: PictureDrop, in folder: URL, promiseTimeout: Duration = promiseTimeout, date: Date = Date()) -> Making {
        let jobs = drop.pictures.map { picture -> Making.Job in
            let pictureFolder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let steps = picture.sources.map { source -> Making.Step in
                switch source {
                case .data(let data, let type):
                    return .data(data, type)
                case .link(let url):
                    return .link(url)
                case .file(let url):
                    return .file(url)
                case .promise(let promise):
                    let promised = PromisedFile()
                    // The promise has to be called in before the drop returns, into a
                    // folder that exists: the one bit of file work done on the main
                    // thread, and only for pictures that came as nothing but a promise.
                    do {
                        try FileManager.default.createDirectory(at: pictureFolder, withIntermediateDirectories: true)
                        promise.callIn(pictureFolder) { promised.deliver($0) }
                    } catch {
                        promised.deliver(nil)
                    }
                    return .promise(promised)
                }
            }
            return Making.Job(folder: pictureFolder, steps: steps, names: picture.names)
        }
        return Making(jobs: jobs, promiseTimeout: promiseTimeout, date: date)
    }

    /// Tries each way of making the picture in turn, and returns the first file made.
    private static func make(_ job: Making.Job, promiseTimeout: Duration, date: Date) async -> URL? {
        for step in job.steps {
            switch step {
            case .data(let data, let declared):
                if let file = write(data, declaredAs: declared, named: job.names, in: job.folder, date: date) {
                    return file
                }
            case .promise(let promised):
                if let file = await promised.file(within: promiseTimeout) {
                    return matchingExtension(file)
                }
            case .link(let url):
                if let data = await fetch(url),
                   let file = write(data, declaredAs: nil, named: job.names, in: job.folder, date: date) {
                    return file
                }
            case .file(let url):
                if await isFinished(url, within: promiseTimeout),
                   let data = read(url, limit: largestPicture),
                   let file = write(
                       data, declaredAs: UTType(filenameExtension: url.pathExtension),
                       named: job.names, in: job.folder, date: date
                   ) {
                    return file
                }
            }
        }
        return nil
    }

    /// Writes the picture's bytes under the name its names give it, with the
    /// extension its bytes call for; a TIFF is written as a PNG. `nil` when the bytes
    /// are not a picture.
    static func write(_ data: Data, declaredAs declared: UTType?, named names: PictureNames, in folder: URL, date: Date) -> URL? {
        guard data.count <= largestPicture, var type = imageType(of: data, declaredAs: declared) else { return nil }
        var bytes = data
        if type == .tiff {
            guard let png = png(fromTIFF: data) else { return nil }
            bytes = png
            type = .png
        }
        let file = folder.appendingPathComponent(fileName(for: names, type: type, date: date), isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// A promised file whose extension does not match its contents gets the one that
    /// does. The name is otherwise the source's own.
    private static func matchingExtension(_ file: URL) -> URL {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier),
              !pathExtension(file.pathExtension, fits: type),
              let preferred = type.preferredFilenameExtension
        else { return file }
        let renamed = file.deletingPathExtension().appendingPathExtension(preferred)
        guard (try? FileManager.default.moveItem(at: file, to: renamed)) != nil else { return file }
        return renamed
    }

    // MARK: Checking

    /// What the bytes are, read from the bytes themselves; the drag's word for it is
    /// only taken for SVG, which Image I/O does not read. `nil` when they are not a
    /// picture.
    static func imageType(of data: Data, declaredAs declared: UTType?) -> UTType? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0,
           let identifier = CGImageSourceGetType(source) as String?,
           let type = UTType(identifier), type.conforms(to: .image) {
            return type
        }
        if declared?.conforms(to: .svg) != false, isSVG(data) {
            return .svg
        }
        return nil
    }

    /// Whether the bytes are an SVG document: whether its root element, past all that
    /// XML allows before it, is `svg`. Illustrator and Inkscape put a declaration,
    /// comments and a DOCTYPE with entities first, often more than a kilobyte of
    /// them, so a look at the opening bytes is not enough; an HTML page with a
    /// drawing in it does not count.
    static func isSVG(_ data: Data) -> Bool {
        var text = Substring(String(decoding: data.prefix(64 * 1024), as: UTF8.self))
        if text.first == "\u{FEFF}" { text = text.dropFirst() }
        while true {
            text = text.drop { $0.isWhitespace }
            if text.hasPrefix("<?") || text.hasPrefix("<!--") {
                guard let end = text.range(of: text.hasPrefix("<?") ? "?>" : "-->") else { return false }
                text = text[end.upperBound...]
            } else if text.prefix(9).uppercased() == "<!DOCTYPE" {
                guard let end = endOfDoctype(in: text) else { return false }
                text = text[end...]
            } else {
                break
            }
        }
        guard text.first == "<" else { return false }
        // `<svg>`, `<svg …>`, `<svg/>`, or a prefixed `<svg:svg …>`.
        let name = text.dropFirst().prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" }.lowercased()
        return name == "svg" || name.hasSuffix(":svg")
    }

    /// Just past a DOCTYPE's closing `>`: the first outside quotes, comments and its
    /// internal subset, whose entity declarations end in `>` of their own.
    private static func endOfDoctype(in text: Substring) -> Substring.Index? {
        var inSubset = false
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if text[index...].hasPrefix("<!--") {
                guard let end = text[index...].range(of: "-->") else { return nil }
                index = end.upperBound
                continue
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                inSubset = true
            } else if character == "]" {
                inSubset = false
            } else if character == ">", !inSubset {
                return text.index(after: index)
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The first image of a TIFF, as a PNG: browsers put a TIFF on the drag only when
    /// they have nothing better, and a PNG is what everything else opens.
    static func png(fromTIFF data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    // MARK: Links

    /// The picture a link points at: decoded from a `data:` URL, or downloaded over
    /// HTTP(S) when the server says it is an image and it is not too large.
    static func fetch(_ url: URL, limit: Int = largestPicture) async -> Data? {
        switch url.scheme?.lowercased() {
        case "data":
            return decode(dataURL: url.absoluteString, limit: limit)
        case "http", "https":
            return await download(url, limit: limit)
        default:
            return nil
        }
    }

    /// The bytes of a `data:image/…` URL, base64 or percent-encoded.
    static func decode(dataURL string: String, limit: Int = largestPicture) -> Data? {
        guard string.prefix(5).lowercased() == "data:", let comma = string.firstIndex(of: ",") else { return nil }
        let header = string[string.index(string.startIndex, offsetBy: 5)..<comma].lowercased()
        let parameters = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parameters.first?.hasPrefix("image/") == true else { return nil }
        let payload = String(string[string.index(after: comma)...])
        // Base64 data is at least three quarters the length of its text.
        guard payload.utf8.count / 4 * 3 <= limit else { return nil }
        let data: Data?
        if parameters.contains("base64") {
            data = Data(base64Encoded: payload.removingPercentEncoding ?? payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, !data.isEmpty, data.count <= limit else { return nil }
        return data
    }

    /// Downloads a picture: only an answer the server calls an image, and no more
    /// than `limit` bytes of it.
    private static func download(_ url: URL, limit: Int) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let answer = try? await session.bytes(for: request) else { return nil }
        let (bytes, response) = answer
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.mimeType?.lowercased().hasPrefix("image/") == true,
              http.expectedContentLength <= Int64(limit)
        else {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    bytes.task.cancel()
                    return nil
                }
            }
        } catch {
            return nil
        }
        return data.isEmpty ? nil : data
    }

    // MARK: Files still being written

    /// Whether a dropped file is a picture in the temporary folder: Firefox's, which
    /// it has only started writing (into `mozDraggedFiles`) when the drop reads its
    /// URL, or another app's that will be cleaned away. Such a file is made into a
    /// picture of the drop's own, like one from Safari, once it is finished. Only the
    /// path is looked at, so this is safe on the main thread.
    static func isPassingPicture(_ url: URL) -> Bool {
        guard url.isFileURL,
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        else { return false }
        let path = url.standardized.path
        return temporaryFolderPaths.contains { path.hasPrefix($0) }
    }

    /// The temporary folder as other apps write it (`/var/folders/…/T/`) and as it
    /// resolves (`/private/var/…`), each ending in a slash. Worked out from the
    /// path alone: Foundation's own resolving drops the `/private`.
    private static let temporaryFolderPaths: [String] = {
        var path = FileManager.default.temporaryDirectory.standardized.path
        if !path.hasSuffix("/") { path += "/" }
        let bare = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        return [bare, "/private" + bare]
    }()

    /// Waits for a file another app is writing to be finished. Firefox creates the file
    /// empty and writes it as the picture comes in, from its cache or the network. It
    /// is finished when complete by its own account (a JPEG's end marker, a PNG's last
    /// chunk, a WebP's stated length), or else not empty and unchanged for `quiet`:
    /// other formats, and a JPEG with bytes after its end, go by that, as does a
    /// download that stalls for longer. `false` if the file is still empty or changing
    /// after `timeout`, or the wait is cancelled.
    static func isFinished(_ file: URL, within timeout: Duration, quiet: Duration = .milliseconds(600)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var last: (size: Int, since: ContinuousClock.Instant)?
        while true {
            // Attributes, not resource values: those are cached, and would not change.
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int
            let now = clock.now
            if let size, size > 0 {
                if isComplete(file, size: size) { return true }
                if let last, last.size == size {
                    if now - last.since >= quiet { return true }
                } else {
                    last = (size, now)
                }
            }
            guard now < deadline, (try? await Task.sleep(for: .milliseconds(100))) != nil else { return false }
        }
    }

    /// The file's bytes, read rather than mapped: the app writing it could still cut
    /// it short, which crashes a reader of a mapping. `nil` if it is over `limit`.
    private static func read(_ file: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    /// Whether the file's bytes run to its format's end. `false` when that cannot be
    /// told, or it is not one of the formats that say.
    private static func isComplete(_ file: URL, size: Int) -> Bool {
        guard size >= 12, let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12,
              (try? handle.seek(toOffset: UInt64(size - 12))) != nil,
              let tail = try? handle.read(upToCount: 12), tail.count == 12
        else { return false }
        let start = [UInt8](head)
        let end = [UInt8](tail)
        if start.starts(with: [0xFF, 0xD8, 0xFF]) {
            // End of image. Entropy-coded data never holds FF D9.
            return end.suffix(2).elementsEqual([0xFF, 0xD9])
        }
        if start.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            // The IEND chunk: an empty length, its name, its checksum.
            return end[4..<8].elementsEqual(Array("IEND".utf8))
        }
        if start.starts(with: Array("RIFF".utf8)), start[8..<12].elementsEqual(Array("WEBP".utf8)) {
            let stated = start[4..<8].reversed().reduce(0) { $0 << 8 | Int($1) }
            return size >= stated + 8
        }
        return false
    }

    // MARK: Names

    /// Stems too general to name a picture by, which servers and browsers fall back
    /// on: Google's thumbnails are all "images", a `data:` picture from Safari is
    /// "Unknown".
    private static let generic: Set<String> = [
        "image", "images", "img", "unknown", "untitled", "download", "file", "index", "blob",
    ]

    /// The picture's file name: the name the source gave it, else its address's last
    /// part when that names a picture, else the link's title, else "Image" and the
    /// time. The extension is always one that fits what the bytes are.
    static func fileName(for names: PictureNames, type: UTType, date: Date) -> String {
        let addressed = names.addresses.lazy
            .filter { ["http", "https"].contains($0.scheme?.lowercased()) }
            .map(\.lastPathComponent)
            .first { !$0.isEmpty && UTType(filenameExtension: ($0 as NSString).pathExtension)?.conforms(to: .image) == true }
        let title = names.title.flatMap { title in
            title.contains("://") || title.lowercased().hasPrefix("data:") ? nil : title
        }

        for candidate in [names.given, addressed, title].compactMap({ $0 }) {
            let cleaned = clean(candidate)
            let pathExtension = (cleaned as NSString).pathExtension
            let namesPicture = !pathExtension.isEmpty
                && UTType(filenameExtension: pathExtension)?.conforms(to: .image) == true
            let stem = namesPicture ? (cleaned as NSString).deletingPathExtension : cleaned
            let trimmed = stem.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
            guard !trimmed.isEmpty, !generic.contains(trimmed.lowercased()) else { continue }
            let kept = namesPicture && self.pathExtension(pathExtension, fits: type) ? pathExtension : nil
            return name(trimmed, extension: kept ?? type.preferredFilenameExtension)
        }
        return name("Image \(stamp.string(from: date))", extension: type.preferredFilenameExtension)
    }

    /// Whether `pathExtension` is one of `type`'s own: "jpg" fits a JPEG, "webp" does not.
    private static func pathExtension(_ pathExtension: String, fits type: UTType) -> Bool {
        guard !pathExtension.isEmpty, let named = UTType(filenameExtension: pathExtension) else { return false }
        return named == type
    }

    private static func name(_ stem: String, extension pathExtension: String?) -> String {
        guard let pathExtension, !pathExtension.isEmpty else { return stem }
        return "\(stem).\(pathExtension)"
    }

    /// Makes a title or a server's name safe for a file name: no slashes or colons,
    /// no line breaks or runs of spaces, not hidden, and short enough for any disk.
    private static func clean(_ raw: String) -> String {
        let separated = raw.unicodeScalars.map { scalar -> String in
            if scalar == "/" || scalar == ":" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        var cleaned = separated.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 100 {
            let pathExtension = (cleaned as NSString).pathExtension
            let keepsExtension = !pathExtension.isEmpty && pathExtension.count <= 5
            let stem = keepsExtension ? (cleaned as NSString).deletingPathExtension : cleaned
            let cut = String(stem.prefix(100)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            cleaned = keepsExtension ? "\(cut).\(pathExtension)" : cut
        }
        return cleaned
    }

    /// "2026-09-25 13.20.05", the way macOS stamps screenshots.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    // MARK: Folders

    /// Where pictures dropped on AirDrop wait to be sent, in the temporary folder.
    /// Emptied after each share and when Islet starts.
    static var sharingFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Islet Pictures", isDirectory: true)
    }

    /// Removes everything in `folder`, keeping the folder. Off the main thread.
    static func empty(_ folder: URL) {
        DispatchQueue.global(qos: .utility).async {
            let files = FileManager.default
            for item in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? files.removeItem(at: item)
            }
        }
    }

    /// Removes the pictures' own folders, some time from now: `delay` gives AirDrop
    /// time to finish reading them.
    static func discard(_ files: [URL], after delay: TimeInterval = 0) {
        let folders = Set(files.map { $0.deletingLastPathComponent() })
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            for folder in folders { try? FileManager.default.removeItem(at: folder) }
        }
    }
}

/// A file promise already called in, whose file is on its way. The first answer
/// counts: the file, a failure, or the wait running out.
final class PromisedFile: @unchecked Sendable {
    private let lock = NSLock()
    /// `.none` while waiting; `.some(nil)` once it failed or ran out of time.
    private var outcome: URL??
    private var waiter: CheckedContinuation<URL?, Never>?

    func deliver(_ file: URL?) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = .some(file)
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: file)
    }

    /// The promised file, or `nil` if it failed, has not arrived within `timeout`, or
    /// the drop was abandoned (the feature stopped) while waiting.
    func file(within timeout: Duration) async -> URL? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                    return
                }
                waiter = continuation
                lock.unlock()
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.deliver(nil)
                }
            }
        } onCancel: {
            deliver(nil)
        }
    }
}
