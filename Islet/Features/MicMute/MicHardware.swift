import CoreAudio
import Foundation

/// What a listener heard.
enum MicChange: Sendable {
    /// The Mac's input moved to another microphone, or a device came or went.
    case devices
    /// The held microphone's mute or level changed.
    case level
    /// The audio server started afresh, and its devices may have come back under new
    /// IDs, with their mute and levels as it remembers them.
    case restarted
}

/// One of a microphone's input levels that can be set: its main one, or one channel's.
struct MicLevelControl: Equatable, Sendable {
    var element: AudioObjectPropertyElement
    /// The quietest the level goes, in decibels, where the device says. A microphone's
    /// level is often a gain, whose floor is some way above silence: the MacBook's own
    /// goes from −12 to +12 dB, so at zero it still hears the room.
    var floorDecibels: Float32?
}

/// Where Mic Mute gets and sets the Mac's input: Core Audio, or made-up microphones for
/// tests.
///
/// Only public properties of a device's input are ever asked for or set: its mute and
/// its level (`kAudioDevicePropertyMute` and `kAudioDevicePropertyVolumeScalar`), on
/// AirPods and other Bluetooth microphones as on any other. One that has neither cannot
/// be muted. Nothing opens an input stream or makes a tap, either of which would light
/// the orange dot.
///
/// Every call is a round trip to the audio server, a millisecond or more on Bluetooth,
/// so Mic Mute makes them all from one serial queue of its own; that queue is also the
/// one `listen(on:_:)` is given, and the only one a conformer is ever called on.
protocol MicHardware: AnyObject, Sendable {
    /// The Mac's input: the microphone every app records from unless it picks another.
    func defaultInput() -> AudioObjectID?
    /// A device's UID, or `nil` once it has gone.
    func uid(of device: AudioObjectID) -> String?
    /// The device with this UID now, which may be a different ID from the last time.
    func device(uid: String) -> AudioObjectID?
    func name(of device: AudioObjectID) -> String?

    /// The input's own mute, or `nil` for a device without one that can be set.
    func mute(of device: AudioObjectID) -> Bool?
    /// Returns whether the write was taken, which is not to say the device heeded it.
    func setMute(_ muted: Bool, of device: AudioObjectID) -> Bool
    /// The input levels that can be set: the main one where there is one, otherwise
    /// each channel's, where every channel has one.
    func levelControls(of device: AudioObjectID) -> [MicLevelControl]
    /// 0...1.
    func level(of device: AudioObjectID, element: AudioObjectPropertyElement) -> Float32?
    func setLevel(_ level: Float32, of device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool

    /// Reports changes to the device list and the Mac's input on `queue`.
    func listen(on queue: DispatchQueue, _ changed: @escaping @Sendable (MicChange) -> Void)
    func stopListening()
    /// Reports `device`'s mute and level changes as well, or stops with `nil`.
    func follow(_ device: AudioObjectID?)
}

/// The Mac's microphones, from Core Audio.
///
/// Listeners are `CoreAudioListener`s reporting on Mic Mute's queue, so each one added
/// is taken off again.
final class CoreAudioMicHardware: MicHardware, @unchecked Sendable {
    // Confined to Mic Mute's queue, like every call.
    private var queue: DispatchQueue?
    private var changed: (@Sendable (MicChange) -> Void)?
    private var listener: CoreAudioListener?
    private var levelListener: CoreAudioListener?
    private var followed: AudioObjectID?

    #if DEBUG
    /// Set by harnesses, which may read the real microphone but must never change it:
    /// every write then fails without reaching the audio server.
    static var writesBlockedForTesting = false
    #endif

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let input = kAudioObjectPropertyScopeInput
    /// The most channels looked at for levels of their own; a microphone has one or
    /// two, an audio interface a handful. A device with more is one Islet cannot mute,
    /// rather than one muted on some channels and hearing on the rest.
    static let channelLimit = 64

    private static let systemProperties = [
        address(kAudioHardwarePropertyDefaultInputDevice),
        address(kAudioHardwarePropertyDevices),
        address(kAudioHardwarePropertyServiceRestarted),
    ]

    deinit {
        stopListening()
    }

    // MARK: Devices

    func defaultInput() -> AudioObjectID? {
        let id = Self.read(AudioObjectID(kAudioObjectUnknown), at: Self.address(kAudioHardwarePropertyDefaultInputDevice), of: Self.system)
        return id == kAudioObjectUnknown ? nil : id
    }

    func uid(of device: AudioObjectID) -> String? {
        Self.string(kAudioDevicePropertyDeviceUID, of: device)
    }

    func device(uid: String) -> AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { qualifier in
            AudioObjectGetPropertyData(Self.system, &address, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    func name(of device: AudioObjectID) -> String? {
        Self.string(kAudioObjectPropertyName, of: device)
    }

    // MARK: Mute and level

    func mute(of device: AudioObjectID) -> Bool? {
        let address = Self.address(kAudioDevicePropertyMute, scope: Self.input)
        guard Self.isSettable(address, of: device) else { return nil }
        return Self.read(UInt32(0), at: address, of: device).map { $0 != 0 }
    }

    func setMute(_ muted: Bool, of device: AudioObjectID) -> Bool {
        Self.write(UInt32(muted ? 1 : 0), at: Self.address(kAudioDevicePropertyMute, scope: Self.input), of: device)
    }

    func levelControls(of device: AudioObjectID) -> [MicLevelControl] {
        if let main = Self.levelControl(of: device, element: kAudioObjectPropertyElementMain) { return [main] }
        return Self.everyChannel(Self.inputChannels(of: device)) { Self.levelControl(of: device, element: $0) }
    }

    /// Each of `channels` channels' level control, or none at all: a channel that cannot
    /// be turned down, or one past `channelLimit` that is never looked at, would go on
    /// hearing. Stops at the first channel without one.
    static func everyChannel(
        _ channels: Int, _ control: (AudioObjectPropertyElement) -> MicLevelControl?
    ) -> [MicLevelControl] {
        guard channels > 0, channels <= channelLimit else { return [] }
        var controls: [MicLevelControl] = []
        for channel in 1...channels {
            guard let found = control(AudioObjectPropertyElement(channel)) else { return [] }
            controls.append(found)
        }
        return controls
    }

    func level(of device: AudioObjectID, element: AudioObjectPropertyElement) -> Float32? {
        Self.read(Float32(0), at: Self.address(kAudioDevicePropertyVolumeScalar, scope: Self.input, element: element), of: device)
            .map { min(max($0, 0), 1) }
    }

    func setLevel(_ level: Float32, of device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        let address = Self.address(kAudioDevicePropertyVolumeScalar, scope: Self.input, element: element)
        return Self.write(min(max(level, 0), 1), at: address, of: device)
    }

    private static func levelControl(of device: AudioObjectID, element: AudioObjectPropertyElement) -> MicLevelControl? {
        guard isSettable(address(kAudioDevicePropertyVolumeScalar, scope: input, element: element), of: device) else { return nil }
        let range = read(AudioValueRange(), at: address(kAudioDevicePropertyVolumeRangeDecibels, scope: input, element: element), of: device)
        return MicLevelControl(element: element, floorDecibels: range.map { Float32($0.mMinimum) })
    }

    /// How many channels the device's input streams carry between them.
    private static func inputChannels(of device: AudioObjectID) -> Int {
        guard device != kAudioObjectUnknown else { return 0 }
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: input)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: Listening

    func listen(on queue: DispatchQueue, _ changed: @escaping @Sendable (MicChange) -> Void) {
        guard listener == nil else { return }
        self.queue = queue
        self.changed = changed
        listener = CoreAudioListener(on: Self.system, Self.systemProperties, queue: queue) { selectors in
            changed(selectors.contains(kAudioHardwarePropertyServiceRestarted) ? .restarted : .devices)
        }
    }

    func stopListening() {
        follow(nil)
        listener?.remove()
        listener = nil
        changed = nil
    }

    /// Any channel's level, as well as the main one's.
    func follow(_ device: AudioObjectID?) {
        guard device != followed else { return }
        levelListener?.remove()
        levelListener = nil
        followed = nil
        guard let device, let queue, let changed else { return }
        followed = device
        let addresses = [
            Self.address(kAudioDevicePropertyMute, scope: Self.input),
            Self.address(kAudioDevicePropertyVolumeScalar, scope: Self.input, element: kAudioObjectPropertyElementWildcard),
        ]
        levelListener = CoreAudioListener(on: device, addresses, queue: queue) { _ in changed(.level) }
    }

    // MARK: Property access

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // No AudioObjectHasProperty first: every call is a round trip, and a missing
    // property already makes the get, set or settable check fail.

    private static func read<T: BitwiseCopyable>(_ initial: T, at address: AudioObjectPropertyAddress, of object: AudioObjectID) -> T? {
        guard object != kAudioObjectUnknown else { return nil }
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && size == MemoryLayout<T>.size ? value : nil
    }

    private static func string(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> String? {
        guard object != kAudioObjectUnknown else { return nil }
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty
        else { return nil }
        return string
    }

    private static func write<T: BitwiseCopyable>(_ value: T, at address: AudioObjectPropertyAddress, of object: AudioObjectID) -> Bool {
        guard object != kAudioObjectUnknown else { return false }
        #if DEBUG
        if writesBlockedForTesting { return false }
        #endif
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    private static func isSettable(_ address: AudioObjectPropertyAddress, of object: AudioObjectID) -> Bool {
        guard object != kAudioObjectUnknown else { return false }
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }
}
