import AppKit

/// Whether macOS lets Islet read what other apps copy.
///
/// macOS 27 asks before an app reads the general pasteboard on its own rather than
/// for a paste: an alert the first time, and after that whatever "Paste from Other
/// Apps" in Privacy & Security says, where the choice is to allow the app outright or
/// to be asked each time. A history read off a timer is exactly that kind of read, so
/// the model reads copies only while reading is allowed outright, and puts up macOS's
/// alert only when someone clicks Allow, never because something was copied.
enum ClipboardAccess: Equatable {
    /// Reads go through without a word: allowed in Privacy & Security, a macOS that
    /// does not ask, or a pasteboard of Islet's own, which never asks.
    case allowed
    /// Never asked. The first read puts up macOS's alert, and lists Islet under Paste
    /// from Other Apps.
    case notAsked
    /// macOS asks at every read, until Islet is allowed under Paste from Other Apps.
    case asks
    /// Turned off under Paste from Other Apps: every read comes back empty.
    case denied

    /// Privacy & Security, at Paste from Other Apps.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")

    /// Looks the access up without reading anything, so it never asks.
    ///
    /// The setting arrived with macOS 15.4, but macOS 27 is the first release known to
    /// ask at its default; before it, the default let reads through. Should an earlier
    /// release ask after all, the first copy's read asks once, which moves the setting
    /// off its default, and from then on this answers as it would on macOS 27.
    static func of(_ pasteboard: NSPasteboard) -> ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch pasteboard.accessBehavior {
        case .alwaysAllow: return .allowed
        case .ask: return .asks
        case .alwaysDeny: return .denied
        case .default:
            // Any other pasteboard always lets reads through.
            guard pasteboard.name == .general else { return .allowed }
            if #available(macOS 27, *) { return .notAsked }
            return .allowed
        @unknown default:
            return .allowed
        }
    }

    /// The types read for macOS's alert, least telling first: a file's address, a
    /// link's, then the text. A picture comes only where there is nothing else, since it
    /// is the largest.
    static let askTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]

    /// The one type to read for macOS's alert from a copy of `types`, or `nil` where
    /// there is none to ask with. A copy the privacy rules leave alone is never read,
    /// not even for this: one marked as not for keeping here, and one a password manager
    /// made, which only the caller can tell, from the apps in front. Nor is a picture
    /// still on an iPhone, which the history leaves alone too, or a copy of nothing the
    /// history keeps. Looking at the types asks nothing of macOS.
    @MainActor
    static func typeToAsk(_ types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        guard !types.isEmpty, !types.contains(where: ClipboardReader.isMarker) else { return nil }
        if let type = askTypes.first(where: types.contains) { return type }
        guard !types.contains(ClipboardReader.remoteMarker) else { return nil }
        return ClipboardReader.pictureTypes.first(where: types.contains)
    }
}
