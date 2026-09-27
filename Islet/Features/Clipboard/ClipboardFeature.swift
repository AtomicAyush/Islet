import AppKit
import SwiftUI

/// The last things copied — text, links, pictures and files — on the home page, a
/// click from being copied again, with a page of everything the tile opens. Pinned
/// items stay at the top, and across restarts.
///
/// macOS says nothing when something is copied, so the model looks at the
/// pasteboard's change count twice a second and reads the pasteboard only once it has
/// moved, and only once macOS allows it (Paste from Other Apps, `ClipboardAccess`).
/// Anything an app marks as not for keeping is never read, nor is anything copied
/// while a password manager is in front. The history lives in memory unless Settings
/// asks for it to be kept between launches.
@MainActor
final class ClipboardFeature: Feature {
    let id = "clipboard"
    let title = "Clipboard History"
    let symbol = "doc.on.clipboard.fill"
    let summary = "The last things you copied on the home page, to copy again with a click."

    /// Where the tile goes on the home page, until the person puts it somewhere else.
    static let tileOrder = 55
    var homeTile: HomeTileInfo? { HomeTileInfo(self, order: Self.tileOrder) }

    /// The id of the page with everything copied, where the tile has room for three,
    /// which the island opens as its focus (`islet://open?focus=clipboard`).
    static let pageID = "clipboard"

    private let model: ClipboardModel
    private var isRunning = false
    private var isPageShown = false
    private var isTileShown = false
    private var defaultsObserver: NSObjectProtocol?
    private var lockObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var keepsHistory = ClipboardPrefs.keepsHistory
    private var previewTask: Task<Void, Never>?

    /// The model watches the general pasteboard; tests pass one on a pasteboard of
    /// their own.
    init(model: ClipboardModel? = nil) {
        let model = model ?? ClipboardModel()
        self.model = model
        model.onChange = { [weak self] in self?.render() }
        model.onHandOff = {
            IslandManager.shared.focusedController?.model.collapse()
        }
    }

    func start() {
        isRunning = true
        model.history.limit = ClipboardPrefs.currentLimit
        keepsHistory = ClipboardPrefs.keepsHistory
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        observeLocking()
        model.start()
        render()
    }

    func stop() {
        isRunning = false
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = nil
        for (center, observer) in lockObservers {
            center.removeObserver(observer)
        }
        lockObservers = []
        previewTask?.cancel()
        previewTask = nil
        model.stop()
        render()
    }

    func settingsView() -> AnyView? {
        AnyView(ClipboardSettingsView(model: model))
    }

    /// A made-up history stands in for the real one while the island stays open, and
    /// for at least eight seconds. Clicking its items says "Copied" and copies nothing.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Clipboard history") { [weak self] in
                self?.preview(opening: ClipboardFeature.pageID)
            },
            FeaturePreview(title: "Clipboard on the home page") { [weak self] in
                self?.preview(opening: IslandViewModel.homeFocus)
            },
        ]
    }

    /// `islet://clipboard/clear` clears everything but pinned items: the real history,
    /// even while a preview's stands in for it.
    func handle(_ url: URL) -> Bool {
        guard url.path() == "/clear" else { return false }
        model.history.clear(keepingPinned: true)
        return true
    }

    // MARK: Island

    /// The page is there to open while the feature runs (or a preview is up), and the
    /// tile on the home page while there is something in the history to show, or a
    /// copy went unread for want of permission.
    private func render() {
        let center = ActivityCenter.shared
        let isAttached = isRunning || model.sample != nil
        // A preview's tile shows even if the person hid it.
        center.setPreviewing(model.sample != nil, homeTile: id)

        if isAttached != isPageShown {
            isPageShown = isAttached
            if isAttached {
                center.setPage(IslandPage(
                    id: Self.pageID, symbol: symbol, height: ClipboardLayout.pageHeight,
                    view: AnyView(ClipboardPage(model: model))
                ))
            } else {
                center.removePage(id: Self.pageID)
            }
        }

        let wantsTile = isAttached && (!model.shown.items.isEmpty || model.wantsAccess)
        guard wantsTile != isTileShown else { return }
        isTileShown = wantsTile
        if wantsTile {
            // After the headphones, before the shelf: both are things kept to hand.
            center.setHomeWidget(HomeWidget(
                id: id, order: Self.tileOrder, weight: 1.5, personal: .files,
                view: AnyView(ClipboardHomeTile(model: model) {
                    IslandManager.shared.focusedController?.model.select(focus: Self.pageID)
                })
            ))
        } else {
            center.removeHomeWidget(id: id)
        }
    }

    // MARK: Settings

    private func applySettings() {
        model.history.limit = ClipboardPrefs.currentLimit
        let keeps = ClipboardPrefs.keepsHistory
        if keeps != keepsHistory {
            keepsHistory = keeps
            model.keepingChanged()
        }
    }

    /// Locking the screen, or switching to another user, clears the history if
    /// Settings asks, pinned items apart. The notifications come whether or not the
    /// setting is on, and cost nothing until then.
    private func observeLocking() {
        let locked: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked() }
        }
        let distributed = DistributedNotificationCenter.default()
        lockObservers.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: locked
        )))
        let workspace = NSWorkspace.shared.notificationCenter
        lockObservers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: locked
        )))
    }

    func screenLocked() {
        guard isRunning, ClipboardPrefs.bool(ClipboardPrefs.clearOnLock, default: false) else { return }
        model.endSample()
        model.history.clear(keepingPinned: true)
    }

    // MARK: Previews

    private func preview(opening focus: String) {
        model.showSample(ClipboardSamples.items())
        IslandManager.shared.focusedController?.model.expand(focus: focus)
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            // Not while an island is still open, where the sample would turn into the
            // real history under the pointer; two minutes at most.
            for _ in 0..<120 {
                guard !Task.isCancelled else { return }
                let isOpen = IslandManager.shared.controllers.values.contains { $0.model.isExpanded }
                if !isOpen { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.model.endSample()
        }
    }
}
