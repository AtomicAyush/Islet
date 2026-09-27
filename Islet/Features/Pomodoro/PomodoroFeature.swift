import AppKit
import SwiftUI

/// The Pomodoro method: twenty-five minutes of focus, a five-minute break, and after
/// every fourth focus a longer one, each length and the count up to the long break set
/// in Settings. Started from the home page, a URL or Shortcuts, with the phase and the
/// time left beside the notch while it runs, and a word and a sound as each phase gives
/// way to the next.
///
/// Breaks start by themselves and a focus waits for a click, unless Settings says
/// otherwise. If asked, a focus session turns on Focus with the shortcut chosen in
/// Focus's settings, and turns it off again for the break; and keeps the Mac awake with
/// a power assertion of its own, given back as the focus ends or pauses.
///
/// A session lasts only as long as Islet runs, as the timer's countdown does. Stopping
/// it, turning the feature off or quitting Islet ends it, and nothing is picked back up
/// at the next launch: a focus resumed after a relaunch would be timing someone who may
/// long since have left, and would turn Focus on again with nobody there. Today's count
/// is kept, and survives a relaunch until midnight; and so does a Focus it turned on and
/// could not turn off as Islet quit, which the next launch turns off.
@MainActor
final class PomodoroFeature: Feature {
    let id = "pomodoro"
    let title = "Pomodoro"
    let symbol = PomodoroSymbol.focus
    let summary = "Focus sessions and breaks in turn, with the time left beside the notch."

    /// What became of a session that was asked for.
    enum Outcome: Equatable {
        case on
        /// The feature is turned off.
        case off
        /// A length that is no length.
        case refused
    }

    /// One id for every change, so a quick skip through the phases updates the banner
    /// already up rather than stacking another.
    static let bannerID = "pomodoro.change"
    /// Between the timer's tile and Keep Awake's, until the person moves it.
    static let tileOrder = 32
    /// How long quitting waits for a Focus this turned on to be turned off again: time
    /// for a Set Focus shortcut, and within the five seconds a SIGTERM allows a quit.
    static let quitGrace: TimeInterval = 3
    static let bannerDuration: TimeInterval = 5
    private static let previewLength: TimeInterval = 8
    static let sounds = ["Hero", "Glass", "Ping", "Purr", "Submarine", "Funk", "None"]

    let model: PomodoroModel
    let focusSwitch: PomodoroFocusSwitch
    let awakeHold: PomodoroAwakeHold
    private lazy var activity = PomodoroActivity(model: model)
    private let defaults: UserDefaults
    private let sounds: any PomodoroSoundPlayer
    private var isRunning = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var previewEnd: Task<Void, Never>?

    /// The Mac's clock, sounds, shortcuts and power assertions, unless a test hands in
    /// fakes that only take notes, and defaults of its own. `focus` says which Focus is
    /// on, `nil` when that cannot be told; by default the Focus feature's reading. The
    /// calendar follows the Mac's time zone as it changes, so midnight moves with it.
    init(
        clock: (any KeepAwakeClock)? = nil,
        sounds: (any PomodoroSoundPlayer)? = nil,
        shortcuts: (any PomodoroShortcutRunner)? = nil,
        focus: (@MainActor () -> FocusState?)? = nil,
        assertions: (any PowerAssertions)? = nil,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.defaults = defaults
        self.sounds = sounds ?? SystemSoundPlayer()
        model = PomodoroModel(clock: clock ?? WallClock(), defaults: defaults, calendar: calendar)
        focusSwitch = PomodoroFocusSwitch(
            runner: shortcuts ?? FocusShortcutRunner(),
            reading: focus ?? { FeatureRegistry.shared.feature(FocusFeature.self)?.readableState },
            defaults: defaults
        )
        awakeHold = PomodoroAwakeHold(assertions: assertions ?? SystemPowerAssertions())
        model.onChange = { [weak self] in self?.sync() }
        model.onTransition = { [weak self] transition in self?.transitioned(transition) }
    }

    func start() {
        isRunning = true
        model.apply(.read(from: defaults))
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.model.settle() }
        observe(.default, .NSSystemClockDidChange) { $0.model.settle() }
        observe(.default, .NSSystemTimeZoneDidChange) { $0.model.settle() }
        observe(.default, UserDefaults.didChangeNotification) { feature in
            feature.model.apply(.read(from: feature.defaults))
            feature.sync()
        }
        ActivityCenter.shared.setHomeWidget(HomeWidget(
            id: id, order: Self.tileOrder, view: AnyView(PomodoroHomeTile(model: model) { [weak self] in
                self?.startSession()
            })
        ))
        sync()
    }

    func stop() {
        isRunning = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        previewEnd?.cancel()
        previewEnd = nil
        // Ends the session without a word; `sync` gives back the assertion, and turns
        // off a Focus this turned on.
        model.stop()
        sync()
        let center = ActivityCenter.shared
        center.end(id: activity.id)
        center.removeHomeWidget(id: id)
        center.dismissBanner(id: Self.bannerID)
    }

    var homeTile: HomeTileInfo? { HomeTileInfo(self, order: Self.tileOrder) }

    func settingsView() -> AnyView? {
        AnyView(PomodoroSettingsView())
    }

    /// Whether quitting should wait: a Focus this turned on is to be turned off again,
    /// or a run of the shortcut is under way.
    var needsTimeToQuit: Bool { focusSwitch.turnedOn || focusSwitch.isBusy }

    /// Ends the session, and waits, `limit` at most, for a Focus it turned on to be
    /// turned off again, before the shortcuts still running are ended with Islet. What
    /// is still owed after that is turned off at the next launch.
    func endBeforeQuitting(within limit: TimeInterval) async {
        model.stop()
        sync()
        let deadline = Date().addingTimeInterval(limit)
        while focusSwitch.isBusy, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Made-up sessions beside the notch for eight seconds, and the banners as a phase
    /// ends. They count for nothing and turn nothing on. A session already running is
    /// shown instead of a sample.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Focus session") { [weak self] in
                self?.preview(.init(
                    phase: .focus, round: 2, length: 25 * 60, clock: .running(end: Date() + 18 * 60 + 24)
                ))
            },
            FeaturePreview(title: "Short break") { [weak self] in
                self?.preview(.init(
                    phase: .shortBreak, round: 2, length: 5 * 60, clock: .running(end: Date() + 3 * 60 + 10)
                ))
            },
            FeaturePreview(title: "Focus done") { [weak self] in
                self?.present(Self.sampleFocusDone)
            },
            FeaturePreview(title: "Break over") { [weak self] in
                self?.present(Self.sampleBreakOver)
            },
        ]
    }

    static let sampleFocusDone = PomodoroModel.Transition(
        finished: .focus, next: .init(phase: .shortBreak, round: 2, length: 5 * 60, clock: .waiting)
    )
    static let sampleBreakOver = PomodoroModel.Transition(
        finished: .shortBreak, next: .init(phase: .focus, round: 3, length: 25 * 60, clock: .waiting)
    )

    /// `islet://pomodoro/start` starts a session with a focus of the length in Settings,
    /// or `minutes=` (up to two hours) for this first one; or carries on with one paused
    /// or waiting. `/pause`, `/resume`, `/skip` and `/stop` do as the buttons do, and
    /// `/toggle` pauses one running and otherwise starts or resumes. A length that
    /// cannot be read, or a query with anything else in it, is not understood and
    /// changes nothing. They are understood, and bar `/stop` do nothing, while the
    /// feature is off.
    func handle(_ url: URL) -> Bool {
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { !($0.name.isEmpty && $0.value == nil) }
        let path = url.path()
        if path == "/start" {
            guard let minutes = Self.minutes(in: query) else { return false }
            return startSession(focusMinutes: minutes) != .refused
        }
        guard query.isEmpty else { return false }
        switch path {
        case "/pause": if isRunning { model.pause() }
        case "/resume": if isRunning { model.resume() }
        case "/skip": if isRunning { model.skip() }
        case "/toggle": if isRunning { model.toggle() }
        case "/stop": stopSession()
        default: return false
        }
        return true
    }

    /// The focus length a `/start` URL asks for: `.some(nil)` for none, the one in
    /// Settings, and `nil` for one that is not a whole number of minutes within what
    /// Settings offers, or for anything in the query besides `minutes`.
    static func minutes(in query: [URLQueryItem]) -> Int?? {
        guard !query.isEmpty else { return .some(nil) }
        guard query.count == 1, query[0].name == "minutes",
              let value = query[0].value.flatMap(Int.init),
              PomodoroSettings.focusMinutes.contains(value) else { return nil }
        return .some(value)
    }

    /// Starts a session, or carries on with the one under way. The home tile, URLs and
    /// Shortcuts all come through here.
    @discardableResult
    func startSession(focusMinutes: Int? = nil) -> Outcome {
        guard isRunning else { return .off }
        if let focusMinutes, !PomodoroSettings.focusMinutes.contains(focusMinutes) { return .refused }
        previewEnd?.cancel()
        previewEnd = nil
        model.start(focusLength: focusMinutes.map { TimeInterval($0 * 60) })
        return .on
    }

    func stopSession() {
        model.stop()
    }

    // MARK: Island

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ action: @escaping @MainActor (PomodoroFeature) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    /// Shows the activity while a session (or a sample) is under way, and puts Focus and
    /// the assertion in line with the session and Settings.
    private func sync() {
        let center = ActivityCenter.shared
        if model.shown != nil {
            if !center.isShowing(id: activity.id) { center.show(activity) }
        } else {
            center.end(id: activity.id)
        }

        let session = isRunning ? model.session : nil
        let focusing = session?.phase == .focus
        // Kept awake only while the clock runs: a focus paused and left for the night
        // lets the Mac sleep.
        awakeHold.want(focusing && session?.isRunning == true
            && PomodoroPrefs.bool(PomodoroPrefs.keepAwake, default: false, in: defaults))
        // Focus stays on through a pause, a moment's interruption of the same session,
        // and goes off with the break.
        let shortcut = defaults.string(forKey: FocusPrefs.shortcut).flatMap { $0.isEmpty ? nil : $0 }
        focusSwitch.want(
            focusing && session?.isWaiting == false
                && PomodoroPrefs.bool(PomodoroPrefs.turnOnFocus, default: false, in: defaults),
            shortcut: shortcut
        )
    }

    private func transitioned(_ transition: PomodoroModel.Transition) {
        guard isRunning else { return }
        let sound = defaults.string(forKey: PomodoroPrefs.sound) ?? Self.sounds[0]
        if sound != "None" { sounds.play(sound) }
        present(transition)
    }

    /// A word beside the notch, or in a row under the music: worth the interruption, as
    /// the timer's alert is, so a Focus asking for quiet lets it through.
    private func present(_ transition: PomodoroModel.Transition) {
        ActivityCenter.shared.present(Self.banner(transition))
    }

    static func banner(_ transition: PomodoroModel.Transition) -> IslandBanner {
        let widths = PomodoroBannerLayout.widths(finished: transition.finished, next: transition.next)
        return IslandBanner(
            id: bannerID,
            style: .compact(leading: widths.leading, trailing: widths.trailing),
            duration: bannerDuration,
            interruption: .active,
            leading: AnyView(PomodoroBannerLeading(finished: transition.finished)),
            trailing: AnyView(PomodoroBannerTrailing(next: transition.next))
        )
    }

    // MARK: Previews

    private func preview(_ sample: PomodoroModel.Session) {
        if model.isActive {
            IslandManager.shared.focusedController?.model.expand(focus: activity.id)
            return
        }
        model.showPreview(sample)
        previewEnd?.cancel()
        previewEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.previewLength))
            guard !Task.isCancelled, let self else { return }
            self.previewEnd = nil
            self.model.endPreview()
        }
    }
}

@MainActor
final class PomodoroActivity: IslandActivity {
    let id = "pomodoro"
    /// Something being timed, as the timer is, so it goes ahead of Keep Awake and the
    /// other activities that run for hours in the background. But it lasts all day, a
    /// phase at a time, and gives way to its peers: beside music the song keeps the
    /// island and the ring drains in the bubble, and the phase changes still ride in
    /// the row under the song.
    let priority = ActivityPriority.normal
    var rank: Int { -1 }
    let model: PomodoroModel
    /// The phase's, so the opened island's tab shows a leaf through a break.
    var symbol: String { model.shown?.phase.symbol ?? PomodoroSymbol.focus }

    init(model: PomodoroModel) { self.model = model }

    /// Room for "24:59", as the timer has.
    var compactTrailingWidth: CGFloat? { 58 }
    var expandedHeight: CGFloat { 76 }

    func compactLeading() -> AnyView { AnyView(PomodoroCompactLeading(model: model)) }
    func compactTrailing() -> AnyView { AnyView(PomodoroCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(PomodoroMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(PomodoroExpanded(model: model)) }
}

/// The feature's preference keys, shared by the feature and its settings. Unset keys
/// read as their defaults, the same ones the settings controls declare.
enum PomodoroPrefs {
    static let focusMinutes = "pomodoro.focusMinutes"
    static let shortBreakMinutes = "pomodoro.shortBreakMinutes"
    static let longBreakMinutes = "pomodoro.longBreakMinutes"
    static let rounds = "pomodoro.rounds"
    static let autoStartBreaks = "pomodoro.autoStartBreaks"
    static let autoStartFocus = "pomodoro.autoStartFocus"
    static let sound = "pomodoro.sound"
    static let turnOnFocus = "pomodoro.turnOnFocus"
    static let keepAwake = "pomodoro.keepAwake"
    /// Today's count, and the day it counts.
    static let completedToday = "pomodoro.completedToday"
    static let countedDay = "pomodoro.countedDay"
    /// The Focus Pomodoro turned on and has yet to turn off, by identifier.
    static let focusTurnedOn = "pomodoro.focusTurnedOn"

    static func bool(_ key: String, default value: Bool, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }
}

private struct PomodoroSettingsView: View {
    @AppStorage(PomodoroPrefs.focusMinutes) private var focus = 25
    @AppStorage(PomodoroPrefs.shortBreakMinutes) private var shortBreak = 5
    @AppStorage(PomodoroPrefs.longBreakMinutes) private var longBreak = 15
    @AppStorage(PomodoroPrefs.rounds) private var rounds = 4
    @AppStorage(PomodoroPrefs.autoStartBreaks) private var autoStartBreaks = true
    @AppStorage(PomodoroPrefs.autoStartFocus) private var autoStartFocus = false
    @AppStorage(PomodoroPrefs.sound) private var sound = PomodoroFeature.sounds[0]
    @AppStorage(PomodoroPrefs.turnOnFocus) private var turnOnFocus = false
    @AppStorage(PomodoroPrefs.keepAwake) private var keepAwake = false
    @AppStorage(FocusPrefs.shortcut) private var focusShortcut = ""
    @AppStorage(Prefs.Key.featureEnabled("focus")) private var focusFeatureOn = true

    var body: some View {
        stepper("Focus", value: $focus, in: PomodoroSettings.focusMinutes)
        stepper("Short break", value: $shortBreak, in: PomodoroSettings.shortBreakMinutes)
        stepper("Long break", value: $longBreak, in: PomodoroSettings.longBreakMinutes)
        stepper("Long break after", value: $rounds, in: PomodoroSettings.roundChoices, unit: "focus sessions")
        Toggle(isOn: $autoStartBreaks) {
            Text("Start breaks by themselves")
            Text("Otherwise a break waits beside the notch until you click to start it.")
        }
        Toggle(isOn: $autoStartFocus) {
            Text("Start focus sessions by themselves")
            Text("Otherwise the next focus waits for you after each break.")
        }
        Picker("Sound at each change", selection: $sound) {
            ForEach(PomodoroFeature.sounds, id: \.self) { Text($0).tag($0) }
        }
        .onChange(of: sound) { _, name in
            if name != "None" { NSSound(named: NSSound.Name(name))?.play() }
        }
        Toggle(isOn: $turnOnFocus) {
            Text("Turn on Focus while focusing")
            Text(focusCaption)
        }
        .disabled(focusProblem != nil && !turnOnFocus)
        Toggle(isOn: $keepAwake) {
            Text("Keep the Mac awake while focusing")
            Text("The display stays on through a focus session, and sleeps as usual in a break or a pause.")
        }
    }

    /// Why Focus cannot be turned on, if it cannot: the shortcut toggles, so Islet must
    /// see which Focus is on to know what a run will do.
    private var focusProblem: String? {
        if focusShortcut.isEmpty {
            return "Choose a shortcut in Focus's settings first: this runs the one chosen there."
        }
        if !focusFeatureOn {
            return "Turn on Focus in Islet first: the shortcut toggles, so Islet has to see which Focus is on."
        }
        switch FeatureRegistry.shared.feature(FocusFeature.self)?.access {
        case .needsFullDiskAccess?:
            return "Islet needs Full Disk Access to see which Focus is on, as Focus's settings explain."
        case .unavailable?:
            return "Islet cannot find where this Mac keeps Focus, so cannot tell which one is on."
        default:
            return nil
        }
    }

    private var focusCaption: String {
        focusProblem ?? "Runs “\(focusShortcut)”, the shortcut chosen in Focus's settings, as a focus "
            + "session starts and as its break begins. A Focus already on is left as it is."
    }

    /// The number beside its arrows, as System Settings sets one out.
    private func stepper(
        _ title: String, value: Binding<Int>, in range: ClosedRange<Int>, unit: String = "minutes"
    ) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue == 1 && unit == "minutes" ? "1 minute" : "\(value.wrappedValue) \(unit)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
