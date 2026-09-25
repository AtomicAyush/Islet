import AppKit
import SwiftUI

/// The privacy indicator colours: the iPhone's green while a camera is on and orange
/// while only a microphone is, macOS's purple while the screen or the Mac's sound is
/// being recorded, and the system blue of the location arrow.
let privacyGreen = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
let privacyOrange = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
let privacyPurple = Color(red: 0xBF / 255, green: 0x5A / 255, blue: 0xF2 / 255)
let privacyBlue = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)

extension PrivacyUsage {
    /// The camera and microphone dot's colour, or `nil` when neither is in use.
    var dotTint: Color? {
        if camera.inUse { return privacyGreen }
        return microphone.inUse ? privacyOrange : nil
    }

    /// Whether the purple dot is lit: the screen, or the Mac's sound, recorded by an
    /// app other than Islet.
    var capturesScreenOrSound: Bool { screen.inUse || systemAudio.inUse }
}

extension PrivacyMonitor.Sensor {
    var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .screen: "rectangle.dashed.badge.record"
        case .systemAudio: "waveform"
        case .location: "location.fill"
        }
    }

    var name: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screen: "Screen"
        case .systemAudio: "System Audio"
        case .location: "Location"
        }
    }

    /// The colour of the mark this sensor lights.
    var tint: Color {
        switch self {
        case .camera: privacyGreen
        case .microphone: privacyOrange
        case .screen, .systemAudio: privacyPurple
        case .location: privacyBlue
        }
    }
}

extension PrivacyUse {
    /// "Zoom", "Zoom and Safari", or `nil` when nobody can be named.
    var appNames: String? {
        apps.isEmpty ? nil : apps.map(\.name).formatted(.list(type: .and))
    }
}

/// An app's icon. An app known only by name has none, and draws nothing.
struct PrivacyAppIcon: View {
    let app: PrivacyApp

    var body: some View {
        if let path = app.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
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

// MARK: - Home

/// The home page tile, there only while something is in use. With one sensor in use
/// it is the sensor and its app, large; with more, a line for each: the sensor's
/// symbol in its colour, the app's icon, and "Microphone · Zoom", or "Microphone · In
/// use" where macOS does not say who.
struct PrivacyHomeTile: View {
    let monitor: PrivacyMonitor

    /// Wider with more than one sensor to list, so each line's names fit.
    static func weight(for usage: PrivacyUsage) -> CGFloat {
        usage.sensorsInUse.count > 1 ? 1.5 : 1
    }

    var body: some View {
        let usage = monitor.usage
        let sensors = usage.sensorsInUse
        if sensors.count == 1, let sensor = sensors.first {
            PrivacySingleSensor(sensor: sensor, use: usage[sensor])
        } else {
            // Every line says the sensor's name beside the app's where all of them
            // fit, or else none does: the symbol still says which sensor it is.
            ViewThatFits(in: .horizontal) {
                lines(usage, sensors, full: true)
                lines(usage, sensors, full: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func lines(_ usage: PrivacyUsage, _ sensors: [PrivacyMonitor.Sensor], full: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sensors, id: \.self) { sensor in
                PrivacySensorLine(sensor: sensor, use: usage[sensor], full: full)
                    .frame(maxHeight: 22)
            }
            // Islet's own recording, beside the rest, where there is room: it explains
            // the purple dot macOS shows that Islet does not.
            if usage.soundMixer, sensors.count < 4 {
                PrivacySoundMixerLine(full: full)
                    .frame(maxHeight: 22)
            }
        }
    }
}

/// One sensor in use, large: its badge and the app's icon, then what is in use and by
/// whom.
private struct PrivacySingleSensor: View {
    let sensor: PrivacyMonitor.Sensor
    let use: PrivacyUse

    var body: some View {
        let tint = sensor.tint
        let lines = [sensor.name, use.appNames ?? "In use"]

        VStack(alignment: .leading, spacing: 0) {
            // A crowded home row leaves tiles narrow: the app's icon goes first, then
            // the badge shrinks, so nothing spills into the neighbouring tile.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    PrivacyBadge(symbol: sensor.symbol, tint: tint)
                    if let app = use.apps.first, app.bundlePath != nil {
                        PrivacyAppIcon(app: app)
                            .frame(width: 30, height: 30)
                    }
                }
                PrivacyBadge(symbol: sensor.symbol, tint: tint)
                PrivacyBadge(symbol: sensor.symbol, tint: tint, diameter: 22)
            }
            Spacer(minLength: 6)
            // One line when the tile is wide enough; otherwise the sensor over the app,
            // at the largest size where each line fits whole. (Text allowed two lines
            // wraps mid-word before it shrinks.) The smallest size truncates.
            ViewThatFits(in: .horizontal) {
                Text(lines.joined(separator: " · "))
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

/// A line of the tile: the sensor's symbol, the first app's icon, and who. `full`
/// names the sensor too ("Microphone · Zoom"); otherwise the app alone, or the sensor
/// alone where no app can be named.
private struct PrivacySensorLine: View {
    let sensor: PrivacyMonitor.Sensor
    let use: PrivacyUse
    let full: Bool

    static let font = Font.system(size: 11, weight: .semibold)

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: sensor.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(sensor.tint)
                .frame(width: 16)
            if let app = use.apps.first, app.bundlePath != nil {
                PrivacyAppIcon(app: app)
                    .frame(width: 15, height: 15)
            }
            Text(full ? "\(sensor.name) · \(use.appNames ?? "In use")" : use.appNames ?? sensor.name)
                .font(Self.font)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Sound Mixer's own recording, muted: it is expected, and lights nothing.
private struct PrivacySoundMixerLine: View {
    let full: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: PrivacyMonitor.Sensor.systemAudio.symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 16)
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 15, height: 15)
            Text(full ? "Islet — Sound Mixer" : "Sound Mixer")
                .font(PrivacySensorLine.font)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.white.opacity(0.4))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Banner

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
        if let app = start.app, app.bundlePath != nil {
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

// MARK: - Settings

struct PrivacySettingsView: View {
    let monitor: PrivacyMonitor

    var body: some View {
        PrivacySettingsRows(names: monitor.names)
    }
}

/// The options, and why apps go unnamed when they do.
struct PrivacySettingsRows: View {
    let names: PrivacyNameTracker.Status
    @AppStorage(PrivacyPrefs.camera) private var camera = true
    @AppStorage(PrivacyPrefs.microphone) private var microphone = true
    @AppStorage(PrivacyPrefs.screen) private var screen = true
    @AppStorage(PrivacyPrefs.location) private var location = false
    @AppStorage(PrivacyPrefs.sayWhichApp) private var sayWhichApp = false

    var body: some View {
        Toggle("Camera", isOn: $camera)
        Toggle("Microphone", isOn: $microphone)
        Toggle(isOn: $screen) {
            Text("Screen & system audio")
            Text(Self.screenDetail(for: names))
        }
        Toggle(isOn: $location) {
            Text("Location")
            Text(Self.locationDetail(for: names))
        }
        Toggle(isOn: $sayWhichApp) {
            Text("Say which app")
            Text("Names the app for a moment when it starts using the camera, microphone or screen.")
        }
        if let note = Self.note(for: names) {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Without the system log, the screen's dot is WindowServer's word alone, which
    /// counts screen mirroring too, and an app recording what the Mac plays is not seen.
    static func screenDetail(for status: PrivacyNameTracker.Status) -> String {
        switch status {
        case .off, .running:
            "A purple dot while an app records the screen or what the Mac plays. The Sound Mixer's own recording never lights it."
        case .notAdministrator, .failed:
            "A purple dot while the screen is being captured, which screen mirroring can light too."
        }
    }

    static func locationDetail(for status: PrivacyNameTracker.Status) -> String {
        switch status {
        case .off, .running:
            "An arrow while an app gets the Mac's location. A single look-up keeps it lit for about twelve seconds."
        case .notAdministrator:
            "macOS tells only administrator accounts when an app gets the Mac's location."
        case .failed:
            "macOS isn't letting Islet see when an app gets the Mac's location right now."
        }
    }

    /// Why apps go unnamed, when they do, and what cannot be seen at all.
    static func note(for status: PrivacyNameTracker.Status) -> String? {
        switch status {
        case .off, .running:
            nil
        case .notAdministrator:
            "macOS only lets administrator accounts see which app is using a sensor, so Islet names only microphone apps, and can't see system audio or location in use."
        case .failed:
            "macOS isn't letting Islet see which app is using a sensor right now, so it names only microphone apps, and can't see system audio or location in use."
        }
    }
}
