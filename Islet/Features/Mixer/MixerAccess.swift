import Foundation

/// Whether Islet may set other apps' volumes. The volume is applied by tapping an
/// app's sound and playing it back at the chosen level, and macOS counts a tap as
/// recording: "System Audio Recording Only" in Privacy & Security.
enum MixerAccess: Equatable, Sendable {
    /// Before macOS 14.2 there are no process taps.
    case unsupported
    /// Not asked yet; the first volume change asks.
    case unknown
    /// macOS is asking.
    case requesting
    case granted
    case denied
}

/// TCC's own check and request for system audio recording, looked up at run time as
/// they are not public API. The check never prompts. The request does, and is only
/// ever made from a slider or a mute button.
///
/// Asking first matters: a tap made without permission raises no error, it just
/// hears silence — and it silences the app it taps, so an app turned down would go
/// quiet altogether. Where the functions are missing, access reads as unknown and
/// the first tap, made from a volume change, has macOS ask instead.
enum AudioCapturePermission {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (
        CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void
    ) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflight: Preflight? = symbol("TCCAccessPreflight")
    private static let request: Request? = symbol("TCCAccessRequest")

    /// Privacy & Security, at the list of apps allowed to record system audio.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")

    /// Whether permission can be looked up and asked for before a tap is made.
    /// Without that, the first tap — made from a volume change — has macOS ask.
    static var asksAhead: Bool { preflight != nil && request != nil }

    /// TCC answers 0 for allowed, 1 for denied, and anything else for not yet asked.
    static func check() -> MixerAccess {
        guard let preflight else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows macOS's prompt, if it has not been answered, and reports the answer on
    /// an arbitrary queue. Returns `false`, never calling `answer`, when there is no
    /// way to ask.
    static func ask(_ answer: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard let request else { return false }
        request(service, nil) { granted in answer(granted) }
        return true
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let framework, let pointer = dlsym(framework, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
