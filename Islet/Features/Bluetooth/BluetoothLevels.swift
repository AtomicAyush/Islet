import CoreBluetooth
import Foundation
import IOBluetooth
import Observation

/// Exact battery levels from IOBluetooth — the figures the Sound menu shows.
///
/// system_profiler stops reporting a level once AirPods Max are connected (and is late
/// for AirPods), but the Bluetooth framework keeps it, to the percent, behind properties
/// that are not in the public headers (`batteryPercentSingle` and friends). Reading them
/// needs Bluetooth permission, and touching IOBluetooth without it gets the process
/// killed by TCC, so nothing here runs until `CBManager.authorization` says it may.
@MainActor
@Observable
final class BluetoothLevels: NSObject {
    static let shared = BluetoothLevels()

    private(set) var authorization = CBManager.authorization

    var isAuthorized: Bool { authorization == .allowedAlways }

    /// Called when access is granted, so levels can be read straight away.
    @ObservationIgnored var onAuthorized: () -> Void = {}

    /// Held only while a permission request is in flight; creating it is what asks.
    @ObservationIgnored private var requester: CBCentralManager?

    private override init() {
        super.init()
    }

    /// Re-reads the status, which can change in System Settings without telling the app.
    func refreshAuthorization() {
        let current = CBManager.authorization
        guard current != authorization else { return }
        authorization = current
        if isAuthorized { onAuthorized() }
    }

    /// Asks macOS for Bluetooth access. Only ever called from a button.
    func requestAccess() {
        authorization = CBManager.authorization
        guard authorization == .notDetermined, requester == nil else { return }
        requester = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
    }

    /// Levels for each connected device, keyed by `BluetoothAudioDevice.canonicalAddress`.
    /// Empty without permission.
    func read() -> [String: HeadsetBattery] {
        authorization = CBManager.authorization
        guard isAuthorized else { return [:] }

        var result: [String: HeadsetBattery] = [:]
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] {
            // The framework keeps the last level of devices that are off; only the
            // connected ones are current.
            guard device.isConnected(), let address = device.addressString else { continue }
            let battery = HeadsetBattery(
                left: Self.percent(device, "batteryPercentLeft"),
                right: Self.percent(device, "batteryPercentRight"),
                chargingCase: Self.percent(device, "batteryPercentCase"),
                main: Self.percent(device, "batteryPercentSingle")
            )
            if !battery.isEmpty {
                result[BluetoothAudioDevice.canonicalAddress(address)] = battery
            }
        }
        return result
    }

    /// Read defensively: only if the device answers to the selector, and a zero means
    /// "not reported", not a flat battery.
    private static func percent(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let value = device.value(forKey: key) as? Int,
              value > 0, value <= 100
        else { return nil }
        return value
    }
}

extension BluetoothLevels: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            authorization = CBManager.authorization
            guard authorization != .notDetermined else { return }
            requester = nil
            if isAuthorized { onAuthorized() }
        }
    }
}
