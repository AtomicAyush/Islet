import AudioToolbox
import CoreAudio
import Foundation

/// An output's volume as the panel's slider shows it.
struct OutputVolume: Equatable, Sendable {
    /// 0...1. Full for an output with no volume of its own.
    var level: Double
    var isMuted: Bool
    /// HDMI and most digital outputs play at one fixed level, as the Sound menu's
    /// greyed-out slider says.
    var isSettable: Bool
}

/// What a listener heard.
enum OutputChange: Sendable {
    /// A device came or went, or sound moved to another one.
    case devices
    /// The followed output's volume or mute changed.
    case volume
    /// A followed headset's listening mode or spatial audio changed, from Islet, the
    /// headset's stem, Control Center or an iPhone.
    case controls
    /// The audio server started afresh, and its devices may have come back under new
    /// IDs.
    case restarted
}

/// Where the output picker gets and sets the Mac's outputs: Core Audio, or made-up
/// ones for previews and tests.
///
/// Every call is a round trip to the audio server, a millisecond or more on Bluetooth
/// headphones and longer while one is still connecting, so the picker makes them all
/// from one serial queue of its own, never the main thread; that queue is also the one
/// `listen(on:_:)` is given, and the only one a conformer is ever called on.
protocol OutputHardware: AnyObject, Sendable {
    func candidates() -> [OutputCandidate]
    /// A device's UID, or `nil` once it has gone.
    func uid(of device: AudioObjectID) -> String?
    /// The device with this UID now. A headset's ID changes when it reconnects and
    /// when the audio server restarts, so one is looked up afresh for every read and
    /// write of its controls.
    func device(uid: String) -> AudioObjectID?
    func defaultOutput() -> AudioObjectID?
    /// Where alerts and sound effects play.
    func defaultSystemOutput() -> AudioObjectID?
    func setDefaultOutput(_ device: AudioObjectID) -> OSStatus
    func setDefaultSystemOutput(_ device: AudioObjectID) -> OSStatus
    func volume(of device: AudioObjectID) -> OutputVolume?
    /// Unmutes on the way unless the level is zero, which mutes, as the Sound menu's
    /// slider does.
    func setVolume(_ level: Double, of device: AudioObjectID) -> Bool

    /// Reports changes to the device list and the default output on `queue`.
    func listen(on queue: DispatchQueue, _ changed: @escaping @Sendable (OutputChange) -> Void)
    func stopListening()
    /// Reports `device`'s volume and mute changes as well, or stops with `nil`.
    func followVolume(of device: AudioObjectID?)

    /// A headset's listening mode and spatial audio and the properties behind them,
    /// or `nil` for a device that is not an Apple headset's output.
    func readHeadset(_ device: AudioObjectID) -> HeadsetReading?
    func setListeningMode(_ mode: ListeningMode, of device: AudioObjectID) -> HeadsetControlResult
    func setSpatialAudio(_ mode: SpatialAudioMode, for content: SpatialContent, of device: AudioObjectID) -> HeadsetControlResult
    /// Reports changes to these properties of these headsets as `.controls` as well,
    /// in place of the last ones given, or stops with none. Given again after every
    /// read, since a headset's properties can appear after it connects. Returns
    /// whether it began listening anywhere, so that the headsets are read once more
    /// for a change made between that read and now, which no listener heard.
    @discardableResult
    func followControls(_ headsets: [AudioObjectID: [HeadsetProperty]]) -> Bool
}

/// The Mac's outputs, from Core Audio.
///
/// Listeners are `CoreAudioListener`s reporting on the picker's queue, so each one
/// added is taken off again; the properties are read with `MixerHAL`, whose calls
/// fail softly for a device that has gone.
final class CoreAudioOutputHardware: OutputHardware, @unchecked Sendable {
    // Confined to the picker's queue, like every call.
    private var queue: DispatchQueue?
    private var changed: (@Sendable (OutputChange) -> Void)?
    private var listener: CoreAudioListener?
    private var volumeListener: CoreAudioListener?
    private var volumeDevice: AudioObjectID?
    private let controlListeners = HeadsetListeners()
    private let headsets = HeadsetControlsReader(hal: CoreAudioHeadsetHAL())

    private static let systemProperties = [
        MixerHAL.address(kAudioHardwarePropertyDevices),
        MixerHAL.address(kAudioHardwarePropertyDefaultOutputDevice),
        MixerHAL.address(kAudioHardwarePropertyServiceRestarted),
    ]
    /// The virtual main volume is what the Sound menu's slider moves: it exists on
    /// devices with no main channel (AirPods, most USB audio), and setting it keeps
    /// the balance.
    private static let volumeAddress = MixerHAL.address(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput
    )
    private static let muteAddress = MixerHAL.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)

    deinit {
        stopListening()
    }

    // MARK: Devices

    func candidates() -> [OutputCandidate] {
        MixerHAL.objects(kAudioHardwarePropertyDevices, of: MixerHAL.system).compactMap(candidate)
    }

    private func candidate(_ id: AudioObjectID) -> OutputCandidate? {
        // Most devices are microphones, which one look at their output streams rules
        // out before any more round trips.
        let output = kAudioObjectPropertyScopeOutput
        let streams = MixerHAL.count(kAudioDevicePropertyStreams, scope: output, of: id)
        guard streams > 0, let uid = MixerHAL.string(kAudioDevicePropertyDeviceUID, of: id) else { return nil }
        let transport = MixerHAL.read(UInt32(0), kAudioDevicePropertyTransportType, of: id) ?? kAudioDeviceTransportTypeUnknown
        let isAggregate = transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate
        return OutputCandidate(
            id: id,
            uid: uid,
            name: MixerHAL.string(kAudioObjectPropertyName, of: id) ?? uid,
            transport: transport,
            modelUID: MixerHAL.string(kAudioDevicePropertyModelUID, of: id),
            outputStreams: streams,
            canBeDefault: MixerHAL.read(UInt32(0), kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: output, of: id) == 1,
            canBeSystemDefault: MixerHAL.read(UInt32(0), kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, scope: output, of: id) == 1,
            isHidden: MixerHAL.read(UInt32(0), kAudioDevicePropertyIsHidden, of: id) == 1,
            isPrivate: isAggregate && Self.isPrivateAggregate(id),
            dataSource: transport == kAudioDeviceTransportTypeBuiltIn
                ? MixerHAL.read(UInt32(0), kAudioDevicePropertyDataSource, scope: output, of: id)
                : nil
        )
    }

    private static func isPrivateAggregate(_ id: AudioObjectID) -> Bool {
        var address = MixerHAL.address(kAudioAggregateDevicePropertyComposition)
        #if DEBUG
        // Asked of a harness as `MixerHAL`'s reads are, since the device may be made up.
        if let values = MixerHAL.valuesForTesting {
            return ((values(id, address) as? [String: Any])?[kAudioAggregateDeviceIsPrivateKey] as? Int) == 1
        }
        #endif
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let composition = value?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? Int) == 1
    }

    func uid(of device: AudioObjectID) -> String? {
        MixerHAL.string(kAudioDevicePropertyDeviceUID, of: device)
    }

    func device(uid: String) -> AudioObjectID? {
        var address = MixerHAL.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { qualifier in
            AudioObjectGetPropertyData(
                MixerHAL.system, &address, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device
            )
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    func defaultOutput() -> AudioObjectID? {
        Self.device(kAudioHardwarePropertyDefaultOutputDevice)
    }

    func defaultSystemOutput() -> AudioObjectID? {
        Self.device(kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    func setDefaultOutput(_ device: AudioObjectID) -> OSStatus {
        Self.write(device, at: MixerHAL.address(kAudioHardwarePropertyDefaultOutputDevice), of: MixerHAL.system)
    }

    func setDefaultSystemOutput(_ device: AudioObjectID) -> OSStatus {
        Self.write(device, at: MixerHAL.address(kAudioHardwarePropertyDefaultSystemOutputDevice), of: MixerHAL.system)
    }

    private static func device(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        let id = MixerHAL.read(AudioObjectID(kAudioObjectUnknown), selector, of: MixerHAL.system)
        return id == kAudioObjectUnknown ? nil : id
    }

    // MARK: Volume

    func volume(of device: AudioObjectID) -> OutputVolume? {
        guard MixerHAL.uidExists(device) else { return nil }
        let muted = MixerHAL.read(UInt32(0), kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, of: device)
        guard let level = MixerHAL.read(
            Float32(0), kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, of: device
        ) else {
            return OutputVolume(level: 1, isMuted: muted == 1, isSettable: false)
        }
        return OutputVolume(
            level: Double(min(max(level, 0), 1)),
            isMuted: muted == 1,
            isSettable: Self.isSettable(Self.volumeAddress, of: device)
        )
    }

    func setVolume(_ level: Double, of device: AudioObjectID) -> Bool {
        let level = min(max(level, 0), 1)
        guard Self.write(Float32(level), at: Self.volumeAddress, of: device) == noErr else { return false }
        let muted = MixerHAL.read(UInt32(0), kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, of: device)
        if let muted, (muted == 1) != (level == 0), Self.isSettable(Self.muteAddress, of: device) {
            _ = Self.write(UInt32(level == 0 ? 1 : 0), at: Self.muteAddress, of: device)
        }
        return true
    }

    // MARK: Listening

    func listen(on queue: DispatchQueue, _ changed: @escaping @Sendable (OutputChange) -> Void) {
        guard listener == nil else { return }
        self.queue = queue
        self.changed = changed
        listener = CoreAudioListener(on: MixerHAL.system, Self.systemProperties, queue: queue) { selectors in
            changed(selectors.contains(kAudioHardwarePropertyServiceRestarted) ? .restarted : .devices)
        }
    }

    func stopListening() {
        followVolume(of: nil)
        controlListeners.removeAll()
        listener?.remove()
        listener = nil
        changed = nil
    }

    func followVolume(of device: AudioObjectID?) {
        guard device != volumeDevice else { return }
        volumeListener?.remove()
        volumeListener = nil
        volumeDevice = nil
        guard let device, let queue, let changed else { return }
        volumeDevice = device
        volumeListener = CoreAudioListener(on: device, [Self.volumeAddress, Self.muteAddress], queue: queue) { _ in
            changed(.volume)
        }
    }

    // MARK: Headset controls

    func readHeadset(_ device: AudioObjectID) -> HeadsetReading? {
        guard Self.mayHaveControls(device) else { return nil }
        return headsets.read(device)
    }

    func setListeningMode(_ mode: ListeningMode, of device: AudioObjectID) -> HeadsetControlResult {
        guard Self.mayHaveControls(device) else { return .gone }
        return headsets.setListeningMode(mode, of: device)
    }

    func setSpatialAudio(_ mode: SpatialAudioMode, for content: SpatialContent, of device: AudioObjectID) -> HeadsetControlResult {
        guard Self.mayHaveControls(device) else { return .gone }
        return headsets.setSpatialAudio(mode, for: content, of: device)
    }

    /// One listener per headset, on the properties its read has just found, so
    /// nothing is asked of it again here (see `HeadsetListeners`).
    func followControls(_ headsets: [AudioObjectID: [HeadsetProperty]]) -> Bool {
        guard let queue, let changed else {
            controlListeners.removeAll()
            return false
        }
        return controlListeners.follow(headsets) { device, properties in
            let addresses = properties.map { CoreAudioHeadsetHAL.address($0) }
            let listener = CoreAudioListener(on: device, addresses, queue: queue) { _ in changed(.controls) }
            return listener.remove
        }
    }

    /// Looks again at what the device is before asking it for a headset's private
    /// properties, since an ID can be taken by another device once its own has gone.
    private static func mayHaveControls(_ device: AudioObjectID) -> Bool {
        guard let uid = MixerHAL.string(kAudioDevicePropertyDeviceUID, of: device),
              let transport = MixerHAL.read(UInt32(0), kAudioDevicePropertyTransportType, of: device)
        else { return false }
        return HeadsetControlsReader.mayHaveControls(
            transport: transport, uid: uid, modelUID: MixerHAL.string(kAudioDevicePropertyModelUID, of: device)
        )
    }

    // MARK: Property access

    private static func write<T: BitwiseCopyable>(_ value: T, at address: AudioObjectPropertyAddress, of object: AudioObjectID) -> OSStatus {
        guard object != kAudioObjectUnknown else { return kAudioHardwareBadObjectError }
        #if DEBUG
        // A harness's made-up device can share its ID with a real one.
        if MixerHAL.isFakedForTesting { return kAudioHardwareUnsupportedOperationError }
        #endif
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    private static func isSettable(_ address: AudioObjectPropertyAddress, of object: AudioObjectID) -> Bool {
        #if DEBUG
        // Nothing can be set on a made-up device, as `write` says.
        if MixerHAL.isFakedForTesting { return false }
        #endif
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }
}

private extension MixerHAL {
    /// Whether the device is still there to ask.
    static func uidExists(_ device: AudioObjectID) -> Bool {
        string(kAudioDevicePropertyDeviceUID, of: device) != nil
    }
}
