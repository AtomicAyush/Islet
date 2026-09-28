import AppKit
import SwiftUI

/// Keeps the Mac from sleeping for a while — fifteen minutes, an hour, two, or until
/// turned off — started from the home page, a URL or Shortcuts, with a cup and the time
/// left beside the notch while it runs.
///
/// It holds a power assertion, as Amphetamine or `caffeinate` do, named so that
/// `pmset -g assertions` says whose it is. macOS stays awake while any app holds one, so
/// it sits alongside those apps without either undoing the other. An assertion stands in
/// for someone still at the Mac, nothing more: closing the lid sleeps the Mac as ever,
/// unless macOS keeps it awake with a display and power attached.
///
/// A session lasts only as long as Islet runs. Stopping it, turning the feature off or
/// quitting Islet releases the assertion (and macOS releases one left by a crash), and
/// nothing is taken again at the next launch: a relaunch that picked a session back up
/// would keep a Mac awake that its owner last saw let go, and quitting is the one sure
/// way to stop it.
@MainActor
final class KeepAwakeFeature: Feature {
    let id = "keepAwake"
    let title = "Keep Awake"
    let symbol = KeepAwakeSymbol.on
    let summary = "Keeps the Mac from sleeping for a while, with the time left beside the notch."

    /// Where the tile goes on the home page, until the person puts it somewhere else.
    static let tileOrder = 35
    var homeTile: HomeTileInfo? { HomeTileInfo(self, order: Self.tileOrder) }
    var islandActivity: IslandActivityInfo? { IslandActivityInfo(self, order: 100) }

    /// What became of a session that was asked for.
    enum Outcome: Equatable {
        /// The Mac is kept awake.
        case on
        /// macOS would not give Islet a power assertion.
        case refused
        /// The feature is turned off.
        case off
    }

    static let bannerID = "keepAwake.ended"
    private static let widgetID = "keepAwake"
    /// What +15 adds.
    static let extra: TimeInterval = 15 * 60
    private static let previewLength: TimeInterval = 8

    let model: KeepAwakeModel
    private lazy var activity = KeepAwakeActivity(model: model)
    private let defaults: UserDefaults
    private var isRunning = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// The activity's trailing width as last published: an end or none.
    private var publishedTimed: Bool?
    private var previewEnd: Task<Void, Never>?

    /// IOKit and the Mac's clock, unless a test hands in power assertions that only take
    /// notes and a clock it moves by hand, and defaults of its own.
    init(
        assertions: (any PowerAssertions)? = nil,
        clock: (any KeepAwakeClock)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        model = KeepAwakeModel(assertions: assertions ?? SystemPowerAssertions(), clock: clock ?? WallClock())
        model.onChange = { [weak self] in self?.sync() }
        model.onFinish = { [weak self] in self?.finished() }
    }

    func start() {
        isRunning = true
        model.letsDisplaySleep = KeepAwakePrefs.bool(KeepAwakePrefs.letDisplaySleep, default: false, in: defaults)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.model.settle() }
        observe(.default, .NSSystemClockDidChange) { $0.model.settle() }
        observe(.default, UserDefaults.didChangeNotification) { feature in
            feature.model.letsDisplaySleep = KeepAwakePrefs.bool(
                KeepAwakePrefs.letDisplaySleep, default: false, in: feature.defaults
            )
        }
        ActivityCenter.shared.setHomeWidget(HomeWidget(
            id: Self.widgetID, order: Self.tileOrder, view: AnyView(KeepAwakeHomeTile(model: model) { [weak self] length in
                self?.keepAwake(for: length.seconds)
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
        // Releases the assertion, and says nothing: only running out is announced.
        model.stop()
        let center = ActivityCenter.shared
        center.end(id: activity.id)
        center.removeHomeWidget(id: Self.widgetID)
        center.dismissBanner(id: Self.bannerID)
        publishedTimed = nil
    }

    func settingsView() -> AnyView? {
        AnyView(KeepAwakeSettings())
    }

    /// Sample sessions beside the notch for eight seconds, and the banner as one runs
    /// out. They take no assertion: the Mac sleeps as it would. A session already
    /// running is shown instead of a sample.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Keep awake for an hour") { [weak self] in self?.preview(length: 60 * 60) },
            FeaturePreview(title: "Keep awake until turned off") { [weak self] in self?.preview(length: nil) },
            FeaturePreview(title: "Keep Awake ends") { [weak self] in self?.presentEnded() },
        ]
    }

    /// `islet://keepAwake/start?minutes=60` keeps the Mac awake for an hour (`hours=` and
    /// `seconds=` work too, up to a day), and without a length until turned off.
    /// `/toggle` does the same, or stops a session running; `/extend` adds fifteen
    /// minutes, or `minutes=`, to a timed one; `/stop` lets the Mac sleep again. A length
    /// that cannot be read, or a query with anything else in it, is not understood and
    /// changes nothing. They are understood, and bar `/stop` do nothing, while the
    /// feature is off.
    func handle(_ url: URL) -> Bool {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.path() {
        case "/start":
            guard let length = Self.length(in: query) else { return false }
            keepAwake(for: length)
        case "/toggle":
            guard let length = Self.length(in: query) else { return false }
            if model.isOn {
                model.stop()
            } else {
                keepAwake(for: length)
            }
        case "/extend":
            guard let length = Self.length(in: query) else { return false }
            if isRunning { model.extend(by: length ?? Self.extra) }
        case "/stop":
            model.stop()
        default:
            return false
        }
        return true
    }

    /// Keeps the Mac awake for `length`, or until turned off with `nil`, in place of any
    /// session running. The home tile, URLs and Shortcuts all come through here.
    @discardableResult
    func keepAwake(for length: TimeInterval?) -> Outcome {
        guard isRunning else { return .off }
        guard model.start(for: length) else { return .refused }
        // The session has taken a sample's place, so its timeout has nothing left to
        // end. Refused, a sample showing keeps it, and goes when it was due to.
        previewEnd?.cancel()
        previewEnd = nil
        return .on
    }

    /// Lets the Mac sleep again. Stopping what is not running changes nothing.
    func letSleep() {
        model.stop()
    }

    /// The length a URL asks for: `.some(nil)` for none, until turned off, and `nil` for
    /// one that is not a length (not a number, not above zero, or over a day) or for
    /// anything in the query that is not `seconds`, `minutes` or `hours`.
    static func length(in query: [URLQueryItem]) -> TimeInterval?? {
        let units: [(name: String, seconds: TimeInterval)] = [("seconds", 1), ("minutes", 60), ("hours", 3600)]
        // A name that is not one of these is a length misspelt, not no length at all:
        // read as none, `?min=30` would keep the Mac awake for good when half an hour was
        // asked for. A stray `&` leaves an empty item, which is nothing.
        let given = query.filter { !($0.name.isEmpty && $0.value == nil) }
        guard given.allSatisfy({ item in units.contains { $0.name == item.name } }) else { return nil }
        for unit in units {
            guard let item = query.first(where: { $0.name == unit.name }) else { continue }
            guard let value = item.value.flatMap(Double.init), value.isFinite, value > 0 else { return nil }
            let seconds = value * unit.seconds
            return seconds <= KeepAwakeModel.longest ? .some(seconds) : nil
        }
        return .some(nil)
    }

    // MARK: Island

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (KeepAwakeFeature) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    /// Shows the activity while a session (or a sample) runs, re-published when it gains
    /// or loses an end, which changes its width.
    private func sync() {
        let center = ActivityCenter.shared
        if let shown = model.shown {
            let timed = shown.end != nil
            if !center.isShowing(id: activity.id) || publishedTimed != timed {
                publishedTimed = timed
                center.show(activity)
            }
        } else {
            publishedTimed = nil
            center.end(id: activity.id)
        }
    }

    private func finished() {
        guard isRunning, KeepAwakePrefs.bool(KeepAwakePrefs.announceEnd, default: true, in: defaults) else { return }
        // Another feature's banner is left where it is. One replaced would never come
        // back — a timer's alert, or a battery warning arriving with this on waking —
        // and this one says only what the cup leaving the notch already has.
        if let current = ActivityCenter.shared.banner, current.id != Self.bannerID { return }
        presentEnded()
    }

    /// A moment's word that the Mac may sleep again. Passive: nobody needs telling
    /// during a Focus that asks for quiet.
    private func presentEnded() {
        let widths = KeepAwakeBannerLayout.widths
        ActivityCenter.shared.present(IslandBanner(
            id: Self.bannerID,
            style: .compact(leading: widths.leading, trailing: widths.trailing),
            duration: 3,
            interruption: .passive,
            leading: AnyView(KeepAwakeEndedLeading()),
            trailing: AnyView(KeepAwakeEndedTrailing())
        ))
    }

    // MARK: Previews

    private func preview(length: TimeInterval?) {
        if model.isOn {
            IslandManager.shared.focusedController?.model.expand(focus: activity.id)
            return
        }
        model.showPreview(length: length)
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
final class KeepAwakeActivity: IslandActivity {
    let id = "keepAwake"
    let name = "Keep Awake"
    /// Below everything else. It runs for hours at a time, and music, a timer or a
    /// meeting about to start matter more in the moment: beside one of them it waits in
    /// the bubble, and with two it is out of the closed island's sight until one ends.
    /// Its tab in the opened island and the home tile still say it is on.
    let priority = ActivityPriority.background
    let symbol = KeepAwakeSymbol.on
    let model: KeepAwakeModel

    init(model: KeepAwakeModel) { self.model = model }

    /// Room for "1:59:59", as the timer has; the infinity sign fits the usual width.
    var compactTrailingWidth: CGFloat? { model.shown?.end == nil ? nil : 58 }
    var expandedHeight: CGFloat { 76 }

    func compactLeading() -> AnyView { AnyView(KeepAwakeCompactLeading()) }
    func compactTrailing() -> AnyView { AnyView(KeepAwakeCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(KeepAwakeMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(KeepAwakeExpanded(model: model)) }
}

/// The feature's preference keys, shared by the feature and its settings. Unset keys
/// read as their defaults, the same ones the settings toggles declare.
enum KeepAwakePrefs {
    static let letDisplaySleep = "keepAwake.letDisplaySleep"
    static let announceEnd = "keepAwake.announceEnd"

    static func bool(_ key: String, default value: Bool, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }
}

private struct KeepAwakeSettings: View {
    @AppStorage(KeepAwakePrefs.letDisplaySleep) private var letDisplaySleep = false
    @AppStorage(KeepAwakePrefs.announceEnd) private var announceEnd = true

    var body: some View {
        Toggle(isOn: $letDisplaySleep) {
            Text("Let the display sleep")
            Text("The Mac stays awake for a download or a long task, and the screen turns off as it would.")
        }
        Toggle(isOn: $announceEnd) {
            Text("Show when the time runs out")
            Text("A moment's word beside the notch that the Mac may sleep again.")
        }
    }
}
