import CoreAudio
import Foundation
import IOKit.ps

/// A Core Audio device as the output list reads it, before anything is decided
/// about showing it.
struct OutputCandidate: Equatable, Sendable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var transport: UInt32
    /// Bluetooth devices give "<product id> <vendor id>" in hex ("2024 4c" for AirPods
    /// Pro 2); AirPlay receivers their model ("AppleTV14,1").
    var modelUID: String?
    var outputStreams = 1
    var canBeDefault = true
    /// Whether macOS will play alerts and sound effects through it.
    var canBeSystemDefault = true
    var isHidden = false
    /// An aggregate device made private to the process that made it: one of Islet's
    /// own taps, or something another app would not want listed.
    var isPrivate = false
    /// What the built-in output plays through, where one device is both the speakers
    /// and the headphone jack (`'hdpn'` for the jack).
    var dataSource: UInt32?
}

/// One row of the output list.
struct OutputDevice: Identifiable, Equatable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let kind: OutputKind
    let canBeSystemDefault: Bool
    /// A Bluetooth headset's address, in `BluetoothAudioDevice.canonicalAddress`
    /// spelling: the key its battery levels come under.
    var headsetAddress: String?
    /// An Apple headset, which may have listening modes and spatial audio (see
    /// `HeadsetControlsReader.mayHaveControls`). No other device is asked.
    var mayHaveControls = false

    var symbol: String { kind.symbol }

    /// The name without its owner, where space is short: "Ayush’s AirPods Pro 2"
    /// reads as "AirPods Pro 2".
    var shortName: String { Headset.shortName(name) }
}

/// What sort of output a device is, which decides its picture and its place in the
/// list.
enum OutputKind: Equatable, Sendable {
    /// The Mac's own speakers; `portable` for a laptop's.
    case builtInSpeakers(portable: Bool)
    /// The headphone jack.
    case builtInHeadphones
    case headset(HeadsetKind)
    /// A display's speakers, over DisplayPort, Thunderbolt or USB.
    case display
    /// A television, or anything else on HDMI.
    case television
    /// USB, PCI, FireWire or AVB: an interface or a pair of speakers.
    case external
    /// An aggregate or multi-output device made in Audio MIDI Setup.
    case multiOutput
    /// A driver of an app's own: a virtual cable, a meeting app's speaker.
    case virtual
    /// An AirPlay receiver the Mac is playing to, with its picture.
    case airPlay(symbol: String)

    var symbol: String {
        switch self {
        case .builtInSpeakers(let portable): portable ? "laptopcomputer" : "desktopcomputer"
        case .builtInHeadphones: "headphones"
        case .headset(let kind): kind.symbol
        case .display: "display"
        case .television: "tv"
        case .external: "hifispeaker"
        case .multiOutput: "hifispeaker.2"
        case .virtual: "waveform"
        case .airPlay(let symbol): symbol
        }
    }

    /// The Sound menu's order: the Mac itself, then what is worn, then what is
    /// plugged in, then what the person put together, then AirPlay.
    var rank: Int {
        switch self {
        case .builtInSpeakers: 0
        case .builtInHeadphones, .headset: 1
        case .display, .television, .external: 2
        case .multiOutput, .virtual: 3
        case .airPlay: 4
        }
    }

    var isAirPlay: Bool {
        if case .airPlay = self { true } else { false }
    }
}

/// Turns what Core Audio lists into the outputs the Sound menu would offer, in its
/// order.
enum OutputCatalog {
    /// Whether this Mac runs on a battery, which is what tells a laptop's speakers
    /// from a desktop's: the model name does not (`Mac16,8` could be either).
    static let isPortableMac: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return list.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()

    /// The devices that pass the Sound menu's test, sorted. `ownPrefix` marks the
    /// aggregate devices Islet's own taps make (see `VolumeTap.deviceUIDPrefix`): they
    /// are private, so only Islet sees them, and it would otherwise list its own
    /// plumbing.
    static func outputs(
        from candidates: [OutputCandidate],
        isPortableMac: Bool = isPortableMac,
        ownPrefix: String = VolumeTap.deviceUIDPrefix
    ) -> [OutputDevice] {
        candidates
            .filter { isListed($0, ownPrefix: ownPrefix) }
            .map { device(for: $0, isPortableMac: isPortableMac) }
            .sorted { a, b in
                if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.uid < b.uid : order == .orderedAscending
            }
    }

    /// Something sound can be sent to, that macOS would let be the default, and
    /// that is nobody's private plumbing.
    static func isListed(_ candidate: OutputCandidate, ownPrefix: String) -> Bool {
        candidate.outputStreams > 0
            && candidate.canBeDefault
            && !candidate.isHidden
            && !candidate.isPrivate
            && !candidate.uid.hasPrefix(ownPrefix)
    }

    static func device(for candidate: OutputCandidate, isPortableMac: Bool) -> OutputDevice {
        var address: String?
        let kind: OutputKind
        switch candidate.transport {
        case kAudioDeviceTransportTypeBuiltIn:
            let isJack = candidate.dataSource == headphonesSource
                || candidate.uid.localizedCaseInsensitiveContains("headphone")
                || candidate.name.localizedCaseInsensitiveContains("headphone")
            kind = isJack ? .builtInHeadphones : .builtInSpeakers(portable: isPortableMac)
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            let model = candidate.modelUID.flatMap(BluetoothAudioWatcher.parseModelUID)
            kind = .headset(HeadsetKind(
                name: candidate.name, productID: model?.product, vendorID: model?.vendor, minorType: nil
            ))
            address = BluetoothAudioWatcher.headsetID(uid: candidate.uid)
        case kAudioDeviceTransportTypeAirPlay:
            kind = .airPlay(symbol: airPlaySymbol(model: candidate.modelUID, name: candidate.name))
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            kind = .multiOutput
        case kAudioDeviceTransportTypeVirtual:
            kind = .virtual
        case kAudioDeviceTransportTypeHDMI:
            kind = isDisplay(candidate.name) ? .display : .television
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt:
            kind = .display
        default:
            // A display's speakers often come over USB (the Studio Display's do).
            kind = isDisplay(candidate.name) ? .display : .external
        }
        return OutputDevice(
            id: candidate.id, uid: candidate.uid, name: candidate.name, kind: kind,
            canBeSystemDefault: candidate.canBeSystemDefault, headsetAddress: address,
            mayHaveControls: HeadsetControlsReader.mayHaveControls(
                transport: candidate.transport, uid: candidate.uid, modelUID: candidate.modelUID
            )
        )
    }

    /// An AirPlay receiver's picture from its model, or from its name when the model
    /// says nothing useful: Apple TVs are `AppleTV…`, HomePods `AudioAccessory…`
    /// (5 is the mini).
    static func airPlaySymbol(model: String?, name: String) -> String {
        let model = model?.lowercased() ?? ""
        let name = name.lowercased()
        if model.contains("appletv") || name.contains("apple tv") { return "appletv" }
        if model.contains("audioaccessory5") || name.contains("homepod mini") { return "homepodmini" }
        if model.contains("audioaccessory") || name.contains("homepod") { return "homepod" }
        return "airplayaudio"
    }

    /// `'hdpn'`, the built-in output's data source while headphones are plugged in.
    static let headphonesSource: UInt32 = 0x6864_706E

    private static func isDisplay(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("display")
    }
}
