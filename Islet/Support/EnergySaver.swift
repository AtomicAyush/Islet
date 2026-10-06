import AppKit
import IOKit.ps
import Observation
import notify

/// When the island saves energy (Settings › General).
enum SaveEnergy: String, CaseIterable, Identifiable {
    case inLowPowerMode
    /// On battery, and in Low Power Mode whatever the Mac runs on.
    case onBattery
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inLowPowerMode: "In Low Power Mode"
        case .onBattery: "On battery"
        case .never: "Never"
        }
    }

    /// What it does, under the choice in Settings.
    var footnote: String? {
        let what = "the music's waveform, spinners and colours hold still, lyrics change line by line, "
            + "and the timer's ring and the player's clocks are redrawn less often."
        switch self {
        case .inLowPowerMode: return "In Low Power Mode, " + what
        case .onBattery: return "On battery, and in Low Power Mode, " + what
        case .never: return nil
        }
    }
}

/// Whether the island saves energy now, as the person chose in Settings: in Low Power
/// Mode (the default), on battery, or never.
///
/// While it does, what would otherwise move for as long as something runs holds still
/// in a state that says the same: the Now Playing waveform stands as uneven bars while
/// music plays and low ones while it is paused, and stops listening to the music
/// altogether; spinners stand as an arc from the top; the breathing symbols are drawn
/// whole; the island's colours are drawn still; lyrics change line by line, a line too
/// long cut short rather than scrolled; a long title in the player stays put, cut
/// short; and the timer's ring and the player's clocks are redrawn only when what they
/// show changes. Nothing else changes, and with the saver off nothing does.
///
/// It is told when Low Power Mode or the power source changes, never asks, and listens
/// for the power source only while the choice turns on it.
@MainActor
@Observable
final class EnergySaver {
    static let shared = EnergySaver()

    /// Posted on the main thread when `isSaving` changes, for AppKit views and models;
    /// SwiftUI views read `isSaving` and are redrawn by Observation.
    static let didChange = Notification.Name("EnergySaverDidChange")

    private(set) var isSaving = false

    #if DEBUG
    /// For the harness: what the Mac would say, in place of asking it. Like the Mac's
    /// own answers, it takes effect when Low Power Mode, the power source or the
    /// setting is next said to have changed.
    struct Conditions: Equatable {
        var lowPower = false
        var onBattery = false
    }
    @ObservationIgnored var conditions: Conditions?
    /// For the harness: the notification the power source is watched by, so it can be
    /// posted without touching the system's own.
    static var powerSourceNotification = kIOPSNotifyPowerSource
    /// For the harness: whether the power source is watched.
    var isWatchingPowerSource: Bool { powerSourceToken != nil }
    #endif

    @ObservationIgnored private var choice = SaveEnergy.inLowPowerMode
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var powerSourceToken: Int32?

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        reconcile()
    }

    private func reconcile() {
        choice = SaveEnergy(rawValue: UserDefaults.standard.string(forKey: Prefs.Key.saveEnergy) ?? "")
            ?? .inLowPowerMode
        watchPowerSource(choice == .onBattery)
        var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        var onBattery = choice == .onBattery && Self.isOnBattery
        #if DEBUG
        if let conditions {
            lowPower = conditions.lowPower
            onBattery = choice == .onBattery && conditions.onBattery
        }
        #endif
        let saving = choice != .never && (lowPower || onBattery)
        guard saving != isSaving else { return }
        isSaving = saving
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Listens for the notification macOS posts as the Mac moves between its adapter
    /// and its battery, and for no other change of the battery's, registered directly
    /// so that stopping cancels it (see `BatteryModel`).
    private func watchPowerSource(_ wanted: Bool) {
        guard wanted != (powerSourceToken != nil) else { return }
        if let powerSourceToken {
            notify_cancel(powerSourceToken)
            self.powerSourceToken = nil
            return
        }
        #if DEBUG
        let name = Self.powerSourceNotification
        #else
        let name = kIOPSNotifyPowerSource
        #endif
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        if status == UInt32(NOTIFY_STATUS_OK) { powerSourceToken = token }
    }

    /// Whether the Mac runs on its battery: a Mac without one never does.
    private static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return type as String == kIOPSBatteryPowerValue
    }
}
