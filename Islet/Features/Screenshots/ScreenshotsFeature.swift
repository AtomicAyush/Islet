import AppKit
import SwiftUI

/// A screenshot, the moment it is taken, the way the iPhone offers one: its picture in a
/// card for a few seconds, to drag straight into another app, copy, put on Drop Zone's
/// shelf, find in Finder or move to the Trash.
///
/// `ScreenshotWatcher` notices screenshots as macOS saves them. Nothing is done to one
/// unless a button is clicked; Delete moves it to the Trash, where it can be put back.
@MainActor
final class ScreenshotsFeature: Feature {
    let id = "screenshots"
    let title = "Screenshots"
    let symbol = "camera.viewfinder"
    let summary = "A screenshot you take, in a card to drag into another app, copy, shelve or throw away."

    static let bannerID = "screenshots.card"
    /// A few seconds, as the iPhone's thumbnail stays, from when it goes up or the
    /// pointer leaves it. It stays while the pointer is on it (`heldDuration`).
    static let cardDuration: TimeInterval = 6
    /// How long the card stays with the pointer on it: until the pointer leaves, but no
    /// more than a minute, should its leaving go unheard.
    static let heldDuration: TimeInterval = 60

    private let watcher: ScreenshotWatcher
    private let shelf: ScreenshotShelf
    private let files: ScreenshotFileActions
    private let settings: ScreenshotSettingsStore
    private var isRunning = false
    private var banner: IslandBanner?

    /// Tests give a watcher on a folder of their own, a shelf of their own, file actions
    /// that leave the pasteboard, Finder and the Trash alone, and a stand-in for the
    /// Screenshot app's settings.
    init(
        watcher: ScreenshotWatcher? = nil,
        shelf: ScreenshotShelf = .dropZone,
        files: ScreenshotFileActions = .system,
        settings: ScreenshotSettingsStore = .system
    ) {
        let watcher = watcher ?? ScreenshotWatcher(preferences: { ScreenshotPreferences.read(from: settings) })
        self.watcher = watcher
        self.shelf = shelf
        self.files = files
        self.settings = settings
        watcher.onScreenshot = { [weak self] shot in self?.present(shot) }
    }

    func start() {
        isRunning = true
        watcher.start()
    }

    func stop() {
        isRunning = false
        watcher.stop()
        ActivityCenter.shared.dismissBanner(id: Self.bannerID)
        banner = nil
    }

    func settingsView() -> AnyView? {
        AnyView(ScreenshotsSettingsView(settings: settings) { [weak self] preferences in self?.watcher.follow(preferences) })
    }

    /// Made-up screenshots drawn in code, never the person's screen. Their Delete only
    /// closes the card.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Screenshot taken") { [weak self] in self?.preview(.screen) },
            FeaturePreview(title: "Screenshot of a window") { [weak self] in self?.preview(.window) },
        ]
    }

    // MARK: The card

    /// Puts the card up for `shot`, in place of one already up.
    func present(_ shot: Screenshot) {
        let banner = IslandBanner(
            id: Self.bannerID,
            style: .card(width: ScreenshotCardLayout.width, height: ScreenshotCardLayout.height),
            duration: Self.cardDuration,
            // A card of its own for each screenshot, so a new one does not arrive already
            // saying "Copied".
            content: AnyView(ScreenshotCard(
                shot: shot, actions: actions(for: shot),
                hover: { [weak self] in self?.holdCard($0) },
                dismiss: Self.dismissCard
            ).id(shot.url))
        )
        self.banner = banner
        ActivityCenter.shared.present(banner)
    }

    /// What the card's buttons do for `shot`. Opening it, or showing it in Finder,
    /// hands it to another app, and the card goes; so does Delete.
    func actions(for shot: Screenshot) -> ScreenshotCardActions {
        let files = files
        let shelf = shelf
        return ScreenshotCardActions(
            open: {
                files.open(shot.url)
                Self.dismissCard()
            },
            copy: { files.copy(shot.url) },
            shelve: shelf.isAvailable() ? { shelf.add(shot.url) } : nil,
            reveal: {
                files.reveal(shot.url)
                Self.dismissCard()
            },
            delete: {
                // A preview's sample is not the person's to throw away.
                if !shot.isSample { _ = files.trash(shot.url) }
                Self.dismissCard()
            }
        )
    }

    private static func dismissCard() {
        ActivityCenter.shared.dismissBanner(id: bannerID)
    }

    /// The card stays while the pointer is on it, so it does not go while a button is
    /// reached for or the picture picked up; its time starts again when the pointer
    /// leaves.
    func holdCard(_ hovering: Bool) {
        guard var banner, ActivityCenter.shared.banner?.id == Self.bannerID else { return }
        banner.duration = hovering ? Self.heldDuration : Self.cardDuration
        ActivityCenter.shared.present(banner)
    }

    private func preview(_ kind: ScreenshotSamples.Kind) {
        Task { [weak self] in
            guard let shot = await ScreenshotSamples.make(kind) else { return }
            self?.present(shot)
        }
    }
}

/// Where Add to Shelf puts a screenshot: Drop Zone's shelf, while Drop Zone is on.
struct ScreenshotShelf {
    var isAvailable: @MainActor () -> Bool
    /// Returns whether the screenshot is on the shelf afterwards.
    var add: @MainActor (URL) -> Bool

    static let dropZone = ScreenshotShelf(
        isAvailable: { FeatureRegistry.shared.feature(DropZoneFeature.self)?.takesFiles ?? false },
        add: { FeatureRegistry.shared.feature(DropZoneFeature.self)?.shelve([$0]) ?? false }
    )
}

/// What the card's buttons do to the file.
struct ScreenshotFileActions {
    var open: @MainActor (URL) -> Void
    var copy: @MainActor (URL) -> Bool
    var reveal: @MainActor (URL) -> Void
    var trash: @MainActor (URL) -> Bool

    static let system = ScreenshotFileActions(
        open: { NSWorkspace.shared.open($0) },
        copy: { ScreenshotFiles.copy($0) },
        reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        trash: { ScreenshotFiles.trash($0) }
    )
}
