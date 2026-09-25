import SwiftUI
import UniformTypeIdentifiers

/// The island's one drop handler, on the island itself from launch.
///
/// Being a drop destination before any drag begins is what gets the island offered
/// drags at all. At rest the destination is only the notch-sized island, so drags
/// anywhere else are untouched. A file dragged onto it opens the drop page; from
/// then on the pointer's position over the page is passed to the drop target, which
/// decides what lights up and where the files go.
struct IslandDropDelegate: DropDelegate {
    let model: IslandViewModel
    let layout: IslandLayout

    private var target: (any DropTarget)? { model.center.dropTarget }

    func validateDrop(info: DropInfo) -> Bool {
        target != nil && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        model.fileDragApproached()
        track(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
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
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            let urls = await Self.fileURLs(from: providers)
            target.drop(urls, at: point, in: size)
            target.dragMoved(to: nil, in: .zero)
        }
        return true
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
