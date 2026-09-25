import Foundation

/// What `system_profiler` knows about connected Bluetooth devices. It is the one source
/// of AirPods battery levels that needs no Bluetooth permission, but it is a process
/// launch, so it runs off the main thread and only when a headset connects or the home
/// tile is opened.
enum BluetoothProfile {
    struct Device: Equatable, Sendable {
        var name: String
        /// In `BluetoothAudioDevice.canonicalAddress` spelling.
        var address: String?
        var productID: Int?
        var vendorID: Int?
        /// "Headphones", "Headset", "Speaker", "Mouse"…
        var minorType: String?
        var battery: HeadsetBattery
    }

    /// Connected devices, or `nil` when system_profiler could not run or said nothing
    /// useful. Cancelling the calling task terminates the process.
    static func connectedDevices() async -> [Device]? {
        let launch = ProfilerLaunch()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: launch.output().flatMap(parse))
                }
            }
        } onCancel: {
            launch.cancel()
        }
    }

    static func parse(_ data: Data) -> [Device]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return nil }

        // Each connected device is a one-key dictionary: its name, then its details.
        return controllers.flatMap { controller in
            (controller["device_connected"] as? [[String: Any]] ?? []).flatMap { entry in
                entry.compactMap { name, details in
                    (details as? [String: Any]).map { Device(name: name, details: $0) }
                }
            }
        }
    }
}

extension BluetoothProfile.Device {
    init(name: String, details: [String: Any]) {
        func text(_ key: String) -> String? { details[key] as? String }
        /// "64%" → 64.
        func percent(_ key: String) -> Int? {
            text(key).flatMap { Int($0.filter(\.isNumber)) }.map { min(max($0, 0), 100) }
        }
        /// "0x202D" → 0x202D.
        func hex(_ key: String) -> Int? {
            guard let token = text(key)?.split(separator: " ").first?.lowercased(),
                  token.hasPrefix("0x")
            else { return nil }
            return Int(token.dropFirst(2), radix: 16)
        }

        self.init(
            name: name,
            address: text("device_address").map(BluetoothAudioDevice.canonicalAddress),
            productID: hex("device_productID"),
            vendorID: hex("device_vendorID"),
            minorType: text("device_minorType"),
            battery: HeadsetBattery(
                left: percent("device_batteryLevelLeft"),
                right: percent("device_batteryLevelRight"),
                chargingCase: percent("device_batteryLevelCase"),
                main: percent("device_batteryLevelMain") ?? percent("device_batteryLevel")
            )
        )
    }
}

/// One run of system_profiler, which a cancelled read can terminate. The lock keeps
/// cancellation and launch from racing: terminating a process that has not been
/// launched raises an exception.
private final class ProfilerLaunch: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var isCancelled = false

    /// Blocks until the process exits, and returns its output if it succeeded.
    func output() -> Data? {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        lock.lock()
        let launched = !isCancelled && (try? process.run()) != nil
        lock.unlock()
        guard launched else { return nil }

        // It normally answers in a fraction of a second; a wedged one must not hold the
        // read open for ever.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.cancel()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0 ? data : nil
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        if process.isRunning { process.terminate() }
    }
}
