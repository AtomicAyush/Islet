import SwiftUI

/// The colours that mean something: a privacy light, a battery running low, a job done
/// or failed, a Focus. They never take the accent. They start from `dark` (the iPhone's
/// system colours in their dark appearance), which is exactly what the default black
/// island draws; anywhere else a hue that doesn't stand out enough is only fitted for
/// contrast, moved toward the island's ink just far enough, which keeps the hue.
enum SystemHue: String, CaseIterable, Sendable, Hashable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    /// As tuned for the black island.
    var dark: RGB {
        switch self {
        case .red: RGB(bytes: 255, 69, 58)
        case .orange: RGB(bytes: 255, 159, 10)
        case .yellow: RGB(bytes: 255, 214, 10)
        case .green: RGB(bytes: 48, 209, 88)
        case .mint: RGB(bytes: 99, 230, 226)
        case .teal: RGB(bytes: 64, 200, 224)
        case .cyan: RGB(bytes: 100, 210, 255)
        case .blue: RGB(bytes: 10, 132, 255)
        case .indigo: RGB(bytes: 94, 92, 230)
        case .purple: RGB(bytes: 191, 90, 242)
        case .pink: RGB(bytes: 255, 55, 95)
        case .brown: RGB(bytes: 172, 142, 104)
        case .gray: RGB(bytes: 152, 152, 157)
        }
    }

    /// The system's own colour of this hue, which macOS fits to a window's light or dark
    /// appearance: for Settings, where the island's tuning does not apply.
    var system: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    // What each hue means, so a call site says why it is coloured.
    static let success = SystemHue.green
    static let charging = SystemHue.green
    static let camera = SystemHue.green
    static let failure = SystemHue.red
    static let lowBattery = SystemHue.red
    static let destructive = SystemHue.red
    static let muted = SystemHue.red
    static let warning = SystemHue.orange
    static let microphone = SystemHue.orange
    static let lowPower = SystemHue.yellow
    static let capture = SystemHue.purple
    static let location = SystemHue.blue

    /// The hues an accent should not be mistaken for: the privacy lights beside the
    /// notch, and the colours of warnings and failures.
    static let guarded: [SystemHue] = [.camera, .microphone, .capture, .location, .failure]
}
