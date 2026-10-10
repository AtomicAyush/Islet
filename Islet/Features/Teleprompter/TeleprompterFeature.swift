import AppKit
import SwiftUI

/// A teleprompter in the island, right under the camera, so the eyes stay near the lens
/// while reading: the script follows the voice, moves at a set pace, or waits to be
/// scrolled.
///
/// Start holds the island open on the script (`IslandViewModel.KeepOpenPurpose.prompting`)
/// on the display with the camera. Stop lets it go. A long pause lets go of the island
/// too, and the reading waits beside the notch until it is carried on or stopped.
///
/// While the feature runs, and Settings says so (on unless turned off), any island
/// showing the page, before Start as after Stop, or shut with the reading in front, asks
/// macOS to keep it out of screen sharing and recordings (`IslandManager.privatePages`).
///
/// Follow my voice asks for the microphone the first time it starts, never before, and
/// listens only while it runs, through speech recognition on this Mac; where the Mac
/// could only recognise the language on Apple's servers, it says so and doesn't start.
/// A link (`islet://teleprompter/start`) never turns the microphone on: any app or web
/// page can open one. It opens the script ready, for a click on Start, instead.
///
/// The keys ⌃⌥Space, ⌃⌥↑↓ and ⌃⌥←→ work from any app while a reading is under way.
@MainActor
final class TeleprompterFeature: Feature {
    let id = "teleprompter"
    let title = "Teleprompter"
    let symbol = TeleprompterSymbol.feature
    let summary = "A script right under the camera that follows your voice or scrolls at your pace."
    var enabledByDefault: Bool { false }

    static let pageID = "teleprompter"
    /// After Keep Awake's, until the person moves it.
    static let tileOrder = 36
    var homeTile: HomeTileInfo? { HomeTileInfo(self, order: Self.tileOrder) }
    /// Just after the timer's: something being read now goes before music and the rest.
    var islandActivity: IslandActivityInfo? { IslandActivityInfo(self, order: 12) }
    /// How long a pause holds the island open before letting it go.
    static let pauseHold: TimeInterval = 30 * 60
    /// How long the tick beside the notch stays once the script has been read.
    static let finishedHold: TimeInterval = 10

    let scripts: TeleprompterScripts
    let model: TeleprompterModel
    private lazy var activity = TeleprompterActivity(model: model, scripts: scripts, actions: actions)
    private let defaults: UserDefaults
    private var isRunning = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// The island the reading is in, while there is one.
    private weak var island: IslandViewModel?
    private var pauseLetGo: DispatchWorkItem?
    private var finishedEnd: DispatchWorkItem?
    /// The mode a preview reads in, over the one in Settings, while it lasts.
    private var previewMode: TeleprompterMode?
    /// Laying out the script again once typing in Settings pauses, not at every key.
    private var pendingReload: DispatchWorkItem?
    /// How long typing in Settings must pause before the page lays the script out again.
    static let reloadDelay: TimeInterval = 0.4
    /// The island a reading opens in: the one on the display with the camera. The
    /// harness hands it a bare island of its own.
    var findIsland: () -> IslandViewModel? = { IslandManager.shared.notchedController?.model }
    private(set) var keyProblems: [TeleprompterHotKey: String] = [:]
    private var registeredKeys = false
    private var lastPageHeight: CGFloat = 0

    init(
        defaults: UserDefaults = .standard,
        scripts: TeleprompterScripts? = nil,
        access: (any VoiceAccess)? = nil
    ) {
        self.defaults = defaults
        self.scripts = scripts ?? TeleprompterScripts()
        model = TeleprompterModel(settings: TeleprompterSettings.read(from: defaults), access: access ?? SystemVoiceAccess())
        model.onChange = { [weak self] in self?.sync() }
        model.onSettingsChange = { [weak self] settings in
            guard let self, self.previewMode == nil else { return }
            settings.writeControls(to: self.defaults)
        }
        model.onPlace = { [weak self] id, word in self?.scripts.remember(place: word, in: id) }
        self.scripts.changed = { [weak self] in self?.showChosenScript() }
    }

    /// A reading not under way shows the script chosen, as it now is: the page opened
    /// before Start, and the tile, follow edits in Settings. Another script, or a new
    /// name, shows at once; the words typed are laid out again once typing pauses.
    private func showChosenScript() {
        guard !model.hasStarted, previewMode == nil, let selected = scripts.selected else { return }
        guard model.scriptID == selected.id else { return reloadChosenScript() }
        if model.title != selected.shownTitle { model.rename(selected.shownTitle) }
        guard model.sourceText != selected.text else { return }
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reloadChosenScript() }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reloadDelay, execute: work)
    }

    /// Loads the script chosen now, if a reading isn't under way and it has changed.
    private func reloadChosenScript() {
        pendingReload?.cancel()
        pendingReload = nil
        guard !model.hasStarted, previewMode == nil, let selected = scripts.selected else { return }
        if model.scriptID != selected.id || model.sourceText != selected.text { model.load(selected) }
    }

    var actions: TeleprompterActions {
        TeleprompterActions(
            start: { [weak self] in self?.startReading() },
            togglePause: { [weak self] in self?.togglePause() },
            stop: { [weak self] in self?.model.stop() },
            choose: { [weak self] id in self?.choose(id) },
            editScripts: { [weak self] in self?.editScripts() }
        )
    }

    func start() {
        isRunning = true
        observe(.default, UserDefaults.didChangeNotification) { feature in feature.readSettings() }
        // Nobody reads through sleep, a lock or the screens going dark: the microphone
        // goes off at once.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(NSWorkspace.shared.notificationCenter, name) { feature in feature.model.pause() }
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { feature in
            feature.model.pause()
        }
        observe(.default, NSApplication.willTerminateNotification) { feature in
            feature.model.stop()
            feature.scripts.saveNow()
        }
        ActivityCenter.shared.setHomeWidget(HomeWidget(
            id: id, order: Self.tileOrder,
            view: AnyView(TeleprompterHomeTile(model: model, scripts: scripts, actions: actions))
        ))
        ActivityCenter.shared.setPage(page)
        IslandManager.shared.keepOutOfCapture(Self.pageID, model.settings.hideFromCapture)
        sync()
    }

    func stop() {
        isRunning = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        pendingReload?.cancel()
        pendingReload = nil
        model.stop()
        release()
        IslandManager.shared.keepOutOfCapture(Self.pageID, false)
        scripts.saveNow()
        let center = ActivityCenter.shared
        center.end(id: activity.id)
        center.removeHomeWidget(id: id)
        center.removePage(id: Self.pageID)
    }

    func settingsView() -> AnyView? {
        AnyView(TeleprompterSettingsView(scripts: scripts, keyProblems: keyProblems))
    }

    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Teleprompter at a set pace") { [weak self] in self?.preview(.pace) },
            FeaturePreview(title: "Teleprompter, scrolled by hand") { [weak self] in self?.preview(.manual) },
        ]
    }

    /// `islet://teleprompter/start`, `/pause`, `/resume`, `/toggle` and `/stop`. Started or
    /// carried on by a link, Follow my voice opens the script ready rather than listening.
    func handle(_ url: URL) -> Bool {
        switch url.path() {
        case "/start", "/resume":
            if model.mode == .follow {
                openReady()
            } else if model.phase == .paused {
                resume()
            } else {
                startReading()
            }
        case "/pause": model.pause()
        case "/toggle":
            if model.isGoing { model.pause() } else if model.mode == .follow { openReady() } else { togglePause() }
        case "/stop": model.stop()
        default: return false
        }
        return true
    }

    // MARK: Reading

    /// Starts reading the script chosen, from where it was left, in the island on the
    /// display with the camera: hidden from capture first, if asked, then opened onto the
    /// script and held open.
    func startReading() {
        guard isRunning || previewMode != nil else { return }
        if !model.hasStarted || model.phase == .finished {
            guard let script = previewMode == nil ? scripts.selected : TeleprompterScript.sample else {
                editScripts()
                return
            }
            if model.scriptID != script.id || !model.hasStarted { model.load(script) }
        }
        finishedEnd?.cancel()
        hold(open: true)
        model.start()
    }

    /// Carries on from a pause, in the island again.
    func resume() {
        guard model.phase == .paused else { return startReading() }
        hold(open: true)
        model.start()
    }

    /// Play and pause, from the page's button, its Space key or a link: a pause, or a
    /// start or carrying on that holds the island open again, as Start does, whatever
    /// let go of it meanwhile.
    func togglePause() {
        if model.isGoing {
            model.pause()
        } else if model.phase == .paused {
            resume()
        } else {
            startReading()
        }
    }

    /// The script opened ready to start, for a link: nothing listens until Start. The
    /// island is kept out of captures first, if Settings asks.
    private func openReady() {
        reloadChosenScript()
        guard let island = findIsland() else { return }
        IslandManager.shared.shield(island, before: Self.pageID)
        island.expand(focus: Self.pageID)
    }

    private func choose(_ id: UUID) {
        guard let script = scripts.script(id: id) else { return }
        scripts.selectedID = id
        model.load(script)
    }

    private func editScripts() {
        SettingsWindowController.shared.show(feature: id)
    }

    /// Opens the island on the reading and holds it there, kept out of captures first
    /// if Settings asks, or lets it go.
    private func hold(open: Bool) {
        if open {
            pauseLetGo?.cancel()
            pauseLetGo = nil
            show()
            guard let island = island ?? findIsland() else { return }
            self.island = island
            IslandManager.shared.shield(island, before: Self.pageID)
            if !island.isExpanded || island.resolvedFocus != Self.pageID { island.expand(focus: Self.pageID) }
            island.keepOpen(Self.pageID, for: .prompting)
        } else if let island, island.keptOpenPage == Self.pageID {
            island.endKeepingOpen()
        }
    }

    /// Lets go of everything a reading holds: the island, the keys and a preview's mode.
    /// The capture shield stays for as long as an island shows the page.
    private func release() {
        pauseLetGo?.cancel()
        pauseLetGo = nil
        finishedEnd?.cancel()
        finishedEnd = nil
        hold(open: false)
        island = nil
        registerKeys(false)
        if previewMode != nil {
            previewMode = nil
            readSettings()
        }
    }

    /// Follows the model: the activity and the keys from Start to Stop, the island held
    /// while it reads, a long pause letting go of it, and the end folding it to a tick
    /// beside the notch.
    private func sync() {
        let center = ActivityCenter.shared
        guard model.hasStarted else {
            if center.isShowing(id: activity.id) || island != nil || registeredKeys || previewMode != nil {
                center.end(id: activity.id)
                release()
            }
            return
        }
        show()
        registerKeys(model.settings.shortcuts)
        switch model.phase {
        case .running, .countdown, .preparing:
            pauseLetGo?.cancel()
            pauseLetGo = nil
        case .paused:
            guard pauseLetGo == nil else { break }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.pauseLetGo = nil
                    self?.hold(open: false)
                }
            }
            pauseLetGo = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pauseHold, execute: work)
        case .finished:
            hold(open: false)
            finishedEnd?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.model.phase == .finished else { return }
                    self.model.stop()
                }
            }
            finishedEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishedHold, execute: work)
        case .ready:
            break
        }
    }

    /// Shows the activity, or publishes it again when the page's height has changed.
    private func show() {
        let center = ActivityCenter.shared
        let height = model.pageHeight
        if !center.isShowing(id: activity.id) || height != lastPageHeight {
            lastPageHeight = height
            withAnimation(.islandMorph) { center.show(activity) }
        }
        center.setPage(page)
    }

    /// The page, for the island opened on it before a reading starts (a link, or a tile
    /// on another page): the activity's own while one runs.
    private var page: IslandPage {
        IslandPage(
            id: Self.pageID, symbol: symbol, height: model.pageHeight,
            view: AnyView(TeleprompterPage(model: model, scripts: scripts, actions: actions))
        )
    }

    private func readSettings() {
        var settings = TeleprompterSettings.read(from: defaults)
        if let previewMode { settings.mode = previewMode }
        model.apply(settings)
        if model.hasStarted { registerKeys(settings.shortcuts) }
        // Hide from screen sharing turned on or off takes effect at once.
        if isRunning { IslandManager.shared.keepOutOfCapture(Self.pageID, settings.hideFromCapture) }
        showChosenScript()
        ActivityCenter.shared.setPage(page)
    }

    // MARK: Keys

    private func registerKeys(_ wanted: Bool) {
        let hotKeys = InputHotKey.shared
        guard wanted else {
            if registeredKeys {
                TeleprompterHotKey.allCases.forEach { hotKeys.unregister(id: $0.hotKeyID) }
                registeredKeys = false
            }
            return
        }
        guard !registeredKeys else { return }
        registeredKeys = true
        var problems: [TeleprompterHotKey: String] = [:]
        for hotKey in TeleprompterHotKey.allCases {
            guard let combo = hotKey.combo(in: defaults) else {
                hotKeys.unregister(id: hotKey.hotKeyID)
                continue
            }
            let done = hotKeys.register(id: hotKey.hotKeyID, combo) { [weak self] in self?.pressed(hotKey) }
            if !done { problems[hotKey] = "Another app has \(combo.display)" }
        }
        keyProblems = problems
    }

    private func pressed(_ hotKey: TeleprompterHotKey) {
        switch hotKey {
        case .startPause: togglePause()
        case .lineBack: model.lineBack()
        case .lineOn: model.lineOn()
        case .slower: model.slower()
        case .faster: model.faster()
        }
    }

    // MARK: Previews

    /// The sample script in `mode`, never the microphone and never saved: started at
    /// once, in the island on the display with the camera.
    private func preview(_ mode: TeleprompterMode) {
        if model.hasStarted { model.stop() }
        previewMode = mode
        readSettings()
        model.load(.sample, at: 0)
        startReading()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (TeleprompterFeature) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }
}

@MainActor
final class TeleprompterActivity: IslandActivity {
    let id = TeleprompterFeature.pageID
    let name = "Teleprompter"
    let priority = ActivityPriority.high
    let symbol = TeleprompterSymbol.feature
    let model: TeleprompterModel
    let scripts: TeleprompterScripts
    let actions: TeleprompterActions

    init(model: TeleprompterModel, scripts: TeleprompterScripts, actions: TeleprompterActions) {
        self.model = model
        self.scripts = scripts
        self.actions = actions
    }

    var spokenStatus: String? {
        let percent = Int((model.progress(at: Date()) * 100).rounded())
        switch model.phase {
        case .finished: return "Read to the end"
        case .paused: return "Paused, \(percent)% read"
        default: return "\(model.title), \(percent)% read"
        }
    }

    var compactLeadingWidth: CGFloat? { 30 }
    var compactTrailingWidth: CGFloat? { 34 }
    var expandedHeight: CGFloat { model.pageHeight }

    func compactLeading() -> AnyView { AnyView(TeleprompterCompactLeading(model: model)) }
    func compactTrailing() -> AnyView { AnyView(TeleprompterCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(TeleprompterMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(TeleprompterPage(model: model, scripts: scripts, actions: actions)) }
}
