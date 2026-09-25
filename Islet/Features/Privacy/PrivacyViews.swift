import AppKit
import SwiftUI

/// The iPhone's privacy indicator colours: green while a camera is on, orange while
/// only a microphone is.
let privacyGreen = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
let privacyOrange = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)

extension PrivacyUsage {
    /// The indicator colour, or `nil` when nothing is in use.
    var tint: Color? {
        if camera { return privacyGreen }
        return microphone ? privacyOrange : nil
    }

    var symbol: String { (camera ? PrivacyMonitor.Sensor.camera : .microphone).symbol }

    /// "Camera", "Microphone", "Camera & Mic".
    var sensorName: String {
        camera && microphone ? "Camera & Mic" : (camera ? "Camera" : "Microphone")
    }

    /// "Zoom", "Zoom and Safari", or `nil` when nobody can be named.
    var appNames: String? {
        apps.isEmpty ? nil : apps.map(\.name).formatted(.list(type: .and))
    }

    /// "Camera", "Microphone · Zoom", "Camera & Mic · FaceTime".
    var title: String {
        [sensorName, appNames].compactMap { $0 }.joined(separator: " · ")
    }
}

extension PrivacyMonitor.Sensor {
    var symbol: String { self == .camera ? "video.fill" : "mic.fill" }
    var name: String { self == .camera ? "Camera" : "Microphone" }
}

struct PrivacyAppIcon: View {
    let app: PrivacyApp

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

/// A sensor's symbol on a tinted disc, matching `RoundButton`.
struct PrivacyBadge: View {
    let symbol: String
    let tint: Color
    var diameter: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.4, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(tint.opacity(0.2)))
    }
}

/// The home page tile, there only while something is in use.
struct PrivacyHomeTile: View {
    let monitor: PrivacyMonitor

    var body: some View {
        let usage = monitor.usage
        let tint = usage.tint ?? privacyOrange
        let lines = [usage.sensorName, usage.appNames].compactMap { $0 }

        VStack(alignment: .leading, spacing: 0) {
            // A crowded home row leaves tiles narrow: the app's icon goes first, then
            // the badge shrinks, so nothing spills into the neighbouring tile.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    PrivacyBadge(symbol: usage.symbol, tint: tint)
                    if let app = usage.apps.first {
                        PrivacyAppIcon(app: app)
                            .frame(width: 30, height: 30)
                    }
                }
                PrivacyBadge(symbol: usage.symbol, tint: tint)
                PrivacyBadge(symbol: usage.symbol, tint: tint, diameter: 22)
            }
            Spacer(minLength: 6)
            // One line when the tile is wide enough; otherwise the sensor over the app,
            // at the largest size where each line fits whole. (Text allowed two lines
            // wraps mid-word before it shrinks.) The smallest size truncates.
            ViewThatFits(in: .horizontal) {
                Text(usage.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                ForEach([12, 11, 10, 9, 8.5] as [CGFloat], id: \.self) { size in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { Text(lines[$0]) }
                    }
                    .font(.system(size: size, weight: .semibold))
                    .lineLimit(1)
                }
            }
            .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Left of the notch while announcing: who started — the app's icon and name, or,
/// when the app cannot be named, the sensor itself. Where there is no room for the
/// name (the opened island's header gives it 24 points), just the icon.
struct PrivacyBannerLeading: View {
    let start: PrivacyMonitor.Start
    let tint: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PrivacyBannerLayout.iconSpacing) {
                icon
                Text(PrivacyBannerLayout.name(of: start))
                    .font(Font(PrivacyBannerLayout.font))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: PrivacyBannerLayout.maximumNameWidth, alignment: .leading)
            }
            .padding(.leading, PrivacyBannerLayout.outerInset)
            .padding(.trailing, PrivacyBannerLayout.innerInset)
            icon
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let app = start.app {
            PrivacyAppIcon(app: app)
                .frame(width: PrivacyBannerLayout.iconWidth, height: PrivacyBannerLayout.iconWidth)
        } else {
            PrivacyBadge(symbol: start.sensor.symbol, tint: tint, diameter: PrivacyBannerLayout.iconWidth)
        }
    }
}

/// Right of the notch while announcing: what the app started using, or — when no
/// app can be named — that the sensor is in use, in the colour of the dot.
struct PrivacyBannerTrailing: View {
    let start: PrivacyMonitor.Start
    let tint: Color

    /// Only as wide as its content: the opened island's header sets this beside the
    /// leading icon, where a view that filled its width would push the two apart.
    var body: some View {
        HStack(spacing: PrivacyBannerLayout.glyphSpacing) {
            if start.app != nil {
                Image(systemName: start.sensor.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: PrivacyBannerLayout.glyphWidth)
            }
            Text(PrivacyBannerLayout.status(of: start))
                .font(Font(PrivacyBannerLayout.font))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.leading, PrivacyBannerLayout.innerInset)
        .padding(.trailing, PrivacyBannerLayout.outerInset)
    }
}

/// The announcement's measurements. The island makes both wings as wide as the
/// wider side needs; each side asks only for its own width, so the narrower one
/// sits against the island's outer edge, as the other does, rather than centred in
/// its wing. (The right side cannot fill its wing instead: the opened island's
/// header would part it from the icon.)
enum PrivacyBannerLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let iconWidth: CGFloat = 20
    static let iconSpacing: CGFloat = 6
    static let glyphWidth: CGFloat = 16
    static let glyphSpacing: CGFloat = 5
    /// Wide enough for the usual names whole ("Microsoft Teams", "QuickTime
    /// Player"); anything longer truncates, keeping each wing within 170 points.
    static let maximumNameWidth: CGFloat = 122
    /// Room between each wing's content and the island's outer edge, and the notch.
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10

    /// Left of the notch: the app that started, or, with none to name, the sensor.
    static func name(of start: PrivacyMonitor.Start) -> String {
        start.app?.name ?? start.sensor.name
    }

    /// Right of the notch: the sensor beside the app that started it, or, with no
    /// app to name, what the sensor on the left is doing.
    static func status(of start: PrivacyMonitor.Start) -> String {
        start.app == nil ? "In Use" : start.sensor.name
    }

    /// The room each side of the notch needs for `start`.
    static func widths(for start: PrivacyMonitor.Start) -> (leading: CGFloat, trailing: CGFloat) {
        let nameWidth = min(textWidth(name(of: start)), maximumNameWidth)
        let statusWidth = (start.app == nil ? 0 : glyphWidth + glyphSpacing) + textWidth(status(of: start))
        return (
            outerInset + iconWidth + iconSpacing + nameWidth + innerInset,
            innerInset + statusWidth + outerInset
        )
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it,
    /// which would otherwise truncate a name that just fits.
    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}

struct PrivacySettingsView: View {
    @AppStorage(PrivacyPrefs.camera) private var camera = true
    @AppStorage(PrivacyPrefs.microphone) private var microphone = true
    @AppStorage(PrivacyPrefs.sayWhichApp) private var sayWhichApp = false

    var body: some View {
        Toggle("Camera", isOn: $camera)
        Toggle("Microphone", isOn: $microphone)
        Toggle(isOn: $sayWhichApp) {
            Text("Say which app")
            Text("Names the app for a moment when it starts using the camera or microphone.")
        }
    }
}
