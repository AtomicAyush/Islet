import AudioToolbox
import CoreAudio
import Foundation

/// The default output's volume and mute.
///
/// Each CoreAudio call here is a round trip to the audio server, a millisecond or
/// more on Bluetooth headphones, so the work runs on a serial queue of its own and
/// reports back on the main thread; the queue also keeps a held key's steps in
/// order. What the output allows is kept on the main thread, so a key can be
/// decided on at once.
@MainActor
final class AudioOutput {
    struct Reading {
        /// 0...1. While muted, the level sound will come back at.
        let level: Double
        let isMuted: Bool
        /// The output's name as macOS shows it ("AirPods Max", "MacBook Pro Speakers").
        var deviceName: String?
    }

    /// Whether the default output has a volume the Mac can set, as last looked up.
    private(set) var canSetVolume = false
    /// Whether it can be muted, by its own control or by turning it to zero.
    private(set) var canMute = false

    private let queue = DispatchQueue(label: "Islet.SystemHUD.audio", qos: .userInteractive)
    private let worker = VolumeWorker()
    private var isFollowing = false

    /// Keeps `canSetVolume` and `canMute` current as the default output changes
    /// (headphones connecting, a display's speakers picked in Control Centre). The
    /// listener holds this object unretained: stop following before letting go.
    ///
    /// The listener is added and removed on the queue like every other CoreAudio
    /// call: the first one in the process sets up the audio client, which takes the
    /// best part of a second, and the queue keeps an add ahead of its remove.
    func startFollowing() {
        guard !isFollowing else { return }
        isFollowing = true
        queue.async { [self] in
            var address = AudioDevice.defaultOutputAddress
            let context = Unmanaged.passUnretained(self).toOpaque()
            // Unable to follow the output, the answers would go stale; leave every
            // key to macOS instead.
            guard AudioObjectAddPropertyListener(AudioDevice.system, &address, defaultOutputChanged, context) == noErr
            else { return }
            lookUpCapabilities()
        }
    }

    func stopFollowing() {
        guard isFollowing else { return }
        isFollowing = false
        canSetVolume = false
        canMute = false
        queue.async { [self] in
            var address = AudioDevice.defaultOutputAddress
            let context = Unmanaged.passUnretained(self).toOpaque()
            AudioObjectRemovePropertyListener(AudioDevice.system, &address, defaultOutputChanged, context)
        }
    }

    /// Moves the volume a step; `report` gets the result, or `nil` if it failed.
    func stepVolume(by delta: Double, report: @escaping @MainActor (Reading?) -> Void) {
        run({ $0.step(by: delta) }, report: report)
    }

    func toggleMute(report: @escaping @MainActor (Reading?) -> Void) {
        run({ $0.toggleMute() }, report: report)
    }

    func read(report: @escaping @MainActor (Reading?) -> Void) {
        run({ $0.read() }, report: report)
    }

    /// Called from any thread; answers land on the main thread.
    fileprivate nonisolated func lookUpCapabilities() {
        queue.async { [self, worker] in
            let (volume, mute) = worker.capabilities()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.isFollowing else { return }
                    self.canSetVolume = volume
                    self.canMute = mute
                }
            }
        }
    }

    private func run(_ work: @escaping @Sendable (VolumeWorker) -> Reading?, report: @escaping @MainActor (Reading?) -> Void) {
        queue.async { [worker] in
            let reading = work(worker)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { report(reading) }
            }
        }
    }
}

/// Tells the `AudioOutput` in `context` that the default output changed. A C function
/// rather than a block: Swift wraps a closure in a new block each time it is passed,
/// so a block listener could never be removed again.
private func defaultOutputChanged(
    _: AudioObjectID, _: UInt32, _: UnsafePointer<AudioObjectPropertyAddress>, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context else { return noErr }
    Unmanaged<AudioOutput>.fromOpaque(context).takeUnretainedValue().lookUpCapabilities()
    return noErr
}

/// The volume work itself. Sendable because it is only ever used on
/// `AudioOutput`'s serial queue, which is what keeps `softMuted` consistent.
private final class VolumeWorker: @unchecked Sendable {
    /// Levels of devices with no mute control, muted by turning them to zero.
    private var softMuted: [AudioObjectID: Double] = [:]

    func capabilities() -> (volume: Bool, mute: Bool) {
        let device = AudioDevice.defaultOutput
        let volume = device.canSetVolume
        return (volume, volume || device.canSetMute)
    }

    func read() -> AudioOutput.Reading? {
        let device = AudioDevice.defaultOutput
        guard let current = device.volume else { return nil }
        let restored = softMutedLevel(of: device, current: current)
        return .init(level: restored ?? current, isMuted: device.isMuted == true || restored != nil, deviceName: device.name)
    }

    /// Unmutes on the way unless the step reaches zero, which mutes, as macOS does.
    func step(by delta: Double) -> AudioOutput.Reading? {
        let device = AudioDevice.defaultOutput
        guard let current = device.volume else { return nil }
        let next = SystemHUDModel.stepped(softMutedLevel(of: device, current: current) ?? current, by: delta)
        guard device.setVolume(next) else { return nil }
        softMuted[device.id] = nil
        if let muted = device.isMuted, muted != (next == 0) {
            _ = device.setMuted(next == 0)
        }
        return .init(level: next, isMuted: next == 0, deviceName: device.name)
    }

    func toggleMute() -> AudioOutput.Reading? {
        let device = AudioDevice.defaultOutput
        if let muted = device.isMuted, device.canSetMute {
            guard device.setMuted(!muted) else { return nil }
            // An output with a mute but no volume plays at its one fixed level.
            return .init(level: device.volume ?? 1, isMuted: !muted, deviceName: device.name)
        }

        guard let current = device.volume else { return nil }
        if let restored = softMutedLevel(of: device, current: current) {
            guard device.setVolume(restored) else { return nil }
            softMuted[device.id] = nil
            return .init(level: restored, isMuted: false, deviceName: device.name)
        }
        guard device.setVolume(0) else { return nil }
        softMuted[device.id] = current
        return .init(level: current, isMuted: true, deviceName: device.name)
    }

    /// The level a device muted by zeroing had. Forgotten once it has been turned up
    /// elsewhere, so a later trip to zero by other means does not bring it back.
    private func softMutedLevel(of device: AudioDevice, current: Double) -> Double? {
        if current >= 0.001 { softMuted[device.id] = nil }
        return softMuted[device.id]
    }
}

/// One CoreAudio output device's volume and mute.
///
/// Volume goes through the virtual main volume rather than per-channel scalars: it
/// is what the Sound menu moves, it exists on devices with no main channel (AirPods,
/// most USB audio), and setting it keeps the left/right balance.
private struct AudioDevice {
    let id: AudioObjectID

    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    /// The device sound is playing through now. A cheap lookup: the answer is
    /// cached in-process by CoreAudio.
    static var defaultOutput: AudioDevice {
        AudioDevice(id: read(AudioObjectID(kAudioObjectUnknown), at: defaultOutputAddress, of: system)
            ?? AudioObjectID(kAudioObjectUnknown))
    }

    /// 0...1, or `nil` when the device has no volume (HDMI and most digital outputs).
    var volume: Double? {
        Self.read(Float32(0), at: Self.volumeAddress, of: id).map { Double(min(max($0, 0), 1)) }
    }

    var canSetVolume: Bool { Self.isSettable(Self.volumeAddress, of: id) }

    func setVolume(_ level: Double) -> Bool {
        Self.write(Float32(min(max(level, 0), 1)), at: Self.volumeAddress, of: id)
    }

    /// `nil` when the device has no mute control of its own.
    var isMuted: Bool? {
        Self.read(UInt32(0), at: Self.muteAddress, of: id).map { $0 != 0 }
    }

    var canSetMute: Bool { Self.isSettable(Self.muteAddress, of: id) }

    /// The name macOS gives the device, as in the Sound menu.
    var name: String? {
        guard id != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() as String?, !value.isEmpty
        else { return nil }
        return value
    }

    func setMuted(_ muted: Bool) -> Bool {
        Self.write(UInt32(muted ? 1 : 0), at: Self.muteAddress, of: id)
    }

    // MARK: Property access

    // No AudioObjectHasProperty first: every call is a round trip, and a missing
    // property already makes the get or set fail.

    private static func read<T: BitwiseCopyable>(_ initial: T, at address: AudioObjectPropertyAddress, of object: AudioObjectID) -> T? {
        guard object != kAudioObjectUnknown else { return nil }
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && size == MemoryLayout<T>.size ? value : nil
    }

    private static func write<T: BitwiseCopyable>(_ value: T, at address: AudioObjectPropertyAddress, of object: AudioObjectID) -> Bool {
        guard object != kAudioObjectUnknown else { return false }
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
