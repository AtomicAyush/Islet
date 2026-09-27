import SwiftUI

/// The Magic Mouse, Keyboard and Trackpad running low, the way the iPhone warns of its
/// own battery: a banner either side of the notch as the level falls to 20%, 10% and
/// 5%, each once until the device has been charged. The home page lists each connected
/// device's level, and a card can show one connecting, as for headphones.
///
/// Levels come from the I/O Registry, where macOS keeps what Bluetooth input devices
/// report, so this needs no permission. Other makes' Bluetooth devices show too where
/// macOS keeps their level there; one on its own USB receiver (Logitech's Unifying and
/// Bolt) tells only its maker's app.
@MainActor
final class InputDevicesFeature: Feature {
    let id = "inputDevices"
    let title = "Mouse & Keyboard"
    let symbol = "magicmouse.fill"
    let summary = "Warns when a Magic Mouse, Keyboard or Trackpad runs low on battery."

    /// Where the tile goes on the home page, until the person puts it somewhere else.
    static let tileOrder = 52
    var homeTile: HomeTileInfo? { HomeTileInfo(self, order: Self.tileOrder) }

    private static let bannerPrefix = "inputDevices."
    private static let widgetID = "inputDevices"
    private static let lowDuration: TimeInterval = 4
    private static let cardDuration: TimeInterval = 4
    /// A device back within this long slept, or moved from its cable to Bluetooth, and
    /// was never really away: it gets no card for coming back.
    static let returnWindow: TimeInterval = 10 * 60
    /// For this long after Islet starts or the Mac wakes, devices connecting are finding
    /// their way back, a few seconds apart, not news: none gets a card, and one not seen
    /// before is taken as it stands, as those already there at launch are. Bluetooth can
    /// take twenty seconds or so after a wake, and the level a few more.
    static let settleWindow: TimeInterval = 60
    private static let previewDuration: TimeInterval = 10

    private let model: InputDevicesModel
    private let now: () -> Date
    private var watch = LowBatteryWatch()
    private var isRunning = false
    /// When each device last left, by id and by kind, for `returnWindow`. In memory only.
    private var departures: [String: Date] = [:]
    /// Until when arrivals are reconnections, for `settleWindow`.
    private var settlesUntil = Date.distantPast
    /// Alerts waiting for the island, most urgent first, at most one for each device.
    private var queue: [Alert] = []
    /// Shows the queue's alerts one after another, and only while there are any.
    private var queueRunner: Task<Void, Never>?
    /// Holds sample devices for the home tile while a preview runs.
    private var previewModel: InputDevicesModel?
    private var previewEnd: Task<Void, Never>?
    /// The model the home tile shows, so the tile is only replaced when that changes.
    private var tileModel: InputDevicesModel?
    /// When the connection card on screen is due to go, so a late reading keeps its time.
    private var cardEnds = Date.distantPast
    private var defaultsObserver: NSObjectProtocol?

    /// `source` stands in for the I/O Registry, and `now` for the clock, in tests.
    init(source: (any InputDeviceSource)? = nil, now: @escaping () -> Date = Date.init) {
        model = InputDevicesModel(source: source ?? RegistryInputDeviceSource())
        self.now = now
        model.onChanges = { [weak self] in self?.handle($0) }
        model.onWake = { [weak self] in self?.settle() }
        model.onChange = { [weak self] in self?.syncTile() }
    }

    func start() {
        isRunning = true
        model.start()
        // What is connected at launch is where things stand, not news, and so is what
        // connects in the moments after it, at login.
        model.devices.forEach { watch.baseline($0) }
        settle()
        // "Show on the home page" takes the tile away, or brings it back, at once.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncTile() }
        }
        syncTile()
    }

    func stop() {
        isRunning = false
        model.stop()
        queue = []
        queueRunner?.cancel()
        queueRunner = nil
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = nil
        previewEnd?.cancel()
        previewEnd = nil
        previewModel = nil
        syncTile()
        let center = ActivityCenter.shared
        if let id = center.banner?.id, id.hasPrefix(Self.bannerPrefix) {
            center.dismissBanner(id: id)
        }
    }

    func settingsView() -> AnyView? {
        AnyView(InputDevicesSettings())
    }

    /// Sample devices, never the person's. The connection preview also puts samples on
    /// the home page for ten seconds.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Mouse at 20%") { [weak self] in
                var mouse = InputDevice.sampleMagicMouse
                mouse.level = 20
                self?.presentLow(mouse)
            },
            FeaturePreview(title: "Keyboard at 5%") { [weak self] in
                var keyboard = InputDevice.sampleMagicKeyboard
                keyboard.level = 5
                self?.presentLow(keyboard)
            },
            FeaturePreview(title: "Trackpad connected") { [weak self] in
                self?.presentCard(for: .sampleMagicTrackpad, duration: Self.cardDuration)
                self?.previewTile()
            },
            FeaturePreview(title: "Home tile") { [weak self] in self?.previewTile() },
        ]
    }

    // MARK: Events

    /// Everything one read found, weighed together. Departures are noted first; then
    /// each arrival and change is asked what it has to say, and the answers wait their
    /// turn on the island, most urgent first, rather than replace one another.
    private func handle(_ changes: InputDeviceChanges) {
        guard isRunning else { return }
        changes.departed.forEach(departed)
        let isSettling = now() < settlesUntil
        let alerts = changes.arrived.compactMap { arrived($0, isSettling: isSettling) }
            + changes.updated.compactMap { updated($0.new) }
        enqueue(alerts)
    }

    /// The Mac woke, or Islet started: what connects in the next minute was here before.
    private func settle() {
        settlesUntil = now().addingTimeInterval(Self.settleWindow)
    }

    /// A device seen before and back while things settle gets no card, but a level it
    /// fell through while away still gets its warning; one never seen is taken as it is.
    private func arrived(_ device: InputDevice, isSettling: Bool) -> Alert? {
        if isSettling, !watch.knows(device) {
            watch.baseline(device)
            return nil
        }
        let warning = watch.check(device, enabled: enabledLevels)
        let hasReturned = isReturning(device) || isSettling
        if InputDevicesPrefs.bool(InputDevicesPrefs.showConnect, default: false), !hasReturned {
            // The card shows a low level in its colour, and says so: one alert, not two.
            return Alert(deviceID: device.id, kind: .card, warning: warning)
        }
        return warning.map { Alert(deviceID: device.id, kind: .low, warning: $0) }
    }

    private func updated(_ device: InputDevice) -> Alert? {
        let warning = watch.check(device, enabled: enabledLevels)
        if ActivityCenter.shared.banner?.id == Self.cardID(device) {
            // A level arriving while the card is up replaces it in place, and keeps it
            // long enough to be read.
            presentCard(for: device, duration: max(cardEnds.timeIntervalSince(now()), 2.5))
            return nil
        }
        return warning.map { Alert(deviceID: device.id, kind: .low, warning: $0) }
    }

    private func departed(_ device: InputDevice) {
        let time = now()
        for key in Self.returnKeys(device) { departures[key] = time }
        queue.removeAll { $0.deviceID == device.id }
        ActivityCenter.shared.dismissBanner(id: Self.cardID(device))
    }

    /// Whether the device left only a moment ago: by id, or, for one that moved from its
    /// cable to Bluetooth, by kind. That one comes back under another id and usually
    /// another name too ("Magic Keyboard with Touch ID" on the cable, "Sam’s Magic
    /// Keyboard" over Bluetooth). A second keyboard connecting within minutes of the
    /// first leaving is rare enough to go without its card.
    private func isReturning(_ device: InputDevice) -> Bool {
        let time = now()
        departures = departures.filter { time.timeIntervalSince($0.value) < Self.returnWindow }
        return Self.returnKeys(device).contains { departures[$0] != nil }
    }

    private static func returnKeys(_ device: InputDevice) -> [String] {
        [device.id, "kind.\(device.kind)"]
    }

    // MARK: Queue

    /// Something to say about one device: its battery reaching a warning level, or its
    /// connecting, which may carry a warning of its own.
    struct Alert: Equatable {
        enum Kind { case low, card }

        let deviceID: String
        let kind: Kind
        /// The warning level it gives, if any.
        let warning: Int?

        /// Warnings first, the lowest level first, since a device at 5% needs charging
        /// before one at 20%; then cards that only say hello.
        static func isMoreUrgent(_ a: Alert, than b: Alert) -> Bool {
            switch (a.warning, b.warning) {
            case let (a?, b?): a < b
            case (.some, nil): true
            default: false
            }
        }
    }

    /// Adds `alerts` to those waiting, keeping one for each device (the more urgent),
    /// and shows the first at once if none of this feature's is on the island, or if it
    /// is the one on the island (a level falling from 10% to 5% under its own banner
    /// updates it in place). A fresh warning goes over another feature's banner, as it
    /// always has; those that wait then wait for the island to be clear.
    private func enqueue(_ alerts: [Alert]) {
        guard !alerts.isEmpty else { return }
        var next = queue
        for alert in alerts {
            if let index = next.firstIndex(where: { $0.deviceID == alert.deviceID }) {
                if Alert.isMoreUrgent(alert, than: next[index]) { next[index] = alert }
            } else {
                next.append(alert)
            }
        }
        // Ties keep their order, which is the devices' display order.
        queue = next.enumerated()
            .sorted { Alert.isMoreUrgent($0.element, than: $1.element)
                || (!Alert.isMoreUrgent($1.element, than: $0.element) && $0.offset < $1.offset) }
            .map(\.element)
        let current = ActivityCenter.shared.banner?.id
        if !(current?.hasPrefix(Self.bannerPrefix) ?? false) || current == queue.first.map(Self.bannerID) {
            presentNext()
        }
        runQueue()
    }

    /// Looks once a second, while anything waits, for the island to be clear, and shows
    /// the next alert then. With nothing waiting it stops.
    private func runQueue() {
        guard queueRunner == nil, !queue.isEmpty else { return }
        queueRunner = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.queueCheckInterval))
                guard !Task.isCancelled, let self else { return }
                if ActivityCenter.shared.banner == nil { self.presentNext() }
                if self.queue.isEmpty {
                    self.queueRunner = nil
                    return
                }
            }
        }
    }

    private static let queueCheckInterval: TimeInterval = 1

    /// Shows the most urgent alert still worth showing, with the device as it is now,
    /// and drops those that no longer are: a device that has gone, or a warning for one
    /// now on its cable.
    private func presentNext() {
        while !queue.isEmpty {
            let alert = queue.removeFirst()
            guard let device = model.devices.first(where: { $0.id == alert.deviceID }) else { continue }
            switch alert.kind {
            case .card:
                presentCard(for: device, duration: Self.cardDuration)
                return
            case .low:
                guard !device.isOnPower else { continue }
                presentLow(device)
                return
            }
        }
    }

    /// The warning levels switched on in Settings.
    private var enabledLevels: Set<Int> {
        Set(LowBatteryWatch.levels.filter { InputDevicesPrefs.bool(InputDevicesPrefs.warnAt($0), default: true) })
    }

    // MARK: Presentation

    private static func cardID(_ device: InputDevice) -> String { cardID(device.id) }
    private static func cardID(_ deviceID: String) -> String { "\(bannerPrefix)connected.\(deviceID)" }
    private static func lowID(_ deviceID: String) -> String { "\(bannerPrefix)low.\(deviceID)" }

    /// The id of the banner `alert` would show.
    private static func bannerID(_ alert: Alert) -> String {
        switch alert.kind {
        case .low: lowID(alert.deviceID)
        case .card: cardID(alert.deviceID)
        }
    }

    /// "Magic Mouse · 10%": the device and its picture left of the notch, the level and a
    /// battery right of it, in orange from 20% and red from 10%.
    private func presentLow(_ device: InputDevice) {
        let widths = InputDeviceBannerLayout.widths(for: device)
        ActivityCenter.shared.present(IslandBanner(
            id: Self.lowID(device.id),
            style: .compact(leading: widths.leading, trailing: widths.trailing),
            duration: Self.lowDuration,
            leading: AnyView(InputDeviceLowLeading(device: device)),
            trailing: AnyView(InputDeviceLowTrailing(device: device))
        ))
    }

    private func presentCard(for device: InputDevice, duration: TimeInterval) {
        cardEnds = now().addingTimeInterval(duration)
        ActivityCenter.shared.present(IslandBanner(
            id: Self.cardID(device),
            style: .card(width: 360, height: 60),
            duration: duration,
            content: AnyView(InputDeviceConnectedCard(device: device))
        ))
    }

    /// The tile, while a device reports a level and Settings wants it; a desktop Mac's
    /// keyboard is always there, and may not deserve a place on the home page for good.
    private func syncTile() {
        let showsTile = isRunning && !model.devices.isEmpty
            && InputDevicesPrefs.bool(InputDevicesPrefs.showTile, default: true)
        let source = previewModel ?? (showsTile ? model : nil)
        guard source !== tileModel else { return }
        tileModel = source
        if let source {
            // Beside the headphones' tile, the other things running on a battery.
            ActivityCenter.shared.setHomeWidget(
                HomeWidget(id: Self.widgetID, order: Self.tileOrder, view: AnyView(InputDevicesHomeTile(model: source)))
            )
        } else {
            ActivityCenter.shared.removeHomeWidget(id: Self.widgetID)
        }
    }

    private func previewTile() {
        previewModel = InputDevicesModel(samples: [.sampleMagicKeyboard, .sampleMagicMouse, .sampleMagicTrackpad])
        syncTile()
        previewEnd?.cancel()
        previewEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.previewDuration))
            guard !Task.isCancelled, let self else { return }
            self.previewEnd = nil
            self.previewModel = nil
            self.syncTile()
        }
    }
}

/// The feature's preference keys, shared by the feature and its settings. Unset keys
/// read as their defaults, the same ones the settings toggles declare.
enum InputDevicesPrefs {
    static let showConnect = "inputDevices.showConnect"
    static let showTile = "inputDevices.showTile"

    static func warnAt(_ level: Int) -> String { "inputDevices.warnAt\(level)" }

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

private struct InputDevicesSettings: View {
    @AppStorage(InputDevicesPrefs.warnAt(20)) private var warnAt20 = true
    @AppStorage(InputDevicesPrefs.warnAt(10)) private var warnAt10 = true
    @AppStorage(InputDevicesPrefs.warnAt(5)) private var warnAt5 = true
    @AppStorage(InputDevicesPrefs.showConnect) private var showConnect = false
    @AppStorage(InputDevicesPrefs.showTile) private var showTile = true

    var body: some View {
        LabeledContent {
            HStack(spacing: 14) {
                Toggle("20%", isOn: $warnAt20)
                Toggle("10%", isOn: $warnAt10)
                Toggle("5%", isOn: $warnAt5)
            }
            .toggleStyle(.checkbox)
        } label: {
            Text("Warn when a battery falls to")
            Text("Magic Mouse, Keyboard and Trackpad report their battery to macOS, as do some other makes' Bluetooth mice, keyboards and game controllers. Those on their own USB receiver tell only their maker's app.")
        }
        Toggle(isOn: $showConnect) {
            Text("Show when one connects")
            Text("A card with its battery, as for headphones.")
        }
        Toggle(isOn: $showTile) {
            Text("Show on the home page")
            Text("Each connected device's battery; with more than three, the three lowest.")
        }
    }
}
