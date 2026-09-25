import AppKit

/// How the engine's tap is going, as the waveform cares.
enum NowPlayingLevelStatus: Equatable, Sendable {
    /// Nothing followed, or nothing to tap for now: the app is sending no sound
    /// through this Mac, or the output is slower than the bars can wait for.
    case idle
    /// A tap is feeding the meter.
    case running
    /// No tap could be had: no permission, or macOS would not make one.
    case failed
}

/// The engine and meter as the waveform's coordinator uses them. A protocol so the
/// coordinator, which runs on every macOS, need not name types that need macOS 15.
protocol NowPlayingLevelSource: AnyObject {
    /// Follows `appID`'s sound, or nothing; `report` hears how it goes.
    func follow(_ appID: String?, report: @escaping @MainActor @Sendable (NowPlayingLevelStatus) -> Void)
    /// When anything but silence last arrived, in host seconds; `nil` for never since
    /// the app was taken up.
    var lastSignalTime: Double? { get }
    /// When the tap followed now last delivered a buffer, or was taken up if it has
    /// delivered none, in host seconds.
    var lastBufferTime: Double? { get }
    /// The newest levels for `layout` heard by `time`, and when they were heard.
    func read(layout: Int, at time: Double) -> (word: UInt64, time: Double)?
}

@available(macOS 15.0, *)
extension NowPlayingLevelEngine: NowPlayingLevelSource {
    var lastSignalTime: Double? { meter.lastSignalTime }
    var lastBufferTime: Double? { meter.lastBufferTime }

    func read(layout: Int, at time: Double) -> (word: UInt64, time: Double)? {
        meter.board.read(layout: layout, at: time)
    }
}

/// Whether the Now Playing waveform follows the music, and the levels it follows.
///
/// The feature says which app is on show and whether it plays; each waveform drawn
/// for that app says when it is on screen. While the app plays and one of them is
/// visible — the island up on a screen, not hidden for a full-screen app, the display
/// awake — the engine keeps a tap on the app's sound, and those bars take their
/// heights from it every frame. Otherwise nothing runs. The tap goes 1.5 s after a
/// pause or the last waveform leaving the screen, so a gap between songs or the
/// island opening does not remake it, and at once when another app is on show, the
/// Mac or its displays sleep, the setting is turned off, or Reduce Motion is on.
///
/// The bars go live once the tap has delivered actual sound and its first levels are
/// due — through AirPlay, two seconds after it starts — and back to their canned
/// motion if it stops delivering. A tap that stops delivering for 2 s, or hears
/// nothing but silence for 6 (a tab muted while it plays, say), counts as a failure:
/// it goes, and that app is left canned until it is played again or another is on
/// show. Each tap is judged from when it started running, however long the engine
/// waited before. Without a tap — no permission, macOS 15 not there, macOS refusing —
/// the bars stay canned, as ever.
@MainActor
final class NowPlayingLevels {
    static let shared = NowPlayingLevels()

    /// How long the tap outlives a pause, or the last waveform leaving the screen.
    private static let hold: TimeInterval = 1.5
    /// How often the tap's health is looked at while there is one.
    private static let checkInterval: TimeInterval = 0.25
    /// Buffers stopping for this long means the tap has failed.
    private static let staleAfter: Double = 2
    /// Hearing nothing but digital silence for this long means there is nothing to
    /// hear: longer than any gap between songs, shorter than a muted tab should keep
    /// the recording indicator on.
    private static let silentAfter: Double = 6
    /// Levels older than this read as silence: the bars fall to rest.
    private static let freshness: Double = 0.25

    /// Bars for the app on show follow its sound.
    private(set) var isLive = false

    private let source: (any NowPlayingLevelSource)?
    /// Waveforms for the app on show that are on screen.
    private let views = NSHashTable<WaveformBarsView>.weakObjects()
    private var observers: [NSObjectProtocol] = []

    private var appID: String?
    private var isPlaying = false
    private var isEnabled = true
    private var reduceMotion = false
    private var isAsleep = false
    /// An app whose tap stopped delivering; canned until it is played again.
    private var gaveUpOn: String?

    /// The app the engine follows.
    private var followed: String?
    private var status = NowPlayingLevelStatus.idle
    /// Bumped whenever `followed` changes, so an old report is ignored.
    private var generation = 0
    /// When `status` last became `.running`: a tap is judged from then.
    private var runningSince: CFTimeInterval = 0
    private var releaseWork: DispatchWorkItem?
    private var checkTimer: Timer?

    #if DEBUG
    /// Levels for harnesses to supply in place of the engine's, set before `shared` is
    /// first used, so nothing they run can tap an app.
    static var sourceForTesting: (any NowPlayingLevelSource)?
    #endif

    private init() {
        #if DEBUG
        if let source = Self.sourceForTesting {
            self.source = source
            readSettings()
            observe()
            return
        }
        #endif
        if #available(macOS 15.0, *), let meter = NowPlayingLevelMeter() {
            source = NowPlayingLevelEngine(meter: meter)
            // Before the mixer makes any tap, so each of them tells the meter too.
            MixerTaps.listener = meter
        } else {
            source = nil
        }
        readSettings()
        observe()
    }

    // MARK: Inputs

    /// The app on show and whether it plays; `nil` when nothing real is on show, as
    /// during a preview or with the feature off.
    func show(_ app: String?, playing: Bool) {
        if app != appID || playing && !isPlaying { gaveUpOn = nil }
        guard app != appID || playing != isPlaying else { return }
        appID = app
        isPlaying = playing
        reconcile()
    }

    /// A waveform for the app on show came on screen.
    func register(_ view: WaveformBarsView) {
        guard !views.contains(view) else { return }
        views.add(view)
        reconcile()
    }

    /// It left the screen, or stopped following the app on show.
    func unregister(_ view: WaveformBarsView) {
        guard views.contains(view) else { return }
        views.remove(view)
        reconcile()
    }

    /// The heights, 0...1, of `bars` bars in `layout` as they should look at `time`
    /// (host seconds). False while there are none fresh, when the bars should fall to
    /// rest. Main thread, every frame of a live waveform.
    func levels(layout: Int, bars: Int, at time: CFTimeInterval, into heights: inout [CGFloat]) -> Bool {
        guard isLive, let source, let reading = source.read(layout: layout, at: time),
              time - reading.time < Self.freshness
        else { return false }
        for bar in 0..<min(bars, heights.count) {
            heights[bar] = CGFloat(AudioLevelAnalyser.unpack(reading.word, bar: bar))
        }
        return true
    }

    // MARK: Following

    private var wanted: String? {
        guard source != nil, isEnabled, !reduceMotion, !isAsleep, isPlaying,
              let appID, appID != gaveUpOn, views.anyObject != nil
        else { return nil }
        return appID
    }

    private func reconcile() {
        if let wanted {
            cancelRelease()
            if followed != wanted { follow(wanted) }
        } else if let followed {
            // A pause, or the waveform leaving the screen, holds the tap a moment.
            let holds = appID == followed && isEnabled && !reduceMotion && !isAsleep && gaveUpOn != followed
            if !holds {
                follow(nil)
            } else if releaseWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.releaseWork = nil
                        if self.wanted == nil { self.follow(nil) }
                    }
                }
                releaseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold, execute: work)
            }
        }
    }

    private func follow(_ app: String?) {
        cancelRelease()
        generation += 1
        followed = app
        status = .idle
        let generation = self.generation
        source?.follow(app) { [weak self] status in
            guard let self, self.generation == generation else { return }
            if status == .running, self.status != .running { self.runningSince = CACurrentMediaTime() }
            self.status = status
            self.check()
        }
        if app == nil {
            checkTimer?.invalidate()
            checkTimer = nil
        } else if checkTimer == nil {
            let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            timer.tolerance = Self.checkInterval / 2
            RunLoop.main.add(timer, forMode: .common)
            checkTimer = timer
        }
        check()
    }

    private func cancelRelease() {
        releaseWork?.cancel()
        releaseWork = nil
    }

    /// Goes live once the tap has heard sound and its levels are due, back if it
    /// stops delivering, and gives up on a tap that has stopped for good or hears
    /// only silence.
    private func check() {
        var live = false
        if let followed, status == .running, let source {
            let now = CACurrentMediaTime()
            // Nothing from before this tap started running counts against it.
            let lastBuffer = max(source.lastBufferTime ?? runningSince, runningSince)
            let lastSound = max(source.lastSignalTime ?? runningSince, runningSince)
            if now - lastBuffer > Self.staleAfter || now - lastSound > Self.silentAfter {
                gaveUpOn = followed
                follow(nil)
                return
            }
            let due = source.read(layout: 0, at: now).map { now - $0.time < Self.freshness } ?? false
            live = source.lastSignalTime != nil && now - lastBuffer < 0.5 && due
        }
        guard live != isLive else { return }
        isLive = live
        for view in views.allObjects { view.liveLevelsChanged() }
    }

    // MARK: Settings and the Mac

    private func readSettings() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: NowPlayingPrefs.followMusic) as? Bool ?? NowPlayingPrefs.followMusicDefault
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func observe() {
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
        let sleeps: [(Notification.Name, Bool)] = [
            (NSWorkspace.willSleepNotification, true),
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.sessionDidResignActiveNotification, true),
            (NSWorkspace.didWakeNotification, false),
            (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        for (name, asleep) in sleeps {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isAsleep != asleep else { return }
                    self.isAsleep = asleep
                    self.reconcile()
                }
            })
        }
    }

    private func settingsChanged() {
        let before = (isEnabled, reduceMotion)
        readSettings()
        guard before != (isEnabled, reduceMotion) else { return }
        reconcile()
    }
}
