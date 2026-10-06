import AppKit
import SwiftUI

/// Downloads as they arrive, beside the notch: the file's icon left of the camera and a
/// ring filling right of it, or a spinner while the size is not known; opened, how much
/// has come, how fast and how long is left. When one finishes, a card with the file,
/// to drag where it is needed, open, show in Finder or delete.
///
/// The browsers say how their downloads are going the way they tell Finder, and
/// `DownloadMonitor` listens. Islet can only watch another app's download: it cannot
/// pause or cancel one, so it never offers to, nor to delete one under way. A download
/// that fails or is cancelled just goes.
///
/// Delete is for a file dragged out to be uploaded, say, and not wanted after: it
/// deletes for good, not to the Trash, so it asks first (`DeleteConfirmation`). It is
/// offered only for a plain file, never a folder (an app, or an archive Safari has
/// opened), and deletes only while the file is still the one the card was made for.
/// Once the file has been dragged out somewhere, the card stays until it is deleted or
/// closed (`keptDuration`), stepping aside while something else needs the island.
///
/// A PDF saved from Print (⌘P, then PDF › Save as PDF, or a browser's Save as PDF) is
/// not a download, and nothing says it has been made; `PrintedPDFWatcher` looks for
/// them, and one gets the same card, saying it was saved. A file shows once, as a
/// download or as a PDF saved, never both.
@MainActor
final class DownloadsFeature: Feature {
    let id = "downloads"
    let title = "Downloads"
    let symbol = "arrow.down.circle.fill"
    let summary = "Downloads as they arrive beside the notch, and the file in a card when one finishes."
    var islandActivity: IslandActivityInfo? { IslandActivityInfo(self, order: 50) }

    static let bannerID = "downloads.finished"
    /// Long enough to reach for the file, from when the card goes up or the pointer
    /// leaves it. It stays while the pointer is on it (`heldDuration`).
    static let bannerDuration: TimeInterval = 5
    /// How long the card stays with the pointer on it, or the file being dragged: until
    /// the pointer leaves, but no more than a minute, should its leaving go unheard.
    static let heldDuration: TimeInterval = 60
    /// How long the card stays once its file has been dragged out somewhere, for it to be
    /// deleted once it has been uploaded: until it is deleted or closed, but no more than
    /// ten minutes, should it be forgotten.
    static let keptDuration: TimeInterval = 600
    /// A kept card with less than this left is not put back.
    static let keptReturnMinimum: TimeInterval = 2
    /// How long the card stays to say what Delete did: a moment to see the file is gone,
    /// longer to read why it was not.
    static let deletedDuration: TimeInterval = 0.9
    static let keptFileDuration: TimeInterval = 2.5
    /// A download over within this long gets no activity of its own; its card says it is done.
    static let showDelay: TimeInterval = 0.6
    /// Chrome withdraws a download's progress and publishes another when it renames the
    /// file; the activity waits this long before going, so it does not blink in between.
    static let endDelay: TimeInterval = 0.6

    let model = DownloadsModel()
    /// What macOS lets Islet see of the folders PDFs saved from Print are found in.
    let folderAccess: FolderAccessModel
    private let monitor: DownloadMonitor
    private let printed: PrintedPDFWatcher
    private let files: DownloadFileActions
    private let defaults: UserDefaults
    /// The folders followed from the start, and all of them once Safari's settings have
    /// been read; tests give their own.
    private let startingFolders: [URL]?
    private let folders: () -> [URL]
    private lazy var activity = DownloadsActivity(model: model)

    private var isRunning = false
    private var publishedSizes: DownloadsActivity.Sizes?
    private var showWork: DispatchWorkItem?
    private var endWork: DispatchWorkItem?
    private var folderTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?
    private var banner: IslandBanner?
    /// The finished download whose card was put up last.
    private(set) var shownCard: DownloadedCardFile?
    /// The card that stays because its file was dragged out: until it is deleted, closed
    /// or out of time. Another card, or a live activity arriving, may take the island
    /// meanwhile; it comes back once they have gone (`settleKeptCard`).
    private(set) var keptCard: DownloadedCardFile?
    private var isDragging = false
    private var isWatchingIsland = false
    /// The PDFs saved from Print shown so far, by path, with the file as it was then:
    /// word that a download finished there does not show it again while it is still
    /// that file, but a new file there, downloaded or saved, shows.
    private var savedFiles: [String: FileStamp] = [:]

    /// Tests give a watcher for PDFs saved from Print on folders of their own, file
    /// actions that leave Finder and the person's files alone, defaults of their own, and
    /// made-up answers about the folders macOS lets Islet see.
    init(
        monitor: DownloadMonitor? = nil, printed: PrintedPDFWatcher? = nil, startingFolders: [URL]? = nil,
        folders: @escaping () -> [URL] = DownloadFolders.all, files: DownloadFileActions = .system,
        defaults: UserDefaults = .standard, folderAccess: FolderAccessModel.Probe = .live
    ) {
        let monitor = monitor ?? DownloadMonitor()
        let printed = printed ?? PrintedPDFWatcher()
        self.monitor = monitor
        self.printed = printed
        self.startingFolders = startingFolders
        self.folders = folders
        self.files = files
        self.defaults = defaults
        self.folderAccess = FolderAccessModel(probe: folderAccess, defaults: defaults)
        self.folderAccess.refreshed = { [weak printed] in printed?.refresh() }
        model.onChange = { [weak self] in self?.sync() }
        monitor.onChange = { [weak self] items in self?.model.update(items) }
        monitor.onFinished = { [weak self] file in self?.finished(file) }
        printed.isDownload = { [weak monitor] url in monitor?.isDownload(url) ?? false }
        printed.onPrinted = { [weak self] file in self?.finished(file) }
        printed.onWithdrawn = { [weak self] url in self?.withdraw(url) }
    }

    func start() {
        isRunning = true
        // Downloads straight away; Safari's folder once its settings have been read.
        monitor.start(folders: startingFolders ?? DownloadFolders.downloads.map { [$0] } ?? [])
        followPrinted()
        let folders = folders
        folderTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { folders() }.value
            guard let self, self.isRunning, !Task.isCancelled else { return }
            self.monitor.watch(found)
            self.printed.watch(found)
        }
    }

    /// Looks for PDFs saved from Print while that is turned on in Settings, in the
    /// folders downloads are followed into as well as through Spotlight; not at all while
    /// it is off.
    func followPrinted() {
        if isRunning, DownloadsPrefs.bool(DownloadsPrefs.showPrinted, default: true, in: defaults) {
            printed.start(folders: monitor.folders)
        } else {
            printed.stop()
            savedFiles.removeAll()
        }
    }

    func stop() {
        isRunning = false
        folderTask?.cancel()
        folderTask = nil
        monitor.stop()
        printed.stop()
        savedFiles.removeAll()
        model.update([])
        // Gone at once, rather than after the moment a download ending waits; a preview
        // still running carries on.
        if model.shown.isEmpty {
            showWork?.cancel()
            showWork = nil
            endWork?.cancel()
            endWork = nil
            publishedSizes = nil
            ActivityCenter.shared.end(id: activity.id)
        }
        keptCard = nil
        isDragging = false
        ActivityCenter.shared.dismissBanner(id: Self.bannerID)
        banner = nil
    }

    func settingsView() -> AnyView? {
        // The folders as Settings finds them, followed from then on: Safari's may have
        // been changed since the feature started.
        AnyView(DownloadsSettingsView(
            found: { [weak self] folders in
                guard let self, self.isRunning, self.startingFolders == nil else { return }
                self.monitor.watch(folders)
                self.printed.watch(folders)
            },
            printedChanged: { [weak self] in self?.followPrinted() },
            access: folderAccess
        ))
    }

    /// Made-up downloads, not the person's: each runs its course beside the notch, and
    /// the finished card hands over a small sample file.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Download in progress") { [weak self] in self?.preview(.single) },
            FeaturePreview(title: "Download of unknown size") { [weak self] in self?.preview(.unknownSize) },
            FeaturePreview(title: "Several downloads") { [weak self] in self?.preview(.several) },
            FeaturePreview(title: "Download finished") { [weak self] in self?.previewFinished() },
        ]
    }

    // MARK: Island

    /// Shows the activity while anything is downloading, a moment after the first
    /// download starts and until a moment after the last one ends.
    private func sync() {
        let center = ActivityCenter.shared
        if !model.shown.isEmpty {
            endWork?.cancel()
            endWork = nil
            if center.isShowing(id: activity.id) {
                let sizes = activity.sizes
                if sizes != publishedSizes {
                    publishedSizes = sizes
                    center.show(activity)
                }
            } else if showWork == nil {
                schedule(after: model.isPreviewing ? 0 : Self.showDelay, into: \.showWork) { feature in
                    guard !feature.model.shown.isEmpty else { return }
                    feature.publishedSizes = feature.activity.sizes
                    center.show(feature.activity)
                }
            }
        } else {
            showWork?.cancel()
            showWork = nil
            guard center.isShowing(id: activity.id), endWork == nil else { return }
            schedule(after: Self.endDelay, into: \.endWork) { feature in
                guard feature.model.shown.isEmpty else { return }
                feature.publishedSizes = nil
                center.end(id: feature.activity.id)
            }
        }
    }

    private func schedule(
        after delay: TimeInterval,
        into slot: ReferenceWritableKeyPath<DownloadsFeature, DispatchWorkItem?>,
        _ body: @escaping @MainActor (DownloadsFeature) -> Void
    ) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self[keyPath: slot] = nil
                body(self)
            }
        }
        self[keyPath: slot] = work
        if delay <= 0 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// A download has finished, or a PDF has been saved from Print.
    private func finished(_ file: FinishedDownload) {
        guard isRunning else { return }
        let path = file.url.resolvingSymlinksInPath().path
        let stamp = files.stamp(file.url)
        if let saved = savedFiles[path], saved == stamp { return }
        if file.isSaved {
            guard DownloadsPrefs.bool(DownloadsPrefs.showPrinted, default: true, in: defaults) else { return }
            savedFiles[path] = stamp
        } else {
            guard DownloadsPrefs.bool(DownloadsPrefs.showFinished, default: true, in: defaults) else { return }
        }
        // The opened island draws no banners. One open on the download, watching it come
        // in, closes for the card, which is what the watching was for.
        for island in IslandManager.shared.controllers.values.map(\.model)
        where island.isExpanded && island.resolvedFocus == activity.id {
            island.collapse()
        }
        present(file)
    }

    /// Takes down the card of a PDF saved from Print that turned out to be one of many
    /// copied at once, unless its file has been dragged out since.
    private func withdraw(_ url: URL) {
        guard let card = shownCard, card.file.isSaved, card.keptUntil == nil,
              card.file.url.standardizedFileURL.path == url.standardizedFileURL.path
        else { return }
        dismissCard(of: card)
    }

    /// Puts up the card for `file`, in place of any card up already. A kept card steps
    /// aside for it.
    func present(_ file: FinishedDownload) {
        show(DownloadedCardFile(file: file, stamp: files.stamp(file.url)))
    }

    private func show(_ card: DownloadedCardFile, haptic: Bool = true) {
        let actions = actions(for: card)
        let banner = IslandBanner(
            id: Self.bannerID,
            style: .card(
                width: actions.delete == nil ? DownloadedCardLayout.width : DownloadedCardLayout.deleteWidth,
                height: DownloadedCardLayout.height
            ),
            duration: card.keptUntil?.timeIntervalSinceNow ?? Self.bannerDuration,
            haptic: haptic,
            personal: .files,
            // Each card starts afresh, even one for a file of the same name put up in its
            // place, so Delete asked on one is never answered on another.
            content: AnyView(DownloadedCard(
                file: card.file,
                hover: { [weak self] in self?.holdBanner($0) },
                open: actions.open,
                reveal: actions.reveal,
                dismiss: actions.close,
                delete: actions.delete,
                dragged: actions.dragged,
                isKept: card.keptUntil != nil
            ).id(ObjectIdentifier(card)))
        )
        self.banner = banner
        shownCard = card
        ActivityCenter.shared.present(banner)
    }

    /// What the card's buttons do. Opening the file, or showing it in Finder, hands it to
    /// another app, and the card goes; so does closing it, for good if it was kept.
    ///
    /// Delete, once confirmed, deletes the file for good the first time, never a
    /// preview's sample, and only while it is still the plain file the card was made
    /// for: not if it has been moved, replaced, turned into a symbolic link or changed.
    /// The card says what it did, then goes. `nil` for a card with no Delete: a folder,
    /// or a file that could not be read when the card went up.
    ///
    /// A drag of the file that ends over somewhere that took it keeps the card up
    /// (`keep`); it is not deleted then, as the app it went to may still be reading it.
    func actions(for card: DownloadedCardFile) -> DownloadedCardActions {
        let files = files
        let url = card.file.url
        return DownloadedCardActions(
            open: { [weak self] in
                guard card.deleteResult == nil else { return }
                files.open(url)
                self?.close(card)
            },
            reveal: { [weak self] in
                guard card.deleteResult == nil else { return }
                files.reveal(url)
                self?.close(card)
            },
            close: { [weak self] in self?.close(card) },
            delete: card.stamp == nil ? nil : { [weak self] in
                self?.delete(card) ?? card.deleteResult ?? .failed
            },
            dragged: { [weak self] phase in self?.dragged(card, phase) }
        )
    }

    private func delete(_ card: DownloadedCardFile) -> DownloadDeleteResult {
        if let tried = card.deleteResult { return tried }
        let result = deleting(card)
        card.deleteResult = result
        if keptCard === card { keptCard = nil }
        let shownFor = result == .deleted ? Self.deletedDuration : Self.keptFileDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + shownFor) { [weak self] in
            MainActor.assumeIsolated { self?.dismissCard(of: card) }
        }
        return result
    }

    private func deleting(_ card: DownloadedCardFile) -> DownloadDeleteResult {
        // A preview's sample is not the person's to delete: the card goes as a
        // download's would, and the sample stays.
        if card.file.isSample { return .deleted }
        let url = card.file.url
        guard let stamp = card.stamp, let now = files.stamp(url) else {
            return files.isThere(url) ? .changed : .missing
        }
        guard now == stamp else { return .changed }
        return files.delete(url) ? .deleted : .failed
    }

    /// Takes the card down, and lets it go if it was kept.
    private func close(_ card: DownloadedCardFile) {
        if keptCard === card { keptCard = nil }
        dismissCard(of: card)
    }

    /// Takes the card down if it is still `card`'s, not another's put up since.
    private func dismissCard(of card: DownloadedCardFile) {
        guard shownCard === card, ActivityCenter.shared.banner?.id == Self.bannerID else { return }
        ActivityCenter.shared.dismissBanner(id: Self.bannerID)
    }

    /// The card stays while the pointer is on it, or the file is being dragged, so it
    /// does not go while the file is reached for; its time starts again when the pointer
    /// leaves. A kept card keeps its own time.
    func holdBanner(_ hovering: Bool) {
        guard var banner, ActivityCenter.shared.banner?.id == Self.bannerID, shownCard?.keptUntil == nil else { return }
        banner.duration = hovering || isDragging ? Self.heldDuration : Self.bannerDuration
        ActivityCenter.shared.present(banner)
    }

    private func dragged(_ card: DownloadedCardFile, _ phase: FileDragSource.Phase) {
        switch phase {
        case .began:
            isDragging = true
            holdBanner(true)
        case .ended(let dropped):
            isDragging = false
            if dropped, card.deleteResult == nil {
                keep(card)
            } else {
                holdBanner(false)
            }
        }
    }

    // MARK: Kept card

    /// The file has been dragged out somewhere, to be uploaded, say: its card stays, so
    /// the file can be deleted once it has gone, until it is deleted or closed or
    /// `keptDuration` has passed, from the last drop. Only the last card dragged out is
    /// kept, and it takes the place of one kept before. It covers the live activities
    /// showing now, as any card would, but not one arriving later.
    func keep(_ card: DownloadedCardFile) {
        let before = keptCard
        card.keptUntil = Date().addingTimeInterval(Self.keptDuration)
        card.covers = Set(ActivityCenter.shared.activities.map(\.id))
        keptCard = card
        if let shown = shownCard, shown === card || shown === before, ActivityCenter.shared.banner?.id == Self.bannerID {
            show(card)
        }
        settleKeptCard()
        watchIsland()
    }

    /// Puts the kept card back up once nothing else needs the island, and takes it down
    /// while something does: another card or banner, a live activity that arrived after
    /// it was kept (a download under way, a timer, a call), whose place it would take
    /// for minutes, or a shared screen the person's files are held back from. Once its
    /// time is up it is let go.
    private func settleKeptCard() {
        guard let card = keptCard else { return }
        guard let until = card.keptUntil, until.timeIntervalSinceNow > Self.keptReturnMinimum else {
            keptCard = nil
            return
        }
        let center = ActivityCenter.shared
        let isUp = shownCard === card && center.banner?.id == Self.bannerID
        let isFree = !center.holdsBack(.files) && Set(center.activities.map(\.id)).isSubset(of: card.covers)
        if isUp, !isFree {
            dismissCard(of: card)
        } else if !isUp, isFree, center.banner == nil {
            show(card, haptic: false)
        }
    }

    /// While a card is kept, looks again whenever the island's banner or live
    /// activities change, or what is held back from a shared screen, to take the card
    /// down or put it back (`settleKeptCard`).
    private func watchIsland() {
        guard keptCard != nil, !isWatchingIsland else { return }
        isWatchingIsland = true
        let center = ActivityCenter.shared
        withObservationTracking {
            _ = center.banner
            _ = center.activities
            _ = center.heldBack
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isWatchingIsland = false
                self.settleKeptCard()
                self.watchIsland()
            }
        }
    }

    // MARK: Previews

    private func preview(_ run: DownloadsSamples.Run) {
        sampleTask?.cancel()
        sampleTask = Task { [weak self] in
            let started = Date()
            var elapsed: TimeInterval = 0
            while elapsed <= run.duration {
                guard let self, !Task.isCancelled else { return }
                model.updateSamples(DownloadsSamples.items(for: run, at: elapsed, started: started))
                try? await Task.sleep(for: .seconds(0.5))
                elapsed = Date().timeIntervalSince(started)
            }
            guard let self, !Task.isCancelled else { return }
            model.updateSamples([])
            if var file = await DownloadsSamples.guide(), !Task.isCancelled {
                if run == .unknownSize { file.size = nil }
                present(file)
            }
        }
    }

    private func previewFinished() {
        Task { [weak self] in
            guard let file = await DownloadsSamples.guide() else { return }
            self?.present(file)
        }
    }
}

/// A finished download's card, and what has been done with it, shared by its buttons.
@MainActor
final class DownloadedCardFile {
    let file: FinishedDownload
    /// The file as it was when the card first went up; `nil` for a folder, or a file that
    /// could not be read, which the card offers no Delete for.
    let stamp: FileStamp?
    /// Once the file has been dragged out, until when the card stays.
    var keptUntil: Date?
    /// The live activities showing when the file was dragged out, which the kept card
    /// may cover; it steps aside for any other.
    var covers: Set<String> = []
    /// What Delete did, once it has been tried: it is tried only once.
    var deleteResult: DownloadDeleteResult?

    init(file: FinishedDownload, stamp: FileStamp?) {
        self.file = file
        self.stamp = stamp
    }
}

/// What the card's buttons do, given by the feature.
struct DownloadedCardActions {
    var open: () -> Void
    var reveal: () -> Void
    var close: () -> Void
    /// `nil` while the card has no Delete.
    var delete: (() -> DownloadDeleteResult)?
    var dragged: (FileDragSource.Phase) -> Void
}

/// What the card does to the file.
struct DownloadFileActions {
    var open: @MainActor (URL) -> Void
    var reveal: @MainActor (URL) -> Void
    /// The file as it is now; `nil` for anything but a plain file.
    var stamp: @MainActor (URL) -> FileStamp?
    /// Whether anything at all is where the file was.
    var isThere: @MainActor (URL) -> Bool
    /// Deletes the file for good, not to the Trash. Returns whether it is gone.
    var delete: @MainActor (URL) -> Bool

    static let system = DownloadFileActions(
        open: { NSWorkspace.shared.open($0) },
        reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        stamp: { FileStamp.read($0) },
        isThere: { FileStamp.isThere($0) },
        delete: { FileStamp.delete($0) }
    )
}

@MainActor
final class DownloadsActivity: IslandActivity {
    /// What the island's size depends on; a change re-publishes the activity.
    struct Sizes: Equatable {
        var trailing: CGFloat?
    }

    let id = "downloads"
    let name = "Downloads"
    var spokenStatus: String? {
        guard let item = model.displayed else { return nil }
        guard let fraction = item.fraction else { return item.name }
        return "\(item.name), \(Int((fraction * 100).rounded())) percent"
    }
    let symbol = "arrow.down.circle.fill"
    /// Its page names the files coming in.
    var personal: PersonalContent? { .files }
    let model: DownloadsModel

    init(model: DownloadsModel) { self.model = model }

    /// Wider on the right while several download, for their count beside the ring.
    var sizes: Sizes { Sizes(trailing: model.count > 1 ? ProgressWingLayout.countedTrailingWidth : nil) }

    var compactTrailingWidth: CGFloat? { sizes.trailing }
    var expandedHeight: CGFloat { ProgressWingLayout.expandedHeight }

    func compactLeading() -> AnyView { AnyView(DownloadsCompactLeading(model: model)) }
    func compactTrailing() -> AnyView { AnyView(DownloadsCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(DownloadsMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(DownloadsExpanded(model: model)) }
}

/// The feature's preference keys. Unset keys read as their defaults, the same ones the
/// settings toggles declare.
enum DownloadsPrefs {
    static let showFinished = "downloads.showFinished"
    static let showPrinted = "downloads.showPrinted"
    /// What macOS decided about each of the folders PDFs saved from Print are seen in, at
    /// the last look; there once the person has first asked (`FolderAccessModel`).
    static let folderAccess = "downloads.folderAccess"

    static func bool(_ key: String, default value: Bool, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }
}
