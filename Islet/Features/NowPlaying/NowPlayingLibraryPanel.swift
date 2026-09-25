import SwiftUI
import Observation

/// The opened player's window onto the playing app's library: buttons for what it
/// offers, and a panel below the player listing what is up next or the person's
/// playlists.
///
/// The library does its own talking to its app off the main thread; this only keeps
/// what the panel shows, and drops any answer that arrives for a panel, a library
/// or a request that has since been replaced.
@MainActor
@Observable
final class NowPlayingLibraryModel {
    enum Panel: Equatable {
        case upNext
        case playlists
    }

    enum Listing {
        case loading
        case queue(MediaQueue)
        case playlists([MediaPlaylist])
        case failed(String)
    }

    /// The playing app's library (a sample one during previews), if it has one.
    private(set) var library: (any MediaLibrary)?
    private(set) var panel: Panel?
    private(set) var listing = Listing.loading
    /// The row just picked, shown busy until the app has acted on it.
    private(set) var pendingRow: String?

    /// Called when the panel opens or closes, which changes the card's height.
    @ObservationIgnored var onPanelChange: () -> Void = {}

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?

    /// A moment for the app to move its queue on after a track change, so the
    /// refreshed list is the new one.
    private static let trackChangeDelay: TimeInterval = 1

    // MARK: What the library offers

    func offers(_ capability: MediaLibraryCapabilities) -> Bool {
        library?.capabilities.contains(capability) ?? false
    }

    /// Whether the player has a row of library buttons under it.
    var hasButtons: Bool {
        offers(.upNext) || offers(.playlists) || offers(.listeningTogether)
    }

    // MARK: Library

    /// Follows the app that is playing. Another library closes the panel, since
    /// what it listed belonged to the last one, and drops what was asked of the
    /// last one.
    func use(_ newLibrary: (any MediaLibrary)?) {
        guard newLibrary.map({ ObjectIdentifier($0) }) != library.map({ ObjectIdentifier($0) }) else { return }
        close()
        actionTask?.cancel()
        actionTask = nil
        pendingRow = nil
        library = newLibrary
    }

    /// A new track can move the queue on and change which playlist is playing.
    func trackChanged() {
        guard panel != nil else { return }
        load(after: Self.trackChangeDelay, quietly: true)
    }

    // MARK: Panel

    /// Opens the panel, or closes it when it is the one already open.
    func toggle(_ newPanel: Panel) {
        if panel == newPanel {
            close()
        } else {
            open(newPanel)
        }
    }

    func open(_ newPanel: Panel) {
        guard library != nil, panel != newPanel else { return }
        withAnimation(.islandMorph) {
            panel = newPanel
            listing = .loading
        }
        load(quietly: false)
        onPanelChange()
    }

    /// Something already picked still plays; only the list is dropped.
    func close() {
        guard panel != nil else { return }
        loadTask?.cancel()
        loadTask = nil
        withAnimation(.islandMorph) { panel = nil }
        listing = .loading
        onPanelChange()
    }

    /// Loads the open panel's list afresh, showing that it is loading.
    func reload() {
        load(quietly: false)
    }

    // MARK: Actions

    func play(_ item: MediaItem, at index: Int) {
        perform(row: Self.queueRow(index)) { try await $0.playFromQueue(item, at: index) }
    }

    /// Queues a song still to come. It keeps its place in the playlist too, so the
    /// list comes back with it twice, the first time under "Next in queue". The
    /// library waits for its app to list it before returning.
    func playNext(_ item: MediaItem, at index: Int) {
        perform(row: Self.queueRow(index)) { try await $0.playNext(item) }
    }

    func play(_ playlist: MediaPlaylist) {
        perform(row: Self.playlistRow(playlist)) { try await $0.play(playlist) }
    }

    func openListeningTogether() {
        library?.openListeningTogether()
    }

    /// Rows are told apart by position in the queue, where a song can appear twice.
    static func queueRow(_ index: Int) -> String { "queue.\(index)" }
    static func playlistRow(_ playlist: MediaPlaylist) -> String { "playlist.\(playlist.id)" }

    // MARK: Loading

    /// Fetches the open panel's list. A quiet load keeps the list on screen until
    /// the new one arrives, and keeps it if that fails; a loud one shows the spinner
    /// and any error.
    private func load(after delay: TimeInterval = 0, quietly: Bool) {
        loadTask?.cancel()
        loadTask = nil
        guard let library, let panel, library.state == .ready else { return }
        if !quietly { listing = .loading }
        loadTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            let result: Listing
            do {
                switch panel {
                case .upNext: result = .queue(try await library.upNext())
                case .playlists: result = .playlists(try await library.playlists())
                }
            } catch {
                result = .failed(error.localizedDescription)
            }
            guard let self, !Task.isCancelled, self.panel == panel, self.library === library else { return }
            self.loadTask = nil
            if quietly, case .failed = result, self.isShowingList { return }
            self.listing = result
        }
    }

    private var isShowingList: Bool {
        switch listing {
        case .queue, .playlists: true
        case .loading, .failed: false
        }
    }

    /// One at a time, and it runs to the end even if the panel closes meanwhile.
    private func perform(row: String, _ action: @escaping @MainActor (any MediaLibrary) async throws -> Void) {
        guard let library, actionTask == nil else { return }
        pendingRow = row
        actionTask = Task { [weak self] in
            var failure: String?
            do {
                try await action(library)
            } catch {
                failure = error.localizedDescription
            }
            guard let self, !Task.isCancelled, self.library === library else { return }
            self.actionTask = nil
            self.pendingRow = nil
            guard self.panel != nil else { return }
            if let failure {
                self.loadTask?.cancel()
                self.loadTask = nil
                self.listing = .failed(failure)
            } else {
                self.load(quietly: true)
            }
        }
    }
}

// MARK: - Buttons

/// Small capsules under the player, one for each thing the library offers. Up Next
/// and Playlists open their panel (and close it again); listening together hands
/// over to the app.
struct NowPlayingLibraryButtons: View {
    let model: NowPlayingModel
    let library: NowPlayingLibraryModel

    var body: some View {
        HStack(spacing: 8) {
            if library.offers(.upNext) {
                LibraryChip(title: "Up Next", symbol: "list.bullet", isSelected: library.panel == .upNext) {
                    library.toggle(.upNext)
                }
            }
            if library.offers(.playlists) {
                LibraryChip(title: "Playlists", symbol: "music.note.list", isSelected: library.panel == .playlists) {
                    library.toggle(.playlists)
                }
            }
            if library.offers(.listeningTogether) {
                let together = ListeningTogether(bundleID: model.track?.bundleID)
                LibraryChip(title: together.title, symbol: together.symbol, isSelected: false) {
                    library.openListeningTogether()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// What the playing app calls listening with other people.
private struct ListeningTogether {
    let title: String
    let symbol: String

    init(bundleID: String?) {
        switch bundleID {
        case "com.spotify.client":
            title = "Jam"
            symbol = "person.2.wave.2.fill"
        case "com.apple.Music":
            title = "SharePlay"
            symbol = "shareplay"
        default:
            title = "Listen Together"
            symbol = "person.2.fill"
        }
    }
}

private struct LibraryChip: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color.black : .white.opacity(isHovering ? 1 : 0.85))
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(isSelected ? Color.white : .white.opacity(isHovering ? 0.18 : 0.11)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Panel

/// The open panel: the list, or whatever stands in its way — loading, a sign-in or
/// permission to ask for, a library that cannot be used, an error.
struct NowPlayingLibraryPanel: View {
    let model: NowPlayingModel
    let library: NowPlayingLibraryModel

    var body: some View {
        ZStack {
            if let source = library.library {
                let state = source.state
                content(source, state: state)
                    // A library that has just been connected lists straight away.
                    .onChange(of: state) { _, new in
                        if new == .ready { library.reload() }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(_ source: any MediaLibrary, state: MediaLibraryState) -> some View {
        switch state {
        case .ready:
            listing
        case .needsConnection(let prompt):
            PanelMessage(text: nil, button: prompt) { source.connect() }
        case .unavailable(let reason):
            // As the island's own settings button does: close, then open Settings.
            PanelMessage(text: reason, button: "Open Settings") {
                IslandManager.shared.focusedController?.model.collapse()
                UserDefaults.standard.set("activities", forKey: SettingsView.tabKey)
                SettingsWindowController.shared.show()
            }
        }
    }

    @ViewBuilder
    private var listing: some View {
        switch library.listing {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .failed(let message):
            PanelMessage(text: message, button: "Retry") { library.reload() }
        case .queue(let queue):
            if queue.all.isEmpty {
                PanelMessage(text: "Nothing up next")
            } else {
                PanelList {
                    ForEach(QueueLine.lines(queue, canPlayNext: library.offers(.playNext))) { line in
                        switch line {
                        case .header(let title):
                            PanelHeader(title: title)
                        case .song(let item, let index, let canPlayNext):
                            // Spotify adds after songs already queued, so the label
                            // says where it will actually land.
                            queueRow(item, at: index, canPlayNext: canPlayNext, joinsQueue: !queue.queued.isEmpty)
                        }
                    }
                }
            }
        case .playlists(let playlists):
            if playlists.isEmpty {
                PanelMessage(text: "No playlists")
            } else {
                PanelList {
                    ForEach(playlists) { playlist in
                        LibraryRow(
                            title: playlist.name,
                            subtitle: playlist.detail,
                            artworkURL: playlist.artworkURL,
                            placeholder: "music.note.list",
                            isBusy: library.pendingRow == NowPlayingLibraryModel.playlistRow(playlist),
                            action: { library.play(playlist) }
                        ) {
                            if playlist.isCurrent {
                                CurrentMark(model: model)
                            }
                        }
                    }
                }
            }
        }
    }

    private func queueRow(_ item: MediaItem, at index: Int, canPlayNext: Bool, joinsQueue: Bool) -> some View {
        LibraryRow(
            title: item.title,
            subtitle: item.subtitle,
            artworkURL: item.artworkURL,
            placeholder: "music.note",
            isBusy: library.pendingRow == NowPlayingLibraryModel.queueRow(index),
            action: library.offers(.playFromQueue) ? { library.play(item, at: index) } : nil,
            playNext: canPlayNext ? { library.playNext(item, at: index) } : nil,
            joinsQueue: joinsQueue
        ) {
            if let duration = item.duration, duration > 0 {
                Text(NowPlayingClock.text(duration))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

/// A line of Up Next: a song, or the header over one part of the queue.
///
/// They make one list, not a list per part, because the lazy stack under them
/// shows stale rows when a row's id moves from one part to the other, as it does
/// when a song is queued ahead of it.
private enum QueueLine: Identifiable {
    case header(String)
    /// `index` is the song's position in `MediaQueue.all`.
    case song(MediaItem, index: Int, canPlayNext: Bool)

    /// Songs go by position, since one can be in the queue twice.
    var id: String {
        switch self {
        case .header(let title): "header.\(title)"
        case .song(_, let index, _): "song.\(index)"
        }
    }

    /// Split as Spotify shows it: what was queued plays first, then the rest of
    /// what is playing. Only the rest can be queued to play next.
    static func lines(_ queue: MediaQueue, canPlayNext: Bool) -> [QueueLine] {
        var lines: [QueueLine] = []
        if queue.isSplit, !queue.queued.isEmpty {
            lines.append(.header("Next in queue"))
        }
        lines += queue.queued.enumerated().map { .song($1, index: $0, canPlayNext: false) }
        if queue.isSplit, !queue.upcoming.isEmpty {
            lines.append(.header(upcomingTitle(queue.sourceName)))
        }
        lines += queue.upcoming.enumerated().map {
            .song($1, index: queue.queued.count + $0, canPlayNext: canPlayNext)
        }
        return lines
    }

    /// "Next from: My playlist #9", or plainer when the app does not say.
    private static func upcomingTitle(_ sourceName: String?) -> String {
        guard let name = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return "Next up" }
        return "Next from: \(name)"
    }
}

/// Names a part of Up Next, over its rows.
private struct PanelHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A short scrolling list whose edges soften where rows pass under them.
private struct PanelList<Rows: View>: View {
    @ViewBuilder let rows: Rows

    private let fade: CGFloat = 12

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 2) { rows }
                .padding(.vertical, fade / 2)
        }
        .scrollIndicators(.automatic)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: fade / 2)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: fade)
            }
        }
    }
}

private struct LibraryRow<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    /// SF Symbol shown until (or instead of) the artwork.
    let placeholder: String
    let isBusy: Bool
    /// `nil` when the library cannot act on the row.
    let action: (() -> Void)?
    /// Queues the song to play next, for a song still to come that the library can
    /// queue: a button over the accessory while the pointer is on the row, and the
    /// row's menu.
    var playNext: (() -> Void)?
    /// Songs are already queued, so a queued song goes after them: "Add to Queue"
    /// rather than "Play Next".
    var joinsQueue = false
    @ViewBuilder let accessory: Accessory
    @State private var isHovering = false

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 10) {
                LibraryArtwork(url: artworkURL, placeholder: placeholder)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    // Kept in the layout under the button, so the title does not
                    // shift when the button comes and goes.
                    accessory
                        .opacity(showsPlayNext ? 0 : 1)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(isHovering && action != nil ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Over the row's button rather than inside it, so it takes its own clicks.
        .overlay(alignment: .trailing) {
            if showsPlayNext, let playNext {
                PlayNextButton(joinsQueue: joinsQueue, action: playNext)
                    .padding(.trailing, 6)
            }
        }
        .contextMenu {
            if let playNext {
                Button(PlayNextButton.title(joinsQueue), systemImage: PlayNextButton.symbol(joinsQueue), action: playNext)
            }
        }
        .allowsHitTesting(action != nil || playNext != nil)
        .onHover { isHovering = $0 }
    }

    private var showsPlayNext: Bool {
        isHovering && playNext != nil && !isBusy
    }
}

/// Play Next (or Add to Queue) on a row the pointer is on.
private struct PlayNextButton: View {
    let joinsQueue: Bool
    let action: () -> Void
    @State private var isHovering = false

    static func title(_ joinsQueue: Bool) -> String { joinsQueue ? "Add to Queue" : "Play Next" }

    /// Music's own Play Next and Play Later symbols.
    static func symbol(_ joinsQueue: Bool) -> String {
        joinsQueue ? "text.line.last.and.arrowtriangle.forward" : "text.line.first.and.arrowtriangle.forward"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: Self.symbol(joinsQueue))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.85))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(isHovering ? 0.22 : 0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Self.title(joinsQueue))
        .accessibilityLabel(Self.title(joinsQueue))
    }
}

private struct LibraryArtwork: View {
    let url: URL?
    let placeholder: String

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(white: 0.17)
                    Image(systemName: placeholder)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Marks the playlist that is playing, in the tint colour.
private struct CurrentMark: View {
    let model: NowPlayingModel
    @AppStorage(NowPlayingPrefs.tintWaveform) private var tinted = NowPlayingPrefs.tintWaveformDefault

    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(model.tint(tinted))
            .accessibilityLabel("Playing")
    }
}

/// A line of explanation and, where there is something to do about it, a button.
private struct PanelMessage: View {
    var text: String?
    var button: String?
    var action: () -> Void = {}
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 10) {
            if let text {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            if let button {
                Button(action: action) {
                    Text(button)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background(Capsule().fill(.white.opacity(isHovering ? 1 : 0.9)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
            }
        }
        .padding(.horizontal, 24)
    }
}
