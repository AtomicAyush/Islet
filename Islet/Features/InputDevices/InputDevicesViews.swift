import AppKit
import SwiftUI

extension FeatureTint {
    /// A keyboard's, mouse's or trackpad's level when it is fine: the iPhone's green, as
    /// its Batteries widget draws it.
    static let inputDeviceLevel = FeatureTint.colour(RGB(bytes: 48, 209, 88))
}

/// The iPhone's Batteries widget's colours: green, orange from 20%, red from 10%.
enum InputDevicePalette {
    /// The level's colour. On its cable a device is green whatever its level, as the
    /// iPhone's battery turns green on the charger. Charging, a warning and a low
    /// battery never take the accent; a level that is fine is the feature's own colour.
    /// With `minimum: Contrast.text` it is the level's words.
    static func tint(
        for device: InputDevice, in theme: IslandTheme, minimum: Double = Contrast.graphic,
        on backdrop: IslandBackdrop = .island
    ) -> IslandInk {
        if device.isOnPower { return .hue(.charging, minimum: minimum, on: backdrop) }
        if device.level <= 10 { return .hue(.lowBattery, minimum: minimum, on: backdrop) }
        if device.level <= 20 { return .hue(.warning, minimum: minimum, on: backdrop) }
        return theme.restingLevel(.inputDeviceLevel, minimum: minimum, on: backdrop)
    }

    /// The level as words are drawn: the island's ink, unless it is low.
    static func text(for device: InputDevice, in theme: IslandTheme, on backdrop: IslandBackdrop = .island) -> IslandInk {
        device.isOnPower || device.level > 20
            ? .text(1, on: backdrop) : tint(for: device, in: theme, minimum: Contrast.text, on: backdrop)
    }
}

/// A device's picture, fitted into a box so a wide keyboard takes no more room than a
/// tall mouse.
struct InputDeviceGlyph: View {
    let symbol: String
    let width: CGFloat
    let height: CGFloat
    var weight: Font.Weight = .medium

    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .fontWeight(weight)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

// MARK: - Banner

/// Left of the notch as a battery runs low: which device, by picture and name. Where
/// there is no room for the name, or even the insets (the opened island's header gives
/// it 24 points), the picture.
struct InputDeviceLowLeading: View {
    let device: InputDevice

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: InputDeviceBannerLayout.glyphSpacing) {
                glyph
                Text(device.shortName)
                    .font(Font(InputDeviceBannerLayout.font))
                    .foregroundStyle(.islandPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: InputDeviceBannerLayout.maximumNameWidth, alignment: .leading)
            }
            .padding(.leading, InputDeviceBannerLayout.outerInset)
            .padding(.trailing, InputDeviceBannerLayout.innerInset)
            glyph
                .padding(.leading, InputDeviceBannerLayout.outerInset)
                .padding(.trailing, InputDeviceBannerLayout.innerInset)
            glyph
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glyph: some View {
        InputDeviceGlyph(
            symbol: device.symbol,
            width: InputDeviceBannerLayout.glyphWidth(for: device.symbol),
            height: InputDeviceBannerLayout.glyphSize.height
        )
        .foregroundStyle(.islandGraphic())
    }
}

/// Right of the notch: the level, in orange or red, and a battery drawn to it, against
/// the wing's outer edge. Only as wide as its content, for the opened island's header.
struct InputDeviceLowTrailing: View {
    let device: InputDevice
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let tint = InputDevicePalette.tint(for: device, in: theme)
        HStack(spacing: InputDeviceBannerLayout.valueSpacing) {
            Text("\(device.level)%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.island(InputDevicePalette.tint(for: device, in: theme, minimum: Contrast.text)))
                .lineLimit(1)
                .contentTransition(.numericText(value: Double(device.level)))
            BatteryGlyph(level: device.level, tint: tint)
                .frame(width: InputDeviceBannerLayout.batterySize.width, height: InputDeviceBannerLayout.batterySize.height)
        }
        .fixedSize()
        .padding(.leading, InputDeviceBannerLayout.innerInset)
        .padding(.trailing, InputDeviceBannerLayout.outerInset)
        .animation(.smooth(duration: 0.3), value: device.level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.shortName) battery \(device.level)%")
    }
}

/// The low-battery banner's measurements, matching the other compact banners: 13-point
/// semibold words, a picture about the size of the headphones', the same insets. Each
/// side asks only for its own width; the island makes both wings as wide as the wider,
/// so it stays centred on the notch.
enum InputDeviceBannerLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// The most room a picture gets. A keyboard fills its width; a mouse, narrower, is
    /// given only its own width, so the name follows it at the usual spacing.
    static let glyphSize = CGSize(width: 24, height: 18)
    static let glyphSpacing: CGFloat = 7
    /// Wide enough for the usual names whole ("Magic Keyboard", "MX Master 3S");
    /// anything longer truncates rather than stretch each wing past 165 points.
    static let maximumNameWidth: CGFloat = 112
    /// The battery beside the level: the Battery banner's.
    static let batterySize = CGSize(width: 26, height: 12)
    static let valueSpacing: CGFloat = 5
    /// Room between each wing's content and the island's outer edge, and the notch.
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10

    static func widths(for device: InputDevice) -> (leading: CGFloat, trailing: CGFloat) {
        let percent = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        return (
            outerInset + glyphWidth(for: device.symbol) + glyphSpacing
                + min(textWidth(device.shortName, font: font), maximumNameWidth) + innerInset,
            innerInset + textWidth("\(device.level)%", font: percent) + valueSpacing + batterySize.width + outerInset
        )
    }

    /// The width `symbol` takes fitted to the picture's height, at most the box's.
    static func glyphWidth(for symbol: String) -> CGFloat {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
              image.size.height > 0
        else { return glyphSize.width }
        return min(glyphSize.width, ceil(glyphSize.height * image.size.width / image.size.height))
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it,
    /// which would otherwise truncate a name that just fits.
    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}

// MARK: - Card

/// The card that drops down when a device connects, like the headphones': the device,
/// its name, and its battery. A device that connects low says so in the card.
struct InputDeviceConnectedCard: View {
    let device: InputDevice
    @Environment(\.islandTheme) private var theme
    @State private var hasAppeared = false

    var body: some View {
        HStack(spacing: 12) {
            InputDeviceGlyph(symbol: device.symbol, width: 44, height: 32, weight: .regular)
                .foregroundStyle(.islandGraphic())
                .frame(width: 46)
                .scaleEffect(hasAppeared ? 1 : 0.7)
                .opacity(hasAppeared ? 1 : 0)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.islandPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.island(statusColor))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InputDeviceBatteryRing(device: device, diameter: 30)
        }
        .frame(maxHeight: .infinity)
        .animation(.islandMorph, value: device.level)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62).delay(0.08)) { hasAppeared = true }
        }
    }

    private var status: String {
        if device.isOnPower { return "Charging" }
        if device.level <= 20 { return "Low Battery" }
        return "Connected"
    }

    private var statusColor: IslandInk {
        device.isOnPower || device.level > 20
            ? .text(0.55) : InputDevicePalette.tint(for: device, in: theme, minimum: Contrast.text)
    }
}

/// The level as a ring round its figure, filled to it, in the level's colour, as the
/// iPhone's Batteries widget draws it.
struct InputDeviceBatteryRing: View {
    let device: InputDevice
    let diameter: CGFloat
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let tint = IslandStyle(ink: InputDevicePalette.tint(for: device, in: theme))
        ZStack {
            Circle()
                .stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(device.level) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(device.level)")
                .font(.system(size: diameter * 0.34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.islandPrimary)
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.4), value: device.level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(device.level)%")
    }

    private var lineWidth: CGFloat { diameter >= 26 ? 3 : 2.5 }
}

// MARK: - Home

/// The home page tile while any device reports a battery. One device gets the tile to
/// itself — its picture and name, and its level beside a battery; several are listed a
/// row each, keyboards first, with their names where the tile is wide enough for them
/// and by picture alone where it is not.
struct InputDevicesHomeTile: View {
    let model: InputDevicesModel
    @Environment(\.islandTheme) private var theme

    /// As many rows as the tile holds, with a line under them for the rest.
    static let maximumRows = 3

    /// The devices the rows show, in display order: all of them if they fit, otherwise
    /// the lowest, since a device left off the tile must not be the one running out.
    static func shown(_ devices: [InputDevice]) -> [InputDevice] {
        guard devices.count > maximumRows else { return devices }
        let lowest = devices.enumerated()
            .sorted { $0.element.level != $1.element.level ? $0.element.level < $1.element.level : $0.offset < $1.offset }
            .prefix(maximumRows)
            .map(\.element)
        return devices.filter { device in lowest.contains { $0.id == device.id } }
    }

    var body: some View {
        let devices = model.devices
        Group {
            if devices.count == 1, let device = devices.first {
                single(device)
            } else if !devices.isEmpty {
                list(Self.shown(devices), more: devices.count - Self.shown(devices).count)
            }
        }
        .animation(.islandMorph, value: devices)
    }

    private func single(_ device: InputDevice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                InputDeviceGlyph(symbol: device.symbol, width: 24, height: 20)
                    .foregroundStyle(.islandGraphic(1, on: .homeTile))
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.shortName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.islandText(1, on: .homeTile))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(device.isOnPower ? "Charging" : "Connected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.islandText(0.55, on: .homeTile))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                BatteryGlyph(level: device.level, tint: InputDevicePalette.tint(for: device, in: theme, on: .homeTile), showsBolt: device.isOnPower)
                    .frame(width: 30, height: 14)
                Text("\(device.level)%")
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.island(InputDevicePalette.text(for: device, in: theme, on: .homeTile)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText(value: Double(device.level)))
            }
        }
    }

    /// Names where the tile is wide enough for them whole; otherwise the pictures alone,
    /// which say which device is which, as the iPhone's Batteries widget does. With the
    /// home page's tiles sharing its width, names only fit without the little batteries,
    /// so a row with a name gives its level alone, orange or red when low, with a bolt
    /// on the cable: two keyboards told apart by name matter more than a drawing.
    private func list(_ devices: [InputDevice], more: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                rows(devices, showsNames: true)
                rows(devices, showsNames: false)
            }
            if more > 0 {
                Text("+\(more) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.islandText(0.45, on: .homeTile))
                    .lineLimit(1)
            }
        }
    }

    /// A row with a name fits "Magic Keyboard" at 100% in about 160 points: the tile's
    /// width beside the date and the Mac's battery.
    private func rows(_ devices: [InputDevice], showsNames: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(devices) { device in
                HStack(spacing: 0) {
                    InputDeviceGlyph(symbol: device.symbol, width: 20, height: 16)
                        .foregroundStyle(.islandGraphic(1, on: .homeTile))
                    if showsNames {
                        Text(device.shortName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.islandText(0.8, on: .homeTile))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.leading, 6)
                        Spacer(minLength: 6)
                        if device.isOnPower {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.islandHue(.charging, on: .homeTile))
                                .padding(.trailing, 1)
                        }
                    } else {
                        Spacer(minLength: 6)
                        BatteryGlyph(level: device.level, tint: InputDevicePalette.tint(for: device, in: theme, on: .homeTile), showsBolt: device.isOnPower)
                            .frame(width: 22, height: 10)
                            .padding(.trailing, 6)
                    }
                    Text("\(device.level)%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.island(InputDevicePalette.text(for: device, in: theme, on: .homeTile)))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 31, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(device.shortName), \(device.level)%\(device.isOnPower ? ", charging" : "")")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
