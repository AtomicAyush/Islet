import Foundation
import IOKit.ps
import Observation
import notify

/// One reading of the internal battery, as the menu bar's battery item sees it.
struct BatteryState: Equatable {
    /// Percent, 0 to 100.
    var level: Int
    /// Running from the power adapter, whether or not the battery is taking charge
    /// (it may be held at a limit, or already full).
    var isPluggedIn: Bool
    var isCharging: Bool
    /// macOS considers the battery full.
    var isCharged: Bool
    /// Minutes until empty on battery. IOKit reports -1 while it is still estimating
    /// and 0 when the figure does not apply.
    var minutesToEmpty: Int
    /// Minutes until full while charging, with the same conventions.
    var minutesToFull: Int
    var isLowPowerMode: Bool

    var isFull: Bool { isCharged || level >= 100 }
}

/// Watches the internal battery and Low Power Mode. It knows nothing about the island:
/// it keeps the current reading for views, and reports a change only once a burst of
/// notifications has settled, because plugging in alone posts several (the adapter,
/// then charging starting, then a new estimate).
@MainActor
@Observable
final class BatteryModel {
    /// `nil` while stopped, and on Macs without an internal battery.
    private(set) var state: BatteryState?

    /// Called with the previous settled reading and the new one, after a change.
    @ObservationIgnored var onSettle: (_ old: BatteryState?, _ new: BatteryState?) -> Void = { _, _ in }

    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var powerSourceToken: Int32?
    @ObservationIgnored private var lowPowerObserver: NSObjectProtocol?
    @ObservationIgnored private var settleWork: DispatchWorkItem?
    @ObservationIgnored private var settled: BatteryState?

    /// Long enough to swallow the burst for one plug or unplug, short enough that the
    /// banner still feels like it answers the cable.
    private static let settleDelay: TimeInterval = 0.4

    /// Reads the current state as the baseline, so nothing is reported for it.
    func start() {
        isRunning = true
        state = Self.read()
        settled = state
        // The notification IOPSNotificationCreateRunLoopSource is built on (it fires as
        // the adapter, charging, level or estimate change), registered directly because
        // releasing that run-loop source never cancels its registration: every
        // start and stop would leak a Mach port.
        var token: Int32 = 0
        let status = notify_register_dispatch(kIOPSNotifyTimeRemaining, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if status == UInt32(NOTIFY_STATUS_OK) { powerSourceToken = token }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        isRunning = false
        if let powerSourceToken {
            notify_cancel(powerSourceToken)
        }
        powerSourceToken = nil
        if let lowPowerObserver {
            NotificationCenter.default.removeObserver(lowPowerObserver)
        }
        lowPowerObserver = nil
        settleWork?.cancel()
        settleWork = nil
        state = nil
        settled = nil
    }

    private func refresh() {
        // A delivery already queued on the main queue can still arrive after stop().
        guard isRunning else { return }
        let next = Self.read()
        if next != state { state = next }

        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settle() }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func settle() {
        settleWork = nil
        guard state != settled else { return }
        let old = settled
        settled = state
        onSettle(old, state)
    }

    /// The first internal battery IOKit lists. A UPS or other external source is
    /// skipped, and a Mac with no battery reads as `nil`.
    nonisolated static func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue()
        else { return nil }

        for source in list as [CFTypeRef] {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool != false,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0
            else { continue }

            // Max Capacity is normally 100 here, so this is the percentage itself.
            let level = Int((Double(current) * 100 / Double(capacity)).rounded())
            return BatteryState(
                level: min(100, max(0, level)),
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                minutesToEmpty: description[kIOPSTimeToEmptyKey] as? Int ?? -1,
                minutesToFull: description[kIOPSTimeToFullChargeKey] as? Int ?? -1,
                isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }
        return nil
    }
}
