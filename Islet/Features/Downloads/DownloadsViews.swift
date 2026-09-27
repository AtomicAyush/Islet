import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The iPhone's blue in its dark appearance, Safari's colour for downloads.
let downloadsBlue = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
private let downloadsBlueNS = NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 255 / 255, alpha: 1)

// MARK: - Pieces

/// The icon Finder gives a download's type (a PDF's page, a disk image's drive), from
/// the finished file's extension: the partial file's own icon says only "unfinished".
struct DownloadTypeIcon: View {
    let fileExtension: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: DownloadIcons.icon(forExtension: fileExtension))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Type icons, made once per type.
@MainActor
enum DownloadIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(forExtension fileExtension: String) -> NSImage {
        let key = fileExtension.lowercased()
        if let icon = cache[key] { return icon }
        let type = key.isEmpty ? UTType.data : UTType(filenameExtension: key) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        cache[key] = icon
        return icon
    }
}

/// The ring while the download's size is known; while it is not, the spinner Shortcuts
/// runs on, turned by Core Animation so it costs nothing per frame.
struct DownloadMark: View {
    let item: DownloadItem?
    var lineWidth: CGFloat = 2.5

    var body: some View {
        if let fraction = item?.fraction {
            ProgressRing(fraction: fraction, lineWidth: lineWidth, tint: downloadsBlue)
        } else {
            ShortcutSpinner(lineWidth: lineWidth, color: downloadsBlueNS)
        }
    }
}

// MARK: - Compact

/// Left of the notch: the icon of the newest download's type.
struct DownloadsCompactLeading: View {
    let model: DownloadsModel

    var body: some View {
        ProgressWingLeading(id: model.displayed?.id) {
            if let item = model.displayed {
                DownloadTypeIcon(fileExtension: item.fileExtension, size: ProgressWingLayout.compactIcon)
            }
        }
    }
}

/// Right of the notch: the newest download's ring, with how many are under way when
/// there are several.
struct DownloadsCompactTrailing: View {
    let model: DownloadsModel

    var body: some View {
        ProgressWingTrailing(count: model.count) {
            DownloadMark(item: model.displayed)
        }
    }
}

/// In the bubble, or folded into the island: the ring round a download arrow, as
/// Safari's toolbar button draws it.
struct DownloadsMinimal: View {
    let model: DownloadsModel

    var body: some View {
        DownloadMark(item: model.displayed)
            .overlay(
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(downloadsBlue)
            )
            .padding(5)
    }
}

// MARK: - Expanded

/// Opened: the newest download's name, how much of it has come, how fast and how long
/// is left. Islet cannot pause or cancel another app's download, so it offers neither.
struct DownloadsExpanded: View {
    let model: DownloadsModel

    var body: some View {
        HStack(spacing: 14) {
            if let item = model.displayed {
                DownloadTypeIcon(fileExtension: item.fileExtension, size: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(DownloadNames.progress(received: item.received, total: item.total))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    if let caption = caption(item) {
                        Text(caption)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                ZStack {
                    DownloadMark(item: item, lineWidth: 4)
                    if let fraction = item.fraction {
                        // Rounded down, so it never reads 100% while bytes are still to come.
                        Text("\(Int((fraction * 100).rounded(.down)))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(downloadsBlue)
                    }
                }
                .frame(width: 46, height: 46)
                .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    /// "3.2 MB/s · 2 min left · 1 more downloading", with whatever of it is known.
    private func caption(_ item: DownloadItem) -> String? {
        var parts: [String] = []
        if let speed = item.bytesPerSecond { parts.append(DownloadNames.speed(speed)) }
        if let seconds = item.secondsLeft, let left = DownloadNames.timeLeft(seconds) { parts.append(left) }
        let others = model.count - 1
        if others > 0 { parts.append("\(others) more downloading") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Finished

enum DownloadedCardLayout {
    /// Room for a file name of twenty-odd characters beside the three buttons before it
    /// truncates, in its middle, where names differ least.
    static let width: CGFloat = 440
    static let height: CGFloat = 64
    /// The clear space either side of the page in a document icon 44 points wide.
    static let iconInset: CGFloat = 6
}

/// A download has finished: the file, to drag straight to where it is needed, open, or
/// find in Finder.
struct DownloadedCard: View {
    let file: FinishedDownload
    /// The pointer arrived (`true`) or left: the card stays while it is on it.
    let hover: (Bool) -> Void
    let open: () -> Void
    let reveal: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(url: file.url, size: 44)
                .contentShape(Rectangle())
                .onDrag { FileDrag.provider(for: file.url) }
                .onTapGesture(perform: open)
                .help("Drag the file where you need it")
                // A document's icon is a page with clear space either side; this puts
                // the page, rather than the space, as far from the card's edge as the
                // close button is from the other.
                .padding(.leading, -DownloadedCardLayout.iconInset)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: open) {
                Text("Open")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(downloadsBlue)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Capsule().fill(downloadsBlue.opacity(0.2)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            RoundButton(symbol: "magnifyingglass", tint: .white, diameter: 30, action: reveal)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            RoundButton(symbol: "xmark", tint: .white, diameter: 30, action: dismiss)
                .accessibilityLabel("Close")
        }
        .frame(maxHeight: .infinity)
        .onHover(perform: hover)
    }

    private var subtitle: String {
        guard let size = file.size, size > 0 else { return "Downloaded" }
        return "Downloaded · \(DownloadNames.bytes(size))"
    }
}

// MARK: - Settings

struct DownloadsSettingsView: View {
    /// Called with the folders once they have been read.
    let found: ([URL]) -> Void
    @AppStorage(DownloadsPrefs.showFinished) private var showFinished = true
    @State private var folders: [URL] = DownloadFolders.downloads.map { [$0] } ?? []

    var body: some View {
        Toggle(isOn: $showFinished) {
            Text("Show finished downloads")
            Text("The file in a card for a few seconds, to drag where it's needed, open, or show in Finder.")
        }
        LabeledContent {
            Text(folders.map(DownloadFolders.abbreviated).joined(separator: "\n"))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        } label: {
            Text("Follows downloads into")
            Text("Your Downloads folder, and Safari's download folder where it is another. A download saved anywhere else shows only once it has finished.")
        }
        .task {
            folders = await Task.detached(priority: .utility) { DownloadFolders.all() }.value
            found(folders)
        }
    }
}
