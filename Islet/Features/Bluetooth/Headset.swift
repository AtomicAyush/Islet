import AppKit

/// A connected pair of headphones, earbuds or a Bluetooth speaker.
struct Headset: Identifiable, Equatable, Sendable {
    /// See `BluetoothAudioDevice.id`.
    let id: String
    var name: String
    var kind: HeadsetKind
    /// From CoreAudio, or system_profiler when CoreAudio did not say.
    var productID: Int?
    var vendorID: Int?
    var battery = HeadsetBattery()

    var symbol: String { kind.symbol }

    /// The name without its owner, where space is short: "Ayush’s AirPods Pro" reads as
    /// "AirPods Pro".
    var shortName: String {
        for mark in ["’s ", "'s "] {
            if let range = name.range(of: mark), range.upperBound < name.endIndex {
                return String(name[range.upperBound...])
            }
        }
        return name
    }

    static let sampleAirPodsPro = Headset(
        id: "preview.airpodspro",
        name: "AirPods Pro",
        kind: .airpodsPro,
        battery: HeadsetBattery(left: 100, right: 95, chargingCase: 64)
    )

    static let sampleAirPodsMax = Headset(
        id: "preview.airpodsmax",
        name: "AirPods Max",
        kind: .airpodsMax,
        battery: HeadsetBattery(main: 72)
    )
}

/// Battery levels in percent. AirPods report one per bud and one for the case, most
/// headphones a single main level, and some (AirPods Max among them) none at all.
struct HeadsetBattery: Equatable, Sendable {
    var left: Int?
    var right: Int?
    var chargingCase: Int?
    var main: Int?

    struct Reading: Identifiable, Equatable, Sendable {
        let id: String
        /// "L", "R" or "Case"; `nil` for a lone main level.
        let label: String?
        let level: Int
    }

    var isEmpty: Bool { readings.isEmpty }

    /// The levels to draw, left to right.
    var readings: [Reading] {
        var readings: [Reading] = []
        if let left { readings.append(Reading(id: "left", label: "L", level: left)) }
        if let right { readings.append(Reading(id: "right", label: "R", level: right)) }
        if let chargingCase { readings.append(Reading(id: "case", label: "Case", level: chargingCase)) }
        if readings.isEmpty, let main { readings.append(Reading(id: "main", label: nil, level: main)) }
        return readings
    }
}

/// Which picture a headset gets.
enum HeadsetKind: CaseIterable, Sendable {
    case airpods, airpodsGen3, airpodsPro, airpodsMax
    case beatsHeadphones, beatsEarphones
    case speaker, headphones

    /// Apple's product id is the surest guide, since people rename their AirPods; the
    /// name is next, and system_profiler's minor type catches speakers.
    init(name: String, productID: Int?, vendorID: Int?, minorType: String?) {
        if vendorID == Self.apple, let productID, let kind = Self.appleProducts[productID] {
            self = kind
            return
        }
        let name = name.lowercased()
        if name.contains("airpods max") {
            self = .airpodsMax
        } else if name.contains("airpods pro") {
            self = .airpodsPro
        } else if name.contains("airpods") {
            self = .airpods
        } else if name.contains("beats") {
            let inEar = ["buds", "flex", "fit", "powerbeats", "beatsx", "beats x"].contains { name.contains($0) }
            self = inEar ? .beatsEarphones : .beatsHeadphones
        } else if minorType?.localizedCaseInsensitiveContains("speaker") == true {
            self = .speaker
        } else {
            self = .headphones
        }
    }

    /// Falls back to plain headphones on a system too old to draw the model's symbol.
    var symbol: String {
        Self.drawable.contains(preferredSymbol) ? preferredSymbol : "headphones"
    }

    private var preferredSymbol: String {
        switch self {
        case .airpods: "airpods"
        case .airpodsGen3: "airpods.gen3"
        case .airpodsPro: "airpodspro"
        case .airpodsMax: "airpodsmax"
        case .beatsHeadphones: "beats.headphones"
        case .beatsEarphones: "beats.earphones"
        case .speaker: "hifispeaker.fill"
        case .headphones: "headphones"
        }
    }

    private static let drawable = Set(
        allCases.map(\.preferredSymbol).filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    )

    private static let apple = 0x004C

    private static let appleProducts: [Int: HeadsetKind] = [
        0x2002: .airpods, 0x200F: .airpods,
        0x2013: .airpodsGen3, 0x2019: .airpodsGen3, 0x201B: .airpodsGen3,
        0x200E: .airpodsPro, 0x2014: .airpodsPro, 0x2024: .airpodsPro, 0x2027: .airpodsPro,
        0x200A: .airpodsMax, 0x201F: .airpodsMax, 0x202D: .airpodsMax,
        0x2006: .beatsHeadphones, 0x2009: .beatsHeadphones, 0x200C: .beatsHeadphones,
        0x2017: .beatsHeadphones, 0x2025: .beatsHeadphones,
        0x2003: .beatsEarphones, 0x2005: .beatsEarphones, 0x200B: .beatsEarphones,
        0x200D: .beatsEarphones, 0x2010: .beatsEarphones, 0x2011: .beatsEarphones,
        0x2012: .beatsEarphones, 0x2016: .beatsEarphones, 0x201D: .beatsEarphones,
        0x2026: .beatsEarphones,
    ]
}
