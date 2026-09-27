import Foundation
import Observation

/// A copy under way, as the island shows it: Finder copying or duplicating, or moving
/// something to another disk, which it does by copying.
struct FileCopyItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case copying
        case duplicating
    }

    let id: String
    var kind: Kind
    /// What is being copied: the item's name, or "12 items" for several.
    var name: String
    /// How many items were chosen, where the copy says; a folder counts as one.
    var itemCount: Int?
    /// The folder it is going into, and that folder's name as Finder shows it; `nil`
    /// where macOS would not say.
    var destination: URL?
    var destinationName: String?
    var copied: Int64
    /// `nil` while the copy is still working out how much there is.
    var total: Int64?
    /// From 0 to 1, as the copy measures itself, or `nil` while it cannot say.
    var fraction: Double?
    var bytesPerSecond: Double?
    var secondsLeft: TimeInterval?
    /// Whether the copy lets itself be stopped from outside, as Finder's do.
    var canStop: Bool
    /// Stop was clicked, and the copy has yet to go.
    var isStopping = false
    let startedAt: Date

    var isSeveral: Bool { (itemCount ?? 1) > 1 }

    /// The one item's extension, for the icon of its type; none for several items.
    var fileExtension: String { isSeveral ? "" : (name as NSString).pathExtension }

    /// "12 items", or "1 item".
    static func itemsName(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}

/// The copies under way, oldest first, and the one that has just finished. Knows
/// nothing about the island.
@MainActor
@Observable
final class FileCopiesModel {
    /// The real copies, as `FileCopyMonitor` last reported them.
    private(set) var items: [FileCopyItem] = []
    /// Made-up copies a preview is running. While there are any they are shown in place
    /// of the real ones, which carry on underneath.
    private(set) var samples: [FileCopyItem] = []
    /// The copy the island was showing when it finished, while its tick shows.
    private(set) var finished: FileCopyItem?

    /// How long a finished copy's tick shows before the activity folds away.
    static let finishedDuration: TimeInterval = 1.2

    /// Called after every change to what is shown.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private var finishedTask: Task<Void, Never>?

    var shown: [FileCopyItem] { samples.isEmpty ? items : samples }
    /// The newest copy, which the island shows, unless one that started later still has
    /// just finished; the rest are counted beside it.
    var displayed: FileCopyItem? {
        if let finished, finished.startedAt >= (shown.last?.startedAt ?? .distantPast) { return finished }
        return shown.last ?? finished
    }
    /// Whether the island is showing a copy that has finished.
    var isDisplayedFinished: Bool { finished != nil && displayed?.id == finished?.id }
    /// Copies still under way.
    var count: Int { shown.count }
    var isActive: Bool { !shown.isEmpty || finished != nil }
    var isPreviewing: Bool { !samples.isEmpty }

    func update(_ items: [FileCopyItem]) {
        guard items != self.items else { return }
        self.items = items
        if samples.isEmpty { onChange() }
    }

    func updateSamples(_ samples: [FileCopyItem]) {
        guard samples != self.samples else { return }
        self.samples = samples
        onChange()
    }

    /// A copy ran to the end. Its tick shows for a moment if it was the one the island
    /// was showing; one that finishes while a newer one goes on ends quietly. Called
    /// while it is still among `items` or `samples`.
    func finish(_ item: FileCopyItem) {
        guard shown.last?.id == item.id else { return }
        var done = item
        done.fraction = 1
        done.isStopping = false
        if let total = done.total { done.copied = total }
        done.secondsLeft = nil
        done.bytesPerSecond = nil
        finished = done
        finishedTask?.cancel()
        finishedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.finishedDuration))
            guard let self, !Task.isCancelled else { return }
            finished = nil
            onChange()
        }
        onChange()
    }

    /// Drops the finished copy's tick at once: the feature stopping.
    func clearFinished() {
        finishedTask?.cancel()
        finishedTask = nil
        guard finished != nil else { return }
        finished = nil
        onChange()
    }
}
