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

    /// A fixed-size value, or `nil` when the object is gone or has no such property.
    static func read<T: BitwiseCopyable>(
        _ initial: T,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of object: AudioObjectID
    ) -> T? {
        guard object != kAudioObjectUnknown else { return nil }
        var address = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && size == MemoryLayout<T>.size ? value : nil
    }

    static func string(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> String? {
        guard object != kAudioObjectUnknown else { return nil }
        var address = address(selector)
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
