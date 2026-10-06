import AppKit
import Darwin

/// A folder Spotlight tells Islet of PDFs saved from Print in only once macOS lets Islet
/// see it; macOS asks the person first, the first time Islet looks into it.
enum PrintFolder: String, CaseIterable, Sendable {
    case desktop, documents, iCloudDrive

    var name: String {
        switch self {
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .iCloudDrive: "iCloud Drive"
        }
    }

    /// The switch under Islet in Privacy & Security › Files & Folders, as System Settings
    /// itself names it: "Desktop" on recent macOS, "Desktop Folder" before.
    var settingName: String {
        switch self {
        case .desktop: Self.settingNames.desktop
        case .documents: Self.settingNames.documents
        case .iCloudDrive: "iCloud Drive"
        }
    }

    /// Read once from the Privacy & Security extension's own strings, with the older names
    /// where it cannot be read.
    private static let settingNames: (desktop: String, documents: String) = {
        let bundle = Bundle(url: FilesAndFoldersSettings.extensionURL)
        func name(_ key: String, _ fallback: String) -> String {
            bundle?.localizedString(forKey: key, value: fallback, table: "Localizable") ?? fallback
        }
        return (name("DESKTOP_FOLDER", "Desktop Folder"), name("DOCUMENTS_FOLDER", "Documents Folder"))
    }()

    var url: URL {
        let path = switch self {
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .iCloudDrive: "Library/Mobile Documents/com~apple~CloudDocs"
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path, isDirectory: true)
    }

    /// "Desktop, Documents and iCloud Drive", or as few of them as there are.
    static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// What macOS decided about a folder, from one look into it.
enum FolderAccess: String, Sendable {
    case allowed
    /// Refused, and macOS does not ask again: only System Settings changes it.
    case notAllowed
    /// Nothing there: iCloud Drive turned off, say.
    case missing

    /// Opens `url` and reads its first entry, which has macOS ask the person when it has
    /// not yet decided about the folder, and blocks until they answer; it never asks twice.
    /// Off the main thread. Decided from errno, as Foundation reports a refusal that covers
    /// the folder itself, or a folder above it, as there being no such file.
    static func look(at url: URL) -> FolderAccess {
        let folder = open(url.path, O_RDONLY | O_DIRECTORY)
        guard folder >= 0 else { return verdict(errno: errno) }
        guard let listing = fdopendir(folder) else {
            let error = errno
            close(folder)
            return verdict(errno: error)
        }
        defer { closedir(listing) }
        errno = 0
        // NULL with errno still 0 is an empty folder.
        if readdir(listing) == nil, errno != 0 { return verdict(errno: errno) }
        return .allowed
    }

    /// Refused for EPERM or EACCES; anything else (ENOENT, ENOTDIR, ELOOP) means there is no
    /// folder there to see.
    static func verdict(errno code: Int32) -> FolderAccess {
        code == EPERM || code == EACCES ? .notAllowed : .missing
    }
}

/// Whether Islet has Full Disk Access, which lets it see every folder without macOS
/// asking about any. Full Disk Access is never asked for, so looking never prompts: the
/// answer is whether macOS lets Islet open a file only Full Disk Access opens.
enum FullDiskAccess {
    /// The Mac's own privacy database, there on every Mac, which its file permissions let
    /// anyone read, so Full Disk Access alone decides; then the person's own, which a Mac
    /// on macOS 27 may not have at all.
    static var markers: [String] {
        ["/Library/Application Support/com.apple.TCC/TCC.db",
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path]
    }

    /// Opens the first of `markers` that is there, for reading, and closes it unread:
    /// opened is Full Disk Access, EPERM (or EACCES) is not. With none there it answers no,
    /// so the folders are asked about one by one.
    static func isGranted(markers: [String] = markers) -> Bool {
        for path in markers {
            let file = open(path, O_RDONLY)
            if file >= 0 {
                close(file)
                return true
            }
            if errno != ENOENT { return false }
        }
        return false
    }
}

/// Privacy & Security › Files & Folders in System Settings, where a folder macOS has been
/// told Islet may not see is turned back on.
enum FilesAndFoldersSettings {
    static let anchor = "Privacy_FilesAndFolders"
    static let paneURL = "x-apple.systempreferences:com.apple.preference.security"
    static let anchoredURL = paneURL + "?" + anchor
    /// System Settings' Privacy & Security, whose search terms are keyed by the anchors it
    /// opens at.
    static let extensionURL = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex")

    /// The anchors the Privacy & Security extension at `url` lists, or `nil` where it
    /// cannot be read.
    static func anchors(in url: URL = extensionURL) -> Set<String>? {
        guard let bundle = Bundle(url: url),
              let attributes = bundle.object(forInfoDictionaryKey: "EXAppExtensionAttributes") as? [String: Any],
              let settings = attributes["SettingsExtensionAttributes"] as? [String: Any],
              let name = settings["searchTermsFileName"] as? String,
              let file = bundle.url(forResource: name, withExtension: "searchTerms"),
              let data = try? Data(contentsOf: file),
              let terms = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return Set(terms.keys)
    }

    /// Files & Folders where this macOS lists it, and Privacy & Security where it does not.
    /// Where the list cannot be read the anchor is used all the same: every macOS Islet
    /// runs on has it.
    static func url(anchors: Set<String>? = anchors()) -> URL {
        URL(string: (anchors.map { $0.contains(anchor) } ?? true) ? anchoredURL : paneURL)!
    }

    static func open() {
        NSWorkspace.shared.open(url())
    }
}

/// What macOS has decided about the folders PDFs saved from Print are seen in, for the
/// row in Settings that has it ask. Nothing is looked into until the person first asks:
/// from then on (remembered in the defaults) the folders macOS has decided about are
/// looked at again, silently, as the row shows and as Islet comes back to the front,
/// which is how a folder turned on in System Settings is noticed. A folder that was not
/// there is left until asked about again, as looking into it once it is would have macOS
/// ask out of the blue.
@MainActor
@Observable
final class FolderAccessModel {
    /// How the folders are looked at: for real, or made-up answers for tests.
    struct Probe: Sendable {
        var fullDiskAccess: @Sendable () -> Bool
        var look: @Sendable (PrintFolder) -> FolderAccess

        static let live = Probe(fullDiskAccess: { FullDiskAccess.isGranted() }, look: { FolderAccess.look(at: $0.url) })
    }

    /// `nil` until first looked at.
    private(set) var hasFullDiskAccess: Bool?
    /// What macOS decided, at the last look at each folder.
    private(set) var verdicts: [PrintFolder: FolderAccess]
    /// The folder being looked into on the person's click, which macOS may be asking about.
    private(set) var asking: PrintFolder?
    /// From the person's click until its answers are in, and for at least
    /// `minimumCheck`, so a click macOS answers at once still shows it was heard.
    private(set) var isAsking = false
    /// Called when a folder becomes one Islet may see, or Full Disk Access comes, for
    /// Spotlight to be asked again.
    @ObservationIgnored var refreshed: () -> Void = {}

    @ObservationIgnored private let probe: Probe
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let minimumCheck: Duration
    @ObservationIgnored private var isLooking = false
    /// Moved on by each click, so a silent look begun before it does not overwrite it.
    @ObservationIgnored private var generation = 0

    init(probe: Probe = .live, defaults: UserDefaults = .standard, minimumCheck: Duration = .milliseconds(600)) {
        self.probe = probe
        self.defaults = defaults
        self.minimumCheck = minimumCheck
        let saved = defaults.dictionary(forKey: DownloadsPrefs.folderAccess) as? [String: String] ?? [:]
        verdicts = saved.reduce(into: [:]) { verdicts, entry in
            if let folder = PrintFolder(rawValue: entry.key), let access = FolderAccess(rawValue: entry.value) {
                verdicts[folder] = access
            }
        }
    }

    /// Whether the person has ever clicked to be asked, which lets the silent looks begin.
    var hasAsked: Bool { defaults.object(forKey: DownloadsPrefs.folderAccess) != nil }

    /// Whether a click has brought answers in: one cut short, by Islet quitting while
    /// macOS asked, has none, and the row offers to ask again.
    var hasAnswers: Bool { !verdicts.isEmpty }

    var refused: [PrintFolder] { PrintFolder.allCases.filter { verdicts[$0] == .notAllowed } }

    /// Looks into each folder in turn, which has macOS ask about any it has not decided
    /// on yet; only ever on the person's click.
    func ask() async {
        guard !isAsking else { return }
        isAsking = true
        generation += 1
        if !hasAsked { save() }
        let started = ContinuousClock.now
        let before = verdicts
        var found: [(PrintFolder, FolderAccess)] = []
        let probe = probe
        for folder in PrintFolder.allCases {
            asking = folder
            let access = await Task.detached(priority: .userInitiated) { probe.look(folder) }.value
            found.append((folder, access))
            verdicts[folder] = access
        }
        asking = nil
        record(found, before: before)
        try? await Task.sleep(until: started + minimumCheck, clock: .continuous)
        isAsking = false
    }

    /// Full Disk Access, which never prompts, and then, only once the person has asked,
    /// the folders macOS has already decided about, which do not prompt either.
    func recheck() async {
        guard !isLooking, !isAsking else { return }
        isLooking = true
        defer { isLooking = false }
        let probe = probe
        let granted = await Task.detached(priority: .utility) { probe.fullDiskAccess() }.value
        let had = hasFullDiskAccess
        hasFullDiskAccess = granted
        if granted {
            if had == false { refreshed() }
            return
        }
        guard hasAsked else { return }
        let decided = PrintFolder.allCases.filter { verdicts[$0] == .allowed || verdicts[$0] == .notAllowed }
        guard !decided.isEmpty else { return }
        let started = generation
        let found = await Task.detached(priority: .utility) { decided.map { ($0, probe.look($0)) } }.value
        guard started == generation, !isAsking else { return }
        record(found, before: verdicts)
    }

    /// Keeps what was found, and has Spotlight asked again if a folder has become one
    /// Islet may see (a first look counts).
    private func record(_ found: [(PrintFolder, FolderAccess)], before: [PrintFolder: FolderAccess]) {
        var opened = false
        for (folder, access) in found {
            if access == .allowed, before[folder] != .allowed { opened = true }
            verdicts[folder] = access
        }
        save()
        if opened { refreshed() }
    }

    private func save() {
        defaults.set(verdicts.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value.rawValue },
                     forKey: DownloadsPrefs.folderAccess)
    }
}
