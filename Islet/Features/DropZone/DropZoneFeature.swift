import AppKit
import SwiftUI

/// Files dragged to the notch. The island opens onto two places to drop them:
/// AirDrop, and a shelf that keeps them for later. While the shelf holds anything it
/// sits on the home page, and its files drag back out wherever they are needed.
@MainActor
final class DropZoneFeature: Feature {
    let id = "dropZone"
    let title = "Drop Zone"
    let symbol = "tray.and.arrow.down.fill"
    let summary = "Drag files to the notch to AirDrop them or keep them on a shelf."

    private let model = DropZoneModel()
    private lazy var target = DropZoneTarget(model: model)
    private var isRunning = false
    private var widgetShown = false
    /// Takes the drop zone down again after a preview put it up with the feature off.
    private var previewTeardown: DispatchWorkItem?
    private var demo: Task<Void, Never>?

    init() {
        model.shelf.onChange = { [weak self] in self?.syncWidget() }
        model.onHandOff = {
            IslandManager.shared.focusedController?.model.collapse()
        }
    }

    func start() {
        isRunning = true
        cancelPreviewTeardown()
        attach()
    }

    func stop() {
        isRunning = false
        cancelPreviewTeardown()
        detach()
    }

    func settingsView() -> AnyView? {
        AnyView(DropZoneSettings(shelf: model.shelf))
    }

    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Open drop zone") { [weak self] in self?.previewDropPage() },
            FeaturePreview(title: "Drop files on the shelf") { [weak self] in self?.previewDrop() },
            FeaturePreview(title: "Add sample files to shelf") { [weak self] in self?.previewShelf() },
        ]
    }

    /// `islet://dropZone/clear` empties the shelf.
    func handle(_ url: URL) -> Bool {
        guard url.path() == "/clear" else { return false }
        model.shelf.clear()
        return true
    }

    // MARK: Island

    private var isAttached: Bool { isRunning || previewTeardown != nil }

    private func attach() {
        ActivityCenter.shared.dropTarget = target
        model.shelf.loadIfNeeded()
        syncWidget()
    }

    private func detach() {
        demo?.cancel()
        demo = nil
        let center = ActivityCenter.shared
        if center.dropTarget === target { center.dropTarget = nil }
        widgetShown = false
        center.removeHomeWidget(id: id)
        model.reset()
        model.shelf.flush()
        FileThumbnails.shared.removeAll()
    }

    /// The shelf is on the home page exactly while it holds something.
    private func syncWidget() {
        let wanted = isAttached && !model.shelf.items.isEmpty
        guard wanted != widgetShown else { return }
        widgetShown = wanted
        if wanted {
            ActivityCenter.shared.setHomeWidget(HomeWidget(
                id: id, order: 60, weight: 1.5, view: AnyView(ShelfHomeTile(model: model))
            ))
        } else {
            ActivityCenter.shared.removeHomeWidget(id: id)
        }
    }

    // MARK: Previews

    private func previewDropPage() {
        attachForPreview()
        IslandManager.shared.focusedController?.model.expand(focus: IslandViewModel.dropFocus)
    }

    /// The drop page as a drag reaches it: the shelf lights up, then takes three
    /// sample files and says so. The page stays open until the pointer leaves it.
    private func previewDrop() {
        previewDropPage()
        demo?.cancel()
        demo = Task { [weak self] in
            let urls = await DropZoneSamples.make()
            guard let self, !Task.isCancelled else { return }
            // Take them off first, so the drop reads "Added" rather than "Already on the shelf".
            model.shelf.remove(urls: urls)
            model.demoTarget = .shelf
            try? await Task.sleep(for: .seconds(1.6))
            // Unlit even when cancelled by another preview, or the tile stays lit.
            model.demoTarget = nil
            guard !Task.isCancelled else { return }
            model.dropped(urls, on: .shelf)
        }
    }

    /// Fills the shelf and opens the home page on it. The files stay on the shelf.
    private func previewShelf() {
        demo?.cancel()
        demo = Task { [weak self] in
            let urls = await DropZoneSamples.make()
            guard let self, !Task.isCancelled else { return }
            attachForPreview()
            model.shelf.add(urls)
            IslandManager.shared.focusedController?.model.expand(focus: IslandViewModel.homeFocus)
        }
    }

    /// Puts the drop zone up for a preview. With the feature switched off it comes
    /// down again after ten seconds, closing an island still open on its page,
    /// which would otherwise fall back to another page and stay open.
    private func attachForPreview() {
        guard !isRunning else { return }
        previewTeardown?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isRunning else { return }
                self.previewTeardown = nil
                for island in IslandManager.shared.controllers.values.map(\.model)
                where island.focus == IslandViewModel.dropFocus && !island.isHovering {
                    island.collapse()
                }
                self.detach()
            }
        }
        previewTeardown = work
        attach()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func cancelPreviewTeardown() {
        previewTeardown?.cancel()
        previewTeardown = nil
    }
}

/// What the island opens onto while a file is dragged to the notch: AirDrop on the
/// left half of the page, the shelf on the right.
@MainActor
final class DropZoneTarget: DropTarget {
    let model: DropZoneModel

    init(model: DropZoneModel) { self.model = model }

    var expandedHeight: CGFloat { 104 }

    func view() -> AnyView { AnyView(DropZonePage(model: model)) }

    func dragMoved(to point: CGPoint?, in size: CGSize) {
        let place = point.map { Self.place(at: $0, in: size) }
        if model.hovered != place { model.hovered = place }
    }

    func canDrop(at point: CGPoint, in size: CGSize) -> Bool { true }

    func drop(_ urls: [URL], at point: CGPoint, in size: CGSize) {
        model.dropped(urls, on: Self.place(at: point, in: size))
    }

    /// The two tiles split the page down the middle.
    private static func place(at point: CGPoint, in size: CGSize) -> DropZoneModel.Place {
        point.x < size.width / 2 ? .airDrop : .shelf
    }
}

private struct DropZoneSettings: View {
    let shelf: ShelfStore
    @AppStorage(ShelfArchive.keepKey) private var keepsShelf = true

    var body: some View {
        Toggle("Keep files on the shelf between launches", isOn: $keepsShelf)
            .onChange(of: keepsShelf) { _, keeps in shelf.keepingChanged(keeps) }
    }
}
