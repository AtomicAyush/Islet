import CoreAudio
import CoreAudio.AudioServerPlugIn
import Foundation

// MARK: - Properties

/// The private Core Audio properties AirPods' output device carries for its listening
/// mode and spatial audio. macOS's Bluetooth audio plug-in serves them, and they are
/// what the Sound menu itself reads and sets: none is in the SDK, and none needs an
/// entitlement or a permission.
///
/// These and no others. The plug-in answers some of its other properties only when
/// asked with a qualifier, and one asked without crashes the audio server, taking
/// whatever is playing with it. So this is an enum rather than a selector: nothing can
/// ask a headset for anything else, and each of these is asked without a qualifier, in
/// the global scope and main element, of the headset's output device only.
///
/// Which of them take no qualifier was worked out from the plug-in on macOS 27, and a
/// crash inside the plug-in is not something `AudioObjectHasProperty` or a size check
/// can stop. So they are asked only on macOS 27, not before it or after it
/// (`HeadsetControlsReader.isCheckedSystem`), and only those the plug-in's own list of
/// its properties gives as plain data with no qualifier (`HeadsetHAL.plainProperties`).
/// That list is how the audio server itself learns what to pass a plug-in, and on
/// macOS 27 it gives every one of these so; it does not name every property that reads
/// a qualifier, so it narrows what is asked rather than vouching for it.
enum HeadsetProperty: AudioObjectPropertySelector, CaseIterable, Sendable {
    /// `'lstm'`, UInt32: the listening mode, as `ListeningMode`'s raw values; 0 while
    /// it is not known. Settable.
    case listeningMode = 0x6C73_746D
    /// `'lsms'`, UInt32: the modes the headset has, 0x1 Noise Cancellation, 0x2
    /// Transparency and 0x4 Adaptive. Off is never in it. Every Bluetooth output has
    /// this property, so its value is what tells.
    case listeningModes = 0x6C73_6D73
    /// `'iesb'`, two UInt32s: where each bud is, 1 in an ear, 2 out, 3 in the case and
    /// 0 unknown.
    case inEar = 0x6965_7362
    /// `'iede'`, UInt32: automatic ear detection, 1 while it is on.
    case earDetection = 0x6965_6465
    /// `'spap'`, UInt32: the headset does spatial audio. The plug-in ignores a spatial
    /// write to one that does not.
    case spatialSupported = 0x7370_6170
    /// `'spsv'`, UInt32: Spatialize Stereo is on offer, because stereo is playing
    /// through the headset.
    case stereoAvailable = 0x7370_7376
    /// `'spss'`, UInt32 to read, a `SpatialAudioRequest` to set: Spatialize Stereo.
    case stereoSpatialized = 0x7370_7373
    /// `'spav'`, UInt32: Spatial Audio is on offer, for multichannel sound.
    case multichannelAvailable = 0x7370_6176
    /// `'spcs'`, UInt32 to read, a `SpatialAudioRequest` to set: Spatial Audio.
    case multichannelSpatialized = 0x7370_6373
    /// `'htst'`, UInt32: head tracking is on for the app being spatialized.
    case headTracking = 0x6874_7374
    /// `'htav'`, UInt32: head tracking can be had.
    case headTrackingAvailable = 0x6874_6176
    /// `'htac'`, UInt32: head tracking is offered, as Control Center reads it.
    case headTrackingOffered = 0x6874_6163
    /// `'iass'`, UInt32: the playing audio session is spatial. Only listened to: it
    /// changes alongside the others.
    case sessionIsSpatial = 0x6961_7373
    /// `'acsc'`, Int32: the process whose sound is spatialized, negative for none.
    case spatialApp = 0x6163_7363
}

/// Core Audio calls on a headset's output device, for a `HeadsetProperty` and nothing
/// else: the real ones, or made-up ones for previews and tests.
protocol HeadsetHAL: Sendable {
    /// The properties the plug-in's list of its custom properties (`'cust'`) gives as
    /// plain data taking no qualifier; empty when the list cannot be read. Asked first
    /// on every look at a headset: nothing else is asked about a property left out.
    func plainProperties(of object: AudioObjectID) -> Set<HeadsetProperty>
    func has(_ property: HeadsetProperty, on object: AudioObjectID) -> Bool
    /// Exactly `size` bytes, or `nil` when the read fails or answers with another size.
    func read(_ property: HeadsetProperty, on object: AudioObjectID, size: Int) -> [UInt8]?
    func isSettable(_ property: HeadsetProperty, on object: AudioObjectID) -> Bool
    func write(_ bytes: [UInt8], to property: HeadsetProperty, on object: AudioObjectID) -> OSStatus
}

/// The headset's properties, from Core Audio.
struct CoreAudioHeadsetHAL: HeadsetHAL {
    /// `'cust'` (`kAudioObjectPropertyCustomPropertyInfoList`), asked as the others
    /// are: global scope, main element, no qualifier, and only once the object says it
    /// has it. A headset lists about a hundred properties, 12 bytes each.
    func plainProperties(of object: AudioObjectID) -> Set<HeadsetProperty> {
        guard object != kAudioObjectUnknown else { return [] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyCustomPropertyInfoList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let stride = MemoryLayout<AudioServerPlugInCustomPropertyInfo>.stride
        var size: UInt32 = 0
        guard AudioObjectHasProperty(object, &address),
              AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0, size <= Self.listLimit, Int(size) % stride == 0
        else { return [] }
        var list = [AudioServerPlugInCustomPropertyInfo](repeating: .init(), count: Int(size) / stride)
        var ioSize = size
        let status = list.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &ioSize, base)
        }
        guard status == noErr, ioSize <= size, Int(ioSize) % stride == 0 else { return [] }
        return Self.plain(in: list.prefix(Int(ioSize) / stride))
    }

    /// Far more than any headset lists; a larger answer is not taken for a list.
    private static let listLimit: UInt32 = 64 * 1024
    /// The Bluetooth plug-in's data type for a property that is plain bytes. The SDK
    /// has no name for it; its own for plain data,
    /// `kAudioServerPlugInCustomPropertyDataTypeNone`, is taken as well.
    static let rawDataType: AudioServerPlugInCustomPropertyDataType = 0x7261_7777 // 'raww'

    /// The properties a list gives as plain data taking no qualifier, and nowhere as
    /// anything else.
    static func plain(in list: some Sequence<AudioServerPlugInCustomPropertyInfo>) -> Set<HeadsetProperty> {
        var plain: Set<HeadsetProperty> = []
        var other: Set<HeadsetProperty> = []
        for info in list {
            guard let property = HeadsetProperty(rawValue: info.mSelector) else { continue }
            let isPlain = info.mQualifierDataType == kAudioServerPlugInCustomPropertyDataTypeNone
                && (info.mPropertyDataType == rawDataType || info.mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeNone)
            if isPlain { plain.insert(property) } else { other.insert(property) }
        }
        return plain.subtracting(other)
    }

    func has(_ property: HeadsetProperty, on object: AudioObjectID) -> Bool {
        guard object != kAudioObjectUnknown else { return false }
        var address = Self.address(property)
        return AudioObjectHasProperty(object, &address)
    }

    func read(_ property: HeadsetProperty, on object: AudioObjectID, size: Int) -> [UInt8]? {
        guard object != kAudioObjectUnknown, size > 0 else { return nil }
        var address = Self.address(property)
        var bytes = [UInt8](repeating: 0, count: size)
        var ioSize = UInt32(size)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &ioSize, base)
        }
        return status == noErr && ioSize == UInt32(size) ? bytes : nil
    }

    func isSettable(_ property: HeadsetProperty, on object: AudioObjectID) -> Bool {
        guard object != kAudioObjectUnknown else { return false }
        var address = Self.address(property)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    func write(_ bytes: [UInt8], to property: HeadsetProperty, on object: AudioObjectID) -> OSStatus {
        guard object != kAudioObjectUnknown else { return kAudioHardwareBadObjectError }
        var address = Self.address(property)
        return bytes.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(buffer.count), base)
        }
    }

    static func address(_ property: HeadsetProperty) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: property.rawValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

// MARK: - Listening mode

/// AirPods' listening modes, with the plug-in's values for them.
enum ListeningMode: UInt32, CaseIterable, Sendable {
    case off = 1
    case noiseCancellation = 2
    case transparency = 3
    case adaptive = 4

    /// The Sound menu's order.
    static let menuOrder: [ListeningMode] = [.off, .transparency, .adaptive, .noiseCancellation]

    var title: String {
        switch self {
        case .off: "Off"
        case .noiseCancellation: "Noise Cancellation"
        case .transparency: "Transparency"
        case .adaptive: "Adaptive"
        }
    }

    /// The Sound menu's pictures are private; these public symbols are drawn the same
    /// way, a person in a ring: open for Transparency, closed for Noise Cancellation,
    /// and both for Adaptive, which moves between the two.
    var symbol: String {
        switch self {
        case .off: "person.fill"
        case .noiseCancellation: "person.crop.circle"
        case .transparency: "person.crop.circle.dashed"
        case .adaptive: "person.crop.circle.dashed.circle"
        }
    }

    /// The mode's bit in `'lsms'`; Off has none.
    var supportBit: UInt32? {
        switch self {
        case .off: nil
        case .noiseCancellation: 0x1
        case .transparency: 0x2
        case .adaptive: 0x4
        }
    }

    /// Noise Cancellation and Adaptive work only with both buds in. macOS refuses
    /// Noise Cancellation otherwise; Adaptive it records as set and broadcasts as
    /// such, while the AirPods stay as they were and nothing ever corrects it. So
    /// neither is asked for unless both buds are in.
    var needsBothInEar: Bool {
        self == .noiseCancellation || self == .adaptive
    }
}

/// A headset's listening modes as Core Audio reports them.
struct ListeningModeState: Equatable, Sendable {
    /// `'lsms'`.
    var support: UInt32
    /// `nil` while the headset has not said.
    var current: ListeningMode?
    var isSettable: Bool
    /// Both buds are in, or ear detection is off, so every mode may be asked for.
    var isWorn: Bool

    func supports(_ mode: ListeningMode) -> Bool {
        mode.supportBit.map { support & $0 != 0 } ?? false
    }

    /// The modes to offer, in the Sound menu's order: the headset's, the current one
    /// whatever it is, and Off where it is allowed. Whether AirPods allow Off is a
    /// setting of theirs no other app may read, so Off is offered only while it is the
    /// mode, or once it has been seen (`allowsOff`).
    func offered(allowsOff: Bool) -> [ListeningMode] {
        ListeningMode.menuOrder.filter { mode in
            mode == current || supports(mode) || (mode == .off && allowsOff)
        }
    }

    /// The bits of `'lsms'` that are modes.
    static let supportMask: UInt32 = 0b111
}

// MARK: - Spatial audio

/// What is playing, which decides the Sound menu's row and the property behind it.
enum SpatialContent: Equatable, Sendable {
    /// "Spatialize Stereo", `'spss'`.
    case stereo
    /// "Spatial Audio", `'spcs'`.
    case multichannel

    var title: String {
        switch self {
        case .stereo: "Spatialize Stereo"
        case .multichannel: "Spatial Audio"
        }
    }

    var property: HeadsetProperty {
        switch self {
        case .stereo: .stereoSpatialized
        case .multichannel: .multichannelSpatialized
        }
    }
}

/// The Sound menu's three choices for spatial audio.
enum SpatialAudioMode: CaseIterable, Sendable {
    case off, fixed, headTracked

    var title: String {
        switch self {
        case .off: "Off"
        case .fixed: "Fixed"
        case .headTracked: "Head Tracked"
        }
    }

    func symbol(for content: SpatialContent) -> String {
        switch (self, content) {
        case (.off, _): "person.fill"
        case (.fixed, .stereo): "person.spatialaudio.stereo.fill"
        case (.fixed, .multichannel): "person.spatialaudio.fill"
        case (.headTracked, .stereo): "person.spatialaudio.stereo.3d.fill"
        case (.headTracked, .multichannel): "person.spatialaudio.3d.fill"
        }
    }
}

/// A headset's spatial audio as Core Audio reports it, while something it can
/// spatialize is playing.
struct SpatialAudioState: Equatable, Sendable {
    var content: SpatialContent
    var mode: SpatialAudioMode
    /// `'htst'` as it is, which an Off request hands back unchanged.
    var isHeadTracked: Bool
    var offersHeadTracking: Bool
    /// `'acsc'`: the app whose sound is spatialized. Spatial audio is set per app,
    /// and a request names it.
    var app: Int32
    var isSettable: Bool

    /// Off and Fixed, and Head Tracked where the headset offers it or has it on.
    var offered: [SpatialAudioMode] {
        SpatialAudioMode.allCases.filter { $0 != .headTracked || offersHeadTracking || mode == .headTracked }
    }

    /// Control Center's reading: off, or on and fixed, or on and following the head.
    static func mode(isOn: Bool, headTracked: Bool) -> SpatialAudioMode {
        guard isOn else { return .off }
        return headTracked ? .headTracked : .fixed
    }
}

/// What Control Center writes to `'spss'` or `'spcs'`: eight bytes, the app's process
/// ID, then a byte each for head tracking and for on, then two of padding.
///
/// The layout was read out of Control Center and the plug-in, not tried on a headset,
/// so a request may miss. A miss does no harm: the plug-in checks only the size and
/// drops a request for an app it is not spatializing, a refusal only puts up a line
/// for a few seconds, and the row never shows a choice as made before Core Audio
/// reports it, so it goes on showing the headset as it is.
struct SpatialAudioRequest: Equatable, Sendable {
    var app: Int32
    var headTracked: Bool
    var isOn: Bool

    /// Off keeps head tracking as it is; Fixed and Head Tracked turn it off and on.
    init(_ mode: SpatialAudioMode, from state: SpatialAudioState) {
        app = state.app
        switch mode {
        case .off:
            headTracked = state.isHeadTracked
            isOn = false
        case .fixed:
            headTracked = false
            isOn = true
        case .headTracked:
            headTracked = true
            isOn = true
        }
    }

    var bytes: [UInt8] {
        withUnsafeBytes(of: UInt32(bitPattern: app).littleEndian, Array.init)
            + [headTracked ? 1 : 0, isOn ? 1 : 0, 0, 0]
    }
}

// MARK: - Reading and setting

/// A headset's listening mode and spatial audio, where it has either.
struct HeadsetControls: Equatable, Sendable {
    var listening: ListeningModeState?
    var spatial: SpatialAudioState?
}

/// A read of a headset: its controls, and the properties to listen to for them.
struct HeadsetReading: Equatable, Sendable {
    /// `nil` for a headset with neither control.
    var controls: HeadsetControls?
    /// Those it has now, in `HeadsetProperty`'s order. `'lstm'` is among them once
    /// `'lsms'` turns nonzero, which is heard, and the headset read again.
    var listened: [HeadsetProperty]
}

/// How setting a headset's control went.
enum HeadsetControlResult: Equatable, Sendable {
    case done
    /// The headset went before the click: put back in its case, or disconnected.
    case gone
    /// It no longer offers what was clicked.
    case unavailable
    /// Noise Cancellation or Adaptive, with a bud out: not asked for.
    case needsBothInEar
    /// Core Audio would not have it: `'nope'` for Noise Cancellation with a bud out,
    /// `'unop'` for Noise Cancellation or Transparency while the plug-in has its
    /// far-field mode on, `'stop'` while the headset's link is not up.
    case refused(OSStatus)
}

/// One look at a headset, taken afresh for every read and every write: the
/// properties its plug-in lists as plain data taking no qualifier, and of those the
/// ones it says it has now. Nothing outside `plain` is asked about, and nothing
/// outside `present` is read, asked whether it can be set, written or listened to.
struct HeadsetLook: Sendable {
    let object: AudioObjectID
    let plain: Set<HeadsetProperty>
    let present: Set<HeadsetProperty>
}

/// Reads and sets a headset's controls through a `HeadsetHAL`: the plug-in's list
/// of its properties first, then whether each is there, and only then a read, whose
/// size is checked.
struct HeadsetControlsReader: Sendable {
    let hal: any HeadsetHAL

    /// Whether this Mac's macOS is the one the properties were checked on (see
    /// `HeadsetProperty`): macOS 27, and not a later one, whose plug-in may want a
    /// qualifier with one of them without its list saying so. A new major release
    /// takes these controls in only once the plug-in's list and the properties it
    /// reads a qualifier for have been checked on it again. On any other macOS no
    /// headset is asked anything, and the panel shows no controls.
    static var isCheckedSystem: Bool {
        if #available(macOS 28, *) { return false }
        if #available(macOS 27, *) { return true }
        return false
    }

    /// Whether a Core Audio device may have these properties at all: an Apple
    /// headset's output half, on classic Bluetooth, on a checked macOS. Nothing else
    /// is ever asked.
    static func mayHaveControls(transport: UInt32, uid: String, modelUID: String?) -> Bool {
        isCheckedSystem
            && transport == kAudioDeviceTransportTypeBluetooth
            && uid.lowercased().hasSuffix(":output")
            && modelUID.flatMap(BluetoothAudioWatcher.parseModelUID)?.vendor == 0x004C
    }

    func look(at object: AudioObjectID) -> HeadsetLook {
        let plain = hal.plainProperties(of: object)
        let present = HeadsetProperty.allCases.filter { plain.contains($0) && hal.has($0, on: object) }
        return HeadsetLook(object: object, plain: plain, present: Set(present))
    }

    /// The controls and what to listen to, from one look.
    func read(_ object: AudioObjectID) -> HeadsetReading {
        let look = look(at: object)
        let controls = HeadsetControls(listening: listeningModes(look), spatial: spatialAudio(look))
        return HeadsetReading(
            controls: controls.listening == nil && controls.spatial == nil ? nil : controls,
            listened: HeadsetProperty.allCases.filter(look.present.contains)
        )
    }

    /// The listening modes, for a headset that has any: a nonzero `'lsms'` and an
    /// `'lstm'`, which the plug-in has only while `'lsms'` is nonzero.
    func listeningModes(_ look: HeadsetLook) -> ListeningModeState? {
        guard let support = uint32(.listeningModes, look), support & ListeningModeState.supportMask != 0,
              let current = uint32(.listeningMode, look)
        else { return nil }
        return ListeningModeState(
            support: support,
            current: ListeningMode(rawValue: current),
            isSettable: hal.isSettable(.listeningMode, on: look.object),
            isWorn: isWorn(look)
        )
    }

    /// Both buds in, or ear detection off. Off only on the headset's word: a plug-in
    /// that lists `'iede'` as plain but has none on this headset, or one that reads
    /// other than 1. An `'iede'` that is there but cannot be read counts as on, like
    /// one the list leaves out, so that no failed read lets Noise Cancellation or
    /// Adaptive through with a bud out.
    private func isWorn(_ look: HeadsetLook) -> Bool {
        let hasNoDetection = look.plain.contains(.earDetection) && !look.present.contains(.earDetection)
        let detectionIsOff = hasNoDetection || (uint32(.earDetection, look).map { $0 != 1 } ?? false)
        guard !detectionIsOff else { return true }
        guard let buds = pair(.inEar, look) else { return false }
        return buds.0 == 1 && buds.1 == 1
    }

    /// Spatial audio, while the Sound menu would show its row: Spatialize Stereo for
    /// stereo, Spatial Audio for multichannel.
    func spatialAudio(_ look: HeadsetLook) -> SpatialAudioState? {
        guard uint32(.spatialSupported, look) == 1 else { return nil }
        let content: SpatialContent
        if flag(.stereoAvailable, look) {
            content = .stereo
        } else if flag(.multichannelAvailable, look) {
            content = .multichannel
        } else {
            return nil
        }
        // Read before it is asked whether it can be set, as every property is.
        guard let isOn = uint32(content.property, look) else { return nil }
        let headTracked = flag(.headTracking, look)
        let offered = (uint32(.headTrackingOffered, look) ?? 1) != 0
            && (uint32(.headTrackingAvailable, look) ?? 1) != 0
        return SpatialAudioState(
            content: content,
            mode: SpatialAudioState.mode(isOn: isOn != 0, headTracked: headTracked),
            isHeadTracked: headTracked,
            offersHeadTracking: offered,
            app: int32(.spatialApp, look) ?? -1,
            isSettable: hal.isSettable(content.property, on: look.object)
        )
    }

    /// Sets the listening mode, looking at the headset once more first: a mode it
    /// does not have, or Noise Cancellation or Adaptive with a bud out, is not asked
    /// for. Off is not in `'lsms'`, so the caller decides whether to offer it.
    ///
    /// On success the plug-in has already taken the new mode as the current one and
    /// said so, which the listener hears; bluetoothd then sends it to the headset.
    func setListeningMode(_ mode: ListeningMode, of object: AudioObjectID) -> HeadsetControlResult {
        guard let state = listeningModes(look(at: object)), state.isSettable,
              mode == .off || state.supports(mode)
        else { return .unavailable }
        guard !mode.needsBothInEar || state.isWorn else { return .needsBothInEar }
        guard state.current != mode else { return .done }
        let status = hal.write(withUnsafeBytes(of: mode.rawValue.littleEndian, Array.init), to: .listeningMode, on: object)
        return status == noErr ? .done : .refused(status)
    }

    /// Asks for spatial audio as Control Center does, for the app being spatialized.
    /// Untried on a headset: see `SpatialAudioRequest` for why a request that misses
    /// changes nothing.
    func setSpatialAudio(_ mode: SpatialAudioMode, for content: SpatialContent, of object: AudioObjectID) -> HeadsetControlResult {
        guard let state = spatialAudio(look(at: object)), state.content == content, state.isSettable,
              state.app > 0, state.offered.contains(mode)
        else { return .unavailable }
        guard state.mode != mode else { return .done }
        let status = hal.write(SpatialAudioRequest(mode, from: state).bytes, to: content.property, on: object)
        return status == noErr ? .done : .refused(status)
    }

    // MARK: Values

    private func uint32(_ property: HeadsetProperty, _ look: HeadsetLook) -> UInt32? {
        guard look.present.contains(property), let bytes = hal.read(property, on: look.object, size: 4) else { return nil }
        return Self.uint32(bytes, at: 0)
    }

    private func int32(_ property: HeadsetProperty, _ look: HeadsetLook) -> Int32? {
        uint32(property, look).map { Int32(bitPattern: $0) }
    }

    private func flag(_ property: HeadsetProperty, _ look: HeadsetLook) -> Bool {
        (uint32(property, look) ?? 0) != 0
    }

    private func pair(_ property: HeadsetProperty, _ look: HeadsetLook) -> (UInt32, UInt32)? {
        guard look.present.contains(property), let bytes = hal.read(property, on: look.object, size: 8) else { return nil }
        return (Self.uint32(bytes, at: 0), Self.uint32(bytes, at: 4))
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, index in value | UInt32(bytes[offset + index]) << (8 * UInt32(index)) }
    }
}

// MARK: - Listening

/// The listeners on the headsets being followed: one per headset, on the properties
/// its last read found, replaced only when those change and taken off once it is no
/// longer followed, say under an ID it had before reconnecting. Confined to the
/// picker's queue, like the hardware that owns it.
final class HeadsetListeners {
    /// Adds a listener on these properties of a headset, returning what takes it off.
    typealias Add = (AudioObjectID, [HeadsetProperty]) -> () -> Void

    private var listening: [AudioObjectID: (properties: [HeadsetProperty], remove: () -> Void)] = [:]

    /// What is listened to now, by headset.
    var followed: [AudioObjectID: [HeadsetProperty]] {
        listening.mapValues(\.properties)
    }

    deinit {
        removeAll()
    }

    /// Listens to these headsets' properties and no others: a listener whose headset
    /// has gone or whose properties have changed comes off before any is added.
    /// Returns whether it added one, for a listener goes on only after the read that
    /// found its properties, and a change made in between is never heard.
    @discardableResult
    func follow(_ headsets: [AudioObjectID: [HeadsetProperty]], add: Add) -> Bool {
        for (device, entry) in listening where headsets[device] != entry.properties {
            entry.remove()
            listening[device] = nil
        }
        var added = false
        for (device, properties) in headsets where listening[device] == nil && !properties.isEmpty {
            listening[device] = (properties, add(device, properties))
            added = true
        }
        return added
    }

    func removeAll() {
        for entry in listening.values { entry.remove() }
        listening = [:]
    }
}
