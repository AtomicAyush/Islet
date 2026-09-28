import AppKit
import SwiftUI

/// Downloads as they arrive, beside the notch: the file's icon left of the camera and a
/// ring filling right of it, or a spinner while the size is not known; opened, how much
/// has come, how fast and how long is left. When one finishes, a card with the file,
/// to drag where it is needed, open, or show in Finder.
///
/// The browsers say how their downloads are going the way they tell Finder, and
/// `DownloadMonitor` listens. Islet can only watch another app's download: it cannot
/// pause or cancel one, so it never offers to. A download that fails or is cancelled
/// just goes.
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
    /// How long the card stays with the pointer on it: until the pointer leaves, but no
    /// more than a minute, should its leaving go unheard.
    static let heldDuration: TimeInterval = 60
    /// A download over within this long gets no activity of its own; its card says it is done.
    static let showDelay: TimeInterval = 0.6
    /// Chrome withdraws a download's progress and publishes another when it renames the
    /// file; the activity waits this long before going, so it does not blink in between.
    static let endDelay: TimeInterval = 0.6

    let model = DownloadsModel()
    private let monitor: DownloadMonitor
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

    init(monitor: DownloadMonitor? = nil, startingFolders: [URL]? = nil, folders: @escaping () -> [URL] = DownloadFolders.all) {
        let monitor = monitor ?? DownloadMonitor()
        self.monitor = monitor
        self.startingFolders = startingFolders
        self.folders = folders
        model.onChange = { [weak self] in self?.sync() }
        monitor.onChange = { [weak self] items in self?.model.update(items) }
        monitor.onFinished = { [weak self] file in self?.finished(file) }
    }

    func start() {
        isRunning = true
        // Downloads straight away; Safari's folder once its settings have been read.
        monitor.start(folders: startingFolders ?? DownloadFolders.downloads.map { [$0] } ?? [])
        let folders = folders
        folderTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { folders() }.value
            guard let self, self.isRunning, !Task.isCancelled else { return }
            self.monitor.watch(found)
        }
    }

    func stop() {
        isRunning = false
        folderTask?.cancel()
        folderTask = nil
        monitor.stop()
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
        ActivityCenter.shared.dismissBanner(id: Self.bannerID)
        banner = nil
    }

    func settingsView() -> AnyView? {
        // The folders as Settings finds them, followed from then on: Safari's may have
        // been changed since the feature started.
        AnyView(DownloadsSettingsView { [weak self] folders in
            guard let self, self.isRunning, self.startingFolders == nil else { return }
            self.monitor.watch(folders)
        })
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

    private func finished(_ file: FinishedDownload) {
        guard isRunning, DownloadsPrefs.bool(DownloadsPrefs.showFinished, default: true) else { return }
        // The opened island draws no banners. One open on the download, watching it come
        // in, closes for the card, which is what the watching was for.
        for island in IslandManager.shared.controllers.values.map(\.model)
        where island.isExpanded && island.resolvedFocus == activity.id {
            island.collapse()
        }
        present(file)
    }

    private func present(_ file: FinishedDownload) {
        let center = ActivityCenter.shared
        let dismiss = { center.dismissBanner(id: Self.bannerID) }
        let banner = IslandBanner(
            id: Self.bannerID,
            style: .card(width: DownloadedCardLayout.width, height: DownloadedCardLayout.height),
            duration: Self.bannerDuration,
            personal: .files,
            content: AnyView(DownloadedCard(
                file: file,
                hover: { [weak self] in self?.holdBanner($0) },
                open: {
                    NSWorkspace.shared.open(file.url)
                    dismiss()
                },
                reveal: {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    dismiss()
                },
                dismiss: dismiss
            ).id(file.url))
        )
        self.banner = banner
        center.present(banner)
    }

    /// The card stays while the pointer is on it, so it does not go while the file is
    /// reached for; its time starts again when the pointer leaves.
    func holdBanner(_ hovering: Bool) {
        guard var banner, ActivityCenter.shared.banner?.id == Self.bannerID else { return }
        banner.duration = hovering ? Self.heldDuration : Self.bannerDuration
        ActivityCenter.shared.present(banner)
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
            if let file = await DownloadsSamples.guide(), !Task.isCancelled {
                present(run == .unknownSize ? FinishedDownload(url: file.url, size: nil) : file)
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

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}
