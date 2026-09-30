import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// What "Look at my screen" takes a picture of.
enum ScreenLookTarget: String, CaseIterable, Identifiable {
    /// The front window of the app the person was in.
    case frontWindow = "window"
    /// The whole display the island is on.
    case display

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frontWindow: "Front window"
        case .display: "Whole display"
        }
    }

    var symbol: String {
        switch self {
        case .frontWindow: "macwindow"
        case .display: "display"
        }
    }
}

/// Whether Islet may take pictures of the screen: Screen Recording, in System Settings.
enum ScreenPermission: Equatable {
    case granted
    case denied

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    @MainActor
    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}

/// A picture asked for, the moment "Look at my screen" is pressed.
struct ScreenCaptureRequest: Equatable {
    var target: ScreenLookTarget
    /// The display the island is on.
    var displayID: CGDirectDisplayID?
    /// The app the person was in.
    var frontmost: pid_t?
    /// Islet itself: none of its windows is in the picture.
    var excluding: pid_t
}

/// A picture as it was taken, and what of: "Safari", "Built-in Retina Display".
struct ScreenCapture {
    var image: CGImage
    var source: String
}

/// Why no picture was taken.
enum ScreenLookFailure: Error, Equatable {
    case permissionOff
    /// The app in front has no window to look at: its name, if known.
    case noWindow(String?)
    case failed
}

/// What takes the picture: ScreenCaptureKit, or a test's stand-in.
@MainActor
protocol ScreenCapturer: AnyObject {
    func permission() -> ScreenPermission
    /// Asks macOS for Screen Recording, which shows its own prompt the first time.
    func requestPermission()
    func capture(_ request: ScreenCaptureRequest) async throws -> ScreenCapture
}

/// One picture of the screen, made small enough to send, held in memory only: for the
/// next question, and with it in the conversation until the island closes. It is never
/// written anywhere but, for ChatGPT's tool, which takes a file, a private one in its
/// run's folder (`CodexAskBackend`), and never logged.
struct ScreenSnapshot: Identifiable, Equatable {
    let id = UUID()
    let target: ScreenLookTarget
    /// What it is of: the app, or the display.
    let source: String
    /// The picture as it is sent.
    let image: CGImage
    let jpeg: Data

    /// The longest side, in pixels, of a picture sent: enough to read a window's text.
    static let longestSide = 1600

    static let mediaType = "image/jpeg"

    /// "the Safari window", "the whole display".
    var what: String {
        switch target {
        case .frontWindow: "the \(source) window"
        case .display: "the whole display"
        }
    }

    static func == (lhs: ScreenSnapshot, rhs: ScreenSnapshot) -> Bool {
        lhs.id == rhs.id
    }

    /// The picture taken, no larger than `longestSide`, as a JPEG in memory.
    static func make(from capture: ScreenCapture, target: ScreenLookTarget) -> ScreenSnapshot? {
        guard let image = scaled(capture.image), let jpeg = jpeg(image) else { return nil }
        return ScreenSnapshot(target: target, source: capture.source, image: image, jpeg: jpeg)
    }

    static func fitted(_ size: CGSize) -> CGSize {
        let scale = min(1, CGFloat(longestSide) / max(size.width, size.height, 1))
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    private static func scaled(_ image: CGImage) -> CGImage? {
        let size = fitted(CGSize(width: image.width, height: image.height))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Choosing what to look at.
enum ScreenLook {
    /// A window on screen, as the window server lists them, front to back.
    struct Window: Equatable {
        var id: CGWindowID
        var pid: pid_t
        var layer: Int
        var bounds: CGRect
    }

    /// The front window of `frontmost`, among ordinary windows (not menus, panels over
    /// everything or slivers), never one of Islet's. With Islet itself in front (its
    /// Settings), the front window of the app behind it.
    static func frontWindow(in windows: [Window], frontmost: pid_t?, excluding own: pid_t) -> Window? {
        let ordinary = windows.filter { $0.layer == 0 && $0.pid != own && $0.bounds.width >= 40 && $0.bounds.height >= 40 }
        guard let frontmost, frontmost != own else { return ordinary.first }
        return ordinary.first { $0.pid == frontmost }
    }

    /// The display the island is on.
    @MainActor
    static func display(of island: IslandViewModel?) -> CGDirectDisplayID? {
        guard let island else { return nil }
        return IslandManager.shared.controllers.first { $0.value.model === island }?.key
    }
}

/// Pictures taken with ScreenCaptureKit, at the moment asked and not otherwise.
@MainActor
final class SystemScreenCapturer: ScreenCapturer {
    func permission() -> ScreenPermission {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    func capture(_ request: ScreenCaptureRequest) async throws -> ScreenCapture {
        guard permission() == .granted else { throw ScreenLookFailure.permissionOff }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw (error as? SCStreamError)?.code == .userDeclined ? ScreenLookFailure.permissionOff : ScreenLookFailure.failed
        }
        let filter: SCContentFilter
        let source: String
        switch request.target {
        case .frontWindow:
            let front = request.frontmost.flatMap { NSRunningApplication(processIdentifier: $0) }
            guard let chosen = ScreenLook.frontWindow(in: Self.windows(), frontmost: request.frontmost, excluding: request.excluding),
                  let window = content.windows.first(where: { $0.windowID == chosen.id })
            else { throw ScreenLookFailure.noWindow(front?.localizedName) }
            filter = SCContentFilter(desktopIndependentWindow: window)
            source = window.owningApplication?.applicationName ?? front?.localizedName ?? "The app"
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == request.displayID }) ?? content.displays.first
            else { throw ScreenLookFailure.failed }
            let own = content.applications.filter { $0.processID == request.excluding }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            source = NSScreen.screens.first { $0.displayID == display.displayID }?.localizedName ?? "The display"
        }
        let configuration = SCStreamConfiguration()
        let pixels = ScreenSnapshot.fitted(CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                                                  height: filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        configuration.width = Int(pixels.width)
        configuration.height = Int(pixels.height)
        configuration.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return ScreenCapture(image: image, source: source)
        } catch {
            throw (error as? SCStreamError)?.code == .userDeclined ? ScreenLookFailure.permissionOff : ScreenLookFailure.failed
        }
    }

    /// Windows on screen, front to back: only their numbers, owners, layers and bounds.
    private static func windows() -> [ScreenLook.Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { return nil }
            return ScreenLook.Window(id: id, pid: pid, layer: layer, bounds: bounds)
        }
    }
}
