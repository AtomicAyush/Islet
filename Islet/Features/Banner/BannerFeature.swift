import AppKit
import SwiftUI

/// Show in Islet: banners that shortcuts, scripts and tools put up — a build finishing,
/// tests passing or failing, Claude Code done with a long task — through
/// `islet://banner?title=…` (`BannerRequest`) or the Show in Islet action in Shortcuts
/// (`ShowInIsletIntent`).
///
/// Anything on the Mac can open a URL, so what arrives is checked (`CustomBanner`),
/// shows as text only, and is kept to a pace a person can read (`BannerThrottle`): what
/// arrives faster than that is held, the newest in place of the rest, and shown when
/// the pace allows. Turning the feature off in Settings turns every one of them away.
///
/// A banner from Claude Code's or ChatGPT's hook names its session: a click on it opens
/// that session's chat, and a reply finishing in the chat in front of the person puts
/// up none, as their features decide (`BannerSessionSource`).
@MainActor
final class BannerFeature: Feature {
    let id = "banner"
    let title = "Show in Islet"
    let symbol = "bell.badge.fill"
    let summary = "Banners your shortcuts, scripts and tools put up, with islet://banner or the Show in Islet action."

    /// What became of a banner that was asked for.
    enum Outcome: Equatable {
        /// It is up.
        case shown
        /// It came too soon after others. It shows when the throttle allows, unless
        /// something newer arrives first and takes its place.
        case held
        /// It was passive, and a Focus asks for quiet.
        case quieted
        /// Presentation Mode is holding messages back while the screen is shared: it is
        /// counted, for the word the island says afterwards, and not shown or heard.
        case heldBack
        /// The feature is turned off.
        case off
        /// It said a reply finished in a chat the person has in front of them already.
        case onScreen
    }

    /// Every banner gets an id of its own under this prefix, so each one arrives as a
    /// new banner rather than silently rewriting the last, and a dismissal can tell
    /// the feature's banners from the rest of the island's.
    static let bannerPrefix = "banner.custom."

    private let presenter: any BannerPresenter
    private let playSound: @MainActor (String) -> Void
    /// Whether any island is open, when a card cannot be seen.
    private let isIslandOpen: @MainActor () -> Bool
    /// The feature whose sessions an activity's banners name, by the activity's id.
    private let sessions: @MainActor (String) -> (any BannerSessionSource)?
    private var throttle: BannerThrottle
    private var isRunning = false
    private var serial = 0
    /// The newest banner waiting for the throttle, and the wait.
    private var held: CustomBanner?
    private var release: Task<Void, Never>?

    /// `presenter` is the island's `ActivityCenter` unless a test hands in its own, as it
    /// may a throttle with a shorter window, a sound player that only takes notes, its
    /// own say on whether the island is open, and its own sessions.
    init(
        presenter: (any BannerPresenter)? = nil,
        throttle: BannerThrottle = BannerThrottle(),
        playSound: @escaping @MainActor (String) -> Void = { NSSound(named: NSSound.Name($0))?.play() },
        isIslandOpen: @escaping @MainActor () -> Bool = {
            IslandManager.shared.controllers.values.contains { $0.model.isExpanded }
        },
        sessions: @escaping @MainActor (String) -> (any BannerSessionSource)? = { activity in
            FeatureRegistry.shared.features.first { $0.id == activity } as? any BannerSessionSource
        }
    ) {
        self.presenter = presenter ?? ActivityCenter.shared
        self.throttle = throttle
        self.playSound = playSound
        self.isIslandOpen = isIslandOpen
        self.sessions = sessions
    }

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
        dismiss()
    }

    /// Samples of either style. They skip the throttle and make no sound, and show
    /// whether or not the feature is on; `islet://preview` runs them for anyone who
    /// asks, so they say they are samples rather than read like a real result.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Custom banner (compact)") { [weak self] in
                self?.present(.sampleCompact)
            },
            FeaturePreview(title: "Custom banner (card)") { [weak self] in
                self?.present(.sampleCard)
            },
        ]
    }

    /// `islet://banner?title=…` puts a banner up, and `islet://banner/dismiss` takes
    /// down the one showing and anything held. Both are understood, and do nothing,
    /// while the feature is off.
    func handle(_ url: URL) -> Bool {
        guard let request = BannerRequest(url: url) else { return false }
        switch request {
        case .show(let banner):
            show(banner)
        case .dismiss:
            if isRunning { dismiss() }
        }
        return true
    }

    // MARK: Showing

    /// Puts `banner` up now, or once the throttle allows.
    @discardableResult
    func show(_ banner: CustomBanner) -> Outcome {
        guard isRunning else { return .off }
        if isOnScreen(banner) { return .onScreen }
        if isQuieted(banner) { return .quieted }
        if presenter.holdsBack(.messages) {
            // Handed over all the same, for the island to count, but not throttled: the
            // throttle keeps to a pace a person can read, and nothing is shown.
            present(banner)
            return .heldBack
        }
        // Something already waiting goes out first, so this takes its place rather
        // than jumping ahead of it and being replaced by an older banner a moment later.
        if held != nil || throttle.admit(at: .now) != nil {
            hold(banner)
            return .held
        }
        present(banner)
        return .shown
    }

    /// Takes the feature's banner down, if one is showing, and forgets anything held.
    /// Other features' banners are left where they are.
    func dismiss() {
        held = nil
        release?.cancel()
        release = nil
        if let id = presenter.bannerID, id.hasPrefix(Self.bannerPrefix) {
            presenter.dismissBanner(id: id)
        }
    }

    /// Whether `banner` says a reply finished in a session whose chat its feature sees
    /// in front of the person, and Settings asks for none then.
    private func isOnScreen(_ banner: CustomBanner) -> Bool {
        guard banner.isReplyDone, let activity = banner.activityID, let id = banner.sessionID else { return false }
        return sessions(activity)?.skipsDone(for: id) ?? false
    }

    private func isQuieted(_ banner: CustomBanner) -> Bool {
        banner.interruption == .passive && presenter.silencesPassiveBanners
    }

    private func present(_ banner: CustomBanner) {
        var banner = banner
        // The opened island shows a compact banner in its header, but a card nowhere:
        // it would wait out its time under the page. There the card goes up as its
        // compact self, which the header shows, title and all.
        if banner.style == .card, isIslandOpen() { banner.style = .compact }
        serial += 1
        var island = banner.islandBanner(id: "\(Self.bannerPrefix)\(serial)")
        // A click opens the session's chat, if its feature has a session by that name
        // when the click comes; the banner says nothing of where.
        if let activity = banner.activityID, let id = banner.sessionID {
            island.open = { [sessions] in sessions(activity)?.openSession(id) ?? false }
        }
        // One Presentation Mode holds back is not heard either: a sound during a call
        // is heard by everyone on it.
        let isHeard = !presenter.holdsBack(island.personal)
        presenter.present(island)
        if isHeard, let sound = banner.sound { playSound(sound) }
    }

    /// Keeps `banner` in place of whatever was waiting, and waits for the throttle.
    private func hold(_ banner: CustomBanner) {
        held = banner
        guard release == nil else { return }
        scheduleRelease()
    }

    private func scheduleRelease() {
        var probe = throttle
        let due = probe.admit(at: .now) ?? .now
        release = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.releaseHeld()
        }
    }

    private func releaseHeld() {
        release = nil
        guard let banner = held, isRunning else {
            held = nil
            return
        }
        // Woken a hair early, it waits the rest.
        guard throttle.admit(at: .now) == nil else {
            scheduleRelease()
            return
        }
        held = nil
        // A Focus may have come on while it waited, or the chat come to the front.
        if !isQuieted(banner), !isOnScreen(banner) { present(banner) }
    }
}

/// Where the feature's banners go: the island, or a stand-in that takes notes in tests.
@MainActor
protocol BannerPresenter: AnyObject {
    /// The banner on screen, if any.
    var bannerID: String? { get }
    /// Whether a Focus asks for quiet, so passive banners are dropped.
    var silencesPassiveBanners: Bool { get }
    /// Whether Presentation Mode holds this kind back now, so a banner of it is dropped,
    /// and its sound goes unplayed.
    func holdsBack(_ content: PersonalContent?) -> Bool
    func present(_ banner: IslandBanner)
    func dismissBanner(id: String?)
}

extension BannerPresenter {
    /// A stand-in that knows nothing of presenting holds nothing back.
    func holdsBack(_ content: PersonalContent?) -> Bool { false }
}

extension ActivityCenter: BannerPresenter {
    var bannerID: String? { banner?.id }
}

/// Samples for previews, shaped like what a test run and a Claude Code hook send, and
/// saying they are samples.
extension CustomBanner {
    static let sampleCompact = CustomBanner(
        title: "Sample banner", subtitle: "From a script", symbol: "checkmark.circle.fill", tint: .named(.green),
        duration: defaultDuration(for: .compact), style: .compact, sound: nil, interruption: .active
    )
    static let sampleCard = CustomBanner(
        title: "Sample card",
        subtitle: "What a script puts up with style=card: a title, and up to three lines of subtitle under it.",
        symbol: "sparkles", tint: .named(.orange),
        duration: defaultDuration(for: .card), style: .card, sound: nil, interruption: .active
    )
}
