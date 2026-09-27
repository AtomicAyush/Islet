import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The iPhone's cyan in its dark appearance: of a family with the downloads' blue, and
/// told apart from it at a glance when both are up.
let copiesCyan = Color(red: 100 / 255, green: 210 / 255, blue: 255 / 255)
private let copiesCyanNS = NSColor(srgbRed: 100 / 255, green: 210 / 255, blue: 255 / 255, alpha: 1)
/// The iPhone's green in its dark appearance, for a copy's tick.
private let copiedGreen = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)

// MARK: - Pieces

/// What is being copied, as Finder draws it: the icon of the item's type, a folder, or
/// a stack of documents for several items. Nothing is read from the copy itself, which
/// may be somewhere macOS asks about before letting Islet look.
struct FileCopyIcon: View {
    let item: FileCopyItem
    let size: CGFloat

    var body: some View {
        Image(nsImage: FileCopyIcons.icon(for: item))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
enum FileCopyIcons {
    private static let folder = NSWorkspace.shared.icon(for: .folder)
    private static let several = NSImage(named: NSImage.multipleDocumentsName) ?? NSWorkspace.shared.icon(for: .data)

    /// Several items; one without an extension, which is nearly always a folder; or the
    /// icon of the one item's type.
    static func icon(for item: FileCopyItem) -> NSImage {
        if item.isSeveral { return several }
        if item.fileExtension.isEmpty { return folder }
        return DownloadIcons.icon(forExtension: item.fileExtension)
    }
}

/// How far a copy has come: a ring filling, the spinner while Finder is still working
/// out how much there is, and a tick once it has finished.
struct FileCopyMark: View {
    let item: FileCopyItem?
    var isFinished = false
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            if isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .fontWeight(.semibold)
                    .foregroundStyle(copiedGreen)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else if let fraction = item?.fraction {
                ProgressRing(fraction: fraction, lineWidth: lineWidth, tint: copiesCyan)
                    .transition(.opacity)
            } else {
                ShortcutSpinner(lineWidth: lineWidth, color: copiesCyanNS)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isFinished)
    }
}

// MARK: - Compact

/// Left of the notch: the icon of what the newest copy is copying.
struct FileCopiesCompactLeading: View {
    let model: FileCopiesModel

    var body: some View {
        ProgressWingLeading(id: model.displayed?.id) {
            if let item = model.displayed {
                FileCopyIcon(item: item, size: ProgressWingLayout.compactIcon)
            }
        }
    }
}

/// Right of the notch: the newest copy's ring, with how many are under way when there
/// are several.
struct FileCopiesCompactTrailing: View {
    let model: FileCopiesModel

    var body: some View {
        ProgressWingTrailing(count: model.count) {
            FileCopyMark(item: model.displayed, isFinished: model.isDisplayedFinished)
        }
    }
}

/// In the bubble, or folded into the island: the ring round two pages, the mark Finder
/// gives Duplicate, or the tick in its place.
struct FileCopiesMinimal: View {
    let model: FileCopiesModel

    var body: some View {
        FileCopyMark(item: model.displayed, isFinished: model.isDisplayedFinished)
            .overlay {
                if !model.isDisplayedFinished {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(copiesCyan)
                }
            }
            .padding(5)
    }
}

// MARK: - Expanded

/// Opened: what the newest copy is copying and where to, how much of it is done, how
/// fast and how long is left, and Stop where the copy allows it.
struct FileCopiesExpanded: View {
    let model: FileCopiesModel
    let stop: (String) -> Void

    var body: some View {
        HStack(spacing: 14) {
            if let item = model.displayed {
                let isFinished = model.isDisplayedFinished
                FileCopyIcon(item: item, size: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.status(item, isFinished: isFinished))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !isFinished, let caption = Self.caption(item, others: model.count - 1) {
                        Text(caption)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                ZStack {
                    // The tick smaller than the ring it takes the place of, as heavy as
                    // the ring was.
                    FileCopyMark(item: item, isFinished: isFinished, lineWidth: 4)
                        .padding(isFinished ? 7 : 0)
                    if isFinished {
                        EmptyView()
                    } else if item.canStop, !item.isStopping {
                        // The ring goes round the button, so it still says how far along
                        // the copy is: the stop button of an App Store download.
                        RoundButton(symbol: "stop.fill", tint: .white, diameter: 32) { stop(item.id) }
                            .help("Stop copying")
                            .accessibilityLabel("Stop copying")
                    } else if let fraction = item.fraction {
                        // Rounded down, so it never reads 100% while bytes are still to go.
                        Text("\(Int((fraction * 100).rounded(.down)))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 46, height: 46)
                .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    /// "To Backup · 3.2 GB of 8 GB", "In Movies · Preparing…", "Copied to Backup",
    /// with whatever of it is known.
    static func status(_ item: FileCopyItem, isFinished: Bool) -> String {
        let place = item.destinationName.map { item.kind == .duplicating ? "in \($0)" : "to \($0)" }
        if isFinished {
            let done = item.kind == .duplicating ? "Duplicated" : "Copied"
            return [done, place].compactMap { $0 }.joined(separator: " ")
        }
        let amount: String
        if item.isStopping {
            amount = "Stopping…"
        } else if item.total == nil, item.copied == 0 {
            amount = "Preparing…"
        } else {
            amount = DownloadNames.progress(received: item.copied, total: item.total)
        }
        guard let place else { return amount }
        return "\(place.prefix(1).uppercased())\(place.dropFirst()) · \(amount)"
    }

    /// "45 MB/s · 2 min left · 1 more copying", with whatever of it is known.
    static func caption(_ item: FileCopyItem, others: Int) -> String? {
        var parts: [String] = []
        if !item.isStopping {
            if let speed = item.bytesPerSecond { parts.append(DownloadNames.speed(speed)) }
            if let seconds = item.secondsLeft, let left = DownloadNames.timeLeft(seconds) { parts.append(left) }
        }
        if others > 0 { parts.append("\(others) more copying") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Settings

struct FileCopiesSettingsView: View {
    /// Called when the threshold changes, for copies under way to be weighed again.
    let changed: () -> Void
    @AppStorage(FileCopiesPrefs.threshold) private var megabytes = FileCopiesPrefs.defaultMegabytes

    var body: some View {
        Picker(selection: $megabytes) {
            ForEach(FileCopiesPrefs.choices, id: \.self) { choice in
                Text(FileCopiesPrefs.label(megabytes: choice)).tag(choice)
            }
        } label: {
            Text("Show copies of")
            Text("A smaller copy shows too when it will take more than a few seconds, and one that's over in a moment never does.")
        }
        .onChange(of: megabytes) { changed() }
    }
}
