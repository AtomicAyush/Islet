import Foundation
import Observation

/// A download under way, as the island shows it.
struct DownloadItem: Identifiable, Equatable {
    let id: String
    /// The finished file's name.
    var name: String
    /// Where the browser is writing it: its partial file, or Safari's bundle.
    var location: URL
    var received: Int64
    /// `nil` while the browser does not know how big the file will be.
    var total: Int64?
    var bytesPerSecond: Double?
    var secondsLeft: TimeInterval?
    let startedAt: Date

    /// How much has come, from 0 to 1, or `nil` while the size is not known.
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }

    /// The finished file's extension, for the icon of its type.
    var fileExtension: String { (name as NSString).pathExtension }
}

/// A download that has finished: the file, where it ended up.
struct FinishedDownload: Equatable {
    var url: URL
    var size: Int64?
    /// The file a preview hands over, made up by Islet: Delete leaves it be.
    var isSample = false
    /// A PDF saved from Print rather than downloaded (`PrintedPDFWatcher`): its card
    /// says it was saved.
    var isSaved = false

    var name: String { url.lastPathComponent }
}

/// The downloads under way, oldest first. Knows nothing about the island.
@MainActor
@Observable
final class DownloadsModel {
    /// The real downloads, as `DownloadMonitor` last reported them.
    private(set) var items: [DownloadItem] = []
    /// Made-up downloads a preview is running. While there are any they are shown in
    /// place of the real ones, which carry on underneath.
    private(set) var samples: [DownloadItem] = []

    /// Called after every change to what is shown.
    @ObservationIgnored var onChange: () -> Void = {}

    var shown: [DownloadItem] { samples.isEmpty ? items : samples }
    /// The newest download, which the island shows; the rest are counted beside it.
    var displayed: DownloadItem? { shown.last }
    var count: Int { shown.count }
    var isPreviewing: Bool { !samples.isEmpty }

    func update(_ items: [DownloadItem]) {
        guard items != self.items else { return }
        self.items = items
        if samples.isEmpty { onChange() }
    }

    func updateSamples(_ samples: [DownloadItem]) {
        guard samples != self.samples else { return }
        self.samples = samples
        onChange()
    }
}
