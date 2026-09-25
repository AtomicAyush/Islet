import SwiftUI

/// The battery's moments, the way the iPhone shows them: a flash of "Charging" when
/// the cable goes in, a warning as the level runs low, and a word when it is full or
/// Low Power Mode changes. Charging is only ever an alert, never an ongoing activity;
/// the level itself lives on the home page. A Mac without a battery shows nothing.
@MainActor
final class BatteryFeature: Feature {
    let id = "battery"
    let title = "Battery"
    let symbol = "battery.100percent.bolt"
    let summary = "A charging flash when you plug in, and a warning when the battery runs low."

    private static let widgetID = "battery"

    private let model = BatteryModel()
    private var isRunning = false
    /// Low-battery levels that will warn the next time the level falls through them.
    private var armedThresholds: Set<Int> = []
    /// Set once the battery is full on the charger; cleared when it comes off the
    /// charger or drains well below full.
    private var hasReachedFull = false
    /// Puts the live tile back after the home tile preview.
    private var tilePreviewWork: DispatchWorkItem?

    @AppStorage(BatteryPrefs.warnAt20) private var warnAt20 = true
    @AppStorage(BatteryPrefs.warnAt10) private var warnAt10 = true
    @AppStorage(BatteryPrefs.showOnUnplug) private var showOnUnplug = false
    @AppStorage(BatteryPrefs.showWhenCharged) private var showWhenCharged = true

    init() {
        model.onSettle = { [weak self] old, new in self?.settled(from: old, to: new) }
    }

    func start() {
        isRunning = true
        model.start()
        armedThresholds = Set(thresholds.map(\.level))
        hasReachedFull = model.state.map { $0.isPluggedIn && $0.isFull } ?? false
        syncHomeWidget()
    }

    func stop() {
        isRunning = false
        model.stop()
        tilePreviewWork?.cancel()
        tilePreviewWork = nil
        let center = ActivityCenter.shared
        center.removeHomeWidget(id: Self.widgetID)
        for id in BatteryAlert.ids { center.dismissBanner(id: id) }
    }

    func settingsView() -> AnyView? {
        AnyView(BatterySettings())
    }

    /// Banners stay their usual 2.8 s (4 s for low battery). The home tile preview
    /// swaps in a sample tile for 10 s; open the island to see it.
    var previews: [FeaturePreview] {
        func banner(_ title: String, _ alert: BatteryAlert) -> FeaturePreview {
            FeaturePreview(title: title) { ActivityCenter.shared.present(alert.banner) }
        }
        return [
            banner("Plug in charger", .power(.sample(level: 80, pluggedIn: true, charging: true, minutes: 65))),
            banner("Low battery", .low(.sample(level: 20, minutes: 48))),
            banner("Low Power Mode on", .lowPower(.sample(level: 46, lowPower: true, minutes: 190))),
            banner("Fully charged", .charged(.sample(level: 100, pluggedIn: true))),
            banner("Plug in, not charging", .power(.sample(level: 80, pluggedIn: true))),
            banner("Unplug charger", .power(.sample(level: 72, minutes: 200))),
            FeaturePreview(title: "Home tile, charging") { [weak self] in self?.previewHomeTile() },
        ]
    }

    /// `islet://battery/status` flashes the current level and power source.
    func handle(_ url: URL) -> Bool {
        guard url.path() == "/status" else { return false }
        if let state = BatteryModel.read() {
            ActivityCenter.shared.present(BatteryAlert.power(state).banner)
        }
        return true
    }

    // MARK: Events

    /// Low-battery levels, highest first, with whether each warns.
    private var thresholds: [(level: Int, isOn: Bool)] {
        [(20, warnAt20), (10, warnAt10)]
    }

    /// Picks the banner, if any, that a settled change deserves. The checks run least
    /// important first, so when several coincide the most important is shown.
    private func settled(from old: BatteryState?, to new: BatteryState?) {
        syncHomeWidget()
        guard let old, let new else { return }
        let center = ActivityCenter.shared
        let reachedFull = updateReachedFull(from: old, to: new)
        let fellBelowThreshold = updateThresholds(from: old, to: new)

        var alert: BatteryAlert?
        if old.isLowPowerMode != new.isLowPowerMode {
            alert = .lowPower(new)
        }
        if old.isPluggedIn != new.isPluggedIn {
            if new.isPluggedIn || showOnUnplug {
                alert = .power(new)
            } else {
                center.dismissBanner(id: BatteryAlert.powerID)
            }
        } else if new.isPluggedIn, old.isCharging != new.isCharging,
                  center.banner?.id == BatteryAlert.powerID {
            // Charging often starts a beat after the cable goes in: correct the banner
            // that is still up, in place.
            alert = .power(new)
        }
        if reachedFull, showWhenCharged {
            alert = .charged(new)
        }
        if fellBelowThreshold {
            alert = .low(new)
        }

        if let alert { center.present(alert.banner) }
    }

    /// Whether the battery has just become full on the charger, for the first time this
    /// stint. macOS lets a full battery drift into the high nineties and tops it up
    /// again, which must not count as reaching full again.
    private func updateReachedFull(from old: BatteryState, to new: BatteryState) -> Bool {
        let reached = !hasReachedFull && old.isPluggedIn && new.isPluggedIn && !old.isFull && new.isFull
        if new.isPluggedIn && new.isFull {
            hasReachedFull = true
        } else if !new.isPluggedIn || new.level < 90 {
            hasReachedFull = false
        }
        return reached
    }

    /// Whether the level has just fallen through a switched-on threshold on battery.
    /// Each threshold fires once, then rearms when the Mac is plugged in or the level is
    /// clearly back above it; the gauge can wobble by a point, which must not re-fire.
    private func updateThresholds(from old: BatteryState, to new: BatteryState) -> Bool {
        var fell = false
        for threshold in thresholds {
            if new.isPluggedIn || new.level >= threshold.level + 3 {
                armedThresholds.insert(threshold.level)
            } else if old.level > threshold.level, new.level <= threshold.level,
                      armedThresholds.remove(threshold.level) != nil {
                fell = fell || threshold.isOn
            }
        }
        return fell
    }

    // MARK: Home

    private func syncHomeWidget() {
        // The sample tile is up; its end calls back here.
        guard tilePreviewWork == nil else { return }
        let center = ActivityCenter.shared
        let wanted = isRunning && model.state != nil
        let shown = center.homeWidgets.contains { $0.id == Self.widgetID }
        if wanted, !shown {
            center.setHomeWidget(HomeWidget(
                id: Self.widgetID, order: 40, view: AnyView(BatteryLiveTile(model: model))
            ))
        } else if !wanted, shown {
            center.removeHomeWidget(id: Self.widgetID)
        }
    }

    private func previewHomeTile() {
        let sample = BatteryState.sample(level: 64, pluggedIn: true, charging: true, minutes: 65)
        ActivityCenter.shared.setHomeWidget(HomeWidget(
            id: Self.widgetID, order: 40, view: AnyView(BatteryHomeTile(state: sample))
        ))
        tilePreviewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tilePreviewWork = nil
                ActivityCenter.shared.removeHomeWidget(id: Self.widgetID)
                self.syncHomeWidget()
            }
        }
        tilePreviewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }
}

/// The feature's preference keys, shared by the feature and its settings.
enum BatteryPrefs {
    static let warnAt20 = "battery.warnAt20"
    static let warnAt10 = "battery.warnAt10"
    static let showOnUnplug = "battery.showOnUnplug"
    static let showWhenCharged = "battery.showWhenCharged"
}

private struct BatterySettings: View {
    @AppStorage(BatteryPrefs.warnAt20) private var warnAt20 = true
    @AppStorage(BatteryPrefs.warnAt10) private var warnAt10 = true
    @AppStorage(BatteryPrefs.showOnUnplug) private var showOnUnplug = false
    @AppStorage(BatteryPrefs.showWhenCharged) private var showWhenCharged = true

    var body: some View {
        LabeledContent("Warn when the battery falls to") {
            HStack(spacing: 14) {
                Toggle("20%", isOn: $warnAt20)
                Toggle("10%", isOn: $warnAt10)
            }
            .toggleStyle(.checkbox)
        }
        Toggle("Show when the charger is removed", isOn: $showOnUnplug)
        Toggle("Show when fully charged", isOn: $showWhenCharged)
    }
}

private extension BatteryState {
    /// A made-up reading for the previews.
    static func sample(
        level: Int, pluggedIn: Bool = false, charging: Bool = false,
        lowPower: Bool = false, minutes: Int = 0
    ) -> BatteryState {
        BatteryState(
            level: level,
            isPluggedIn: pluggedIn,
            isCharging: charging,
            isCharged: pluggedIn && !charging && level >= 100,
            minutesToEmpty: pluggedIn ? 0 : minutes,
            minutesToFull: charging ? minutes : 0,
            isLowPowerMode: lowPower
        )
    }
}
