import AppKit
import CryptoKit
import SwiftUI

/// A screenshot, the moment it is taken, the way the iPhone offers one: its picture in a
/// card for a few seconds, to drag straight into another app, copy, put on Drop Zone's
/// shelf, find in Finder or move to the Trash.
///
/// `ScreenshotWatcher` notices screenshots as macOS saves them. Nothing is done to one
/// unless a button is clicked; Delete moves it to the Trash, where it can be put back.
/// With Delete after Copying on, Copy deletes the file for good once the picture is on
/// the clipboard (`actions(for:)` says when it does not). That is the same whether the
/// card comes at once or after macOS's floating thumbnail: either way it comes only once
/// the file is saved. The watcher pays no heed to a file that goes, so a deleted
/// screenshot is not heard of again. While Show screenshots here at once is on, and the
/// feature is, `FloatingThumbnail` keeps macOS's floating thumbnail off.
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
    /// How long the card stays once Copy has deleted its file: long enough to see the tick.
    static let deletedDuration: TimeInterval = 0.9

    private let watcher: ScreenshotWatcher
    private let shelf: ScreenshotShelf
    private let files: ScreenshotFileActions
    private let settings: ScreenshotSettingsStore
    private let defaults: UserDefaults
    private let thumbnail: FloatingThumbnail
    private var isRunning = false
    private var activation: NSObjectProtocol?
    private var banner: IslandBanner?
    /// The screenshot whose card was put up last.
    private var shown: URL?

    /// Tests give a watcher on a folder of their own, a shelf of their own, file actions
    /// that leave the pasteboard, Finder and the Trash alone, a stand-in for the
    /// Screenshot app's settings, defaults of their own, and a thumbnail kept with them.
    init(
        watcher: ScreenshotWatcher? = nil,
        shelf: ScreenshotShelf = .dropZone,
        files: ScreenshotFileActions = .system,
        settings: ScreenshotSettingsStore = .system,
        defaults: UserDefaults = .standard,
        thumbnail: FloatingThumbnail? = nil
    ) {
        let watcher = watcher ?? ScreenshotWatcher(preferences: { ScreenshotPreferences.read(from: settings) })
        self.watcher = watcher
        self.shelf = shelf
        self.files = files
        self.settings = settings
        self.defaults = defaults
        self.thumbnail = thumbnail ?? FloatingThumbnail(settings: settings, defaults: defaults)
        watcher.onScreenshot = { [weak self] shot in
            // One may come late because the thumbnail was turned back on elsewhere.
            self?.thumbnail.recheck()
            self?.present(shot)
        }
    }

    /// At launch, whether the feature is on or not: macOS's thumbnail may need putting
    /// back, or the switch taking over from it.
    func launched() {
        thumbnail.launched()
    }

    func start() {
        isRunning = true
        watcher.start()
        thumbnail.start()
        // The Screenshot app's Options may have been changed meanwhile.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.thumbnail.recheck() }
        }
    }

    func stop() {
        isRunning = false
        watcher.stop()
        thumbnail.stop()
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        ActivityCenter.shared.dismissBanner(id: Self.bannerID)
        banner = nil
    }

    func settingsView() -> AnyView? {
        AnyView(ScreenshotsSettingsView(settings: settings, thumbnail: thumbnail) { [weak self] preferences in
            self?.watcher.follow(preferences)
            self?.thumbnail.recheck()
        })
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
            personal: .files,
            // A card of its own for each screenshot, so a new one does not arrive already
            // saying "Copied".
            content: AnyView(ScreenshotCard(
                shot: shot, actions: actions(for: shot),
                hover: { [weak self] in self?.holdCard($0) },
                dismiss: Self.dismissCard
            ).id(shot.url))
        )
        self.banner = banner
        shown = shot.url
        ActivityCenter.shared.present(banner)
    }

    /// What the card's buttons do for `shot`. Opening it, or showing it in Finder,
    /// hands it to another app, and the card goes; so does Delete.
    ///
    /// With Delete after Copying on, Copy copies, reads the picture back from the
    /// clipboard, and only then deletes the file, for good, the first time it copies.
    /// It keeps the file, and the card says why, while the shelf holds it (the shelf
    /// keeps only where a file is), or if it is no longer the file the card was made
    /// for: moved, replaced, turned into a symbolic link or changed. A preview's sample
    /// is never deleted. Once the file is deleted the other buttons do nothing, and the
    /// card goes a moment later.
    func actions(for shot: Screenshot) -> ScreenshotCardActions {
        let files = files
        let shelf = shelf
        let defaults = defaults
        let card = ScreenshotCardFile()
        // A moment after Copy has deleted the file, for the tick to be seen.
        let dismissSoon: () -> Void = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.deletedDuration) {
                MainActor.assumeIsolated { self?.dismissCard(of: shot.url) }
            }
        }
        return ScreenshotCardActions(
            open: {
                guard !card.isDeleted else { return }
                files.open(shot.url)
                Self.dismissCard()
            },
            copy: {
                guard !card.isDeleted else { return .copiedAndDeleted }
                guard files.copy(shot.url) else { return .failed }
                guard ScreenshotsPrefs.bool(ScreenshotsPrefs.deleteAfterCopying, default: false, in: defaults) else {
                    return .copied
                }
                // Tried once: a later copy only copies.
                if let kept = card.kept { return .copiedAndKept(kept) }
                guard files.isCopied(shot.url) else { return .failed }
                if card.isShelved || shelf.holds(shot.url) { return card.keep("Copied · kept for the shelf") }
                // A preview's sample is not the person's to delete: the card goes as a
                // screenshot's would, and the sample stays.
                if !shot.isSample {
                    guard let stamp = shot.file, FileStamp.read(shot.url) == stamp else {
                        return card.keep("Copied · file changed, so kept")
                    }
                    guard files.delete(shot.url) else { return card.keep("Copied · couldn't delete the file") }
                }
                card.isDeleted = true
                dismissSoon()
                return .copiedAndDeleted
            },
            shelve: shelf.isAvailable() ? {
                guard !card.isDeleted, shelf.add(shot.url) else { return false }
                card.isShelved = true
                return true
            } : nil,
            reveal: {
                guard !card.isDeleted else { return }
                files.reveal(shot.url)
                Self.dismissCard()
            },
            delete: {
                // A preview's sample is not the person's to throw away.
                if !shot.isSample, !card.isDeleted { _ = files.trash(shot.url) }
                Self.dismissCard()
            }
        )
    }

    private static func dismissCard() {
        ActivityCenter.shared.dismissBanner(id: bannerID)
    }

    /// Takes the card down if it is still `url`'s, not another screenshot's put up since.
    private func dismissCard(of url: URL) {
        guard shown == url else { return }
        Self.dismissCard()
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

/// What a card's buttons have done to its screenshot, shared by them.
@MainActor
private final class ScreenshotCardFile {
    /// Copy deleted the file.
    var isDeleted = false
    /// Add to Shelf put it on the shelf.
    var isShelved = false
    /// Why Copy kept the file, once it has.
    private(set) var kept: String?

    func keep(_ reason: String) -> ScreenshotCopyResult {
        kept = reason
        return .copiedAndKept(reason)
    }
}

/// The feature's own preference keys, shared by the feature and its settings; the rest
/// of its settings are the Screenshot app's. Unset keys read as their defaults, the same
/// ones the settings toggles declare.
enum ScreenshotsPrefs {
    /// Show screenshots here at once: macOS's floating thumbnail is kept off while Islet
    /// runs. Unset until the first launch with it, which takes it from macOS's setting.
    static let showsAtOnce = "screenshots.showsAtOnce"

    /// Copy deletes the screenshot's file for good once the picture is on the clipboard.
    static let deleteAfterCopying = "screenshots.deleteAfterCopying"

    static func bool(_ key: String, default value: Bool, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }
}

/// Where Add to Shelf puts a screenshot: Drop Zone's shelf, while Drop Zone is on.
struct ScreenshotShelf {
    var isAvailable: @MainActor () -> Bool
    /// Returns whether the screenshot is on the shelf afterwards.
    var add: @MainActor (URL) -> Bool
    /// Whether the shelf holds the file, however it got there: added from the card, or
    /// dragged from it to the island.
    var holds: @MainActor (URL) -> Bool

    static let dropZone = ScreenshotShelf(
        isAvailable: { FeatureRegistry.shared.feature(DropZoneFeature.self)?.takesFiles ?? false },
        add: { FeatureRegistry.shared.feature(DropZoneFeature.self)?.shelve([$0]) ?? false },
        holds: { FeatureRegistry.shared.feature(DropZoneFeature.self)?.holds($0) ?? false }
    )
}

/// What the card's buttons do to the file.
struct ScreenshotFileActions {
    var open: @MainActor (URL) -> Void
    /// Returns whether the picture went on the clipboard.
    var copy: @MainActor (URL) -> Bool
    /// Whether the clipboard holds the picture Copy last put there for the file, read
    /// back from it: asked before Delete after Copying deletes the file.
    var isCopied: @MainActor (URL) -> Bool
    var reveal: @MainActor (URL) -> Void
    var trash: @MainActor (URL) -> Bool
    /// Deletes the file for good, not to the Trash. Returns whether it is gone.
    var delete: @MainActor (URL) -> Bool

    static let system = ScreenshotFileActions(pasteboard: .general)
}

extension ScreenshotFileActions {
    /// The real thing, copying to `pasteboard`: the general one, or a test's own.
    init(pasteboard: NSPasteboard) {
        let last = ScreenshotLastCopy()
        self.init(
            open: { NSWorkspace.shared.open($0) },
            copy: { url in
                let picture = ScreenshotFiles.copy(url, to: pasteboard)
                last.url = url
                last.fingerprint = picture.map(ScreenshotFiles.fingerprint(of:))
                last.changeCount = pasteboard.changeCount
                return picture != nil
            },
            isCopied: { url in
                // Nothing copied since, by Islet or another app.
                guard last.url == url, let fingerprint = last.fingerprint, pasteboard.changeCount == last.changeCount
                else { return false }
                return ScreenshotFiles.holds(fingerprint, on: pasteboard)
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            trash: { ScreenshotFiles.trash($0) },
            delete: { FileStamp.delete($0) }
        )
    }
}

/// What Copy last put on the clipboard, and for which file, to be read back. Only
/// Copy's actions, on the main thread, use it.
private final class ScreenshotLastCopy {
    var url: URL?
    /// The picture's fingerprint, not the picture, so a large one is not held on to.
    var fingerprint: [NSPasteboard.PasteboardType: SHA256.Digest]?
    var changeCount = 0
}
