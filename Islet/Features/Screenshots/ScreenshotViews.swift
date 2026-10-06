import AppKit
import SwiftUI

enum ScreenshotCardLayout {
    static let width: CGFloat = 400
    static let height: CGFloat = 88
    /// The box the picture is fitted into: a landscape screenshot fills its width, a
    /// tall one its height.
    static let thumbnail = CGSize(width: 128, height: 80)
    /// The narrowest a very tall or very wide screenshot is drawn, cropped to fit, so it
    /// is still something to take hold of.
    static let thumbnailMinimum: CGFloat = 44
    static let button: CGFloat = 30

    /// The picture's size in the card, at the screenshot's own proportions. The card is
    /// laid out around it, so a tall one sits at the card's edge as a wide one does,
    /// with the words beside it.
    static func thumbnailSize(for image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return thumbnail }
        let scale = min(thumbnail.width / image.width, thumbnail.height / image.height)
        return CGSize(
            width: max(thumbnailMinimum, (image.width * scale).rounded()),
            height: max(thumbnailMinimum, (image.height * scale).rounded())
        )
    }
}

/// What the card's buttons do, given by the feature: the real thing for a screenshot,
/// something harmless for a preview's sample.
struct ScreenshotCardActions {
    var open: () -> Void
    var copy: () -> ScreenshotCopyResult
    /// `nil` while there is no shelf to add to (Drop Zone is off). Returns whether the
    /// screenshot is on the shelf afterwards.
    var shelve: (() -> Bool)?
    var reveal: () -> Void
    var delete: () -> Void
}

/// What Copy did, for the card to show.
enum ScreenshotCopyResult: Equatable {
    /// The picture is on the clipboard.
    case copied
    /// On the clipboard, and the file deleted for good (Delete after Copying): the card
    /// says so and goes, as there is nothing left to drag, open or show.
    case copiedAndDeleted
    /// On the clipboard, and the file kept, for the reason the card shows.
    case copiedAndKept(String)
    /// Not on the clipboard, and nothing done to the file.
    case failed

    /// What the card says in place of the screenshot's size and place, if anything.
    var note: String? {
        switch self {
        case .copiedAndDeleted: "Copied · file deleted"
        case .copiedAndKept(let reason): reason
        case .copied, .failed: nil
        }
    }
}

/// A screenshot just taken: the picture, to drag straight into another app, and
/// buttons to copy it, put it on the shelf, find it in Finder or throw it away.
struct ScreenshotCard: View {
    let shot: Screenshot
    let actions: ScreenshotCardActions
    /// The pointer arrived (`true`) or left: the card stays while it is on it.
    let hover: (Bool) -> Void
    let dismiss: () -> Void
    @State private var copied = false
    @State private var shelved = false
    /// Said in place of the size and place once Copy has deleted the file, or kept it.
    @State private var note: String?
    /// Copy deleted the file: there is nothing left to drag or open.
    @State private var deleted = false

    var body: some View {
        HStack(spacing: 14) {
            ScreenshotThumbnail(shot: shot, open: actions.open)
                .allowsHitTesting(!deleted)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Screenshot")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.islandPrimary)
                        Text(note ?? subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.islandText(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    RoundButton(symbol: "xmark", diameter: 24, action: dismiss)
                        .accessibilityLabel("Close")
                }

                HStack(spacing: 8) {
                    button(copied ? "checkmark" : "doc.on.doc", copied ? .hue(.success) : .text(1), "Copy", action: copy)
                    if let shelve = actions.shelve {
                        button(shelved ? "checkmark" : "tray.and.arrow.down.fill", shelved ? .hue(.success) : .accent(.dropZoneShelf),
                               shelved ? "On the Shelf" : "Add to Shelf") {
                            shelved = shelve()
                        }
                    }
                    button("folder", .text(1), "Show in Finder", action: actions.reveal)
                    button("trash", .hue(.destructive), "Move to Trash", action: actions.delete)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onHover(perform: hover)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: copied)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: shelved)
    }

    private func copy() {
        let result = actions.copy()
        copied = result != .failed
        deleted = result == .copiedAndDeleted
        guard let said = result.note else { return }
        note = said
        AccessibilityNotification.Announcement(said).post()
    }

    private func button(_ symbol: String, _ tint: IslandInk, _ label: String, action: @escaping () -> Void) -> some View {
        RoundButton(symbol: symbol, tint: tint, diameter: ScreenshotCardLayout.button, action: action)
        .help(label)
        .accessibilityLabel(label)
    }

    /// "1512 × 982 · Desktop".
    private var subtitle: String {
        guard let size = shot.pixelSize else { return shot.place }
        return "\(Int(size.width)) × \(Int(size.height)) · \(shot.place)"
    }
}

/// The picture itself, framed like the iPhone's screenshot thumbnail. Drag it out to
/// drop the file into another app; click it to open it.
struct ScreenshotThumbnail: View {
    let shot: Screenshot
    let open: () -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let size = ScreenshotCardLayout.thumbnailSize(for: shot.pixelSize ?? shot.thumbnail.size)
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Image(nsImage: shot.thumbnail)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.islandDecorative(0.22), lineWidth: 1))
            .shadow(color: theme.shadow(0.5), radius: 4, y: 2)
            .contentShape(shape)
            .onDrag { FileDrag.provider(for: shot.url) }
            .onTapGesture(perform: open)
            .help("Drag the screenshot into another app, or click to open it")
            .accessibilityLabel("Screenshot")
    }
}

// MARK: - Settings

/// Where screenshots are saved, what in macOS's own settings keeps them from the island,
/// and a switch for the floating thumbnail that holds them back. Where and how they are
/// saved are the Screenshot app's settings, only read here. The switch and Delete after
/// Copying are Islet's own; `FloatingThumbnail` keeps macOS's thumbnail off while the
/// switch is on and Islet is running.
struct ScreenshotsSettingsView: View {
    @State private var model: ScreenshotsSettingsModel
    @AppStorage private var showsAtOnce: Bool
    @AppStorage(ScreenshotsPrefs.deleteAfterCopying) private var deleteAfterCopying = false
    private let thumbnail: FloatingThumbnail

    /// `refresh` is called with the settings as they are read, so the feature follows a
    /// folder changed meanwhile, or tries again one it was refused.
    init(settings: ScreenshotSettingsStore = .system, thumbnail: FloatingThumbnail,
         refresh: @escaping (ScreenshotPreferences) -> Void) {
        _model = State(initialValue: ScreenshotsSettingsModel(settings: settings, refresh: refresh))
        _showsAtOnce = AppStorage(wrappedValue: false, ScreenshotsPrefs.showsAtOnce, store: thumbnail.defaults)
        self.thumbnail = thumbnail
    }

    var body: some View {
        LabeledContent {
            if let preferences = model.preferences {
                Text(preferences.savesFiles ? (preferences.folder.path as NSString).abbreviatingWithTildeInPath : "Not saved")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            Text("Screenshots are saved to")
            Text(Self.explanation(for: model.preferences, showsAtOnce: showsAtOnce))
        }
        .task { model.read() }
        // Options may have been changed in the Screenshot app meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.read()
        }

        if model.preferences?.savesFiles == true {
            Toggle(isOn: Binding(get: { showsAtOnce }, set: { atOnce in
                thumbnail.setShowsAtOnce(atOnce) { model.read() }
            })) {
                Text("Show screenshots here at once")
                Text("Turns off macOS's floating thumbnail while Islet is running, so each screenshot is saved as it is taken and its card comes straight away, in the thumbnail's place: click the picture to mark it up in Preview. The thumbnail comes back as usual when Islet quits.")
            }
        }

        Toggle(isOn: $deleteAfterCopying) {
            Text("Delete after copying")
            Text("Copy on a screenshot's card puts the picture on the clipboard, where it stays to be pasted, then deletes the file for good. It isn't put in the Trash, so it can't be got back. A screenshot on the Drop Zone shelf is kept.")
        }
    }

    /// With the switch on, macOS's thumbnail is off while Islet runs, whatever the
    /// Screenshot app was last set to.
    static func explanation(for preferences: ScreenshotPreferences?, showsAtOnce: Bool) -> String {
        guard let preferences else { return "" }
        if !preferences.savesFiles {
            return "The Screenshot app (⇧⌘5) puts screenshots on the clipboard or straight into an app, which leaves no file for the island to show. Choose a folder under Options there."
        }
        let folder = "Choose another folder under Options in the Screenshot app (⇧⌘5). Screenshots copied to the clipboard (⌃ held down) make no file, so they don't show."
        guard preferences.showsThumbnail, !showsAtOnce else { return folder }
        return folder + " macOS holds each screenshot in its floating thumbnail first, so its card comes about five seconds later."
    }
}

/// The Screenshot app's settings as the Screenshots settings show them, read off the main
/// thread one at a time, in the order asked for.
@MainActor
@Observable
final class ScreenshotsSettingsModel {
    /// As last read; `nil` until they first have been.
    private(set) var preferences: ScreenshotPreferences?

    private let settings: ScreenshotSettingsStore
    private let refresh: (ScreenshotPreferences) -> Void

    private static let queue = DispatchQueue(label: "Islet.ScreenshotSettings", qos: .userInitiated)

    /// Nothing is read until `read()`.
    init(settings: ScreenshotSettingsStore, refresh: @escaping (ScreenshotPreferences) -> Void) {
        self.settings = settings
        self.refresh = refresh
    }

    func read() {
        let settings = settings
        Self.queue.async { [weak self] in
            let fresh = ScreenshotPreferences.read(from: settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.preferences = fresh
                    self.refresh(fresh)
                }
            }
        }
    }
}
