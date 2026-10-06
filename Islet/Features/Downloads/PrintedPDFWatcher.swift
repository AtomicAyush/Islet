import AppKit
import UniformTypeIdentifiers

/// What is known of a new PDF, from Spotlight or, in a followed folder, from the file
/// itself: enough to tell one just saved from Print from a download, a copy, or one an
/// app keeps for itself.
struct PrintedPDFFacts: Equatable {
    var path: String
    /// What wrote it, the PDF's Producer: Spotlight lists it among the file's encoding
    /// applications.
    var producers: [String] = []
    /// When the file was made, as its disk has it.
    var created: Date?
    /// When it was put in its folder: the moment it was made for a file written there,
    /// later for one copied, moved, duplicated or unpacked there, or synced down.
    var added: Date?
    var modified: Date?
    /// Whether it says where it was downloaded from.
    var isDownloaded = false
    /// The PDF's own creation date, when the file itself was read.
    var madeAt: Date?
    var size: Int64?
}

/// Why a PDF was or was not taken for one saved from Print.
enum PrintedPDFVerdict: Equatable {
    case printed
    /// Hidden, in the Trash, inside a package, in a temporary folder, or in the Library
    /// folder outside iCloud Drive and the cloud storage folder: where apps keep their
    /// own PDFs.
    case outOfSight
    /// Written by something other than the Mac's print engine or a browser's.
    case notPrinted
    case downloaded
    /// Made before the watcher started, or too long ago to be news: a new file of a PDF
    /// made long before among them.
    case old
    /// Put in its folder after it was made: copied, moved, duplicated, unpacked or
    /// synced down.
    case moved
    /// Saved again as the PDF it was, edited in Preview say, or another app's PDF saved
    /// again with the print engine.
    case rewritten
    /// Not known yet: Spotlight has not said everything, or the file is still being
    /// written. It is looked at again.
    case unknown
    /// One of more than a few made at once, which printing never does: a folder copied,
    /// or checked out.
    case burst
    /// Shown already, or a copy of one shown, or a download's, which Downloads shows.
    case seen
}

/// The rules a new PDF must pass to be one just saved from Print, the same whether
/// Spotlight told of it or it was found in a followed folder.
enum PrintedPDFs {
    /// The Producer the Mac's own print engine writes, which names this Mac's build:
    /// "macOS Version 27.0.1 (Build 26A434) Quartz PDFContext". A PDF made on another
    /// Mac, or before an update, says another.
    static let quartzProducer = "macOS " + ProcessInfo.processInfo.operatingSystemVersionString + " Quartz PDFContext"

    /// A PDF made longer ago than this when it is heard of is not news. Spotlight takes
    /// half a minute over a long document, and a print may take minutes to write.
    static let maxAge: TimeInterval = 300
    /// A file written in place is added to its folder the moment it is made.
    static let addedWithin: TimeInterval = 2
    /// A PDF whose own creation date is this much older than the file was copied from
    /// one made long ago. Browsers date the PDF when the preview is drawn, which may be a
    /// while before Save.
    static let madeBefore: TimeInterval = 3600
    /// A browser's PDF whose own creation date is this much later than its file's was
    /// written over a file there already, as a browser does when Replace is chosen. An
    /// app's Save as PDF makes a new file instead, and Preview writes with the Mac's print
    /// engine, so an edit never looks like this.
    static let writtenOverAfter: TimeInterval = 5

    /// Where apps keep PDFs of their own, or nobody saves one.
    struct Places {
        var home: URL
        var temporary: [String]

        static var system: Places {
            Places(
                home: FileManager.default.homeDirectoryForCurrentUser,
                temporary: [NSTemporaryDirectory(), "/private/var/folders", "/var/folders", "/private/tmp", "/tmp"]
            )
        }
    }

    /// The Mac's print engine (only this Mac's), Chromium's (Skia, in Chrome, Brave, Edge
    /// and Arc) or Firefox's (cairo).
    static func isPrintEngine(_ producer: String, quartz: String = quartzProducer) -> Bool {
        producer == quartz || isBrowserEngine(producer)
    }

    /// Chromium's or Firefox's.
    static func isBrowserEngine(_ producer: String) -> Bool {
        if producer.hasPrefix("Skia/PDF m") {
            let version = producer.dropFirst("Skia/PDF m".count)
            return !version.isEmpty && version.allSatisfy(isDigit)
        }
        if producer.hasPrefix("cairo ") {
            return producer.dropFirst("cairo ".count).first.map(isDigit) == true
        }
        return false
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// Somewhere a person does not save a PDF: a hidden folder (the Trash among them, and
    /// the ones Google Drive keeps its uploads in), inside a package, a temporary folder,
    /// or the Library folder, but for iCloud Drive (where TextEdit and Pages save) and
    /// the folder Dropbox and others keep theirs in.
    static func isOutOfSight(_ path: String, places: Places = .system) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let path = url.path
        if places.temporary.contains(where: { path.hasPrefix(($0.hasSuffix("/") ? $0 : $0 + "/")) }) { return true }
        let folders = url.pathComponents.dropFirst().dropLast()
        if url.pathComponents.dropFirst().contains(where: { $0.hasPrefix(".") }) { return true }
        if folders.contains(where: isPackage) { return true }
        let library = places.home.standardizedFileURL.appendingPathComponent("Library").path + "/"
        guard path.hasPrefix(library) else { return false }
        let inside = path.dropFirst(library.count).split(separator: "/", omittingEmptySubsequences: true)
        guard inside.count >= 3 else { return true }
        if inside[0] == "CloudStorage" { return false }
        guard inside[0] == "Mobile Documents" else { return true }
        return !(inside[1] == "com~apple~CloudDocs" || inside[2] == "Documents")
    }

    /// A folder macOS shows as one item: an app, a bundle, a Pages document.
    private static func isPackage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory), !type.isDynamic
        else { return false }
        return type.conforms(to: .package) || type.conforms(to: .bundle)
    }

    /// When the PDF was made: when its file was, or, for a browser's written over a file
    /// there already, the PDF's own creation date. A copy, a rename and a Preview save
    /// keep it.
    static func made(_ facts: PrintedPDFFacts) -> Date? {
        guard let created = facts.created else { return nil }
        if let madeAt = facts.madeAt, madeAt.timeIntervalSince(created) > writtenOverAfter,
           facts.producers.contains(where: isBrowserEngine) {
            return madeAt
        }
        return created
    }

    static func verdict(
        _ facts: PrintedPDFFacts, since start: Date, now: Date = Date(),
        places: Places = .system, quartz: String = quartzProducer
    ) -> PrintedPDFVerdict {
        if isOutOfSight(facts.path, places: places) { return .outOfSight }
        if facts.producers.isEmpty { return .unknown }
        guard facts.producers.contains(where: { isPrintEngine($0, quartz: quartz) }) else { return .notPrinted }
        if facts.isDownloaded { return .downloaded }
        guard let created = facts.created, let added = facts.added, let made = made(facts) else { return .unknown }
        if made < start.addingTimeInterval(-1) || now.timeIntervalSince(made) > maxAge { return .old }
        // A new file is added to its folder as it is made; one written over keeps its date.
        if made == created, abs(added.timeIntervalSince(created)) > addedWithin { return .moved }
        if let madeAt = facts.madeAt, made.timeIntervalSince(madeAt) > madeBefore { return .old }
        return .printed
    }

    // MARK: Reading

    /// What Spotlight says of a PDF, without the file itself being looked at.
    static func facts(of item: NSMetadataItem) -> PrintedPDFFacts? {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let encoders = item.value(forAttribute: "kMDItemEncodingApplications")
        let whereFroms = item.value(forAttribute: "kMDItemWhereFroms") as? [Any]
        return PrintedPDFFacts(
            path: path,
            producers: (encoders as? [String]) ?? (encoders as? String).map { [$0] } ?? [],
            created: item.value(forAttribute: "kMDItemFSCreationDate") as? Date,
            added: item.value(forAttribute: "kMDItemDateAdded") as? Date,
            modified: item.value(forAttribute: "kMDItemFSContentChangeDate") as? Date,
            isDownloaded: whereFroms?.isEmpty == false || item.value(forAttribute: "kMDItemDownloadedDate") != nil,
            size: (item.value(forAttribute: "kMDItemFSSize") as? NSNumber)?.int64Value
        )
    }

    /// What the file itself says: its dates, whether it was downloaded, and its PDF's
    /// Producer and creation date. Only for a file Islet may read without macOS asking:
    /// one in a folder it follows, or one Spotlight has told of, which it does only in
    /// folders macOS lets Islet see. `nil` while it cannot be read as a PDF: not
    /// finished yet.
    static func read(_ url: URL) -> PrintedPDFFacts? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey, .addedToDirectoryDateKey,
                                         .contentModificationDateKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
              let document = CGPDFDocument(url as CFURL)
        else { return nil }
        var facts = PrintedPDFFacts(
            path: url.path, created: values.creationDate, added: values.addedToDirectoryDate,
            modified: values.contentModificationDate,
            isDownloaded: hasAttribute("com.apple.metadata:kMDItemWhereFroms", url)
                || hasAttribute("com.apple.metadata:kMDItemDownloadedDate", url),
            size: values.fileSize.map(Int64.init)
        )
        if let info = document.info {
            facts.producers = string(info, "Producer").map { [$0] } ?? []
            facts.madeAt = string(info, "CreationDate").flatMap(date(fromPDF:))
        }
        return facts
    }

    private static func hasAttribute(_ name: String, _ url: URL) -> Bool {
        getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }

    /// A PDF date, "D:20261006142530+01'00'", to the second; without a zone, as UTC.
    static func date(fromPDF text: String) -> Date? {
        var text = Substring(text)
        if text.hasPrefix("D:") { text = text.dropFirst(2) }
        let digits = text.prefix(while: isDigit)
        guard digits.count >= 14 else { return nil }
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        func number(_ from: Int, _ length: Int) -> Int {
            Int(digits.dropFirst(from).prefix(length)) ?? 0
        }
        parts.year = number(0, 4)
        parts.month = number(4, 2)
        parts.day = number(6, 2)
        parts.hour = number(8, 2)
        parts.minute = number(10, 2)
        parts.second = number(12, 2)
        var offset = 0
        let zone = text.dropFirst(digits.count)
        if let sign = zone.first, sign == "+" || sign == "-" {
            let numbers = zone.dropFirst().split(whereSeparator: { !isDigit($0) }).compactMap { Int($0) }
            offset = ((numbers.first ?? 0) * 3600 + (numbers.dropFirst().first ?? 0) * 60) * (sign == "-" ? -1 : 1)
        }
        parts.timeZone = TimeZone(secondsFromGMT: offset)
        return parts.date
    }
}

/// Notices PDFs as they are saved from Print, from the moment it starts: ⌘P, then PDF ›
/// Save as PDF in any app, or Save as PDF in a browser's print preview. Neither is a
/// download, and nothing tells Downloads of them, so they are looked for.
///
/// Spotlight says first: a live query across the home folder for PDFs written since the
/// watcher started, which costs nothing while nothing is saved and hears of a new one
/// about two seconds after it is written (half a minute for a long document). What
/// Spotlight knows of each rules out most at once; one the Mac's print engine or a
/// browser's wrote is then read, for the PDF's own creation date, which tells a new file
/// of an old PDF and a PDF written over a file there already. Spotlight tells Islet only
/// of folders macOS lets it see, quietly, without asking, so reading one asks nothing of
/// macOS either.
///
/// The folders Downloads follows (Downloads, Safari's) are also watched themselves
/// (`FolderWatcher`), which hears of a PDF there at once, and stands in for Spotlight
/// where it is off: a new PDF in one is read, and again a moment later while it is still
/// being written. Whichever hears first decides; the other is let be. With Spotlight off,
/// PDFs saved anywhere else are not seen.
///
/// What is taken for a PDF just saved from Print is set out in `PrintedPDFs.verdict`; a
/// burst of more than a few at once is a folder copied, and none of it shows. What was
/// decided of a file holds until it is written again, and what it was (shown, one of a
/// burst, a download, another app's PDF) follows it when it is renamed, duplicated or
/// saved again in Preview. Each PDF shows once, never one that is a download or a copy of
/// one shown, and never one made before the watcher started.
@MainActor
final class PrintedPDFWatcher {
    var onPrinted: (FinishedDownload) -> Void = { _ in }
    /// Whether a file is a download, under way or finished: those are Downloads' own.
    var isDownload: (URL) -> Bool = { _ in false }
    /// A PDF shown a moment ago turned out to be one of a burst: its card should go.
    var onWithdrawn: (URL) -> Void = { _ in }
    /// What was decided about each PDF heard of, for tests.
    var onVerdict: (String, PrintedPDFVerdict) -> Void = { _, _ in }

    /// More PDFs than this made within `burstSpan` of each other are a burst.
    static let burstLimit = 3
    static let burstSpan: TimeInterval = 2
    /// How long a PDF that passes waits for others made with it, to tell a burst.
    /// Spotlight may tell of the others a second or two later; a PDF shown by then is
    /// withdrawn.
    static let burstHold: TimeInterval = 0.2
    /// When Spotlight is asked again about a PDF it has not said everything of.
    static let askAgainDelays: [TimeInterval] = [0.5, 1.5, 3, 6]
    /// How long what was decided of a file is kept. By then any PDF is too old to show.
    static let forgetAfter: TimeInterval = 1800
    /// Spotlight's results keep every PDF written since the query started; past this
    /// many, it starts again from a few minutes ago, which is all that can still be news.
    static let resultLimit = 1000

    private(set) var isRunning = false
    /// Whether Spotlight is being asked; `false` where it would not start.
    private(set) var isQuerying = false

    /// Where Spotlight looks; none, for the folders alone.
    private let scopes: [Any]
    private let places: PrintedPDFs.Places
    /// When a new PDF in a followed folder is read, after it turns up.
    private let recheckDelays: [TimeInterval]
    private var startedAt = Date()
    /// The PDFs Spotlight is asked about were written since this.
    private var queriedSince = Date()
    private var query: NSMetadataQuery?
    private var queryObservers: [NSObjectProtocol] = []
    private var watchers: [String: FolderWatcher] = [:]
    /// Names in each folder when it was last listed, so what is new can be told.
    private var knownNames: [String: Set<String>] = [:]
    /// What was decided of each file, by its path and when the file was made: when it
    /// was last written, so it is let be until it is written again, and when its PDF was
    /// made, so a save that keeps the PDF it was can be told.
    private var judged: [String: (modified: Date?, made: Date, at: Date)] = [:]
    /// What follows a PDF wherever it goes, by when it was made, which a rename, a
    /// duplicate and a Preview save keep: shown, one of a burst or a download (`.seen`),
    /// or another app's (`.rewritten`, should the print engine save it again).
    private var births: [Int64: (verdict: PrintedPDFVerdict, made: Date)] = [:]
    /// Each PDF shown, by its size and its own creation date, which a copy keeps, with
    /// when its own creation date was and when it was made.
    private var shownContent: [String: (madeAt: Date, made: Date)] = [:]
    /// PDFs being read, and PDFs Spotlight is to be asked about again.
    private var reading: Set<String> = []
    private var askingAgain: Set<String> = []
    /// PDFs that passed, waiting `burstHold`.
    private var pending: [String: (url: URL, facts: PrintedPDFFacts, made: Date)] = [:]
    private var flushWork: DispatchWorkItem?
    /// The PDFs that passed lately, when each was made, and whether it was shown, to
    /// tell a burst.
    private var recent: [(path: String, made: Date, heard: Date, shown: Bool)] = []
    private var generation = 0

    /// Tests keep Spotlight to a folder of their own, with Library and temporary folders
    /// of their own, and read sooner.
    init(
        scopes: [Any] = [NSMetadataQueryUserHomeScope],
        places: PrintedPDFs.Places = .system,
        recheckDelays: [TimeInterval] = [0.3, 1, 2, 4, 8, 15, 30]
    ) {
        self.scopes = scopes
        self.places = places
        self.recheckDelays = recheckDelays
    }

    func start(folders: [URL]) {
        guard !isRunning else { return }
        isRunning = true
        startedAt = Date()
        queriedSince = startedAt.addingTimeInterval(-1)
        generation &+= 1
        if !scopes.isEmpty { startQuery() }
        watch(folders)
    }

    /// Watches these folders themselves from now on, and lets go of the others.
    func watch(_ folders: [URL]) {
        guard isRunning else { return }
        let wanted = Set(folders.map(\.standardizedFileURL.path))
        for (path, watcher) in watchers where !wanted.contains(path) {
            watcher.stop()
            watchers[path] = nil
            knownNames[path] = nil
        }
        for path in wanted {
            if let watcher = watchers[path] {
                watcher.retry()
                continue
            }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let watcher = FolderWatcher(url: folder, debounce: 0.1) { [weak self] in self?.folderChanged(folder) }
            watchers[path] = watcher
            watcher.start()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        stopQuery()
        watchers.values.forEach { $0.stop() }
        watchers.removeAll()
        knownNames.removeAll()
        judged.removeAll()
        births.removeAll()
        shownContent.removeAll()
        reading.removeAll()
        askingAgain.removeAll()
        pending.removeAll()
        flushWork?.cancel()
        flushWork = nil
        recent.removeAll()
    }

    /// Asks Spotlight afresh, for folders macOS may just have let Islet see. PDFs heard
    /// of already are not shown again.
    func refresh() {
        guard isRunning, !scopes.isEmpty else { return }
        stopQuery()
        startQuery()
    }

    // MARK: Spotlight

    private func startQuery() {
        let since = ISO8601DateFormatter().string(from: queriedSince)
        let query = NSMetadataQuery()
        // Every PDF, not only the print engines': one another app made is remembered, so
        // that saving it again in Preview is not taken for a print.
        query.predicate = NSPredicate(fromMetadataQueryString:
            "kMDItemContentType == 'com.adobe.pdf' && kMDItemFSContentChangeDate >= $time.iso(\(since))")
        query.searchScopes = scopes
        query.notificationBatchingInterval = 0.1
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            queryObservers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.received(note) }
            })
        }
        self.query = query
        isQuerying = query.start()
        if !isQuerying { stopQuery() }
    }

    private func stopQuery() {
        query?.stop()
        query = nil
        isQuerying = false
        queryObservers.forEach(NotificationCenter.default.removeObserver)
        queryObservers.removeAll()
    }

    /// Every result once the query has gathered, the ones added or changed after: a PDF
    /// may come first without what is needed to judge it, and that arrives as a change.
    private func received(_ note: Notification) {
        guard let query, note.object as? NSMetadataQuery === query else { return }
        var items: [NSMetadataItem] = []
        if note.name == .NSMetadataQueryDidFinishGathering {
            query.disableUpdates()
            items = (0..<query.resultCount).compactMap { query.result(at: $0) as? NSMetadataItem }
            query.enableUpdates()
        } else {
            for key in [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey] {
                items += (note.userInfo?[key] as? [NSMetadataItem]) ?? []
            }
        }
        for item in items {
            guard let facts = PrintedPDFs.facts(of: item) else { continue }
            if heard(facts) == .unknown { askAgain(item, path: facts.path) }
        }
        let recently = Date().addingTimeInterval(-PrintedPDFs.maxAge - 60)
        if note.name == .NSMetadataQueryDidUpdate, query.resultCount > Self.resultLimit, queriedSince < recently {
            queriedSince = max(startedAt.addingTimeInterval(-1), recently)
            refresh()
        }
    }

    /// Looks at what Spotlight knows of a PDF again, at each of `askAgainDelays`, until it
    /// can be judged, should no change notice come meanwhile.
    private func askAgain(_ item: NSMetadataItem, path: String, attempt: Int = 0) {
        guard Self.askAgainDelays.indices.contains(attempt), attempt > 0 || askingAgain.insert(path).inserted else {
            if attempt > 0 { askingAgain.remove(path) }
            return
        }
        let wait = Self.askAgainDelays[attempt] - (attempt > 0 ? Self.askAgainDelays[attempt - 1] : 0)
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.generation == generation else { return }
                guard let facts = PrintedPDFs.facts(of: item), self.heard(facts) == .unknown else {
                    self.askingAgain.remove(path)
                    return
                }
                self.askAgain(item, path: path, attempt: attempt + 1)
            }
        }
    }

    /// What Spotlight says of a PDF. One it rules out, or one decided already and not
    /// written since, is settled with that; one made by a print engine and written since
    /// the watcher started is read first, for the PDF's own creation date.
    private func heard(_ facts: PrintedPDFFacts) -> PrintedPDFVerdict {
        let url = URL(fileURLWithPath: facts.path).standardizedFileURL
        guard isRunning, pending[url.path] == nil, !reading.contains(url.path), !isUnchanged(url, facts)
        else { return .seen }
        let verdict = PrintedPDFs.verdict(facts, since: startedAt, places: places)
        guard [.printed, .old, .moved].contains(verdict), let modified = facts.modified,
              modified >= startedAt.addingTimeInterval(-1)
        else { return judge(url, facts) }
        reading.insert(url.path)
        let generation = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let read = PrintedPDFs.read(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.isRunning, self.generation == generation else { return }
                    self.reading.remove(url.path)
                    // Gone already, or not a plain file.
                    guard read != nil || FileStamp.read(url) != nil else { return }
                    var known = read ?? facts
                    if known.producers.isEmpty { known.producers = facts.producers }
                    self.judge(url, known)
                }
            }
        }
        return verdict
    }

    // MARK: Followed folders

    private func folderChanged(_ folder: URL) {
        let generation = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.isRunning, self.generation == generation,
                          self.watchers[folder.path] != nil
                    else { return }
                    // The first listing is what was there already.
                    let known = self.knownNames[folder.path]
                    self.knownNames[folder.path] = names
                    guard let known else { return }
                    for name in names.subtracting(known)
                    where !name.hasPrefix(".") && (name as NSString).pathExtension.lowercased() == "pdf" {
                        self.read(folder.appendingPathComponent(name))
                    }
                }
            }
        }
    }

    /// Reads a new PDF in a followed folder at each of `recheckDelays` after it turned
    /// up, until it can be judged: one still being written cannot be.
    private func read(_ url: URL, attempt: Int = 0) {
        let path = url.standardizedFileURL.path
        guard isRunning, recheckDelays.indices.contains(attempt) else {
            reading.remove(path)
            return
        }
        guard attempt > 0 || reading.insert(path).inserted else { return }
        let wait = recheckDelays[attempt] - (attempt > 0 ? recheckDelays[attempt - 1] : 0)
        let generation = generation
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, wait)) {
            var facts = PrintedPDFs.read(url)
            // Changed a moment ago: still being written.
            if let modified = facts?.modified, Date().timeIntervalSince(modified) < 0.25 { facts = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.isRunning, self.generation == generation else { return }
                    if let facts, self.judge(url, facts) != .unknown {
                        self.reading.remove(path)
                    } else {
                        self.read(url, attempt: attempt + 1)
                    }
                }
            }
        }
    }

    // MARK: Showing

    /// Whether this file has been decided on and not written since.
    private func isUnchanged(_ url: URL, _ facts: PrintedPDFFacts) -> Bool {
        guard let created = facts.created, let known = judged[Self.identity(url.path, created)] else { return false }
        guard let before = known.modified, let now = facts.modified else { return true }
        return abs(now.timeIntervalSince(before)) < 0.5
    }

    @discardableResult
    private func judge(_ url: URL, _ facts: PrintedPDFFacts) -> PrintedPDFVerdict {
        let url = url.standardizedFileURL
        guard isRunning, pending[url.path] == nil, !isUnchanged(url, facts) else { return .seen }
        forget()
        let identity = facts.created.map { Self.identity(url.path, $0) }
        let made = PrintedPDFs.made(facts)
        var verdict: PrintedPDFVerdict
        if let identity, let known = judged[identity], let made, Self.key(made) == Self.key(known.made) {
            // Written again, still the PDF it was: saved again in Preview, say.
            verdict = .rewritten
        } else {
            verdict = PrintedPDFs.verdict(facts, since: startedAt, places: places)
        }
        if verdict == .printed, let made {
            if let birth = births[Self.key(made)] {
                verdict = birth.verdict
            } else if isDownload(url) {
                births[Self.key(made)] = (.seen, made)
                verdict = .seen
            } else if let content = Self.content(facts), let shown = shownContent[content],
                      made.timeIntervalSince(shown.made) > Self.burstSpan {
                // The same PDF as one shown, made since: a copy. Ones made with it are
                // a burst.
                verdict = .seen
            }
        }
        if let created = facts.created, births[Self.key(created)] == nil {
            if verdict == .notPrinted { births[Self.key(created)] = (.rewritten, created) }
            if verdict == .downloaded { births[Self.key(created)] = (.seen, created) }
        }
        if let identity, let made, ![.unknown, .outOfSight].contains(verdict) {
            judged[identity] = (facts.modified, made, Date())
        }
        onVerdict(url.path, verdict)
        guard verdict == .printed, let made else { return verdict }
        pending[url.path] = (url, facts, made)
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstHold, execute: work)
        return verdict
    }

    /// Shows the PDFs that passed, unless more were made at once than printing makes;
    /// then any of them shown already is withdrawn.
    private func flush() {
        flushWork = nil
        let now = Date()
        recent.removeAll { now.timeIntervalSince($0.heard) > 60 }
        let waiting = pending.values.sorted { $0.url.path < $1.url.path }
        pending.removeAll()
        let times = recent.map(\.made) + waiting.map(\.made)
        for (url, facts, made) in waiting where isRunning {
            births[Self.key(made)] = (.seen, made)
            let isTogether = { (date: Date) in abs(date.timeIntervalSince(made)) <= Self.burstSpan }
            if times.filter(isTogether).count > Self.burstLimit {
                onVerdict(url.path, .burst)
                recent.append((url.path, made, now, false))
                for index in recent.indices where recent[index].shown && isTogether(recent[index].made) {
                    recent[index].shown = false
                    onWithdrawn(URL(fileURLWithPath: recent[index].path))
                }
                continue
            }
            if let content = Self.content(facts), let madeAt = facts.madeAt { shownContent[content] = (madeAt, made) }
            recent.append((url.path, made, now, true))
            onPrinted(FinishedDownload(url: url, size: facts.size, isSaved: true))
        }
    }

    /// Lets go of what can no longer matter: a PDF made that long ago is not shown.
    private func forget() {
        let now = Date()
        judged = judged.filter { now.timeIntervalSince($0.value.at) < Self.forgetAfter }
        births = births.filter { now.timeIntervalSince($0.value.made) < Self.forgetAfter }
        shownContent = shownContent.filter { now.timeIntervalSince($0.value.madeAt) < PrintedPDFs.madeBefore }
    }

    /// When a file was made, to the microsecond: what a copy of it keeps exactly.
    private static func key(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSinceReferenceDate * 1_000_000).rounded())
    }

    /// A file, by its path and when it was made: a new file there is another.
    private static func identity(_ path: String, _ created: Date) -> String {
        "\(key(created)) \(path)"
    }

    /// A PDF's size and its own creation date, to the second, which a copy keeps.
    private static func content(_ facts: PrintedPDFFacts) -> String? {
        guard let size = facts.size, let madeAt = facts.madeAt else { return nil }
        return "\(size) \(Int64(madeAt.timeIntervalSince1970.rounded(.down)))"
    }
}
