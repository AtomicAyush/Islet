import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The island's one drop handler, on the island itself from launch.
///
/// Being a drop destination before any drag begins is what gets the island offered
/// drags at all. At rest the destination is only the notch-sized island, so drags
/// anywhere else are untouched. A file dragged onto it opens the drop page; from
/// then on the pointer's position over the page is passed to the drop target, which
/// decides what lights up and where the files go.
///
/// A picture dragged out of a web page is taken too. It is not a file: browsers put
/// its bytes, a file promise and its link on the drag instead. SwiftUI's item
/// providers cannot load those bytes, and call promises in on their own (AppKit
/// throws if a promise's source answers with no file), so pictures are read off the
/// drag pasteboard by `PictureDrag` rather than through `DropInfo`.
struct IslandDropDelegate: DropDelegate {
    /// What SwiftUI asks the delegate about. `validateDrop` narrows it down: links
    /// and text are turned away unless they are pictures. Widening this list does not
    /// widen what AppKit sends the island: SwiftUI registers its drop view for all
    /// data whatever the list says, and only filters here.
    static let offeredTypes: [UTType] = [.fileURL, .image, .url]

    let model: IslandViewModel
    let layout: IslandLayout
    /// The pasteboard the drag is on; a test's own stands in for it.
    var pasteboard = NSPasteboard(name: .drag)

    private var target: (any DropTarget)? { model.center.dropTarget }

    func validateDrop(info: DropInfo) -> Bool {
        // A file dragged off the shelf starts over the island; it is leaving.
        !model.dragStartedOnIsland && target != nil && isWanted(info)
    }

    func dropEntered(info: DropInfo) {
        guard isWanted(info) else { return }
        model.fileDragApproached()
        track(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isWanted(info) else { return DropProposal(operation: .forbidden) }
        track(info)
        guard let target, let (point, size) = pagePoint(info.location),
              target.canDrop(at: point, in: size)
        else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        target?.dragMoved(to: nil, in: .zero)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let target, let (point, size) = pagePoint(info.location),
              target.canDrop(at: point, in: size)
        else {
            target?.dragMoved(to: nil, in: .zero)
            return false
        }
        if info.hasItemsConforming(to: [.fileURL]) {
            let providers = info.itemProviders(for: [.fileURL])
            Task { @MainActor in
                let urls = await Self.fileURLs(from: providers)
                target.drop(urls, at: point, in: size)
                target.dragMoved(to: nil, in: .zero)
            }
            return true
        }
        // Read now: promises must be called in before the drop returns, and the
        // next drag replaces what is on the pasteboard.
        guard let pictures = target as? PictureDropTarget, let drop = PictureDrag.read(pasteboard) else {
            target.dragMoved(to: nil, in: .zero)
            return false
        }
        pictures.drop(drop, at: point, in: size)
        // Unlit on the next turn, as it is for files: SwiftUI updates the drag once
        // more as the drop concludes, which would light the tile again.
        Task { @MainActor in target.dragMoved(to: nil, in: .zero) }
        return true
    }

    /// Files, as always, or a picture from a web page for a target that takes them.
    private func isWanted(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
            || (target is PictureDropTarget && PictureDrag.isPictureDrag(pasteboard))
    }

    private func track(_ info: DropInfo) {
        let located = pagePoint(info.location)
        target?.dragMoved(to: located?.0, in: located?.1 ?? .zero)
    }

    /// Where the pointer is over the drop page, if the page is showing. The page sits
    /// below the notch row, inset by the same padding `ExpandedIsland` gives it.
    private func pagePoint(_ location: CGPoint) -> (CGPoint, CGSize)? {
        guard model.mode == .expanded(focus: IslandViewModel.dropFocus) else { return nil }
        let inset = layout.earRadius + IslandLayout.expandedInset.leading - 6
        let size = CGSize(width: layout.size.width - 2 * inset, height: layout.bodyHeight)
        let point = CGPoint(x: location.x - inset, y: location.y - layout.notch.height)
        guard point.y >= 0, point.x >= 0, point.x <= size.width else { return nil }
        return (point, size)
    }

    /// The dragged files' URLs. Loaded as URL objects, which resolves the file
    /// reference URLs Finder drags into paths; anything else is skipped.
    private static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url, url.isFileURL { urls.append(url) }
        }
        return urls
    }
}
