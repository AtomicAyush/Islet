import Foundation
import IOKit

/// Where input devices and their levels come from. The app reads the I/O Registry;
/// tests hand in devices of their own.
@MainActor
protocol InputDeviceSource: AnyObject {
    /// Every connected device that reports a battery level, as it is now.
    func read() -> [InputDevice]
    /// Calls `onChange` whenever a device may have come or gone, until `stopWatching()`.
    func startWatching(_ onChange: @escaping () -> Void)
    func stopWatching()
}

/// Reads levels from the I/O Registry, where macOS keeps what each Bluetooth input
/// device last reported as "BatteryPercent" — the figure the Bluetooth menu shows. It
/// needs no permission: the registry is there for any process to read, no device is
/// opened and none of its reports are read. All that is watched is devices arriving
/// and leaving.
///
/// The registry says nothing when a level changes, so the model reads it again now and
/// then; what it does say is when a HID device arrives or leaves, which is what this
/// watches. Magic accessories keep their level on the `AppleDeviceManagementHIDEventService`
/// under the device; any other device that reports one keeps it on a service of its own
/// class, so the read looks for the property rather than a class.
@MainActor
final class RegistryInputDeviceSource: InputDeviceSource {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var onChange: () -> Void = {}

    func read() -> [InputDevice] {
        InputDeviceRegistry.devices(from: InputDeviceRegistry.readEntries())
    }

    /// Asks IOKit to say when any HID device registers or terminates. A device reports
    /// its level a moment after it arrives, so the model reads a few times after each.
    /// The notifications arrive on the main queue, holding this object unretained:
    /// stop watching before letting go of it.
    func startWatching(_ onChange: @escaping () -> Void) {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.onChange = onChange
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let status = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching("IOHIDDevice"),
                { context, iterator in
                    // Emptying the iterator is what arms the next notification.
                    RegistryInputDeviceSource.drain(iterator)
                    guard let context else { return }
                    let source = Unmanaged<RegistryInputDeviceSource>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated { source.onChange() }
                },
                context, &iterator
            )
            guard status == KERN_SUCCESS else { continue }
            // The devices already there are not news; draining them arms the watch.
            Self.drain(iterator)
            iterators.append(iterator)
        }
    }

    func stopWatching() {
        iterators.forEach { IOObjectRelease($0) }
        iterators = []
        if let port { IONotificationPortDestroy(port) }
        port = nil
        onChange = {}
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}

/// Turns registry entries into devices. Kept apart from IOKit, so tests can hand it
/// entries of their own, shaped as `ioreg -r -l -k BatteryPercent` prints them.
enum InputDeviceRegistry {
    /// The properties read from each entry; the rest (and there are many) are left.
    static let keys = [
        "BatteryPercent", "BatteryStatusFlags", "Product", "VendorID", "ProductID",
        "Transport", "Built-In", "DeviceAddress", "PrimaryUsagePage", "PrimaryUsage",
    ]

    /// Where the device's own power supply seems to show in `BatteryStatusFlags`: set,
    /// as far as anyone outside Apple has seen, while it is on its cable, charging or
    /// charged. Undocumented, so it is only the device's word (`saysOnPower`), which the
    /// model believes once the level bears it out.
    static let externalPowerFlag = 0x02

    /// A Magic accessory plugged into the Mac works over its cable, as a USB device, and
    /// a device on a USB cable has power whatever its flags say.
    static func isWired(transport: String?) -> Bool {
        transport?.hasPrefix("USB") == true
    }

    /// Transports whose devices are headphones, which the Headphones feature shows with
    /// their own levels.
    static let audioTransports: Set<String> = ["BT-AACP", "Audio"]

    /// Where an entry's class goes among its properties, as `ioreg` prints it after the
    /// entry's name.
    static let classKey = "IOObjectClass"
    /// The service under a Magic accessory that keeps its level.
    static let eventServiceClass = "AppleDeviceManagementHIDEventService"

    /// Every registry entry, of whatever class, that has a battery level, with just the
    /// properties in `keys`. About a millisecond, however many devices there are.
    static func readEntries() -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        let matching = ["IOPropertyExistsMatch": "BatteryPercent"] as CFDictionary
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var entries: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            var entry: [String: Any] = [:]
            for key in keys {
                if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() {
                    entry[key] = value
                }
            }
            if let name = IOObjectCopyClass(service)?.takeRetainedValue() {
                entry[classKey] = name as String
            }
            IOObjectRelease(service)
            entries.append(entry)
        }
        return entries
    }

    /// The devices among `entries`, one per device. A device may keep its level on more
    /// than one entry (the HID device, and the event service under it), and not every
    /// entry gives its Bluetooth address, so two entries are one device when their
    /// addresses match or, where either has none, their vendor, product and name do.
    /// Which to believe must not hang on the order IOKit lists them in, or the level
    /// could flip between reads: the event service's, where Magic accessories keep it,
    /// and otherwise the lower level, the one worth warning about.
    static func devices(from entries: [[String: Any]]) -> [InputDevice] {
        var readings: [Reading] = []
        for reading in entries.compactMap(Reading.init(entry:)) {
            if let index = readings.firstIndex(where: { $0.isSameDevice(as: reading) }) {
                readings[index] = readings[index].merged(with: reading)
            } else {
                readings.append(reading)
            }
        }
        return readings.map(\.device)
    }

    /// The device an entry describes, or `nil` for one to leave out: the Mac's own
    /// keyboard and trackpad, headphones and anything else that is not an input device,
    /// and a level that is no level (a zero means "not reported", as it does for
    /// headphones, not a flat battery).
    static func device(from entry: [String: Any]) -> InputDevice? {
        Reading(entry: entry)?.device
    }

    /// One entry's account of a device.
    private struct Reading {
        var address: String?
        /// Vendor, product and name: who the device is without its address.
        let model: String
        let name: String
        let kind: InputDeviceKind
        let level: Int
        let isOnPower: Bool
        let saysOnPower: Bool
        let isEventService: Bool

        init?(entry: [String: Any]) {
            guard let level = int(entry["BatteryPercent"]), (1...100).contains(level),
                  entry["Built-In"] as? Bool != true
            else { return nil }
            let transport = entry["Transport"] as? String
            if let transport, audioTransports.contains(transport) { return nil }

            let vendorID = int(entry["VendorID"])
            let productID = int(entry["ProductID"])
            let product = (entry["Product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let kind = InputDeviceKind(
                vendorID: vendorID, productID: productID, name: product,
                usagePage: int(entry["PrimaryUsagePage"]), usage: int(entry["PrimaryUsage"])
            ) else { return nil }
            self.kind = kind
            name = product.isEmpty ? kind.genericName : product
            model = "\(vendorID ?? 0):\(productID ?? 0):\(name)"
            address = (entry["DeviceAddress"] as? String)
                .map { $0.lowercased().replacingOccurrences(of: "-", with: ":") }
                .flatMap { $0.isEmpty ? nil : $0 }
            self.level = level
            isOnPower = isWired(transport: transport)
            saysOnPower = (int(entry["BatteryStatusFlags"]) ?? 0) & externalPowerFlag != 0
            isEventService = entry[classKey] as? String == eventServiceClass
        }

        /// Its Bluetooth address where there is one, so a keyboard that sleeps and wakes
        /// is the same keyboard; otherwise vendor, product and name.
        var device: InputDevice {
            InputDevice(
                id: address ?? model, name: name, kind: kind, level: level,
                isOnPower: isOnPower, saysOnPower: saysOnPower
            )
        }

        func isSameDevice(as other: Reading) -> Bool {
            if let address, let otherAddress = other.address { return address == otherAddress }
            return model == other.model
        }

        /// The reading to believe of the two, keeping the address if either has it.
        func merged(with other: Reading) -> Reading {
            var kept = other.isPreferred(over: self) ? other : self
            kept.address = kept.address ?? address ?? other.address
            return kept
        }

        private func isPreferred(over other: Reading) -> Bool {
            if isEventService != other.isEventService { return isEventService }
            if level != other.level { return level < other.level }
            if isOnPower != other.isOnPower { return isOnPower }
            if saysOnPower != other.saysOnPower { return saysOnPower }
            return name < other.name
        }
    }

    /// IOKit hands numbers back as `NSNumber`; tests hand in `Int`.
    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? value as? Int
    }
}
