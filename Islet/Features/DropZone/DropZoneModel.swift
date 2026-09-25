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
    }

    let shelf = ShelfStore()
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

    // MARK: Drops

    func dropped(_ urls: [URL], on place: Place) {
        guard !urls.isEmpty else { return }
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

    /// Clears the note and any preview highlight, when the feature stops.
    func reset() {
        noteTask?.cancel()
        noteTask = nil
        note = nil
        hovered = nil
        demoTarget = nil
    }

    private func show(_ note: Note) {
        self.note = note
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
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
    /// picker opens behind whatever window is in front.
    private func airDrop(_ urls: [URL]) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls)
        else { return false }
        sharing = service
        NSApp.activate()
        service.perform(withItems: urls)
        return true
    }
}
