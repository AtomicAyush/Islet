import Foundation

/// A keyboard, mouse, trackpad, game controller or stylus that tells macOS its battery
/// level: Apple's Magic accessories, and other Bluetooth input devices that report one.
struct InputDevice: Identifiable, Equatable, Sendable {
    /// Its Bluetooth address where macOS gives one, so a keyboard that sleeps and wakes
    /// is the same keyboard; otherwise its vendor, product and name. Kept in memory
    /// only, never shown or stored.
    let id: String
    var name: String
    var kind: InputDeviceKind
    /// Percent, 1 to 100.
    var level: Int
    /// On its cable, charging or charged: plugged into the Mac, or its own word for it
    /// borne out by the level (`confirmingPower(since:)`). A device on power is not
    /// warned about, so this is only set on good evidence.
    var isOnPower = false
    /// What the device's own status flag says about power. The flag is undocumented,
    /// and a misread one would silence every warning without a sign, so on its own it
    /// changes nothing.
    var saysOnPower = false

    var symbol: String { kind.symbol }

    /// The name without its owner, where space is short: "Ayush’s Magic Mouse" reads as
    /// "Magic Mouse", as a headset's name does.
    var shortName: String { Headset.shortName(name) }

    /// Keyboards first, then mice, trackpads and the rest, as the Bluetooth menu lists
    /// them; by name within a kind, so the order holds still as levels change.
    static func displayOrder(_ a: InputDevice, _ b: InputDevice) -> Bool {
        if a.kind.sortOrder != b.kind.sortOrder { return a.kind.sortOrder < b.kind.sortOrder }
        if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return a.id < b.id
    }

    /// This reading with its own word on power weighed against the reading before it:
    /// believed once the level has been seen rising under it, and for as long as the
    /// level does not then fall. A battery that is going down is not charging, whatever
    /// a flag says; one at 100% that climbed there on the charger stays on it.
    func confirmingPower(since previous: InputDevice?) -> InputDevice {
        guard !isOnPower, saysOnPower, let previous else { return self }
        var device = self
        device.isOnPower = level > previous.level || (previous.isOnPower && level >= previous.level)
        return device
    }

    static let sampleMagicKeyboard = InputDevice(
        id: "preview.magickeyboard", name: "Magic Keyboard", kind: .keyboard, level: 64
    )
    static let sampleMagicMouse = InputDevice(
        id: "preview.magicmouse", name: "Magic Mouse", kind: .magicMouse, level: 10
    )
    static let sampleMagicTrackpad = InputDevice(
        id: "preview.magictrackpad", name: "Magic Trackpad", kind: .trackpad, level: 82, isOnPower: true
    )
}

/// Which picture a device gets, and where it sorts.
enum InputDeviceKind: CaseIterable, Sendable {
    case keyboard, magicMouse, mouse, trackpad, gameController, stylus

    /// Apple's product id is the surest guide, since people rename their devices; the
    /// name comes next, then what the device says it is to HID (a mouse, a keyboard, a
    /// game pad), which is all a device of another make may give. Anything else is not
    /// an input device, or not one this feature can name: a headset's media buttons
    /// (the Headphones feature has its level), a presenter's remote. `nil` leaves it out
    /// rather than list it, and warn of it, as an unnamed accessory.
    init?(vendorID: Int?, productID: Int?, name: String, usagePage: Int?, usage: Int?) {
        if let vendorID, Self.appleVendors.contains(vendorID), let productID,
           let kind = Self.appleProducts[productID] {
            self = kind
            return
        }
        if let kind = Self.kind(named: name) {
            self = kind
            return
        }
        switch (usagePage, usage) {
        case (Self.genericDesktop, 1), (Self.genericDesktop, 2): self = .mouse
        case (Self.genericDesktop, 6), (Self.genericDesktop, 7): self = .keyboard
        case (Self.genericDesktop, 4), (Self.genericDesktop, 5): self = .gameController
        case (Self.digitizer, 5): self = .trackpad
        case (Self.digitizer, 1), (Self.digitizer, 2): self = .stylus
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .keyboard: "keyboard.fill"
        case .magicMouse: "magicmouse.fill"
        case .mouse: "computermouse.fill"
        // SF Symbols has no trackpad; a hand on a pad reads as one.
        case .trackpad: "rectangle.and.hand.point.up.left.fill"
        case .gameController: "gamecontroller.fill"
        case .stylus: "pencil.tip"
        }
    }

    /// What to call a device that gives no name.
    var genericName: String {
        switch self {
        case .keyboard: "Keyboard"
        case .magicMouse: "Magic Mouse"
        case .mouse: "Mouse"
        case .trackpad: "Trackpad"
        case .gameController: "Game Controller"
        case .stylus: "Stylus"
        }
    }

    var sortOrder: Int {
        switch self {
        case .keyboard: 0
        case .magicMouse, .mouse: 1
        case .trackpad: 2
        case .gameController: 3
        case .stylus: 4
        }
    }

    private static func kind(named name: String) -> InputDeviceKind? {
        let name = name.lowercased()
        if name.contains("trackpad") { return .trackpad }
        if name.contains("magic mouse") { return .magicMouse }
        if name.contains("keyboard") || logitechKeyboards.contains(where: name.contains) { return .keyboard }
        if name.contains("mouse") || logitechMice.contains(where: name.contains) { return .mouse }
        if name.contains("controller") || name.contains("gamepad") { return .gameController }
        return nil
    }

    /// Logitech's names say what they are only to people who know them.
    private static let logitechMice = ["mx master", "mx anywhere", "mx ergo", "mx vertical", "lift", "pebble", "signature m"]
    private static let logitechKeyboards = ["mx keys", "mx mechanical", "pop keys", "k380", "k780"]

    private static let genericDesktop = 0x01
    private static let digitizer = 0x0D

    /// Apple's id over Bluetooth, and over USB (a Magic accessory on its cable).
    private static let appleVendors: Set<Int> = [0x004C, 0x05AC]

    private static let appleProducts: [Int: InputDeviceKind] = [
        // Apple Wireless Keyboard, then Magic Keyboard: 2015, with numeric keypad,
        // with Touch ID, 2021, and the USB-C models.
        0x022C: .keyboard, 0x022D: .keyboard, 0x022E: .keyboard,
        0x0239: .keyboard, 0x023A: .keyboard, 0x023B: .keyboard,
        0x0255: .keyboard, 0x0256: .keyboard, 0x0257: .keyboard,
        0x0267: .keyboard, 0x026C: .keyboard, 0x029A: .keyboard, 0x029C: .keyboard, 0x029F: .keyboard,
        0x0320: .keyboard, 0x0321: .keyboard, 0x0322: .keyboard,
        // Magic Mouse, Magic Mouse 2 and the USB-C model.
        0x030D: .magicMouse, 0x0269: .magicMouse, 0x0323: .magicMouse,
        // Magic Trackpad, Magic Trackpad 2 and the USB-C model.
        0x030E: .trackpad, 0x0265: .trackpad, 0x0324: .trackpad,
    ]
}
