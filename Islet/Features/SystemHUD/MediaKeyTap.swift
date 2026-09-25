import AppKit
import IOKit.hidsystem

/// A volume or brightness key on the keyboard's top row.
enum MediaKey: Equatable {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown

    /// `nil` for the keys this feature leaves to macOS: media transport, the
    /// keyboard backlight, eject and the rest.
    init?(keyType: Int32) {
        switch keyType {
        case NX_KEYTYPE_SOUND_UP: self = .volumeUp
        case NX_KEYTYPE_SOUND_DOWN: self = .volumeDown
        case NX_KEYTYPE_MUTE: self = .mute
        case NX_KEYTYPE_BRIGHTNESS_UP: self = .brightnessUp
        case NX_KEYTYPE_BRIGHTNESS_DOWN: self = .brightnessDown
        default: return nil
        }
    }
}

/// One press or release of a special key, decoded from a system-defined event.
/// These keys arrive as aux control button events whose `data1` packs the key type
/// in the high half, the state in the next byte and a repeat flag in the low bit.
struct MediaKeyEvent {
    let keyType: Int32
    let isDown: Bool
    /// An automatic repeat while the key is held, rather than a fresh press.
    let isRepeat: Bool
    let modifiers: NSEvent.ModifierFlags

    init?(_ event: NSEvent) {
        guard event.type == .systemDefined,
              event.subtype.rawValue == Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS) else { return nil }
        let data = event.data1
        let state = (data & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        keyType = Int32(truncatingIfNeeded: (data & 0xFFFF_0000) >> 16)
        isDown = state == 0xA
        isRepeat = data & 0x1 != 0
        modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }
}

/// Catches the volume and brightness keys before macOS acts on them, so the island
/// can stand in for the system's overlay.
///
/// An active tap at the head of the session's event stream sees each key first;
/// dropping the event there means the system never changes the level or draws its
/// overlay. Creating the tap needs Accessibility, so `install()` fails until that is
/// granted. The tap holds this object unretained: uninstall it before letting go.
@MainActor
final class MediaKeyTap {
    /// Asked on every key-down (repeats included) of a key the first press was taken
    /// for. Returns whether it acted; a key it declines reaches macOS untouched.
    var onKeyDown: (MediaKey, MediaKeyEvent) -> Bool = { _, _ in false }
    /// Called when macOS switched the tap off because Accessibility was taken away.
    /// The tap is still installed; the owner should uninstall it (not from here).
    var onAccessLost: () -> Void = {}

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// Keys whose latest key-down was dropped, so their key-up is dropped too: the
    /// system must never see half a press.
    private var swallowed: Set<Int32> = []

    var isInstalled: Bool { port != nil }

    /// Starts catching keys. Returns false if macOS refused the tap (no Accessibility).
    @discardableResult
    func install() -> Bool {
        if let port {
            // Left off when access looked lost as macOS switched it off (see
            // `shouldDrop`); access is back, so switch it on again.
            if !CGEvent.tapIsEnabled(tap: port) { CGEvent.tapEnable(tap: port, enable: true) }
            return true
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventMask(NX_SYSDEFINED),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                // The source is on the main run loop, so this is always the main thread.
                let drop = MainActor.assumeIsolated { tap.shouldDrop(event, type: type) }
                return drop ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        // Common modes, so keys are still caught while a menu is open.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func uninstall() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
        swallowed.removeAll()
    }

    private func shouldDrop(_ event: CGEvent, type: CGEventType) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS switches a tap off if it once answers too slowly; switch it back
            // on. Without Accessibility it would only go off again, so say so instead.
            if AXIsProcessTrusted() {
                if let port { CGEvent.tapEnable(tap: port, enable: true) }
            } else {
                onAccessLost()
            }
            return false
        }
        guard let nsEvent = NSEvent(cgEvent: event),
              let press = MediaKeyEvent(nsEvent),
              let key = MediaKey(keyType: press.keyType) else { return false }

        guard press.isDown else {
            return swallowed.remove(press.keyType) != nil
        }
        // Repeats follow the first press: if macOS got that, it gets these.
        if press.isRepeat, !swallowed.contains(press.keyType) { return false }
        if onKeyDown(key, press) {
            swallowed.insert(press.keyType)
            return true
        }
        swallowed.remove(press.keyType)
        return false
    }
}
