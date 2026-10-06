import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension FeatureTint {
    /// The ring, the spinner and Open: the iPhone's blue in its dark appearance,
    /// Safari's colour for downloads.
    static let downloads = FeatureTint.colour(RGB(bytes: 10, 132, 255))
}

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
            .fileIconBacking(size: size)
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
            ProgressRing(fraction: fraction, lineWidth: lineWidth, tint: .accent(.downloads))
        } else {
            ShortcutSpinner(lineWidth: lineWidth, tint: .accent(.downloads))
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
                    .foregroundStyle(.islandAccent(.downloads))
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
                        .foregroundStyle(.islandPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(DownloadNames.progress(received: item.received, total: item.total))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.islandText(0.55))
                        .lineLimit(1)
                    if let caption = caption(item) {
                        Text(caption)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.islandText(0.4))
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
                            .foregroundStyle(.islandPrimary)
                    } else {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.islandAccent(.downloads))
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
    /// As much room for the name beside Delete as well.
    static let deleteWidth: CGFloat = width + 42
    static let height: CGFloat = 64
    /// The clear space either side of the page in a document icon 44 points wide.
    static let iconInset: CGFloat = 6
}

/// What Delete did, for the card to say before it goes.
enum DownloadDeleteResult: Equatable {
    case deleted
    /// Nothing is where the file was: moved or deleted meanwhile.
    case missing
    /// Something is there, but not the file the card was made for, so it is kept.
    case changed
    case failed

    var note: String {
        switch self {
        case .deleted: "Deleted"
        case .missing: "No longer there"
        case .changed: "File changed, so kept"
        case .failed: "Couldn't delete"
        }
    }
}

/// Delete's two steps: the first click only asks, and the file goes on a click on the
/// Delete that asking puts up. The question lapses after a few seconds, or once the
/// pointer leaves the card; with VoiceOver on it has longer, for the card to be read.
@MainActor
@Observable
final class DeleteConfirmation {
    static let lapse: TimeInterval = 4
    static let spokenLapse: TimeInterval = 30

    private(set) var isAsking = false
    @ObservationIgnored private var lapsing: Task<Void, Never>?

    static func lapse(voiceOver: Bool) -> TimeInterval { voiceOver ? spokenLapse : lapse }

    /// Asks, for `seconds`, or for as long as suits whether VoiceOver is on.
    func ask(for seconds: TimeInterval? = nil) {
        let seconds = seconds ?? Self.lapse(voiceOver: NSWorkspace.shared.isVoiceOverEnabled)
        isAsking = true
        lapsing?.cancel()
        lapsing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    func cancel() {
        lapsing?.cancel()
        lapsing = nil
        isAsking = false
    }

    /// The answer: whether the question was still up, which it no longer is.
    func confirm() -> Bool {
        guard isAsking else { return false }
        cancel()
        return true
    }
}

/// A download has finished, or a PDF has been saved from Print: the file, to drag
/// straight to where it is needed, open, find in Finder or delete.
struct DownloadedCard: View {
    let file: FinishedDownload
    /// The pointer arrived (`true`) or left: the card stays while it is on it.
    let hover: (Bool) -> Void
    let open: () -> Void
    let reveal: () -> Void
    let dismiss: () -> Void
    /// Deletes the file for good, once asked twice; `nil` where the card has no Delete:
    /// for a folder, or a file that could not be read.
    var delete: (() -> DownloadDeleteResult)? = nil
    /// The file's drag began, or ended.
    var dragged: (FileDragSource.Phase) -> Void = { _ in }
    /// The file has been dragged out, and the card stays for it to be deleted.
    var isKept = false
    @State private var confirmation = DeleteConfirmation()
    /// What Delete did, said in place of the size until the card goes.
    @State private var result: DownloadDeleteResult?

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(url: file.url, size: 44)
                .overlay(FileDragSource(url: file.url, help: "Drag the file where you need it", tapped: open, dragged: dragged))
                .allowsHitTesting(result == nil)
                // A document's icon is a page with clear space either side; this puts
                // the page, rather than the space, as far from the card's edge as the
                // close button is from the other.
                .padding(.leading, -DownloadedCardLayout.iconInset)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.islandPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(result?.note ?? subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(noteStyle)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if result == nil {
                if confirmation.isAsking {
                    // Cancel where the bin was, so a double click on it only asks.
                    word("Delete", .hue(.destructive, minimum: Contrast.text), action: confirmDelete)
                        .help("Deletes the file for good. It isn't put in the Trash, so it can't be got back.")
                        .accessibilityLabel("Delete for good")
                    word("Cancel", .text(1)) { confirmation.cancel() }
                } else {
                    word("Open", .accent(.downloads, minimum: Contrast.text), action: open)

                    RoundButton(symbol: "magnifyingglass", diameter: 30, action: reveal)
                        .help("Show in Finder")
                        .accessibilityLabel("Show in Finder")
                    if delete != nil {
                        RoundButton(symbol: "trash", tint: .hue(.destructive), diameter: 30, action: ask)
                            .help("Delete")
                            .accessibilityLabel("Delete")
                            .accessibilityHint("Asks first, then deletes the file for good.")
                    }
                }
            }
            RoundButton(symbol: "xmark", diameter: 30, action: dismiss)
                .accessibilityLabel("Close")
        }
        .frame(maxHeight: .infinity)
        .onHover { hovering in
            if !hovering { confirmation.cancel() }
            hover(hovering)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: confirmation.isAsking)
    }

    private func word(_ title: String, _ ink: IslandInk, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .islandWashed(ink, wash: 0.2, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func ask() {
        confirmation.ask()
        AccessibilityNotification.Announcement("Delete \(file.name) for good? Choose Delete to confirm, or Cancel.").post()
    }

    private func confirmDelete() {
        guard let delete, confirmation.confirm() else { return }
        let done = delete()
        result = done
        AccessibilityNotification.Announcement(done.note).post()
    }

    private var noteStyle: IslandStyle {
        switch result {
        case nil: .islandText(0.55)
        case .deleted?: .islandHueText(.success)
        case .missing?, .changed?: .islandHueText(.warning)
        case .failed?: .islandHueText(.failure)
        }
    }

    private var subtitle: String {
        if confirmation.isAsking { return "Delete for good?" }
        if isKept { return "Stays here to delete later" }
        let done = file.isSaved ? "Saved" : "Downloaded"
        guard let size = file.size, size > 0 else { return done }
        return "\(done) · \(DownloadNames.bytes(size))"
    }
}

// MARK: - Settings

struct DownloadsSettingsView: View {
    /// Called with the folders once they have been read.
    let found: ([URL]) -> Void
    /// Called when PDFs saved from Print are turned on or off.
    var printedChanged: () -> Void = {}
    /// What macOS lets Islet see of the folders PDFs saved from Print are found in.
    let access: FolderAccessModel
    @AppStorage(DownloadsPrefs.showFinished) private var showFinished = true
    @AppStorage(DownloadsPrefs.showPrinted) private var showPrinted = true
    @State private var folders: [URL] = DownloadFolders.downloads.map { [$0] } ?? []

    var body: some View {
        Toggle(isOn: $showFinished) {
            Text("Show finished downloads")
            Text("The file in a card for a few seconds, to drag where it's needed, open, show in Finder or delete. Drag the file out and the card stays, for up to ten minutes, so it can be deleted once it's uploaded. Delete asks first, then deletes the file for good: it isn't put in the Trash.")
        }
        Toggle(isOn: $showPrinted) {
            Text("Show PDFs saved from Print")
            Text(Self.printedExplanation)
        }
        .onChange(of: showPrinted) { printedChanged() }
        if showPrinted {
            PrintFolderAccessRow(model: access)
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

    static let printedExplanation = "A PDF made with ⌘P, then PDF › Save as PDF, in any app, or with Save as PDF in a browser's print preview, comes up in the same card, saying Saved, wherever in your home folder you save it, a couple of seconds after (longer for a long document). PDFs copied, moved, unzipped, synced, downloaded or edited don't show, nor do ones apps make for themselves, or ones with a password to open. Islet hears of them from Spotlight; with Spotlight off, only ones saved to the folders below show."
}

/// Whether macOS lets Islet see the Desktop, Documents and iCloud Drive, where Spotlight
/// finds PDFs saved from Print, and the button that has it ask. With Full Disk Access
/// there is nothing to ask. Otherwise, once asked, it says what macOS decided about each,
/// and where to change a folder macOS was told Islet may not see, as macOS asks only once.
struct PrintFolderAccessRow: View {
    let model: FolderAccessModel

    var body: some View {
        LabeledContent {
            control
        } label: {
            Text("Desktop, Documents and iCloud Drive")
            Text(explanation)
        }
        .task { await model.recheck() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.recheck() }
        }
    }

    /// What the row offers, beside what macOS decided.
    enum Action: Equatable {
        /// Full Disk Access: nothing to ask, so only a tick.
        case none
        /// Not yet known whether Islet has Full Disk Access, for the moment it takes to look.
        case checking
        case ask
        /// macOS may be asking, or a click is being checked: the button gives way to word
        /// that Islet is waiting, for long enough to be seen.
        case waiting
        case openSettings
        case checkAgain
    }

    var action: Action {
        if model.hasFullDiskAccess == true { return .none }
        if model.isAsking { return .waiting }
        if !model.hasAnswers { return model.hasFullDiskAccess == nil ? .checking : .ask }
        return model.refused.isEmpty ? .checkAgain : .openSettings
    }

    @ViewBuilder private var control: some View {
        switch action {
        case .none:
            Label {
                Text("Full Disk Access")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(SystemHue.success.system)
            }
            .foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .ask:
            Button("Ask macOS") { Task { await model.ask() } }
        case .waiting, .openSettings, .checkAgain:
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(PrintFolder.allCases, id: \.self) { folder in
                    FolderVerdict(folder: folder, access: model.verdicts[folder], isAsking: model.asking == folder)
                }
                switch action {
                case .waiting:
                    Text(model.asking == nil ? "Checking…" : "Waiting for macOS…")
                        .foregroundStyle(.secondary)
                case .openSettings:
                    Button("Open Privacy Settings…") { FilesAndFoldersSettings.open() }
                default:
                    Button("Check again") { Task { await model.ask() } }
                        .buttonStyle(.link)
                }
            }
        }
    }

    var explanation: String {
        if model.hasFullDiskAccess == true {
            return "Islet has Full Disk Access, so it sees PDFs saved anywhere in your home folder, and there's nothing for macOS to ask."
        }
        if model.asking != nil {
            return "If macOS asks whether Islet may see a folder, answer it to carry on."
        }
        guard model.hasAnswers else {
            return "Spotlight tells Islet only of PDFs in folders macOS lets it see. Click to have macOS ask about these three; it asks about each only once."
        }
        let refused = model.refused
        if !refused.isEmpty {
            let switches = PrintFolder.list(refused.map(\.settingName))
            return "macOS asks only once. In Privacy & Security › Files & Folders, turn on \(switches) under Islet."
        }
        let seen = PrintFolder.allCases.filter { model.verdicts[$0] == .allowed }.map(\.name)
        let missing = PrintFolder.allCases.filter { model.verdicts[$0] == .missing }.map(\.name)
        var words = seen.isEmpty ? "" : "Islet can see \(PrintFolder.list(seen))."
        if !missing.isEmpty {
            if !words.isEmpty { words += " " }
            words += missing.count == 1 ? "There's no \(missing[0]) folder on this Mac." : "\(PrintFolder.list(missing)) aren't on this Mac."
        }
        return words
    }
}

/// One folder's answer from macOS: a symbol in the colour of what it means, and a word or
/// two.
struct FolderVerdict: View {
    let folder: PrintFolder
    let access: FolderAccess?
    let isAsking: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text("\(folder.name): \(words)")
                .foregroundStyle(.secondary)
            if isAsking {
                ProgressView().controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(colour)
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityElement(children: .combine)
    }

    var words: String {
        if isAsking { return "asking" }
        switch access {
        case .allowed?: return "allowed"
        case .notAllowed?: return "not allowed"
        case .missing?: return "not there"
        case nil: return "not asked yet"
        }
    }

    private var symbol: String {
        switch access {
        case .allowed?: "checkmark.circle.fill"
        case .notAllowed?: "xmark.circle.fill"
        case .missing?, nil: "minus.circle"
        }
    }

    private var colour: Color {
        switch access {
        case .allowed?: SystemHue.success.system
        case .notAllowed?: SystemHue.warning.system
        case .missing?, nil: .secondary
        }
    }
}
