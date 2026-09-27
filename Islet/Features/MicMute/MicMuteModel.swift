import Foundation
import Observation

/// Where a mute or unmute was asked for, which decides whether the island says so: a
/// click in the island changes what is in front of the person anyway; a shortcut, a
/// key or a URL changes something they may not be looking at.
enum MicMuteSource: Equatable {
    case island
    case elsewhere
}

/// What a button, a URL or the Shortcuts action asks of the microphone.
enum MicMuteAction: String, CaseIterable, Sendable {
    case toggle
    case mute
    case unmute
}

/// The Mac's input and Islet's mute, for the island's views, kept on the main thread.
/// The work is the engine's, on its own queue; this only asks and listens.
@MainActor
@Observable
final class MicMuteModel {
    /// The input as last read.
    private(set) var reading = MicMuteSnapshot()
    /// A sample standing in for the reading, while a preview runs.
    private(set) var preview: MicMuteSnapshot?
    /// Whether the feature is on, so that the privacy card knows to offer its button.
    private(set) var isRunning = false
    /// A mute or unmute on its way to the microphone.
    private(set) var isBusy = false

    var shown: MicMuteSnapshot { preview ?? reading }

    /// Whether there is anything to click: Islet's mute to take off, or a microphone it
    /// can mute.
    var canToggle: Bool {
        shown.isMuted || shown.microphone?.way != nil
    }

    /// Called after the reading changes, and after every request, with what came of it
    /// and where it came from. A change with no request behind it (the microphone
    /// unmuted elsewhere, the input moving to one Islet cannot mute) comes with no
    /// source.
    @ObservationIgnored var onChange: (_ event: MicMuteEvent?, _ source: MicMuteSource?) -> Void = { _, _ in }

    @ObservationIgnored private let engine: MicMuteEngine
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// Requests the engine has not answered yet, and the state the newest asked for, so
    /// that a second toggle before the first is done undoes it rather than repeat it.
    @ObservationIgnored private var pending = 0
    @ObservationIgnored private var intended: Bool?

    /// How long a preview stands in for the reading.
    static let previewLength: Duration = .seconds(8)

    /// `hardware` and `store` stand in for Core Audio and the defaults in tests. What
    /// an Islet that ended while muted left behind is put back from here, as Islet
    /// starts, whether or not the feature is on.
    init(hardware: any MicHardware = CoreAudioMicHardware(), store: any MicMuteStore = DefaultsMicMuteStore()) {
        engine = MicMuteEngine(hardware: hardware, store: store)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        engine.start { [weak self] snapshot, event in
            guard let self, self.isRunning else { return }
            self.reading = snapshot
            self.onChange(event, nil)
        }
    }

    /// Unmutes, putting the microphone back as Islet found it, before returning.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        reading = MicMuteSnapshot()
        pending = 0
        intended = nil
        isBusy = false
    }

    /// Mutes, unmutes or toggles. `completion` gets what came of it, or `nil` when the
    /// feature is off. A preview's sample is only there to be looked at, so a click on
    /// it does nothing; a request from elsewhere ends the preview and goes ahead.
    func perform(_ action: MicMuteAction, from source: MicMuteSource, completion: @escaping (MicMuteEvent?) -> Void = { _ in }) {
        guard isRunning, preview == nil || source == .elsewhere else {
            completion(nil)
            return
        }
        endPreview()
        let muted: Bool
        switch action {
        case .toggle: muted = !(intended ?? reading.isMuted)
        case .mute: muted = true
        case .unmute: muted = false
        }
        pending += 1
        intended = muted
        isBusy = true
        engine.setMuted(muted) { [weak self] event in
            guard let self else { return }
            self.pending = max(0, self.pending - 1)
            if self.pending == 0 {
                self.intended = nil
                self.isBusy = false
            }
            if self.isRunning { self.onChange(event, source) }
            completion(event)
        }
    }

    func perform(_ action: MicMuteAction, from source: MicMuteSource) async -> MicMuteEvent? {
        await withCheckedContinuation { continuation in
            perform(action, from: source) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Previews

    /// Stands `sample` in for the reading for `previewLength`.
    func showPreview(_ sample: MicMuteSnapshot) {
        previewTask?.cancel()
        preview = sample
        onChange(nil, nil)
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewLength)
            guard !Task.isCancelled, let self else { return }
            self.endPreview()
        }
    }

    func endPreview() {
        previewTask?.cancel()
        previewTask = nil
        guard preview != nil else { return }
        preview = nil
        onChange(nil, nil)
    }
}
