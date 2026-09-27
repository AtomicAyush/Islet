import CoreServices
import Foundation

/// Where copies are listened for. Finder publishes a copy's progress for the folder the
/// items are going into, and a subscription to a folder hears of progress for the folder
/// itself and for what is directly in it, never deeper (`FileCopyMonitor`). So a folder
/// subscribed to hears of copies into it and into each folder directly inside it.
///
/// A few folders are listened to all the time, which covers where copies mostly go: the
/// home folder and the folders in it, and the ones in Desktop, Documents, Downloads,
/// Movies, Music and Pictures; Applications and the folders in it; iCloud Drive and each
/// cloud storage app's folder, at their tops; and every mounted disk, at its top and in
/// the folders at its top. Anywhere deeper is found as it is written to
/// (`WrittenFolders`).
enum FileCopyPlaces {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL }

    /// Where iCloud Drive keeps its folders, and where apps such as Dropbox, Google Drive
    /// and OneDrive keep theirs, one each.
    nonisolated static func iCloudDrive(home: URL) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    nonisolated static func cloudStorage(home: URL) -> URL {
        home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    /// The folders listened to all the time. Nothing in them is listed or read: a
    /// subscription is matched by the system, against what apps publish.
    static func standard(home: URL = home, volumes: [URL] = mountedVolumes()) -> [URL] {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        var places = [
            root,
            root.appendingPathComponent("Users", isDirectory: true),
            home,
        ]
        places += ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
        places += [
            root.appendingPathComponent("Applications", isDirectory: true),
            root.appendingPathComponent("Users/Shared", isDirectory: true),
            // Each disk's top is directly in /Volumes.
            root.appendingPathComponent("Volumes", isDirectory: true),
            // iCloud Drive, and the folders at its top; the apps' own folders in it.
            home.appendingPathComponent("Library/Mobile Documents", isDirectory: true),
            iCloudDrive(home: home),
            // Each cloud storage app's folder is directly in here.
            cloudStorage(home: home),
        ]
        places += volumes
        var seen: Set<String> = []
        return places.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    /// What the island calls the folder a copy is going into, from its path alone, so
    /// nothing of the folder is asked of the disk: its own name, which for a disk's top
    /// is the disk's, and for the folders that are not called what Finder shows, what
    /// Finder shows. A cloud storage app's folder is named for the app, not the account
    /// its name also carries.
    nonisolated static func name(of folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = folder.standardizedFileURL.path
        if path == "/" { return startupDiskName ?? "Macintosh HD" }
        let drive = iCloudDrive(home: home).standardizedFileURL
        if path == drive.path { return "iCloud Drive" }
        let mobile = drive.deletingLastPathComponent().path + "/"
        if path.hasPrefix(mobile) {
            // An app's folder in iCloud Drive, "com~apple~Pages/Documents", which Finder
            // shows by the app's name.
            let parts = path.dropFirst(mobile.count).split(separator: "/")
            if parts.first != Substring(drive.lastPathComponent),
               parts.count == 1 || (parts.count == 2 && parts[1] == "Documents"),
               let app = parts[0].split(separator: "~").last {
                return String(app)
            }
        }
        let clouds = cloudStorage(home: home).standardizedFileURL.path + "/"
        if path.hasPrefix(clouds) {
            // "GoogleDrive-name@example.com", "OneDrive-Personal", "Dropbox".
            let parts = path.dropFirst(clouds.count).split(separator: "/")
            if parts.count == 1, let app = parts[0].split(separator: "-").first { return String(app) }
        }
        return folder.lastPathComponent
    }

    /// The startup disk's name, which is the startup disk's own to say, not a folder's.
    nonisolated private static var startupDiskName: String? {
        try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
    }

    /// Every disk mounted besides the startup disk, that Finder shows: external drives,
    /// disk images, network shares.
    static func mountedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.volumeIsRootFileSystem != true && values?.volumeIsBrowsable != false
        }
        .map(\.standardizedFileURL)
    }

    /// Somewhere a copy is not the person's: a hidden folder (the Trash, which emptying
    /// or putting back reports as copying, or a disk's own), inside the Library folder
    /// other than iCloud Drive and other cloud storage (where apps keep their caches and
    /// data), or a temporary folder.
    nonisolated static func isOutOfSight(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = url.standardizedFileURL.path
        if url.standardizedFileURL.pathComponents.dropFirst().contains(where: { $0.hasPrefix(".") }) { return true }
        let library = home.standardizedFileURL.appendingPathComponent("Library").path
        if path == library || path.hasPrefix(library + "/") {
            let clouds = ["Mobile Documents", "CloudStorage"].map { library + "/" + $0 }
            return !clouds.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        let temporary = ["/private/var/folders", "/var/folders", "/private/tmp", "/tmp"]
        return temporary.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Kinds of folder that are one document to Finder (an app, a Photos library, an
    /// Xcode project): a copy goes into the folder around one, never into one.
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "photoslibrary", "musiclibrary",
        "tvlibrary", "photolibrary", "aplibrary", "fcpbundle", "logicx", "band", "imovielibrary", "xcodeproj",
        "xcworkspace", "xcassets", "playground", "swiftpm", "rtfd", "pages", "numbers", "key", "sparsebundle",
        "download", "lproj", "dSYM", "xcarchive",
    ]

    /// Whether a folder written in is somewhere a copy might be going: in sight
    /// (`isOutOfSight`), and not inside a package.
    nonisolated static func mayReceiveCopies(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard !isOutOfSight(url, home: home) else { return false }
        return !url.pathComponents.dropFirst().contains { component in
            let ext = (component as NSString).pathExtension
            return !ext.isEmpty && packageExtensions.contains(ext)
        }
    }

    /// The folders of a batch worth listening to: those a copy might go to, each once,
    /// the shallowest first, at most `limit`.
    nonisolated static func candidates(_ paths: [String], limit: Int, mayReceive: (URL) -> Bool) -> [URL] {
        Set(paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path })
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter(mayReceive)
            .sorted { ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path) }
            .prefix(limit)
            .map { $0 }
    }

    /// The folders at the top of what was written, less any inside another of them, the
    /// shallowest first, at most `limit`: a folder copied in brings its own folders with
    /// it, all written at once, and a burst of writes anywhere else (a project building,
    /// an archive unpacking) comes down to the folder at its top.
    nonisolated static func topmost(_ folders: [URL], limit: Int) -> [URL] {
        let sorted = folders.sorted { ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path) }
        var tops: [URL] = []
        for url in sorted where !tops.contains(where: { url.path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") || url.path == $0.path }) {
            tops.append(url)
            if tops.count == limit { break }
        }
        return tops
    }
}

/// Says which folders files are being written in, anywhere a copy might go, so a copy
/// into a folder too deep for the standing subscriptions is heard as it starts: Finder
/// makes the copy's first item in the folder as it begins, and a subscription made while
/// a copy is under way hears of it at once.
///
/// It is the file system's own record of changes, by folder, a moment after they happen,
/// for the home folder (less its Library and the Trash), Applications, Users/Shared and
/// every mounted disk, and for iCloud Drive and cloud storage in the Library (`scopes`).
/// Nothing is opened or read, and Islet's own writes are left out. Folders no copy would
/// go to are passed over off the main thread (`candidates`).
final class WrittenFolders: @unchecked Sendable {
    /// At most this many folders are passed on from one batch.
    static let batchLimit = 64

    /// Where one record looks out, and what it leaves out there, with all that is in it.
    typealias Scope = (roots: [URL], exclusions: [URL])

    /// The records a copy anywhere is looked out for with: the home folder's leaves out
    /// the Library, so iCloud Drive and cloud storage, in the Library, have one of their own.
    static func scopes(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Scope] {
        let home = home.resolvingSymlinksInPath()
        return [
            (
                roots: [
                    home,
                    URL(fileURLWithPath: "/Applications"),
                    URL(fileURLWithPath: "/Users/Shared"),
                    URL(fileURLWithPath: "/Volumes"),
                ],
                exclusions: ["Library", ".Trash"].map { home.appendingPathComponent($0) }
            ),
            (
                roots: [
                    home.appendingPathComponent("Library/Mobile Documents"),
                    FileCopyPlaces.cloudStorage(home: home),
                ],
                exclusions: []
            ),
        ]
    }

    private let roots: [String]
    private let exclusions: [String]
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "Islet.FileCopies.writes", qos: .utility)
    private let handler: Handler
    private var stream: FSEventStreamRef?

    /// The receiver of each batch, held by the stream while it runs.
    private final class Handler: @unchecked Sendable {
        let mayReceive: @Sendable (URL) -> Bool
        let onFolders: @MainActor ([URL]) -> Void

        init(mayReceive: @escaping @Sendable (URL) -> Bool, onFolders: @escaping @MainActor ([URL]) -> Void) {
            self.mayReceive = mayReceive
            self.onFolders = onFolders
        }

        func received(_ paths: [String]) {
            let folders = FileCopyPlaces.candidates(paths, limit: WrittenFolders.batchLimit, mayReceive: mayReceive)
            guard !folders.isEmpty else { return }
            let onFolders = onFolders
            DispatchQueue.main.async { MainActor.assumeIsolated { onFolders(folders) } }
        }
    }

    /// `roots` are where to look out (one of `scopes`), less `exclusions`, and
    /// `mayReceive` which folders to pass on; tests give their own folders, which are
    /// temporary ones.
    init(
        roots: [URL],
        exclusions: [URL] = [],
        latency: TimeInterval = 0.3,
        mayReceive: @escaping @Sendable (URL) -> Bool = { FileCopyPlaces.mayReceiveCopies($0) },
        onFolders: @escaping @MainActor ([URL]) -> Void
    ) {
        // The record goes by each folder's real path, not one through a symbolic link.
        self.roots = roots.map { $0.resolvingSymlinksInPath().path }
        self.exclusions = exclusions.map { $0.resolvingSymlinksInPath().path }
        self.latency = latency
        handler = Handler(mayReceive: mayReceive, onFolders: onFolders)
    }

    deinit { stop() }

    var isRunning: Bool { queue.sync { stream != nil } }

    /// Looks out at the roots that are there. One that is not (cloud storage, on a Mac
    /// with no app that keeps any) is left out until the next start: the record is not
    /// reliably kept for a folder made after it began.
    func start() {
        queue.sync {
            guard stream == nil else { return }
            let roots = roots.filter { FileManager.default.fileExists(atPath: $0) }
            guard !roots.isEmpty else { return }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(handler).toOpaque(), retain: nil, release: nil, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info, let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
                Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().received(Array(list.prefix(count)))
            }
            // By folder rather than by file, which is what is wanted and far less; the
            // first change of a quiet spell comes at once, rather than after `latency`.
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf
            )
            guard let stream = FSEventStreamCreate(
                nil, callback, &context, roots as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
            ) else { return }
            FSEventStreamSetExclusionPaths(stream, exclusions as CFArray)
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return
            }
            self.stream = stream
        }
    }

    /// Stops on the stream's own queue, so no batch is being handled as it goes, and none
    /// comes after.
    func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
