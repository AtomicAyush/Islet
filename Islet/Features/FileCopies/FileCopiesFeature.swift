import AppKit
import SwiftUI

/// Big copies as Finder makes them, beside the notch: what is being copied left of the
/// camera and a ring filling right of it, with a count when several go at once; opened,
/// where it is going, how much is done, how fast and how long is left, and Stop. A move
/// to another disk is a copy too, and so is a Duplicate.
///
/// Finder says how a copy is going the way browsers say how a download is, and
/// `FileCopyMonitor` listens. Only copies worth seeing come up: big ones, and ones that
/// take a while (Settings sets how big); one that is over in a moment never does.
/// Downloads are left to Downloads.
///
/// When a copy finishes, the tick in its ring is all there is: Finder says nothing when
/// one is done, and the copy is where the person put it, usually in a window in front
/// of them. A card for every long copy would be one more thing to close. A copy that is
/// stopped, or that fails, just goes.
@MainActor
final class FileCopiesFeature: Feature {
    let id = "fileCopies"
    let title = "File Copies"
    let symbol = "doc.on.doc.fill"
    let summary = "Big copies in Finder beside the notch, filling a ring as they go, with Stop when opened."
    var islandActivity: IslandActivityInfo? { IslandActivityInfo(self, order: 80) }

    /// The activity waits this long after the last copy goes before it does, so a copy
    /// following straight on from another does not make it blink.
    static let endDelay: TimeInterval = 0.6

    let model = FileCopiesModel()
    private let monitor: FileCopyMonitor
    /// The places listened to at all times; read off the main thread. Tests give their own.
    private let places: @Sendable () -> [URL]
    /// Where files being written are looked out for: every place a copy might go, or the
    /// test's own folders, or nowhere.
    private let writtenRoots: [URL]?
    private let watchesWrites: Bool
    private lazy var activity = FileCopiesActivity(model: model) { [weak self] id in self?.stopCopy(id: id) }

    private var isRunning = false
    private var writes: [WrittenFolders] = []
    private var mountObservers: [NSObjectProtocol] = []
    private var placesTask: Task<Void, Never>?
    private var publishedSizes: FileCopiesActivity.Sizes?
    private var endWork: DispatchWorkItem?
    private var sampleTask: Task<Void, Never>?

    init(
        monitor: FileCopyMonitor? = nil,
        places: @escaping @Sendable () -> [URL] = { FileCopyPlaces.standard() },
        writtenRoots: [URL]? = nil,
        watchesWrites: Bool = true
    ) {
        let monitor = monitor ?? FileCopyMonitor()
        self.monitor = monitor
        self.places = places
        self.writtenRoots = writtenRoots
        self.watchesWrites = watchesWrites
        model.onChange = { [weak self] in self?.sync() }
        monitor.onChange = { [weak self] items in self?.model.update(items) }
        monitor.onFinished = { [weak self] item in self?.model.finish(item) }
    }

    func start() {
        isRunning = true
        monitor.sizeThreshold = FileCopiesPrefs.thresholdBytes
        monitor.start(places: [])
        refreshPlaces()
        // A disk mounted is a place a copy may go; one ejected is not.
        let center = NSWorkspace.shared.notificationCenter
        mountObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPlaces() }
            }
        }
        if watchesWrites {
            let scopes = writtenRoots.map { [WrittenFolders.Scope(roots: $0, exclusions: [])] } ?? WrittenFolders.scopes()
            writes = scopes.map { scope in
                WrittenFolders(roots: scope.roots, exclusions: scope.exclusions) { [weak self] folders in
                    self?.monitor.noticeWrites(in: folders)
                }
            }
            writes.forEach { $0.start() }
        }
    }

    func stop() {
        isRunning = false
        placesTask?.cancel()
        placesTask = nil
        mountObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        mountObservers = []
        writes.forEach { $0.stop() }
        writes = []
        monitor.stop()
        model.update([])
        // Gone at once, rather than after the moment the activity waits; a preview still
        // running carries on.
        if !model.isPreviewing {
            model.clearFinished()
            endWork?.cancel()
            endWork = nil
            publishedSizes = nil
            ActivityCenter.shared.end(id: activity.id)
        }
    }

    func settingsView() -> AnyView? {
        AnyView(FileCopiesSettingsView { [weak self] in
            self?.monitor.sizeThreshold = FileCopiesPrefs.thresholdBytes
        })
    }

    /// Made-up copies, not the person's: each runs its course beside the notch and
    /// finishes with its tick. Stop ends one early.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Copy in progress") { [weak self] in self?.preview(.single) },
            FeaturePreview(title: "Copy of several items") { [weak self] in self?.preview(.several) },
            FeaturePreview(title: "Two copies at once") { [weak self] in self?.preview(.two) },
        ]
    }

    /// Reads the places off the main thread (the mounted disks are asked for), and
    /// listens at them from then on.
    private func refreshPlaces() {
        guard isRunning else { return }
        placesTask?.cancel()
        let places = places
        placesTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { places() }.value
            guard let self, self.isRunning, !Task.isCancelled else { return }
            self.monitor.watch(found)
        }
    }

    private func stopCopy(id: String) {
        if model.isPreviewing {
            // A preview's copy stops the way a real one does: it just goes.
            sampleTask?.cancel()
            sampleTask = nil
            model.updateSamples([])
        } else {
            monitor.stop(id: id)
        }
    }

    // MARK: Island

    /// Shows the activity while a copy is worth seeing, or has just finished, and until a
    /// moment after the last one goes.
    private func sync() {
        let center = ActivityCenter.shared
        if model.isActive {
            endWork?.cancel()
            endWork = nil
            let sizes = activity.sizes
            if !center.isShowing(id: activity.id) || sizes != publishedSizes {
                publishedSizes = sizes
                center.show(activity)
            }
        } else {
            guard center.isShowing(id: activity.id), endWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.endWork = nil
                    guard !self.model.isActive else { return }
                    self.publishedSizes = nil
                    center.end(id: self.activity.id)
                }
            }
            endWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.endDelay, execute: work)
        }
    }

    // MARK: Previews

    private func preview(_ run: FileCopiesSamples.Run) {
        sampleTask?.cancel()
        sampleTask = Task { [weak self] in
            let started = Date()
            var elapsed: TimeInterval = 0
            while elapsed <= run.duration {
                guard let self, !Task.isCancelled else { return }
                model.updateSamples(FileCopiesSamples.items(for: run, at: elapsed, started: started))
                try? await Task.sleep(for: .seconds(0.5))
                elapsed = Date().timeIntervalSince(started)
            }
            guard let self, !Task.isCancelled else { return }
            let last = FileCopiesSamples.items(for: run, at: run.duration, started: started)
            model.updateSamples(last)
            if let newest = last.last { model.finish(newest) }
            model.updateSamples([])
        }
    }
}

@MainActor
final class FileCopiesActivity: IslandActivity {
    /// What the island's size depends on; a change re-publishes the activity.
    struct Sizes: Equatable {
        var trailing: CGFloat?
    }

    let id = "fileCopies"
    let name = "File Copies"
    let symbol = "doc.on.doc.fill"
    /// Its page names the files being copied.
    var personal: PersonalContent? { .files }
    /// Below Now Playing's: music keeps the island, and a copy takes the bubble beside
    /// it. A copy is there to be glanced at, not waited on.
    let priority = ActivityPriority.background
    let model: FileCopiesModel
    let stop: (String) -> Void

    init(model: FileCopiesModel, stop: @escaping (String) -> Void) {
        self.model = model
        self.stop = stop
    }

    /// Wider on the right while several copies go, for their count beside the ring.
    var sizes: Sizes { Sizes(trailing: model.count > 1 ? ProgressWingLayout.countedTrailingWidth : nil) }

    var compactTrailingWidth: CGFloat? { sizes.trailing }
    var expandedHeight: CGFloat { ProgressWingLayout.expandedHeight }

    func compactLeading() -> AnyView { AnyView(FileCopiesCompactLeading(model: model)) }
    func compactTrailing() -> AnyView { AnyView(FileCopiesCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(FileCopiesMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(FileCopiesExpanded(model: model, stop: stop)) }
}

/// The feature's preference keys. Unset keys read as their defaults, the same ones the
/// settings picker declares.
enum FileCopiesPrefs {
    /// The size in megabytes (of a million bytes, as Finder counts them) from which a
    /// copy shows a second in, rather than only when it will take a few.
    static let threshold = "fileCopies.thresholdMegabytes"
    static let choices = [10, 50, 100, 500, 1000]
    static let defaultMegabytes = 50
    static let defaultThreshold = Int64(defaultMegabytes) * 1_000_000

    static var thresholdBytes: Int64 {
        let megabytes = UserDefaults.standard.object(forKey: threshold) as? Int ?? defaultMegabytes
        return Int64(max(1, megabytes)) * 1_000_000
    }

    /// "50 MB or more", "1 GB or more".
    static func label(megabytes: Int) -> String {
        megabytes >= 1000 && megabytes % 1000 == 0 ? "\(megabytes / 1000) GB or more" : "\(megabytes) MB or more"
    }
}
