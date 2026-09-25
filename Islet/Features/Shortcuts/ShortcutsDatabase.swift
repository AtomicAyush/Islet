import Foundation
import SQLite3

/// Shortcuts' own database, `~/Library/Shortcuts/Shortcuts.sqlite`: the icons the
/// command line tool does not print, and a record of every run.
///
/// It is a Core Data store the Shortcuts daemon writes, undocumented, so it is only
/// ever read, through a read-only connection opened for one read and closed after it,
/// and read defensively: a table or column that is not there makes the read
/// `unreadable`, never a crash, and the feature carries on without what it would have
/// given. It is kept in write-ahead-log mode, with the newest rows only in the log
/// beside it, so it is opened normally (never as immutable) to see them.
///
/// Which shortcuts exist, and in what order, is not read from here: the table keeps
/// rows the library no longer shows (left over from iCloud syncing), and the order and
/// folders live in a format of Shortcuts' own. The command line tool says those.
enum ShortcutsDatabase {
    static let fileName = "Shortcuts.sqlite"

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Shortcuts", isDirectory: true)
    }

    /// Whether Islet can read the database.
    enum Access: Equatable, Sendable {
        /// Not looked yet.
        case unknown
        case granted
        /// macOS will not open it to Islet, which then needs Full Disk Access.
        case needsFullDiskAccess
        /// There is no database where Islet knows to look, or it is not one Islet
        /// knows how to read.
        case unavailable
    }

    /// One look at the database.
    enum Reading<Value: Sendable>: Sendable {
        case unavailable
        case needsFullDiskAccess
        /// It opened, but the query failed: a schema this code does not know, or the
        /// file busy for longer than the read would wait.
        case unreadable
        case value(Value)

        var access: Access? {
            switch self {
            case .unavailable: .unavailable
            case .needsFullDiskAccess: .needsFullDiskAccess
            case .unreadable: nil
            case .value: .granted
            }
        }
    }

    // MARK: Catalogue

    /// What the database adds to the tool's list of shortcuts.
    struct Catalogue: Equatable, Sendable {
        /// Keyed by the shortcut's identifier, upper-cased as the tool prints it.
        var icons: [String: ShortcutIcon]
        /// Changes when a shortcut is added, removed, renamed or given a new icon, or
        /// when the library's order or folders change — but not when one merely runs,
        /// which rewrites its row too. The tool is asked for the list again only then.
        var signature: Int
    }

    static func catalogue(directory: URL) -> Reading<Catalogue> {
        read(directory) { connection in
            var icons: [String: ShortcutIcon] = [:]
            var hasher = Hasher()
            let shortcuts = connection.rows("""
                SELECT s.ZWORKFLOWID, s.ZNAME, s.ZTOMBSTONED, s.ZHIDDENFROMLIBRARYANDSYNC, s.ZCONFLICTOF,
                       i.ZGLYPHNUMBER, i.ZBACKGROUNDCOLORVALUE
                FROM ZSHORTCUT s LEFT JOIN ZSHORTCUTICON i ON i.Z_PK = s.ZICON
                ORDER BY s.Z_PK
                """) { row in
                let identifier = row.text(0)?.uppercased()
                let glyph = row.integer(5)
                let colour = row.integer(6)
                hasher.combine(identifier)
                hasher.combine(row.text(1))
                hasher.combine(row.integer(2))
                hasher.combine(row.integer(3))
                hasher.combine(row.integer(4))
                hasher.combine(glyph)
                hasher.combine(colour)
                guard let identifier else { return }
                icons[identifier] = ShortcutIcon(glyph: glyph.map(Int.init), colourValue: colour)
            }
            guard shortcuts else { return nil }
            // Order and folders are kept in the library's row and the folders' rows,
            // whose version numbers rise with every change. Not every macOS may have
            // them; the signature then goes without.
            _ = connection.rows("SELECT Z_PK, Z_OPT FROM ZLIBRARY ORDER BY Z_PK") { row in
                hasher.combine(row.integer(0))
                hasher.combine(row.integer(1))
            }
            _ = connection.rows("SELECT Z_PK, Z_OPT FROM ZCOLLECTION ORDER BY Z_PK") { row in
                hasher.combine(row.integer(0))
                hasher.combine(row.integer(1))
            }
            return Catalogue(icons: icons, signature: hasher.finalize())
        }
    }

    // MARK: Runs

    /// The records of runs with these identifiers (`ZIDENTIFIER`), as a save
    /// notification names them.
    static func runEvents(identifiers: [String], directory: URL) -> Reading<[ShortcutRunEvent]> {
        read(directory) { connection in
            var events: [ShortcutRunEvent] = []
            for identifier in identifiers {
                let ok = connection.rows(runEventQuery + " WHERE r.ZIDENTIFIER = ?", [.text(identifier)]) { row in
                    if let event = ShortcutRunEvent(row: row) { events.append(event) }
                }
                guard ok else { return nil }
            }
            return events
        }
    }

    /// Records written since `key` (the newest one seen before), oldest first, and the
    /// newest key now. With `key` `nil`, only the newest key: where to start watching
    /// from, so runs from before Islet looked are never taken for new ones.
    static func runEvents(
        after key: Int64?, directory: URL, limit: Int = 50
    ) -> Reading<(events: [ShortcutRunEvent], latest: Int64)> {
        read(directory) { connection in
            var latest: Int64 = 0
            guard connection.rows("SELECT IFNULL(MAX(Z_PK), 0) FROM ZSHORTCUTRUNEVENT", [], { latest = $0.integer(0) ?? 0 })
            else { return nil }
            guard let key else { return ([], latest) }
            var events: [ShortcutRunEvent] = []
            let ok = connection.rows(
                runEventQuery + " WHERE r.Z_PK > ? ORDER BY r.Z_PK LIMIT ?", [.integer(key), .integer(Int64(limit))]
            ) { row in
                if let event = ShortcutRunEvent(row: row) { events.append(event) }
            }
            return ok ? (events, latest) : nil
        }
    }

    /// How the latest run of a shortcut from the command line since `date` ended, as
    /// its record says: `nil` when there is no such record. For telling a shortcut that
    /// failed from a tool that failed only after it, in handing back the output.
    static func commandLineOutcome(identifier: String, since date: Date, directory: URL) -> Reading<ShortcutRunEvent.State?> {
        read(directory) { connection in
            var state: ShortcutRunEvent.State?
            let ok = connection.rows(
                runEventQuery + """
                     WHERE UPPER(s.ZWORKFLOWID) = ? AND r.ZSOURCE = 'commandline' AND r.ZDATE >= ?
                    ORDER BY r.ZDATE DESC LIMIT 1
                    """,
                [.text(identifier.uppercased()), .real(date.timeIntervalSinceReferenceDate)]
            ) { row in
                state = ShortcutRunEvent(row: row)?.state
            }
            return ok ? .some(state) : nil
        }
    }

    private static let runEventQuery = """
        SELECT r.Z_PK, r.ZIDENTIFIER, r.ZSOURCE, r.ZDATE, r.ZOUTCOME,
               s.ZWORKFLOWID, s.ZNAME, i.ZGLYPHNUMBER, i.ZBACKGROUNDCOLORVALUE
        FROM ZSHORTCUTRUNEVENT r
        LEFT JOIN ZSHORTCUT s ON s.Z_PK = r.ZSHORTCUT
        LEFT JOIN ZSHORTCUTICON i ON i.Z_PK = s.ZICON
        """

    // MARK: Saves

    /// Posted by the Shortcuts daemon each time it saves the database, across
    /// processes: a run starting writes its record, and its end writes the outcome.
    /// Undocumented, like the database; the daemon's own launch configuration listens
    /// for it by this name.
    static let saveNotification = Notification.Name("com.apple.shortcuts.WFCoreDataDatabaseContextDidSaveNotification")

    // MARK: Reading

    /// Opens the database, runs `body` and closes it. `body` returns `nil` when a query
    /// failed.
    private static func read<Value: Sendable>(_ directory: URL, _ body: (Connection) -> Value?) -> Reading<Value> {
        let file = directory.appendingPathComponent(fileName)
        // macOS refuses a protected file at open(2) with EPERM, which SQLite reports
        // only as "cannot open"; asking first tells refusal from absence.
        let descriptor = open(file.path, O_RDONLY)
        if descriptor < 0 {
            return errno == EPERM || errno == EACCES ? .needsFullDiskAccess : .unavailable
        }
        close(descriptor)
        guard let connection = Connection(file) else { return .unreadable }
        return body(connection).map(Reading.value) ?? .unreadable
    }

    /// A read-only SQLite connection, closed when released.
    final class Connection {
        enum Binding {
            case text(String)
            case integer(Int64)
            case real(Double)
        }

        private let handle: OpaquePointer

        init?(_ file: URL) {
            // A URI, so the connection is read-only however SQLite would otherwise
            // open it. The file URL is already percent-encoded.
            var handle: OpaquePointer?
            let uri = file.absoluteString + "?mode=ro"
            let status = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            guard status == SQLITE_OK, let handle else {
                if let handle { sqlite3_close_v2(handle) }
                return nil
            }
            // The daemon writes in short transactions; a read waits a moment for one
            // rather than failing.
            sqlite3_busy_timeout(handle, 500)
            self.handle = handle
        }

        deinit {
            sqlite3_close_v2(handle)
        }

        /// Runs `sql`, calling `row` for each result row. Whether it ran to the end.
        @discardableResult
        func rows(_ sql: String, _ bindings: [Binding] = [], _ row: (Row) -> Void) -> Bool {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
            defer { sqlite3_finalize(statement) }
            for (index, binding) in bindings.enumerated() {
                let position = Int32(index + 1)
                switch binding {
                case .text(let text):
                    sqlite3_bind_text(statement, position, text, -1, Self.transient)
                case .integer(let value):
                    sqlite3_bind_int64(statement, position, value)
                case .real(let value):
                    sqlite3_bind_double(statement, position, value)
                }
            }
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: row(Row(statement: statement))
                case SQLITE_DONE: return true
                default: return false
                }
            }
        }

        /// SQLite copies bound text straight away.
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /// One result row. Every accessor is `nil` for a NULL, or a value of another type.
    struct Row {
        let statement: OpaquePointer

        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
                  let text = sqlite3_column_text(statement, column)
            else { return nil }
            return String(cString: text)
        }

        func integer(_ column: Int32) -> Int64? {
            guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { return nil }
            return sqlite3_column_int64(statement, column)
        }

        /// Core Data's dates: seconds since 2001.
        func date(_ column: Int32) -> Date? {
            let type = sqlite3_column_type(statement, column)
            guard type == SQLITE_FLOAT || type == SQLITE_INTEGER else { return nil }
            let seconds = sqlite3_column_double(statement, column)
            return seconds.isFinite ? Date(timeIntervalSinceReferenceDate: seconds) : nil
        }
    }
}

/// One record of a run, as the database keeps it: written as the run starts, and
/// given its outcome as it ends.
struct ShortcutRunEvent: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case succeeded
        /// Failed, or cancelled: the database does not tell the two apart.
        case failed
    }

    /// `Z_PK`, which only grows.
    var key: Int64
    /// `ZIDENTIFIER`, unique to the run.
    var identifier: String
    /// What started it: `commandline`, `menu_bar`, `spotlight-search`, `my-workflows`…
    var source: String?
    var date: Date?
    var state: State
    /// The shortcut it ran, as it is now; `nil` when the record names none.
    var shortcut: ShortcutInfo?

    init(key: Int64, identifier: String, source: String?, date: Date?, state: State, shortcut: ShortcutInfo?) {
        self.key = key
        self.identifier = identifier
        self.source = source
        self.date = date
        self.state = state
        self.shortcut = shortcut
    }

    /// A row of `runEventQuery`.
    fileprivate init?(row: ShortcutsDatabase.Row) {
        guard let key = row.integer(0), let identifier = row.text(1) else { return nil }
        // No outcome yet is a run still going; 1 ran to the end; anything else did not.
        let state: State = switch row.integer(4) {
        case nil, 0: .running
        case 1: .succeeded
        default: .failed
        }
        var shortcut: ShortcutInfo?
        if let name = row.text(6) {
            shortcut = ShortcutInfo(
                identifier: row.text(5)?.uppercased(),
                name: name,
                icon: ShortcutIcon(glyph: row.integer(7).map(Int.init), colourValue: row.integer(8))
            )
        }
        self.init(key: key, identifier: identifier, source: row.text(2), date: row.date(3), state: state, shortcut: shortcut)
    }
}

/// What one save of the Shortcuts database changed, from its notification's userInfo:
/// lists of `{identifier, objectType}` under `inserted`, `updated` and `deleted`.
struct ShortcutsDatabaseSave: Equatable {
    /// Runs whose record was written or changed: a start, or an end.
    var runEvents: [String] = []
    /// A shortcut was added, changed or removed (or the save did not say what it
    /// touched): the catalogue may be out of date.
    var touchesShortcuts = false

    /// The object types the daemon uses in these lists.
    static let shortcutType = 0
    static let runEventType = 5

    init(runEvents: [String] = [], touchesShortcuts: Bool = false) {
        self.runEvents = runEvents
        self.touchesShortcuts = touchesShortcuts
    }

    init(userInfo: [AnyHashable: Any]?) {
        guard let userInfo else {
            touchesShortcuts = true
            return
        }
        if (userInfo["invalidatedAllObjects"] as? NSNumber)?.boolValue == true { touchesShortcuts = true }
        var seen = Set<String>()
        for key in ["inserted", "updated", "deleted"] {
            for item in userInfo[key] as? [Any] ?? [] {
                guard let object = item as? [String: Any] else { continue }
                let type = (object["objectType"] as? NSNumber)?.intValue
                switch type {
                case Self.runEventType?:
                    // A record deleted is history being trimmed, not a run.
                    guard key != "deleted", let identifier = object["identifier"] as? String,
                          seen.insert(identifier).inserted
                    else { continue }
                    runEvents.append(identifier)
                case Self.shortcutType?, nil:
                    touchesShortcuts = true
                default:
                    continue
                }
            }
        }
    }
}

/// Listens for the Shortcuts database changing: the daemon's save notification, which
/// says what changed within milliseconds, and the files themselves, which change
/// whether or not a future macOS still posts it.
///
/// The files are the database and its write-ahead log, where every save lands, and
/// the folder they are in, which changes as the log is created and removed. Events
/// come in bursts, so the file callback waits until none has come for `debounce`
/// seconds. Without Full Disk Access the files cannot be watched, and only the
/// notification is heard.
final class ShortcutsDatabaseSignals: @unchecked Sendable {
    private let directory: URL
    private let notification: Notification.Name
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "Islet.Shortcuts.Watch", qos: .utility)
    private let onSave: @MainActor (ShortcutsDatabaseSave) -> Void
    private let onFilesChanged: @MainActor () -> Void

    private var observer: SaveObserver?
    // Only touched on `queue`.
    private var isOn = false
    private var folderSource: DispatchSourceFileSystemObject?
    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    /// Both callbacks are called on the main actor.
    init(
        directory: URL,
        notification: Notification.Name = ShortcutsDatabase.saveNotification,
        debounce: TimeInterval = 0.3,
        onSave: @escaping @MainActor (ShortcutsDatabaseSave) -> Void,
        onFilesChanged: @escaping @MainActor () -> Void
    ) {
        self.directory = directory
        self.notification = notification
        self.debounce = debounce
        self.onSave = onSave
        self.onFilesChanged = onFilesChanged
    }

    @MainActor
    func start() {
        guard observer == nil else { return }
        let onSave = onSave
        let observer = SaveObserver { save in
            DispatchQueue.main.async { MainActor.assumeIsolated { onSave(save) } }
        }
        // AppKit holds distributed notifications back while an app is inactive, and an
        // agent app almost always is.
        DistributedNotificationCenter.default().addObserver(
            observer, selector: #selector(SaveObserver.received(_:)), name: notification,
            object: nil, suspensionBehavior: .deliverImmediately
        )
        self.observer = observer
        queue.async {
            self.isOn = true
            self.armIfNeeded()
        }
    }

    @MainActor
    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        queue.async {
            self.isOn = false
            self.disarm()
            self.pending?.cancel()
            self.pending = nil
        }
    }

    /// Opens the file watch if it is not open, or opens the files again if only the
    /// folder could be watched: after Full Disk Access was granted, say.
    func rearmIfNeeded() {
        queue.async {
            if self.folderSource != nil, self.fileSources.isEmpty { self.watchFiles() }
            self.armIfNeeded()
        }
    }

    private func armIfNeeded() {
        guard isOn, folderSource == nil else { return }
        folderSource = watch(directory.path, events: [.write, .delete, .rename, .revoke]) { [weak self] events in
            self?.folderChanged(events)
        }
        if folderSource != nil { watchFiles() }
    }

    private func disarm() {
        folderSource?.cancel()
        folderSource = nil
        fileSources.forEach { $0.cancel() }
        fileSources.removeAll()
    }

    /// The files are opened again whenever the folder changes: the log is removed and
    /// made afresh, and the old watch would be on the one that went.
    private func watchFiles() {
        fileSources.forEach { $0.cancel() }
        fileSources = [ShortcutsDatabase.fileName, ShortcutsDatabase.fileName + "-wal"].compactMap { name in
            watch(directory.appendingPathComponent(name).path, events: [.write, .extend, .delete, .rename]) { [weak self] events in
                guard let self else { return }
                if !events.isDisjoint(with: [.delete, .rename]) { watchFiles() }
                changed()
            }
        }
    }

    private func folderChanged(_ events: DispatchSource.FileSystemEvent) {
        if events.isDisjoint(with: [.delete, .rename, .revoke]) {
            watchFiles()
        } else {
            disarm()
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.armIfNeeded() }
        }
        changed()
    }

    private func changed() {
        pending?.cancel()
        let onFilesChanged = onFilesChanged
        let work = DispatchWorkItem { [weak self] in
            guard let self, isOn else { return }
            pending = nil
            DispatchQueue.main.async { MainActor.assumeIsolated { onFilesChanged() } }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func watch(
        _ path: String,
        events: DispatchSource.FileSystemEvent,
        handler: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: queue)
        source.setEventHandler { [weak source] in
            guard let source, !source.isCancelled else { return }
            handler(source.data)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private final class SaveObserver: NSObject {
        private let handler: (ShortcutsDatabaseSave) -> Void

        init(handler: @escaping (ShortcutsDatabaseSave) -> Void) {
            self.handler = handler
        }

        @objc func received(_ notification: Notification) {
            handler(ShortcutsDatabaseSave(userInfo: notification.userInfo))
        }
    }
}
