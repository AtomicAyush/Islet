import CoreAudio
import Foundation

/// Property access for the mixer's CoreAudio objects. Every call is a round trip to
/// the audio server, so callers ask only for what has changed, and only from the
/// mixer's own queue.
enum MixerHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    #if DEBUG
    /// Answers `read`, `string`, `objects` and `count`, and the output picker's one read
    /// of its own, in place of the audio server, for harnesses that make up processes and
    /// devices: an object's value at an address, as the call would return it, or `nil`
    /// for none. Set before anything asks.
    ///
    /// Only reads are made up; listeners are faked apart, by
    /// `CoreAudioListener.registrarForTesting`. Everything else, from setting a volume
    /// or the default output to making a tap, would still go to the audio server, where
    /// a made-up ID can name a real device, so while this is set those calls fail
    /// without making it: see `isFakedForTesting`.
    static var valuesForTesting: ((AudioObjectID, AudioObjectPropertyAddress) -> Any?)?

    /// Whether a harness has made the audio objects up, so that whatever would change
    /// or tap one must fail rather than reach a real object that shares its ID.
    static var isFakedForTesting: Bool { valuesForTesting != nil }
    #endif

    /// A fixed-size value, or `nil` when the object is gone or has no such property.
    static func read<T: BitwiseCopyable>(
        _ initial: T,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of object: AudioObjectID
    ) -> T? {
        guard object != kAudioObjectUnknown else { return nil }
        var address = address(selector, scope: scope)
        #if DEBUG
        if let valuesForTesting { return valuesForTesting(object, address) as? T }
        #endif
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && size == MemoryLayout<T>.size ? value : nil
    }

    static func string(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> String? {
        guard object != kAudioObjectUnknown else { return nil }
        var address = address(selector)
        #if DEBUG
        if let valuesForTesting { return valuesForTesting(object, address) as? String }
        #endif
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty
        else { return nil }
        return string
    }

    /// A list of objects: the system's processes, a device's streams.
    static func objects(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of object: AudioObjectID
    ) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        #if DEBUG
        if let valuesForTesting { return valuesForTesting(object, address) as? [AudioObjectID] ?? [] }
        #endif
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        let status = ids.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, base)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(size) / stride))
    }

    /// How many objects a list property holds, without fetching them.
    static func count(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of object: AudioObjectID
    ) -> Int {
        var address = address(selector, scope: scope)
        #if DEBUG
        if let valuesForTesting { return (valuesForTesting(object, address) as? [AudioObjectID])?.count ?? 0 }
        #endif
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.stride
    }
}

/// The device sound plays through, as a tap's aggregate device needs it.
struct MixerOutputDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    /// Input streams of the device's own, like a USB headset's microphone. They come
    /// ahead of the tap's in the aggregate device's input.
    let inputStreams: Int

    static func current() -> MixerOutputDevice? {
        guard let id = MixerHAL.read(
            AudioObjectID(kAudioObjectUnknown), kAudioHardwarePropertyDefaultOutputDevice, of: MixerHAL.system
        ), id != kAudioObjectUnknown,
              let uid = MixerHAL.string(kAudioDevicePropertyDeviceUID, of: id)
        else { return nil }
        let inputs = MixerHAL.count(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: id)
        return MixerOutputDevice(id: id, uid: uid, inputStreams: inputs)
    }
}
