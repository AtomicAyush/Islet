import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key with modifiers, as the system's hot keys take it: a virtual key code and
/// Carbon's modifier bits.
struct KeyCombo: Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// ⌥⇧Space: clear of Spotlight (⌘Space), Finder's search (⌥⌘Space) and ChatGPT
    /// (⌥Space).
    static let standard = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(shiftKey | optionKey))

    /// Combinations that belong to the system or to apps people use for the same thing.
    static let reserved: [KeyCombo] = [
        KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)),
        KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey)),
        KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
    ]

    static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From a key press in the recorder.
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        modifiers = UInt32(carbon)
    }

    /// Why this can't be the shortcut, in a word for the recorder; `nil` when it can. It
    /// needs ⌘, ⌥ or ⌃ (Shift alone would take a letter from typing), unless it is a
    /// function key, and it must not be one the system or ChatGPT has.
    var refusal: String? {
        if Self.reserved.contains(self) { return "\(display) is taken by the system or ChatGPT" }
        let hasModifier = modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        if !hasModifier, !Self.functionKeys.contains(Int(keyCode)) { return "Add ⌘, ⌥ or ⌃" }
        return nil
    }

    /// "⌥⇧Space", in the order menus show modifiers.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            if let index = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
                            kVK_F20].firstIndex(of: Int(keyCode)) {
                return "F\(index + 1)"
            }
            return character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
        }
    }

    /// What the key types on the current keyboard layout, with no modifier held.
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    // MARK: Stored

    /// As kept in the defaults: [key code, modifiers]; an empty list for no shortcut.
    var stored: [Int] { [Int(keyCode), Int(modifiers)] }

    /// The shortcut kept under `key`: the standard one if none was ever chosen, `nil` for
    /// None.
    static func stored(in defaults: UserDefaults, key: String) -> KeyCombo? {
        guard let values = defaults.array(forKey: key) as? [Int] else { return .standard }
        guard values.count == 2, let code = UInt32(exactly: values[0]), let mods = UInt32(exactly: values[1]) else {
            return nil
        }
        return KeyCombo(keyCode: code, modifiers: mods)
    }
}

/// The input box's shortcut, pressed in any app. It is a system hot key: macOS gives it
/// to Islet alone, without Accessibility access, and the app in front never sees it.
@MainActor
final class InputHotKey {
    static let shared = InputHotKey()

    /// What pressing it does. Set by whoever registers it.
    var pressed: () -> Void = {}
    private(set) var combo: KeyCombo?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private init() {}

    /// Makes `combo` the shortcut, or none. Returns false when another app has it.
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        guard combo != self.combo || (combo != nil && hotKey == nil) else { return true }
        unregister()
        guard let combo else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x49534C54), id: 1) // "ISLT"
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return false }
        hotKey = ref
        self.combo = combo
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        combo = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { InputHotKey.shared.pressed() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

// MARK: - Settings

/// Records a new shortcut in Settings: click, then press the keys. Escape leaves it as
/// it was, and a combination that can't be one says why and waits for another.
struct ShortcutRecorder: View {
    /// The shortcut as kept, `nil` for none.
    let combo: KeyCombo?
    /// Something to say beside it: that another app has it, say.
    let problem: String?
    let change: (KeyCombo?) -> Void
    @State private var isRecording = false
    @State private var refusal: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if let message = refusal ?? problem {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button(isRecording ? "Type the shortcut…" : combo?.display ?? "None") {
                isRecording ? stop() : start()
            }
            .monospacedDigit()
            if combo != nil, !isRecording {
                Button("None") { change(nil) }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        refusal = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()
                return nil
            }
            let recorded = KeyCombo(event: event)
            if let reason = recorded.refusal {
                refusal = reason
            } else {
                change(recorded)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
