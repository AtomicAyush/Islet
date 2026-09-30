import AppKit
import SwiftUI
import Observation

/// A quick question, asked from the island and answered there, and forgotten as the
/// island closes. ⌥⇧Space (or the tile, or the Shortcuts action) opens the box on the
/// display under the pointer, ready to type; Return asks. Apple's on-device model answers
/// where it can, and ChatGPT or Claude through their own apps' command line tools, a tap
/// away.
///
/// Islet keeps nothing of it: the questions and answers are in memory while the island
/// is open, for follow-ups to go on from, and are gone when it closes. Nothing is written
/// to disk or the defaults, logged, put in a URL, or copied unless Copy is pressed; the
/// tools are run so that they keep nothing either (`AskProcess`, `CodexAskBackend`,
/// `ClaudeAskBackend`).
@MainActor
final class QuickAskFeature: Feature {
    let id = "quickask"
    let title = "Quick Ask"
    let symbol = "questionmark.bubble.fill"
    let summary = "Ask a quick question from the island, and have it forgotten as the island closes."

    enum Key {
        /// The provider last chosen in the box: a setting, never what was asked.
        static let provider = "feature.quickask.provider"
        /// The shortcut, as [key code, modifiers]; an empty list for none.
        static let shortcut = "feature.quickask.shortcut"
        /// What "Look at my screen" takes a picture of (`ScreenLookTarget`): a setting.
        static let lookAt = "feature.quickask.look-at"
        /// Whether Apple's model may read the calendar (`AskCalendar`): on unless turned off.
        static let calendar = "feature.quickask.calendar"
    }

    /// Where the tile goes on the home page: after the clipboard, before the shelf.
    static let tileOrder = 56
    var homeTile: HomeTileInfo? { HomeTileInfo(self, order: Self.tileOrder) }

    static let modeID = "ask"

    let model: QuickAskModel
    private var defaultsObserver: NSObjectProtocol?

    init(model: QuickAskModel? = nil) {
        self.model = model ?? QuickAskModel()
    }

    func start() {
        // Runs cut short by a crash leave their folders behind.
        AskProcess.removeLeftovers()
        AskNetwork.shared.start()
        let model = model
        model.refreshStatuses()
        InputCenter.shared.register(InputMode(
            id: Self.modeID, title: "Ask", symbol: "questionmark.bubble.fill", tint: .quickAsk,
            placeholder: "Ask anything", order: 0,
            recipient: { model.provider.name },
            makeSession: { QuickAskSession(ask: model) }
        ))
        InputHotKey.shared.pressed = { InputCenter.shared.toggle(QuickAskFeature.modeID) }
        applyShortcut()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyShortcut() }
        }
        ActivityCenter.shared.setHomeWidget(HomeWidget(
            id: id, order: Self.tileOrder,
            view: AnyView(QuickAskHomeTile(model: model) { InputCenter.shared.open(QuickAskFeature.modeID) })
        ))
    }

    func stop() {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        InputHotKey.shared.unregister()
        InputHotKey.shared.pressed = {}
        InputCenter.shared.unregister(id: Self.modeID)
        ActivityCenter.shared.removeHomeWidget(id: id)
        AskNetwork.shared.stop()
    }

    func settingsView() -> AnyView? {
        AnyView(QuickAskSettings(model: model))
    }

    /// The shortcut as Settings has it, registered; when another app has it, Settings
    /// says so.
    private func applyShortcut() {
        let combo = model.shortcut
        let registered = InputHotKey.shared.register(combo)
        let problem = registered ? nil : combo.map { "\($0.display) is taken by another app — choose another" }
        if model.shortcutProblem != problem { model.shortcutProblem = problem }
    }
}

extension FeatureTint {
    /// The box's Ask chip and the tile: a soft violet.
    static let quickAsk = FeatureTint.colour(RGB(bytes: 175, 130, 255))
}

/// What Quick Ask shares between the box, its tile and Settings: who can answer, who
/// was chosen, the shortcut, copying, taking pictures of the screen, and the calendar
/// Apple's model reads. Nothing asked or answered, and no picture, is kept here.
@MainActor
@Observable
final class QuickAskModel {
    @ObservationIgnored let backends: [AskProvider: any AskBackend]
    @ObservationIgnored let defaults: UserDefaults
    /// Where Copy puts an answer.
    @ObservationIgnored var pasteboard: NSPasteboard
    private(set) var statuses: [AskProvider: AskStatus] = [:]
    /// Why the shortcut isn't working, if it isn't.
    var shortcutProblem: String?
    /// What takes pictures of the screen, when "Look at my screen" is pressed.
    @ObservationIgnored let capturer: any ScreenCapturer
    /// Screen Recording, as last looked at.
    private(set) var screenPermission = ScreenPermission.denied
    /// The display an island is on. Tests replace it.
    @ObservationIgnored var islandDisplay: (IslandViewModel?) -> CGDirectDisplayID? = { ScreenLook.display(of: $0) }
    /// macOS was asked for Screen Recording: it is asked once, as the control is first
    /// used, and never again.
    @ObservationIgnored private(set) var askedForScreen = false
    /// The calendar, as Apple's model reads it.
    @ObservationIgnored let calendar: AskCalendar

    init(
        backends: [any AskBackend]? = nil,
        defaults: UserDefaults = .standard,
        pasteboard: NSPasteboard = .general,
        capturer: (any ScreenCapturer)? = nil,
        calendar: AskCalendar? = nil
    ) {
        let backends = backends ?? [AppleAskBackend(), CodexAskBackend(), ClaudeAskBackend()]
        self.backends = Dictionary(uniqueKeysWithValues: backends.map { ($0.provider, $0) })
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.capturer = capturer ?? SystemScreenCapturer()
        self.calendar = calendar ?? AskCalendar(defaults: defaults)
        if let apple = self.backends[.onDevice] as? AppleAskBackend, apple.calendar == nil { apple.calendar = self.calendar }
    }

    func backend(_ provider: AskProvider) -> any AskBackend {
        backends[provider] ?? AppleAskBackend()
    }

    func refreshStatuses() {
        var next: [AskProvider: AskStatus] = [:]
        for provider in AskProvider.allCases { next[provider] = backends[provider]?.status() ?? .notInstalled }
        if next != statuses { statuses = next }
    }

    func status(of provider: AskProvider) -> AskStatus {
        statuses[provider] ?? .notInstalled
    }

    /// The provider chosen, or, before one is, the first that can answer.
    var provider: AskProvider {
        chosen ?? AskProvider.firstReady(status(of:))
    }

    var chosen: AskProvider? {
        defaults.string(forKey: QuickAskFeature.Key.provider).flatMap(AskProvider.init(rawValue:))
    }

    func choose(_ provider: AskProvider) {
        defaults.set(provider.rawValue, forKey: QuickAskFeature.Key.provider)
    }

    var shortcut: KeyCombo? {
        KeyCombo.stored(in: defaults, key: QuickAskFeature.Key.shortcut)
    }

    func setShortcut(_ combo: KeyCombo?) {
        defaults.set(combo?.stored ?? [Int](), forKey: QuickAskFeature.Key.shortcut)
    }

    /// What "Look at my screen" takes a picture of: the front window unless chosen.
    var lookTarget: ScreenLookTarget {
        get { defaults.string(forKey: QuickAskFeature.Key.lookAt).flatMap(ScreenLookTarget.init(rawValue:)) ?? .frontWindow }
        set { defaults.set(newValue.rawValue, forKey: QuickAskFeature.Key.lookAt) }
    }

    /// Whether a question about the calendar for ChatGPT or Claude offers Apple's model
    /// instead: it can answer now, and read the calendar.
    var offersCalendar: Bool {
        status(of: .onDevice) == .ready && calendar.offered
    }

    /// Whether `provider` can be shown a picture now.
    func takesImages(_ provider: AskProvider) -> Bool {
        status(of: provider) == .ready && backend(provider).takesImages
    }

    func refreshScreenPermission() {
        let current = capturer.permission()
        if current != screenPermission { screenPermission = current }
    }

    /// Screen Recording is off, as the control is used: macOS is asked, the first time.
    func askForScreen() {
        guard !askedForScreen else { return }
        askedForScreen = true
        capturer.requestPermission()
    }

    func closeBackends() {
        for backend in backends.values { backend.close() }
    }

    /// Copies an answer as plain text, marked as not for keeping, so clipboard
    /// managers — Islet's own history among them — leave it out.
    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.transientType)
    }

    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
}
