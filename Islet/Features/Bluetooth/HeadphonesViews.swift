import SwiftUI

/// iOS system colours for battery levels.
enum HeadsetPalette {
    static let green = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let red = Color(red: 1, green: 69 / 255, blue: 58 / 255)
}

/// A headset's picture, fitted to a box so that wide AirPods Pro and tall AirPods Max
/// read at the same size.
struct HeadsetGlyph: View {
    let symbol: String
    let width: CGFloat
    let height: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .fontWeight(weight)
            .scaledToFit()
            .frame(maxWidth: width, maxHeight: height)
    }
}

/// One battery level as a ring that fills on arrival, green or red at 20% and below,
/// with its label underneath.
struct HeadsetBatteryRing: View {
    let reading: HeadsetBattery.Reading
    let diameter: CGFloat
    @State private var fill: CGFloat = 0

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fill)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(reading.level)")
                    .font(.system(size: diameter * 0.34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .frame(width: diameter, height: diameter)

            if let label = reading.label {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7).delay(0.15)) { fill = target }
        }
        .onChange(of: reading.level) {
            withAnimation(.easeOut(duration: 0.4)) { fill = target }
        }
    }

    private var target: CGFloat { CGFloat(reading.level) / 100 }
    private var lineWidth: CGFloat { diameter >= 26 ? 3 : 2.5 }
    private var color: Color { reading.level <= 20 ? HeadsetPalette.red : HeadsetPalette.green }
}

/// A ring for each level the headset reports.
struct HeadsetBatteryRings: View {
    let battery: HeadsetBattery
    let diameter: CGFloat
    var spacing: CGFloat = 8

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(battery.readings) { reading in
                HeadsetBatteryRing(reading: reading, diameter: diameter)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .fixedSize()
    }
}

// MARK: - Banners

/// The card that drops down when a headset connects, like the iPhone's: the headset,
/// its name, and its battery. Levels often arrive after the card is up; they slide in.
struct HeadsetConnectedCard: View {
    let headset: Headset
    @State private var hasAppeared = false

    var body: some View {
        HStack(spacing: 12) {
            HeadsetGlyph(symbol: headset.symbol, width: 46, height: 36)
                .foregroundStyle(.white)
                .frame(width: 46)
                .scaleEffect(hasAppeared ? 1 : 0.7)
                .opacity(hasAppeared ? 1 : 0)

            VStack(alignment: .leading, spacing: 1) {
                Text(headset.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("Connected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HeadsetBatteryRings(battery: headset.battery, diameter: 28)
        }
        .frame(maxHeight: .infinity)
        .animation(.islandMorph, value: headset.battery)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62).delay(0.08)) { hasAppeared = true }
        }
    }
}

/// Left of the notch when a headset disconnects: which one, by picture and name.
/// Where there is no room for the name, or even the insets (the opened island's
/// header gives it 24 points), just the picture.
struct HeadsetDisconnectedLeading: View {
    let headset: Headset

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: HeadsetDisconnectedLayout.glyphSpacing) {
                glyph
                Text(headset.shortName)
                    .font(Font(HeadsetDisconnectedLayout.font))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: HeadsetDisconnectedLayout.maximumNameWidth, alignment: .leading)
            }
            .modifier(HeadsetDisconnectedLayout.LeadingInsets())
            glyph
                .modifier(HeadsetDisconnectedLayout.LeadingInsets())
            glyph
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glyph: some View {
        HeadsetGlyph(symbol: headset.symbol, width: HeadsetDisconnectedLayout.glyphWidth, height: 18, weight: .medium)
            .foregroundStyle(.white)
            .frame(width: HeadsetDisconnectedLayout.glyphWidth, height: 20)
    }
}

/// Right of the notch: what happened, quieter than the name and against the
/// wing's outer edge, mirroring the name on the left.
struct HeadsetDisconnectedTrailing: View {
    var body: some View {
        Text(HeadsetDisconnectedLayout.status)
            .font(Font(HeadsetDisconnectedLayout.font))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, HeadsetDisconnectedLayout.innerInset)
            .padding(.trailing, HeadsetDisconnectedLayout.outerInset)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The disconnection banner's measurements. Both wings are the same width, so the
/// island stays centred on the notch.
enum HeadsetDisconnectedLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let status = "Disconnected"
    /// Wide enough for the usual names whole ("AirPods Max", "Beats Studio Pro");
    /// anything longer truncates rather than stretch each wing past 165 points.
    static let maximumNameWidth: CGFloat = 112
    static let glyphWidth: CGFloat = 24
    static let glyphSpacing: CGFloat = 7
    /// Room between each wing's content and the island's outer edge, and the notch.
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10

    struct LeadingInsets: ViewModifier {
        func body(content: Content) -> some View {
            content.padding(.leading, outerInset).padding(.trailing, innerInset)
        }
    }

    /// The width of each wing: whichever side needs more, used for both.
    static func wingWidth(name: String) -> CGFloat {
        let leading = glyphWidth + glyphSpacing + min(textWidth(name), maximumNameWidth)
        return max(leading, textWidth(status)) + outerInset + innerInset
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it,
    /// which would otherwise truncate a name that just fits.
    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}

// MARK: - Home

/// The home page tile while a headset is connected: which one, and its battery. Tiles
/// share the row, so each part falls back to a narrower layout when this one is slim.
struct HeadsetHomeTile: View {
    let model: HeadphonesModel

    var body: some View {
        if let headset = model.current {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        glyph(headset)
                        VStack(alignment: .leading, spacing: 0) {
                            name(headset)
                            Text(status)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        glyph(headset)
                        name(headset)
                    }
                }

                Spacer(minLength: 0)

                if !headset.battery.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HeadsetBatteryRings(battery: headset.battery, diameter: 26)
                        HeadsetBatteryRings(battery: headset.battery, diameter: 22, spacing: 5)
                        HeadsetBatteryList(battery: headset.battery)
                    }
                } else if BluetoothLevels.shared.authorization == .notDetermined {
                    // Only Bluetooth knows some headphones' battery (AirPods Max among
                    // them); offer to ask, rather than asking unprompted.
                    Button {
                        BluetoothLevels.shared.requestAccess()
                    } label: {
                        Label("Show battery…", systemImage: "battery.75percent")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
            .animation(.islandMorph, value: headset.battery)
            .onAppear { model.refreshLevels(olderThan: 60) }
        }
    }

    private func glyph(_ headset: Headset) -> some View {
        HeadsetGlyph(symbol: headset.symbol, width: 24, height: 20, weight: .medium)
            .foregroundStyle(.white)
            .frame(width: 24, alignment: .leading)
    }

    private func name(_ headset: Headset) -> some View {
        Text(headset.shortName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var status: String {
        model.headsets.count > 1 ? "\(model.headsets.count) connected" : "Connected"
    }
}

/// Levels as text, for a tile too narrow for rings.
private struct HeadsetBatteryList: View {
    let battery: HeadsetBattery

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(battery.readings) { reading in
                HStack(spacing: 4) {
                    if let label = reading.label {
                        Text(label).foregroundStyle(.white.opacity(0.55))
                    }
                    Text("\(reading.level)%")
                        .foregroundStyle(reading.level <= 20 ? HeadsetPalette.red : .white)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }
}
