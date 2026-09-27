import AppKit
import SwiftUI

/// The iPhone's green and red in their dark appearance: done, and gone to the Trash.
private let screenshotGreen = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
private let screenshotRed = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)

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
    var copy: () -> Bool
    /// `nil` while there is no shelf to add to (Drop Zone is off). Returns whether the
    /// screenshot is on the shelf afterwards.
    var shelve: (() -> Bool)?
    var reveal: () -> Void
    var delete: () -> Void
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

    var body: some View {
        HStack(spacing: 14) {
            ScreenshotThumbnail(shot: shot, open: actions.open)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Screenshot")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    RoundButton(symbol: "xmark", tint: .white, diameter: 24, action: dismiss)
                        .accessibilityLabel("Close")
                }

                HStack(spacing: 8) {
                    button(copied ? "checkmark" : "doc.on.doc", copied ? screenshotGreen : .white, "Copy") {
                        copied = actions.copy()
                    }
                    if let shelve = actions.shelve {
                        button(shelved ? "checkmark" : "tray.and.arrow.down.fill", shelved ? screenshotGreen : dropZoneYellow,
                               shelved ? "On the Shelf" : "Add to Shelf") {
                            shelved = shelve()
                        }
                    }
                    button("folder", .white, "Show in Finder", action: actions.reveal)
                    button("trash", screenshotRed, "Move to Trash", action: actions.delete)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onHover(perform: hover)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: copied)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: shelved)
    }

    private func button(_ symbol: String, _ tint: Color, _ label: String, action: @escaping () -> Void) -> some View {
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

    var body: some View {
        let size = ScreenshotCardLayout.thumbnailSize(for: shot.pixelSize ?? shot.thumbnail.size)
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Image(nsImage: shot.thumbnail)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
            .contentShape(shape)
            .onDrag { FileDrag.provider(for: shot.url) }
            .onTapGesture(perform: open)
            .help("Drag the screenshot into another app, or click to open it")
            .accessibilityLabel("Screenshot")
    }
}

// MARK: - Settings

/// Where screenshots are saved, and what in macOS's own settings keeps them from the
/// island. Those settings are the Screenshot app's, and are only ever read.
struct ScreenshotsSettingsView: View {
    /// Called with the settings as they are read, so the feature follows a folder
    /// changed meanwhile, or tries again one it was refused.
    let refresh: (ScreenshotPreferences) -> Void
    @State private var preferences: ScreenshotPreferences?

    var body: some View {
        LabeledContent {
            if let preferences {
                Text(preferences.savesFiles ? (preferences.folder.path as NSString).abbreviatingWithTildeInPath : "Not saved")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            Text("Screenshots are saved to")
            Text(explanation)
        }
        .task { await read() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await read() }
        }
    }

    private func read() async {
        let read = await Task.detached(priority: .utility) { ScreenshotPreferences.read() }.value
        preferences = read
        refresh(read)
    }

    private var explanation: String {
        guard let preferences else { return "" }
        if !preferences.savesFiles {
            return "The Screenshot app (⇧⌘5) puts screenshots on the clipboard or straight into an app, which leaves no file for the island to show. Choose a folder under Options there."
        }
        if preferences.showsThumbnail {
            return "macOS holds each screenshot in its floating thumbnail for about five seconds before saving it. Turn off Show Floating Thumbnail under Options in the Screenshot app (⇧⌘5) to see it here at once. Screenshots copied to the clipboard make no file, so they don't show."
        }
        return "Choose another folder under Options in the Screenshot app (⇧⌘5). Screenshots copied to the clipboard make no file, so they don't show."
    }
}
