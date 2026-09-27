import SwiftUI
import Observation

/// Whether the song playing is saved — liked in Spotify, a favourite in Music — for
/// the player's heart, and the song itself as its app knows it, for adding it to a
/// playlist.
///
/// It is read only while the opened island shows a library that saves, once for each
/// song, and not again when the player folds for a panel and back. A tap shows the
/// change straight away and puts it back if the app refuses it. Answers that arrive
/// for a song that has since changed, or from a library since replaced, are dropped.
@MainActor
@Observable
final class NowPlayingSaveModel {
    enum State: Equatable {
        /// No heart: the library cannot save, is not ready, or nothing it could save
        /// is playing (an advert, a local file, a song on another device).
        case hidden
        case loading
        case ready(MediaPlayingItem)
        /// The sign-in has to be given again first; `prompt` says so.
        case needsReconnect(String)
        /// It could not be read; tapping the heart tries again.
        case failed(String)
    }

    private(set) var state = State.hidden
    /// Followed from `NowPlayingLibraryModel`.
    private(set) var library: (any MediaLibrary)?
    /// The song whose change is on its way to the app, so it is not sent twice.
    private(set) var changingID: String?
    /// Why the last change was put back, for the heart's tooltip.
    private(set) var failure: String?

    /// What was read last, and when it was answered: nil while the answer is on its
    /// way, and long ago for an answer not worth keeping.
    @ObservationIgnored private var asked: Question?
    @ObservationIgnored private var answeredAt: Date?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    /// Tells the latest reading from earlier ones still on their way.
    @ObservationIgnored private var generation = 0
    /// Goes up when a change is sent and again when it is answered, so a reading
    /// that overlapped either keeps the heart as the change left it: what it read
    /// may be from before the app had the change.
    @ObservationIgnored private var changes = 0

    /// Long enough to cover the player folding for a panel and unfolding again, short
    /// enough that opening the island later on the same song reads it afresh: the
    /// person may have liked it in the app meanwhile.
    static let freshFor: TimeInterval = 15

    /// The whole track, not just its title: two songs can share one.
    private struct Question: Equatable {
        var track: NowPlayingTrack
        var library: ObjectIdentifier
        var signIns: Int
    }

    /// Whether the library can save, so the heart has a place.
    var offersSave: Bool {
        library?.capabilities.contains(.save) ?? false
    }

    // MARK: Following

    /// Another library forgets what the last one said, and anything asked of it.
    func use(_ newLibrary: (any MediaLibrary)?) {
        guard newLibrary.map({ ObjectIdentifier($0) }) != library.map({ ObjectIdentifier($0) }) else { return }
        library = newLibrary
        forget()
        changingID = nil
        failure = nil
    }

    /// Reads whether `track` is saved, unless it has just been read or is being read
    /// now. `track` is nil when nothing that could be saved is on show (nothing at
    /// all, or a video).
    func refresh(track: NowPlayingTrack?, force: Bool = false) {
        guard let library, library.state == .ready,
              library.capabilities.contains(.save) || library.capabilities.contains(.addToPlaylist),
              let track, !track.title.isEmpty
        else {
            forget()
            return
        }
        let question = Question(track: track, library: ObjectIdentifier(library), signIns: library.signInCount)
        if !force, question == asked, answeredAt.map({ Date().timeIntervalSince($0) < Self.freshFor }) ?? true {
            return
        }
        readTask?.cancel()
        generation += 1
        let generation = generation
        // The same song keeps its heart while it is read again.
        if case .ready = state, asked?.track == track {} else { state = .loading }
        asked = question
        answeredAt = nil
        failure = nil
        let title = track.title
        let changes = changes
        readTask = Task { [weak self] in
            let answer: State
            do {
                answer = try await library.playingItem(titled: title).map(State.ready) ?? .hidden
            } catch let reconnect as MediaLibraryNeedsReconnect {
                answer = .needsReconnect(reconnect.prompt)
            } catch {
                answer = .failed(error.localizedDescription)
            }
            guard let self, generation == self.generation else { return }
            self.answered(answer, changesWhenAsked: changes)
        }
    }

    private func answered(_ answer: State, changesWhenAsked: Int) {
        readTask = nil
        switch answer {
        case .failed, .needsReconnect:
            // Asked again the next time the island opens, not kept for a while.
            answeredAt = .distantPast
        default:
            answeredAt = Date()
        }
        // A change on its way, or made while this was read, is newer than what was read.
        if case .ready(var item) = answer, case .ready(let shown) = state, shown.id == item.id,
           item.id == changingID || changes != changesWhenAsked {
            item.isSaved = shown.isSaved
            state = .ready(item)
        } else {
            state = answer
        }
    }

    private func forget() {
        readTask?.cancel()
        readTask = nil
        generation += 1
        asked = nil
        answeredAt = nil
        state = .hidden
    }

    // MARK: Saving

    /// Saves the song on show, or takes it out: at once on screen, then in the app,
    /// put back if the app refuses. One change at a time for each song.
    func toggle() {
        switch state {
        case .ready(var item):
            guard let library, changingID != item.id else { return }
            let wanted = !item.isSaved
            item.isSaved = wanted
            state = .ready(item)
            changingID = item.id
            changes += 1
            failure = nil
            Task { [weak self] in
                var refusal: Error?
                do {
                    try await library.setSaved(wanted, item)
                } catch {
                    refusal = error
                }
                self?.changed(item, to: wanted, by: library, refusal: refusal)
            }
        case .failed:
            refresh(track: asked?.track, force: true)
        case .hidden, .loading, .needsReconnect:
            break
        }
    }

    /// Puts the heart back after a refusal, as long as it still shows the song.
    private func changed(_ item: MediaPlayingItem, to wanted: Bool, by changer: any MediaLibrary, refusal: Error?) {
        guard library === changer else { return }
        if changingID == item.id { changingID = nil }
        changes += 1
        guard let refusal, case .ready(var shown) = state, shown.id == item.id else { return }
        if let reconnect = refusal as? MediaLibraryNeedsReconnect {
            answeredAt = .distantPast
            state = .needsReconnect(reconnect.prompt)
        } else {
            shown.isSaved = !wanted
            state = .ready(shown)
            failure = refusal.localizedDescription
        }
    }

    // MARK: Adding

    /// `track` as its app knows it, for adding to a playlist: the item the heart
    /// already has for it, or read now.
    func item(for track: NowPlayingTrack) async throws -> MediaPlayingItem {
        if case .ready(let item) = state, asked?.track == track { return item }
        guard let library else { throw MediaLibraryError(message: "Nothing to add is playing") }
        guard let item = try await library.playingItem(titled: track.title) else {
            throw MediaLibraryError(message: "This can't be added to a playlist")
        }
        return item
    }

    /// The item the heart has for `track`, if it has read it: for ticking the
    /// playlists that have it, which is no reason to ask the app.
    func knownItem(for track: NowPlayingTrack?) -> MediaPlayingItem? {
        guard let track, case .ready(let item) = state, asked?.track == track else { return nil }
        return item
    }
}

// MARK: - Heart

/// The heart (Music's star) at the start of the controls, across from the output
/// button: filled in the tint colour when the song is saved, and a tap saves it or
/// takes it out. Dimmed while it is read, and when it cannot be used, where a tap
/// says why or tries again. Nothing at all for a library that cannot save, or when
/// nothing that could be saved is playing.
struct NowPlayingSaveButton: View {
    let model: NowPlayingModel
    let library: NowPlayingLibraryModel
    @AppStorage(NowPlayingPrefs.tintWaveform) private var tinted = NowPlayingPrefs.tintWaveformDefault
    @State private var isHovering = false

    static let diameter: CGFloat = 26

    var body: some View {
        let saving = library.saving
        if !model.isVideo, saving.offersSave, let style = saving.library?.saveStyle {
            switch saving.state {
            case .hidden:
                EmptyView()
            case .loading:
                glyph(style.symbol, colour: .white.opacity(0.35), background: 0.06)
                    .accessibilityLabel(style.save)
                    .accessibilityValue("Loading")
            case .ready(let item):
                button(help: saving.failure ?? (item.isSaved ? style.unsave : style.saveHelp)) {
                    saving.toggle()
                } label: {
                    glyph(
                        item.isSaved ? style.savedSymbol : style.symbol,
                        colour: item.isSaved ? model.tint(tinted) : .white.opacity(isHovering ? 1 : 0.85),
                        background: isHovering ? 0.18 : 0.11
                    )
                    .symbolEffect(.bounce, value: item.isSaved)
                }
                .accessibilityLabel(style.save)
                .accessibilityAddTraits(item.isSaved ? .isSelected : [])
            case .needsReconnect(let prompt):
                // The panel says what is needed, with the button that does it.
                button(help: prompt) {
                    library.showReconnect(prompt)
                } label: {
                    glyph(style.symbol, colour: .white.opacity(isHovering ? 0.8 : 0.45), background: isHovering ? 0.14 : 0.08)
                }
                .accessibilityLabel(style.save)
                .accessibilityHint(prompt)
            case .failed(let message):
                button(help: message) {
                    saving.toggle()
                } label: {
                    glyph(style.symbol, colour: .white.opacity(isHovering ? 0.8 : 0.45), background: isHovering ? 0.14 : 0.08)
                }
                .accessibilityLabel(style.save)
                .accessibilityHint(message)
            }
        }
    }

    private func glyph(_ symbol: String, colour: Color, background: Double) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(colour)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: Self.diameter, height: Self.diameter)
            .background(Circle().fill(.white.opacity(background)))
            .contentShape(Circle())
            .animation(.smooth(duration: 0.2), value: symbol)
    }

    private func button(help: String, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action, label: label)
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(help)
    }
}

/// What the island's player asks the library about: the song on show, from which
/// library, as signed in when. The buttons row reads it whenever this changes; it
/// is there, not on the heart, because the row stays put while the player folds and
/// unfolds for a panel, which would otherwise read it twice.
struct NowPlayingSaveQuestion: Equatable {
    var track: NowPlayingTrack?
    var library: ObjectIdentifier?
    var isReady: Bool
    var signIns: Int

    @MainActor
    init(model: NowPlayingModel, library: NowPlayingLibraryModel) {
        let source = library.library
        track = model.isVideo ? nil : model.track
        self.library = source.map { ObjectIdentifier($0) }
        isReady = source?.state == .ready
        signIns = source?.signInCount ?? 0
    }
}
