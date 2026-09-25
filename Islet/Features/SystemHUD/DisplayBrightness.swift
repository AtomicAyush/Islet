import CoreGraphics
import Darwin

/// The built-in display's brightness, through the private DisplayServices framework:
/// the same perceptual level the Control Centre slider moves.
///
/// Every symbol is looked up at run time and checked, so a macOS release that drops
/// or renames one costs brightness control (the keys go back to macOS), not a crash.
@MainActor
enum DisplayBrightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    private struct Functions {
        let get: GetBrightness
        let set: SetBrightness
        let canChange: CanChangeBrightness
    }

    private static let functions: Functions? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness"),
              let canChange = dlsym(handle, "DisplayServicesCanChangeBrightness")
        else { return nil }
        return Functions(
            get: unsafeBitCast(get, to: GetBrightness.self),
            set: unsafeBitCast(set, to: SetBrightness.self),
            canChange: unsafeBitCast(canChange, to: CanChangeBrightness.self)
        )
    }()

    /// The built-in panel, if it is lit (not with the lid closed) and its brightness
    /// can be changed. The main display is no use here: with an external monitor
    /// attached it is often one DisplayServices cannot drive.
    static var builtIn: CGDirectDisplayID? {
        guard let functions else { return nil }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 && functions.canChange($0) }
    }

    /// 0...1.
    static func level(of display: CGDirectDisplayID) -> Double? {
        guard let functions else { return nil }
        var value: Float = 0
        guard functions.get(display, &value) == 0, value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }

    static func setLevel(_ level: Double, of display: CGDirectDisplayID) -> Bool {
        guard let functions else { return false }
        return functions.set(display, Float(min(max(level, 0), 1))) == 0
    }
}
