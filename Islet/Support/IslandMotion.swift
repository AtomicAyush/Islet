import AppKit
import QuartzCore

/// The one clock every moving colour on the island keeps time by, and whether they move
/// at all.
///
/// Each moving colour is a Core Animation layer animated on the render server
/// (`IslandMotionView`), never redrawn by Islet, and every one counts its cycle from the
/// same moment, so the island, its bubbles, the island on another display and the
/// preview in Settings are always in step.
///
/// They hold still where they are while the screen is shared or recorded (if the person
/// asks), and while the Mac or its displays sleep, or the session is switched away, and
/// carry on from there. With Reduce Motion or Low Power Mode on, the Mac running hot, or
/// the island saving energy (`EnergySaver`), they are drawn still at the start of their
/// cycle. Each view also holds still on its own while it is not on screen, which is how
/// they hold behind the lock screen.
///
/// Nothing here runs until a moving colour is first drawn.
@MainActor
final class IslandMotion {
    static let shared = IslandMotion()

    enum State: Equatable {
        case moving
        /// Held where it was, to carry on from there.
        case held
        /// Drawn still, at the start of each cycle.
        case still
    }

    private(set) var state: State = .moving
    /// The host time (`CACurrentMediaTime`) every cycle counts from.
    private(set) var epoch = CACurrentMediaTime()
    /// When motion was held, while it is.
    private var heldAt: CFTimeInterval?

    #if DEBUG
    /// For the harness: every moving colour posed this far through its own cycle.
    var posedPhase: Double? {
        didSet { tell() }
    }
    /// For the harness: views in a window off screen count as on screen.
    var forceOnScreen = false {
        didSet {
            tell()
            viewChanged()
        }
    }
    /// For the harness: what the Mac would say, in place of asking it.
    struct Conditions: Equatable {
        var reduceMotion = false
        var lowPower = false
        var hot = false
        var asleep = false
        var captured = false
    }
    var conditions: Conditions? {
        didSet { reconcile() }
    }
    /// For the harness: how many times a moving colour's view was handed new values.
    var updates = 0
    #endif

    private let views = NSHashTable<IslandMotionView>.weakObjects()
    private var observers: [NSObjectProtocol] = []
    /// Why motion is held for the Mac itself, each kept apart so waking from one never
    /// ends another: the Mac asleep, its displays asleep, the session switched away.
    private var sleeps: Set<Sleep> = []
    private var isCaptured = false
    /// Made the first time capture matters and kept, started and stopped as it does.
    private var screenWatcher: PrivacyScreenWatcher?
    private var isWatchingCapture = false

    private init() {}

    /// How far through a cycle of `period` seconds every colour is, or is held at.
    func phase(period: CFTimeInterval) -> Double {
        #if DEBUG
        if let posedPhase { return posedPhase }
        #endif
        guard period > 0 else { return 0 }
        let time: CFTimeInterval
        switch state {
        case .still: return 0
        case .held: time = heldAt ?? CACurrentMediaTime()
        case .moving: time = CACurrentMediaTime()
        }
        let phase = ((time - epoch) / period).truncatingRemainder(dividingBy: 1)
        return phase < 0 ? phase + 1 : phase
    }

    /// Whether colours move now, the view's own reasons aside.
    var isMoving: Bool {
        #if DEBUG
        if posedPhase != nil { return false }
        #endif
        return state == .moving
    }

    #if DEBUG
    var isOnScreenForced: Bool { forceOnScreen }
    #else
    var isOnScreenForced: Bool { false }
    #endif

    func register(_ view: IslandMotionView) {
        if observers.isEmpty { observe() }
        views.add(view)
        reconcile()
    }

    /// A view's reasons to move have changed: it was shown or hidden, or came on or off
    /// screen, so whether the screen needs watching may have too.
    func viewChanged() {
        guard !observers.isEmpty else { return }
        reconcile()
    }

    // MARK: State

    private func reconcile() {
        let info = ProcessInfo.processInfo
        var isStill = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || info.isLowPowerModeEnabled
            || info.thermalState == .serious || info.thermalState == .critical
        var isAsleep = !sleeps.isEmpty
        #if DEBUG
        if let conditions {
            isStill = conditions.reduceMotion || conditions.lowPower || conditions.hot
            isAsleep = conditions.asleep
        }
        #endif
        if EnergySaver.shared.isSaving { isStill = true }
        watchCapture(isNeeded: !isStill && !isAsleep)
        var isCaptured = isCaptured
        #if DEBUG
        if let conditions { isCaptured = conditions.captured }
        #endif
        let holdsForCapture = isCaptured && UserDefaults.standard.bool(forKey: Prefs.Key.holdMotionWhenCaptured)
        let next: State = isStill ? .still : isAsleep || holdsForCapture ? .held : .moving
        guard next != state else { return }
        let now = CACurrentMediaTime()
        switch (state, next) {
        case (.moving, .held):
            heldAt = now
        case (.held, .moving):
            // Carries on from where it was held.
            epoch += now - (heldAt ?? now)
            heldAt = nil
        case (_, .still):
            heldAt = nil
        case (.still, _):
            // From the start of the cycle, where it was drawn still.
            epoch = now
            heldAt = next == .held ? now : nil
        default:
            break
        }
        state = next
        tell()
    }

    private func tell() {
        for view in views.allObjects { view.motionChanged() }
    }

    // MARK: Watching

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: EnergySaver.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        let changes: [(Notification.Name, Sleep, Bool)] = [
            (NSWorkspace.willSleepNotification, .system, true),
            (NSWorkspace.didWakeNotification, .system, false),
            (NSWorkspace.screensDidSleepNotification, .displays, true),
            (NSWorkspace.screensDidWakeNotification, .displays, false),
            (NSWorkspace.sessionDidResignActiveNotification, .session, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .session, false),
        ]
        for (name, sleep, asleep) in changes {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if asleep { self.sleeps.insert(sleep) } else { self.sleeps.remove(sleep) }
                    self.reconcile()
                }
            })
        }
        reconcile()
    }

    private enum Sleep: Hashable {
        case system, displays, session
    }

    /// Watches whether the screen is captured only while it matters: the person wants
    /// colours held while the screen is shared or recorded, colours are neither drawn
    /// still nor held for sleep, and some view would move now, shown and on screen. So a
    /// resting island, or one with nothing moving, wakes nothing. Where capture cannot be
    /// told, colours keep moving.
    private func watchCapture(isNeeded: Bool) {
        let wanted = isNeeded
            && UserDefaults.standard.bool(forKey: Prefs.Key.holdMotionWhenCaptured)
            && views.allObjects.contains { $0.couldMove }
        guard wanted != isWatchingCapture else { return }
        isWatchingCapture = wanted
        let watcher = screenWatcher ?? PrivacyScreenWatcher()
        screenWatcher = watcher
        if wanted {
            watcher.start { [weak self] captured in
                // A reading sent just before it stopped is no longer news.
                guard let self, self.isWatchingCapture else { return }
                self.isCaptured = captured ?? false
                self.reconcile()
            }
        } else {
            // The last reading stands until the next start's first one, so nothing moves
            // for a moment mid-recording when watching resumes.
            watcher.stop()
        }
    }
}

/// A view whose layers Core Animation moves through colours, kept in step by
/// `IslandMotion`. It moves only while colours move, it is on screen (in a window macOS
/// counts as visible, so not on a sleeping display, behind the lock screen, ordered out
/// or covered, and not hidden) and it is shown; otherwise its animation is taken off and
/// it is posed where the clock is, so the render server has nothing to do.
class IslandMotionView: NSView {
    /// Whether what it paints is shown at all: the island drawn and wearing its colour.
    var isShown = true {
        didSet {
            guard isShown != oldValue else { return }
            motionChanged()
            IslandMotion.shared.viewChanged()
        }
    }
    private var isOnScreen = false
    private var occlusionObserver: NSObjectProtocol?
    /// The animation on the layer, while there is one.
    private var running: CAAnimation?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        IslandMotion.shared.register(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // Clicks go to the island under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The layer the animation runs on, and the cycle's length: for subclasses.
    var animatedLayer: CALayer? { nil }
    var period: CFTimeInterval { 0 }
    /// The animation for one whole cycle, from phase 0.
    func makeAnimation() -> CAAnimation? { nil }
    /// Sets the layer's own values to `phase` of the cycle.
    func pose(at phase: Double) {}

    /// Something that decides whether it moves has changed, or what it animates has:
    /// starts, stops or re-poses the animation.
    func motionChanged() {
        guard let layer = animatedLayer else { return }
        let motion = IslandMotion.shared
        let moves = motion.isMoving && isShown && (isOnScreen || motion.isOnScreenForced) && period > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "islandMotion")
        running = nil
        pose(at: motion.phase(period: period))
        if moves, let animation = makeAnimation() {
            animation.beginTime = layer.convertTime(motion.epoch, from: nil)
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "islandMotion")
            running = animation
        }
        CATransaction.commit()
    }

    /// What it animates has changed: re-poses it, and tells the clock, since whether the
    /// screen needs watching can turn on it.
    func animationChanged() {
        motionChanged()
        IslandMotion.shared.viewChanged()
    }

    /// Whether it would move if colours moved: shown, on screen and with a cycle to run.
    var couldMove: Bool {
        isShown && window != nil && (isOnScreen || IslandMotion.shared.isOnScreenForced)
            && period > 0 && animatedLayer != nil
    }

    /// Whether an animation is on the layer: for the harness.
    var isAnimating: Bool { running != nil && animatedLayer?.animation(forKey: "islandMotion") != nil }

    // MARK: On screen

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenChanged() }
            }
        }
        screenChanged()
        IslandMotion.shared.viewChanged()
    }

    override func viewDidHide() {
        super.viewDidHide()
        screenChanged()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        screenChanged()
    }

    private func screenChanged() {
        let onScreen = window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        guard onScreen != isOnScreen else { return }
        isOnScreen = onScreen
        motionChanged()
        IslandMotion.shared.viewChanged()
    }
}
