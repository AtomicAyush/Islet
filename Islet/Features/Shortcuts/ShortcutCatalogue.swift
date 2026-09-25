import Foundation
import Observation

/// A shortcut as Islet knows it.
struct ShortcutInfo: Identifiable, Hashable, Sendable {
    /// Upper-cased, as the tool prints it; `nil` for a shortcut known only by name.
    var identifier: String?
    var name: String
    /// The folder it is in, where the tool says.
    var folder: String?
    /// `nil` where the Shortcuts database could not be read: a plain tile stands in.
    var icon: ShortcutIcon?

    init(identifier: String?, name: String, folder: String? = nil, icon: ShortcutIcon? = nil) {
        self.identifier = identifier
        self.name = name
        self.folder = folder
        self.icon = icon
    }

    var id: String { identifier ?? "name:" + name }
    var target: ShortcutTarget { ShortcutTarget(identifier: identifier, name: name) }
}

/// The person's shortcuts, in their library's order, with the folder each is in and
/// its icon.
///
/// Which shortcuts there are comes from the command line tool, which lists exactly
/// what the Shortcuts app shows. Icons come from the Shortcuts database, which needs
/// Full Disk Access; without it every shortcut is drawn on a plain tile, and the list
/// is still complete. The database is also what says the list may have changed: its
/// signature is compared on every change the feature hears of, and the tool is asked
/// again only when it moved.
@MainActor
@Observable
final class ShortcutCatalogue {
    /// `nil` until the tool first answers.
    private(set) var shortcuts: [ShortcutInfo]?
    private(set) var access = ShortcutsDatabase.Access.unknown

    /// What the tool said, kept so a change to icons alone need not ask it again.
    struct Listing: Equatable, Sendable {
        var shortcuts: [ShortcutListing]
        /// Folder names, keyed by the identifiers of the shortcuts in them.
        var folders: [String: String]
    }

    /// Called when `access` changes.
    @ObservationIgnored var onAccessChange: () -> Void = {}

    @ObservationIgnored private let tool: ShortcutsTool
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var listing: Listing?
    @ObservationIgnored private var database: ShortcutsDatabase.Catalogue?
    @ObservationIgnored private var isRefreshing = false
    /// A refresh asked for while one was under way, and whether it must list again.
    @ObservationIgnored private var queued: Bool?
    @ObservationIgnored private var pendingChange: Task<Void, Never>?
    /// Bumped by `reset()`, so a refresh already under way is dropped.
    @ObservationIgnored private var generation = 0

    /// A folder listing as long as the whole library is not believed: the tool lists
    /// every shortcut for a folder it cannot find. At most this many folders are asked
    /// about, each a run of the tool.
    nonisolated static let foldersListed = 24

    init(tool: ShortcutsTool = .system, directory: URL = ShortcutsDatabase.defaultDirectory) {
        self.tool = tool
        self.directory = directory
    }

    func shortcut(identifier: String) -> ShortcutInfo? {
        shortcuts?.first { $0.identifier?.caseInsensitiveCompare(identifier) == .orderedSame }
    }

    /// The shortcut with this name: the one spelled exactly so, or else the only one
    /// whose name matches ignoring case.
    func shortcut(named name: String) -> ShortcutInfo? {
        guard let shortcuts else { return nil }
        if let exact = shortcuts.first(where: { $0.name == name }) { return exact }
        let loose = shortcuts.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return loose.count == 1 ? loose.first : nil
    }

    /// Reads the database again, and asks the tool again if it changed — or always,
    /// with `relist`: for Settings, where a shortcut made a moment ago should be there
    /// to pick, and for when the database cannot be read and so cannot say.
    func refresh(relist: Bool = false) {
        guard !isRefreshing else {
            queued = (queued ?? false) || relist
            return
        }
        isRefreshing = true
        let generation = generation
        let tool = tool
        let directory = directory
        Task {
            let reading = await Task.detached(priority: .utility) {
                ShortcutsDatabase.catalogue(directory: directory)
            }.value
            guard generation == self.generation else { return }

            var database = database
            var access = access
            switch reading {
            case .value(let catalogue):
                database = catalogue
                access = .granted
            case .needsFullDiskAccess, .unavailable:
                database = nil
                access = reading.access ?? .unavailable
            case .unreadable:
                // Keep what was read last; with nothing read yet, the database is not
                // one this code can use.
                if database == nil { access = .unavailable }
            }

            var listing = listing
            let moved = database == nil || database?.signature != self.database?.signature
            if relist || listing == nil || moved, let fresh = await Self.list(tool) {
                listing = fresh
            }
            guard generation == self.generation else { return }

            self.database = database
            self.listing = listing
            if self.access != access {
                self.access = access
                onAccessChange()
            }
            // A tool that never answers still leaves the picker with something to say.
            let assembled = listing.map { Self.assemble($0, icons: database?.icons ?? [:]) } ?? []
            if assembled != shortcuts { shortcuts = assembled }

            isRefreshing = false
            if let relist = queued {
                queued = nil
                refresh(relist: relist)
            }
        }
    }

    /// Something in the database changed: a save the daemon announced, or its files.
    /// Changes come several to a run, so this waits a moment for them to settle.
    func databaseChanged(after delay: TimeInterval = 0.5) {
        guard pendingChange == nil else { return }
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            pendingChange = nil
            refresh()
        }
    }

    /// Forgets everything read, for the feature being switched off.
    func reset() {
        generation &+= 1
        pendingChange?.cancel()
        pendingChange = nil
        isRefreshing = false
        queued = nil
        listing = nil
        database = nil
        shortcuts = nil
        if access != .unknown {
            access = .unknown
            onAccessChange()
        }
    }

    /// The tool's list, and the folders it can place shortcuts in. `nil` when the tool
    /// could not list at all.
    nonisolated static func list(_ tool: ShortcutsTool) async -> Listing? {
        guard let all = await tool.list() else { return nil }
        var folders: [String: String] = [:]
        for folder in (await tool.folders() ?? []).prefix(foldersListed) {
            guard let members = await tool.list(folder: folder.identifier ?? folder.name),
                  members.count < all.count
            else { continue }
            for member in members {
                guard let identifier = member.identifier?.uppercased(), folders[identifier] == nil else { continue }
                folders[identifier] = folder.name
            }
        }
        return Listing(shortcuts: all, folders: folders)
    }

    /// The tool's list with the database's icons, each shortcut once.
    nonisolated static func assemble(_ listing: Listing, icons: [String: ShortcutIcon]) -> [ShortcutInfo] {
        var seen = Set<String>()
        return listing.shortcuts.compactMap { item in
            let identifier = item.identifier?.uppercased()
            let shortcut = ShortcutInfo(
                identifier: identifier,
                name: item.name,
                folder: identifier.flatMap { listing.folders[$0] },
                icon: identifier.flatMap { icons[$0] }
            )
            return seen.insert(shortcut.id).inserted ? shortcut : nil
        }
    }
}
