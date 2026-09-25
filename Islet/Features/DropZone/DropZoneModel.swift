import AppKit
import Observation

/// Where dropped files go (AirDrop, or the shelf for later) and what can be done
/// with them afterwards. Knows nothing about the island.
@MainActor
@Observable
final class DropZoneModel {
    enum Place: Equatable {
        case airDrop
        case shelf
    }

    /// What the tile that took a drop says for a moment afterwards.
    struct Note: Equatable {
        var place: Place
        var text: String
        var isError = false
        /// The drop is still being fetched; the tile shows a spinner until it is done.
        var isWorking = false
    }

    let shelf: ShelfStore
    private(set) var note: Note?
    /// The tile a file drag is over, as the island reports it.
    var hovered: Place?
    /// Lights a tile as if a file were held over it, for previews.
    var demoTarget: Place?

    /// Called after a file from the shelf is handed to another app (opened, shown in
    /// Finder, AirDropped), so the island can get out of the way.
    @ObservationIgnored var onHandOff: () -> Void = {}

    @ObservationIgnored private var noteTask: Task<Void, Never>?
    /// The AirDrop service last used, kept alive for as long as its picker may be up.
    @ObservationIgnored private var sharing: NSSharingService?
    /// Deletes the pictures made for the last AirDrop once it is over.
    @ObservationIgnored private var sharedPictures: SharedPictures?

    /// Where pictures dropped on AirDrop are made, to be deleted once sent.
    @ObservationIgnored private let sharingFolder: URL
    /// Picture drops still being made into files, by drop.
    @ObservationIgnored private var pictureJobs: [UUID: Task<Void, Never>] = [:]
    /// How many of each drop's pictures the shelf shows as on their way.
    @ObservationIgnored private var shownArriving: [UUID: Int] = [:]

    init(shelfFolder: URL? = ShelfArchive.picturesFolder, sharingFolder: URL = PictureFiles.sharingFolder) {
        shelf = ShelfStore(storageFolder: shelfFolder)
        self.sharingFolder = sharingFolder
        // Pictures made for an AirDrop before Islet last quit.
        PictureFiles.empty(sharingFolder)
    }

    // MARK: Drops

    func dropped(_ urls: [URL], on place: Place) {
        guard !urls.isEmpty else { return }
        // A picture in the temporary folder, Firefox's among them, is one its app may
        // still be writing and will not keep, so it goes the way a picture from Safari
        // does: made into a file of the drop's own once it is finished. A drop that
        // mixes them with other files can only come from Finder, where they are
        // finished, and goes as it always has: one note, one AirDrop.
        if urls.allSatisfy(PictureFiles.isPassingPicture) {
            dropped(PictureDrop(pictures: urls.map {
                DroppedPicture(sources: [.file($0)], names: PictureNames(given: $0.lastPathComponent))
            }), on: place)
            return
        }
        switch place {
        case .shelf:
            let added = shelf.add(urls)
            show(Note(
                place: .shelf,
                text: added == 0 ? "Already on the shelf" : "Added \(Self.describe(urls, count: added))"
            ))
        case .airDrop:
            if airDrop(urls) {
                show(Note(place: .airDrop, text: "Sharing \(Self.describe(urls))"))
            } else {
                show(Note(place: .airDrop, text: "AirDrop isn’t available", isError: true))
            }
        }
    }

    /// Pictures dragged out of a web page. They become files first: the shelf's go
    /// straight into its own folder, AirDrop's into a temporary one. Most are on the
    /// pasteboard already and take a moment; a download or a promise can take longer,
    /// and then the tile, and the shelf, show them on their way.
    func dropped(_ pictures: PictureDrop, on place: Place) {
        guard let folder = place == .shelf ? shelf.storageFolder : sharingFolder else {
            show(Note(place: place, text: Self.failure(count: pictures.pictures.count), isError: true))
            return
        }
        let making = PictureFiles.begin(pictures, in: folder)
        let id = UUID()
        let count = making.count
        let working = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            // Not once the drop is over, or was dropped by `reset()`.
            guard !Task.isCancelled, let self, pictureJobs[id] != nil else { return }
            show(Note(
                place: place, text: count == 1 ? "Getting the picture…" : "Getting \(count) pictures…", isWorking: true
            ), lasting: nil)
            if place == .shelf {
                shownArriving[id] = count
                shelf.picturesArriving(count)
            }
        }
        pictureJobs[id] = Task { [weak self] in
            let files = await making.files()
            working.cancel()
            guard let self, !Task.isCancelled else {
                PictureFiles.discard(files)
                return
            }
            pictureJobs[id] = nil
            if let shown = shownArriving.removeValue(forKey: id) { shelf.picturesArriving(-shown) }
            finished(files, of: count, on: place)
        }
    }

    private func finished(_ files: [URL], of count: Int, on place: Place) {
        guard !files.isEmpty else {
            show(Note(place: place, text: Self.failure(count: count), isError: true))
            return
        }
        switch place {
        case .shelf:
            shelf.add(files)
            show(Note(place: .shelf, text: "Added \(Self.describe(files))"))
        case .airDrop:
            if airDrop(files, discardingAfterwards: true) {
                show(Note(place: .airDrop, text: "Sharing \(Self.describe(files))"))
            } else {
                PictureFiles.discard(files)
                show(Note(place: .airDrop, text: "AirDrop isn’t available", isError: true))
            }
        }
    }

    private static func failure(count: Int) -> String {
        count == 1 ? "Couldn’t get the picture" : "Couldn’t get the pictures"
    }

    /// Clears the note and any preview highlight, and drops pictures still being
    /// fetched, when the feature stops.
    func reset() {
        noteTask?.cancel()
        noteTask = nil
        note = nil
        hovered = nil
        demoTarget = nil
        pictureJobs.values.forEach { $0.cancel() }
        pictureJobs.removeAll()
        shelf.picturesArriving(-shownArriving.values.reduce(0, +))
        shownArriving.removeAll()
    }

    /// Shows the note for `lasting`, or until the next one when `nil`.
    private func show(_ note: Note, lasting: Duration? = .seconds(2.4)) {
        self.note = note
        noteTask?.cancel()
        noteTask = nil
        guard let lasting else { return }
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: lasting)
            guard !Task.isCancelled else { return }
            self?.note = nil
        }
    }

    /// “Report.pdf” for one file, “3 items” for more.
    private static func describe(_ urls: [URL], count: Int? = nil) -> String {
        let count = count ?? urls.count
        if count == 1, urls.count == 1, let url = urls.first {
            return "“\(url.lastPathComponent)”"
        }
        return count == 1 ? "1 item" : "\(count) items"
    }

    // MARK: Shelf items

    func open(_ item: ShelfItem) {
        if NSWorkspace.shared.open(item.url) {
            onHandOff()
        } else {
            // Most likely the file has gone; take it off the shelf.
            shelf.refresh()
        }
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
        onHandOff()
    }

    func share(_ item: ShelfItem) {
        if airDrop([item.url]) { onHandOff() }
    }

    /// Hands files to AirDrop. Its picker is a window of this app, and an agent app is
    /// never frontmost by itself, so the app comes forward first; otherwise the
    /// picker opens behind whatever window is in front. Files made only to be sent
    /// are deleted once AirDrop is done with them.
    private func airDrop(_ urls: [URL], discardingAfterwards: Bool = false) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls)
        else { return false }
        sharing = service
        sharedPictures = discardingAfterwards ? SharedPictures(files: urls) : nil
        service.delegate = sharedPictures
        NSApp.activate()
        service.perform(withItems: urls)
        return true
    }
}

/// Deletes pictures made only to be AirDropped once the share is over, sent or not.
/// Any still there when Islet quits go when it next starts.
private final class SharedPictures: NSObject, NSSharingServiceDelegate {
    private let files: [URL]

    init(files: [URL]) {
        self.files = files
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        // AirDrop may report the share before it has read every byte of a large
        // picture; the temporary folder can hold it a while longer.
        PictureFiles.discard(files, after: 300)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        PictureFiles.discard(files, after: 300)
    }
}
