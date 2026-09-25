import CoreAudio
import Foundation

/// A Bluetooth audio device as CoreAudio sees it. AirPods show up as two devices, an
/// input and an output, which this merges into one.
struct BluetoothAudioDevice: Equatable, Sendable {
    /// The Bluetooth address in `canonicalAddress` spelling, which the input and output
    /// halves share. CoreAudio's UID when it carries no address.
    var id: String
    var name: String
    var productID: Int?
    var vendorID: Int?

    /// CoreAudio spells addresses with dashes and system_profiler with colons; this is
    /// the spelling both are compared in.
    static func canonicalAddress(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }
}

/// Finds connected headphones through CoreAudio: every Bluetooth headset is an audio
/// device whose transport is Bluetooth. Unlike IOBluetooth and CoreBluetooth this needs
/// no Bluetooth permission, and property listeners report changes as they happen.
final class BluetoothAudioWatcher {
    struct Snapshot: Equatable, Sendable {
        var devices: [BluetoothAudioDevice]
        /// The device sound is going to, when it is one of `devices`.
        var outputID: String?
    }

    /// CoreAudio calls can stall while a Bluetooth device is still being set up, which is
    /// exactly when these run, so they stay off the main thread.
    private let queue = DispatchQueue(label: "com.ayush.Islet.bluetooth-audio", qos: .utility)
    private var listener: AudioObjectPropertyListenerBlock?
    // These two are touched only on `queue`.
    private var scanScheduled = false
    private var lastSnapshot: Snapshot?

    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]

    /// Starts listening. `deliver` runs on the main thread: once straight away with the
    /// devices already present (`isInitial`), then whenever they or the output change.
    func start(deliver: @escaping @MainActor (Snapshot, _ isInitial: Bool) -> Void) {
        guard listener == nil else { return }

        let send: (Snapshot, Bool) -> Void = { snapshot, isInitial in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(snapshot, isInitial) }
            }
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleScan(send)
        }
        self.listener = listener

        // The first CoreAudio call in a process sets up the audio system, which takes a
        // few hundred milliseconds, so even registering stays off the main thread.
        // Listening before the first scan means no change can slip in between the two.
        let queue = self.queue
        queue.async { [weak self] in
            Self.setListening(true, listener: listener, queue: queue)
            let snapshot = Self.scan()
            self?.lastSnapshot = snapshot
            send(snapshot, true)
        }
    }

    func stop() {
        guard let listener else { return }
        self.listener = nil
        // On the queue, so it always follows the registration, even when stopped at once.
        let queue = self.queue
        queue.async { Self.setListening(false, listener: listener, queue: queue) }
    }

    /// Connecting AirPods changes the device list two or three times in quick succession
    /// (output, input, then the default output); one scan after the burst is enough.
    private func scheduleScan(_ send: @escaping (Snapshot, Bool) -> Void) {
        guard !scanScheduled else { return }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.scanScheduled = false
            let snapshot = Self.scan()
            guard snapshot != self.lastSnapshot else { return }
            self.lastSnapshot = snapshot
            send(snapshot, false)
        }
    }

    // MARK: CoreAudio

    private static func setListening(
        _ isOn: Bool,
        listener: @escaping AudioObjectPropertyListenerBlock,
        queue: DispatchQueue
    ) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in selectors {
            var address = propertyAddress(selector)
            if isOn {
                AudioObjectAddPropertyListenerBlock(system, &address, queue, listener)
            } else {
                AudioObjectRemovePropertyListenerBlock(system, &address, queue, listener)
            }
        }
    }

    private static func scan() -> Snapshot {
        let output = defaultOutputDevice()
        var snapshot = Snapshot(devices: [])

        for device in deviceIDs() {
            let transport = uint32(device, kAudioDevicePropertyTransportType)
            guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                  let uid = string(device, kAudioDevicePropertyDeviceUID)
            else { continue }

            let name = string(device, kAudioObjectPropertyName) ?? "Headphones"
            let isOutput = hasStreams(device, scope: kAudioObjectPropertyScopeOutput)
            let model = string(device, kAudioDevicePropertyModelUID).flatMap(parseModelUID)
            var id = headsetID(uid: uid)

            if let index = snapshot.devices.firstIndex(where: { [id] in $0.id == id || $0.name == name }) {
                id = snapshot.devices[index].id
                // The output half's name is the one the rest of macOS shows.
                if isOutput { snapshot.devices[index].name = name }
                if snapshot.devices[index].productID == nil {
                    snapshot.devices[index].productID = model?.product
                    snapshot.devices[index].vendorID = model?.vendor
                }
            } else {
                snapshot.devices.append(BluetoothAudioDevice(
                    id: id, name: name, productID: model?.product, vendorID: model?.vendor
                ))
            }
            if device == output { snapshot.outputID = id }
        }
        return snapshot
    }

    /// "70-F9-4A-8F-7A-F3:output" becomes "70:F9:4A:8F:7A:F3": a Bluetooth device's UID is
    /// its address followed by its direction.
    private static func headsetID(uid: String) -> String {
        var base = uid
        for suffix in [":input", ":output"] where base.lowercased().hasSuffix(suffix) {
            base.removeLast(suffix.count)
        }
        return BluetoothAudioDevice.canonicalAddress(base)
    }

    /// Bluetooth devices report a model UID of "<product id> <vendor id>" in hex ("202d 4c"
    /// for AirPods Max), which is enough to pick a picture before system_profiler answers.
    private static func parseModelUID(_ uid: String) -> (product: Int, vendor: Int)? {
        let parts = uid.split(separator: " ")
        guard parts.count == 2,
              let product = Int(parts[0], radix: 16),
              let vendor = Int(parts[1], radix: 16)
        else { return nil }
        return (product, vendor)
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func hasStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}
