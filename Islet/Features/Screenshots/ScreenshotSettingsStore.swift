import Foundation

/// Where the Screenshot app's settings are kept: macOS's own, or a stand-in of the
/// tests', so that they never change the real ones. Any of them can be read, but only
/// the floating thumbnail's can be written.
///
/// Built into the thumbnail keeper as well as Islet (`ThumbnailKeeper/main.swift`), so
/// it uses nothing else of Islet's.
struct ScreenshotSettingsStore: Sendable {
    /// Makes the next read a fresh one, and saves what has been set.
    var synchronize: @Sendable () -> Void
    var value: @Sendable (String) -> Any?
    /// Stores the floating thumbnail's setting, or takes it away for `nil`.
    var setThumbnail: @Sendable (CFPropertyList?) -> Void

    static let systemDomain = "com.apple.screencapture"

    static let system = domain(systemDomain)

    /// The floating thumbnail's setting; macOS shows the thumbnail while there is none.
    static let thumbnailKey = "show-thumbnail"

    /// The settings in the preferences domain named `domain`: the Screenshot app's, or a
    /// test's own.
    static func domain(_ domain: String) -> ScreenshotSettingsStore {
        ScreenshotSettingsStore(
            // Another app's settings are cached; synchronising makes the read a fresh one.
            synchronize: { _ = CFPreferencesAppSynchronize(domain as CFString) },
            value: { CFPreferencesCopyAppValue($0 as CFString, domain as CFString) },
            setThumbnail: { CFPreferencesSetAppValue(thumbnailKey as CFString, $0, domain as CFString) }
        )
    }

    /// Whether the floating thumbnail is set off, rather than left to macOS's default or
    /// turned on.
    func thumbnailIsOff() -> Bool {
        synchronize()
        return Self.flag(value(Self.thumbnailKey)) == false
    }

    /// Turns macOS's floating thumbnail off, so each screenshot is saved the moment it is
    /// taken. Called off the main thread.
    func turnThumbnailOff() {
        setThumbnail(kCFBooleanFalse)
        synchronize()
    }

    /// Takes the floating thumbnail's setting away, so macOS's own default, the
    /// thumbnail, is back; a thumbnail turned back on elsewhere is left as it is. Called
    /// off the main thread, or by the keeper.
    func restoreThumbnail() {
        guard thumbnailIsOff() else { return }
        setThumbnail(nil)
        synchronize()
    }

    /// A stored yes or no, read as macOS reads one: a boolean, a number, or a string, as
    /// `defaults write` leaves one without `-bool` ("false", "NO", "0"). `nil` for anything
    /// else, which is taken as missing.
    static func flag(_ value: Any?) -> Bool? {
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }
}
