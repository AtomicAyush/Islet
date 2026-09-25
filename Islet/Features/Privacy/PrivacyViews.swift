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

/// Left of the notch while announcing: the app's icon, or the sensor's symbol when
/// the app cannot be named.
struct PrivacyBannerLeading: View {
    let start: PrivacyMonitor.Start
    let tint: Color

    var body: some View {
        if let app = start.app {
            PrivacyAppIcon(app: app)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: start.sensor.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

/// Right of the notch while announcing: who started, in the colour of their dot.
struct PrivacyBannerTrailing: View {
    let text: String
    let tint: Color

    /// Room for `text` beside the notch: the text itself and 10 pt either side,
    /// within what a compact banner can reasonably take.
    static func width(for text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        return min(max(ceil(measured) + 20, 44), 170)
    }

    /// Only as wide as the text: the opened island's header sets this beside the
    /// leading icon, where a view that filled its width would push the two apart.
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
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
