import AppKit
import SwiftUI

enum PresentationPalette {
    /// The system teal in its dark appearance, which is what the black island shows it
    /// against: apart from the privacy dots' green, orange, purple and blue.
    static let tint = Color(red: 64 / 255, green: 200 / 255, blue: 224 / 255)
    static let off = Color.white.opacity(0.5)
}

/// The crossed-out eye on a disc, matching `RoundButton`: teal while on, grey once off.
struct PresentationBadge: View {
    let isOn: Bool
    var diameter: CGFloat = 30

    var body: some View {
        let tint = isOn ? PresentationPalette.tint : PresentationPalette.off
        Image(systemName: isOn ? "eye.slash.fill" : "eye.fill")
            .font(.system(size: diameter * 0.4, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(tint.opacity(0.18)))
            .accessibilityHidden(true)
    }
}

// MARK: - Indicator card

/// The card the mark beside the notch opens: that personal alerts are being held back,
/// why ("Screen shared by Zoom"), how many so far, and a way to turn it off until that
/// ends. For an app capturing the screen that can be named, it also offers never to
/// turn on for it again, for one that captures the screen all the time. Once off it
/// says so for the moment before it closes.
struct PresentationIndicatorCard: View {
    let model: PresentationModel
    let center: ActivityCenter
    let turnOff: () -> Void
    var ignore: (PresentationApp) -> Void = { _ in }

    /// Wide enough for "Screen shared by Microsoft Teams and QuickTime Player" whole;
    /// longer reasons truncate.
    static let maxWidth: CGFloat = 330

    var body: some View {
        let state = model.shown
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                PresentationBadge(isOn: state.isOn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.isOn ? "Presentation Mode" : "Presentation Mode off")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.isOn ? .white : .white.opacity(0.8))
                        .lineLimit(1)
                    ForEach(state.reasons, id: \.self) { reason in
                        Text(reason.text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if state.isOn {
                        Text(Self.heldText(center.heldBack.isEmpty ? nil : center.heldBackCount))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(PresentationPalette.tint)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.isOn {
                VStack(alignment: .leading, spacing: 6) {
                    PresentationTurnOffButton(
                        title: state.hasTrigger ? "Turn Off Until This Ends" : "Turn Off",
                        action: turnOff
                    )
                    ForEach(Self.ignorable(in: state), id: \.self) { app in
                        PresentationTurnOffButton(title: "Don't Turn On for \(app.name)", isProminent: false) {
                            ignore(app)
                        }
                    }
                }
                .padding(.leading, 40)
            }
        }
        .animation(.smooth(duration: 0.3), value: state)
    }

    /// The apps capturing the screen that the card can offer to ignore, two at most:
    /// those with a bundle identifier, and not the ones people share and record the
    /// screen with, call apps, browsers and Apple's own, where the offer would only be a
    /// way to lose the protection by mistake.
    static func ignorable(in state: PresentationModel.State) -> [PresentationApp] {
        let apps = state.reasons.flatMap { reason -> [PresentationApp] in
            guard case .screen(let apps) = reason else { return [] }
            return apps.filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return !PresentationSignals.isSharingApp(id)
            }
        }
        return Array(apps.prefix(2))
    }

    /// What has been held back so far; `nil` while Settings hold nothing back.
    static func heldText(_ count: Int?) -> String {
        switch count {
        case nil: "Nothing is held back"
        case 0: "Personal alerts are held back"
        case 1: "1 alert held back so far"
        case let count?: "\(count) alerts held back so far"
        }
    }
}

/// The card's button, in teal on a capsule of it, matching `RoundButton`; one less
/// prominent in grey. A title too long for the card loses its middle.
private struct PresentationTurnOffButton: View {
    let title: String
    var isProminent = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let tint = isProminent ? PresentationPalette.tint : Color.white
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isProminent ? tint : tint.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(tint.opacity((isHovering ? 0.3 : 0.2) * (isProminent ? 1 : 0.5))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Banner

/// What a banner says: turned on or off by hand, or, once presenting ends, how many
/// alerts were held back.
enum PresentationAnnouncement: Equatable {
    case on
    case off
    case summary(Int)

    var isSummary: Bool {
        if case .summary = self { return true }
        return false
    }

    var symbol: String { self == .off ? "eye.fill" : "eye.slash.fill" }
    var symbolColor: Color { self == .off ? .white : PresentationPalette.tint }

    /// Left of the notch.
    var name: String {
        switch self {
        case .on, .off: "Presentation"
        case .summary(1): "1 alert"
        case .summary(let count): "\(count) alerts"
        }
    }

    /// All of it in one line, for the opened island's header, which leaves the left
    /// side room for the eye alone: "3 alerts held back", "Presentation On".
    var headerText: String { "\(name) \(status)" }

    /// Right of the notch.
    var status: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        case .summary: "held back"
        }
    }

    var statusColor: Color {
        switch self {
        case .on: PresentationPalette.tint
        case .off, .summary: .white.opacity(0.6)
        }
    }
}

/// Left of the notch: the eye and what the banner is about. Where there is no room for
/// the words, or even the insets (the opened island's header gives it 24 points), the
/// eye.
struct PresentationBannerLeading: View {
    let announcement: PresentationAnnouncement

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PresentationBannerLayout.symbolSpacing) {
                symbol
                Text(announcement.name)
                    .font(Font(PresentationBannerLayout.font))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, PresentationBannerLayout.outerInset)
            .padding(.trailing, PresentationBannerLayout.innerInset)
            symbol
                .padding(.leading, PresentationBannerLayout.outerInset)
                .padding(.trailing, PresentationBannerLayout.innerInset)
            symbol
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: some View {
        Image(systemName: announcement.symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .fontWeight(.semibold)
            .foregroundStyle(announcement.symbolColor)
            .frame(width: PresentationBannerLayout.symbolSize.width, height: PresentationBannerLayout.symbolSize.height)
            .accessibilityHidden(true)
    }
}

/// Right of the notch: "On" in teal, "Off", or "held back", against the wing's outer
/// edge. In the opened island's header, where the left side has room for the eye
/// alone, the whole of it: "3 alerts held back". Only as wide as its content.
struct PresentationBannerTrailing: View {
    let announcement: PresentationAnnouncement
    @Environment(\.isInIslandHeader) private var isInHeader

    var body: some View {
        Text(isInHeader ? announcement.headerText : announcement.status)
            .font(Font(PresentationBannerLayout.font))
            .foregroundStyle(isInHeader && announcement.isSummary ? .white : announcement.statusColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, PresentationBannerLayout.innerInset)
            .padding(.trailing, PresentationBannerLayout.outerInset)
    }
}

/// The banner's measurements, matching the other compact banners: 13-point semibold
/// words, a symbol a capital and a half tall, the same insets. Each side asks only for
/// its own width; the island evens them up beside the notch.
enum PresentationBannerLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// The eye is wider than it is tall.
    static let symbolSize = CGSize(width: 21, height: 15)
    static let symbolSpacing: CGFloat = 7
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10

    static func widths(for announcement: PresentationAnnouncement) -> (leading: CGFloat, trailing: CGFloat) {
        (
            outerInset + symbolSize.width + symbolSpacing + textWidth(announcement.name) + innerInset,
            innerInset + textWidth(announcement.status) + outerInset
        )
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it.
    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}

// MARK: - Settings

/// Under the feature's toggle: what turns it on, and what it holds back.
struct PresentationSettingsView: View {
    @AppStorage(PresentationPrefs.trigger(.screen)) private var screen = PresentationPrefs.triggerDefault
    @AppStorage(PresentationPrefs.trigger(.call)) private var call = PresentationPrefs.triggerDefault
    @AppStorage(PresentationPrefs.trigger(.slideshow)) private var slideshow = PresentationPrefs.triggerDefault
    @AppStorage(PresentationPrefs.heldBack(.messages)) private var messages = PresentationPrefs.heldBackDefault(.messages)
    @AppStorage(PresentationPrefs.heldBack(.files)) private var files = PresentationPrefs.heldBackDefault(.files)
    @AppStorage(PresentationPrefs.heldBack(.schedule)) private var schedule = PresentationPrefs.heldBackDefault(.schedule)
    @AppStorage(PresentationPrefs.heldBack(.music)) private var music = PresentationPrefs.heldBackDefault(.music)
    @AppStorage(PresentationPrefs.heldBack(.devices)) private var devices = PresentationPrefs.heldBackDefault(.devices)

    var body: some View {
        Section("Turn on while") {
            Toggle(isOn: $screen) {
                Text("The screen is shared or recorded")
                Text("By any app but Islet and those below. A screenshot doesn't count.")
            }
            if screen {
                IgnoredScreenApps()
            }
            Toggle(isOn: $call) {
                Text("On a call")
                Text("The camera is on, or a call app such as FaceTime, Zoom, Teams, Webex, Slack or Discord, or a browser, has the microphone.")
            }
            Toggle(isOn: $slideshow) {
                Text("Keynote or PowerPoint plays a slideshow")
            }
            LabeledContent {
                Button("Open Shortcuts") { ShortcutsTool.openShortcutsApp() }
            } label: {
                Text("Turn on yourself")
                Text("With Islet's Presentation Mode action in Shortcuts, or islet://presentation/toggle. It stays on until you turn it off.")
            }
        }
        Section("Hold back") {
            Toggle(isOn: $messages) {
                Text("Messages from scripts and tools")
                Text("Show in Islet banners, Claude Code's among them, and what a shortcut hands back.")
            }
            Toggle(isOn: $files) {
                Text("Files and the clipboard")
                Text("Screenshots, downloads and files being copied, and the clipboard and shelf on the home page.")
            }
            Toggle(isOn: $schedule) {
                Text("Calendar and Focus")
                Text("The day's events on the home page and the calendar's page, and which Focus comes on.")
            }
            Toggle(isOn: $music) {
                Text("Songs and lyrics")
                Text("A new song's banner, the line being sung and the song on the home page. The music stays beside the notch.")
            }
            Toggle(isOn: $devices) {
                Text("Device and network names")
                Text("Headphones, keyboards and mice connecting or running low, and the Wi-Fi network or VPN joined, which are often named after their owner.")
            }
            Text("The volume, brightness and the Mac's battery warnings still show, and the island still opens, on home. Afterwards it says how many messages and files it held back.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("To see a shared screen or a call, Islet watches the camera, the microphone and the screen, and reads the system log for which app is using them, as Camera, Microphone & More does, even while that is off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Apps whose capture of the screen doesn't turn Presentation Mode on: those that
/// capture it all the time, DisplayLink's driver to begin with. Offers those and
/// whatever is capturing the screen right now.
struct IgnoredScreenApps: View {
    @State private var ignored = PresentationPrefs.ignoredScreenAppIDs

    /// Names for identifiers that are a company's rather than an app's.
    private static let knownNames = ["com.displaylink": "DisplayLink"]

    var body: some View {
        LabeledContent("Don't turn on for") {
            Menu(summary) {
                ForEach(candidates, id: \.self) { id in
                    Toggle(Self.name(of: id), isOn: Binding(
                        get: { ignored.contains(id) },
                        set: { isOn in set(isOn ? ignored + [id] : ignored.filter { $0 != id }) }
                    ))
                }
                Divider()
                Button("Reset to DisplayLink") { set(PresentationPrefs.defaultIgnoredScreenApps) }
            }
            .fixedSize()
        }
    }

    private var candidates: [String] {
        var ids = PresentationPrefs.defaultIgnoredScreenApps
        let capturing = PrivacyMonitor.shared.readings.screen.apps.compactMap(\.bundleIdentifier)
        for id in ignored + capturing where !ids.contains(id) && id != PrivacyPrefs.ownBundleIdentifier { ids.append(id) }
        return ids
    }

    private var summary: String {
        let names = ignored.map(Self.name(of:))
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    private func set(_ ids: [String]) {
        ignored = ids
        PresentationPrefs.setIgnoredScreenApps(ids)
    }

    private static func name(of bundleIdentifier: String) -> String {
        if let name = knownNames[bundleIdentifier] { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return name
    }
}
