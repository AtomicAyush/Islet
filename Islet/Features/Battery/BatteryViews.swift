import SwiftUI

/// The iPhone's system colours, as its battery indicator uses them.
enum BatteryPalette {
    static let green = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let red = Color(red: 1, green: 69 / 255, blue: 58 / 255)
    static let yellow = Color(red: 1, green: 214 / 255, blue: 10 / 255)
}

extension BatteryState {
    /// The glyph's colour: green while charging, yellow in Low Power Mode, red when
    /// low on battery, white otherwise, in that order of precedence.
    var tint: Color {
        if isCharging { return BatteryPalette.green }
        if isLowPowerMode { return BatteryPalette.yellow }
        if !isPluggedIn && level <= 20 { return BatteryPalette.red }
        return .white
    }

    /// What the battery is doing, then the estimate that goes with it, if any.
    var statusParts: [String] {
        if isPluggedIn {
            if isCharging {
                return ["Charging"] + Self.estimate(minutesToFull, suffix: " to full")
            }
            return [isFull ? "Fully charged" : "Not charging"]
        }
        let remaining = Self.estimate(minutesToEmpty, suffix: " remaining")
        return remaining.isEmpty ? ["On battery"] : remaining
    }

    /// "1:05 to full"; "Calculating…" while IOKit is still estimating; nothing when it
    /// has no figure to give.
    private static func estimate(_ minutes: Int, suffix: String) -> [String] {
        if minutes < 0 { return ["Calculating…"] }
        if minutes == 0 { return [] }
        return [String(format: "%d:%02d", minutes / 60, minutes % 60) + suffix]
    }
}

// MARK: - Glyph

/// The iPhone's battery: an outlined body with a nub, filled to the level, with a
/// bolt knocked out of it while charging. Draws at whatever size it is given; about
/// 26 x 12 beside the notch.
struct BatteryGlyph: View {
    let level: Int
    let tint: Color
    var showsBolt = false

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let nub = max(1.5, height * 0.14)
            let bodyWidth = max(0, geo.size.width - nub - max(0.5, height * 0.06))
            let stroke = max(1, height / 12)
            let inset = 2 * stroke
            let inner = max(0, bodyWidth - 2 * inset)
            let fraction = CGFloat(min(100, max(0, level))) / 100
            // A sliver stays visible at 1%, as it does on the iPhone.
            let fill = level > 0 ? min(inner, max(inner * fraction, 1.5)) : 0
            let corner = height * 0.3
            let bolt = CGSize(width: height * 0.6, height: height * 0.92)
            let boltOffset = CGSize(width: (bodyWidth - bolt.width) / 2, height: 0)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(tint.opacity(0.4), lineWidth: stroke)
                    .frame(width: bodyWidth, height: height)
                RoundedRectangle(cornerRadius: max(1, corner - inset), style: .continuous)
                    .fill(tint)
                    .frame(width: fill, height: max(0, height - 2 * inset))
                    .offset(x: inset)
                UnevenRoundedRectangle(bottomTrailingRadius: nub * 0.7, topTrailingRadius: nub * 0.7)
                    .fill(tint.opacity(0.4))
                    .frame(width: nub, height: height * 0.36)
                    .offset(x: geo.size.width - nub)
                if showsBolt {
                    // Cut a gap around the bolt, so it reads against the fill and the
                    // empty body alike.
                    BatteryBolt()
                        .stroke(style: StrokeStyle(lineWidth: max(1.2, height * 0.16), lineJoin: .round))
                        .frame(width: bolt.width, height: bolt.height)
                        .offset(boltOffset)
                        .blendMode(.destinationOut)
                }
            }
            .frame(width: geo.size.width, height: height)
            .compositingGroup()
            .overlay(alignment: .leading) {
                if showsBolt {
                    BatteryBolt()
                        .fill(Color.white)
                        .frame(width: bolt.width, height: bolt.height)
                        .offset(boltOffset)
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: level)
        .accessibilityElement()
        .accessibilityLabel(showsBolt ? "Battery \(level)%, charging" : "Battery \(level)%")
    }
}

/// A lightning bolt drawn to fill its frame.
struct BatteryBolt: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.64, 0))
        path.addLine(to: point(0.04, 0.58))
        path.addLine(to: point(0.46, 0.58))
        path.addLine(to: point(0.36, 1))
        path.addLine(to: point(0.96, 0.42))
        path.addLine(to: point(0.54, 0.42))
        path.closeSubpath()
        return path
    }
}

// MARK: - Banners

/// One battery moment as a compact banner, worded and coloured the way the iPhone
/// shows it: what happened left of the camera, the level and glyph right of it.
struct BatteryAlert: Equatable {
    /// Plugging in, unplugging, and charging starting a moment after the cable went
    /// in share one id, so a correction updates the banner already up.
    static let powerID = "battery.power"
    static let lowID = "battery.low"
    static let chargedID = "battery.charged"
    static let lowPowerID = "battery.lowPower"
    static let ids = [powerID, lowID, chargedID, lowPowerID]

    /// Every battery banner is this wide either side of the camera, so the island stays
    /// centred on it and an in-place update never changes its size. It fits the longest
    /// label, "Low Battery" (76 pt at 13 pt semibold), and "100%" beside the glyph, with
    /// the paddings below.
    static let wingWidth: CGFloat = 94
    /// Clear of the island's rounded bottom corners.
    static let outerPadding: CGFloat = 10
    /// Clear of the camera housing.
    static let innerPadding: CGFloat = 8
    static let glyphSize = CGSize(width: 26, height: 12)

    var id: String
    var label: String
    var labelColor: Color = .white
    /// Stands in for the label where there is no room for words.
    var symbol: String
    var value: String
    var valueColor: Color = .white
    var level: Int
    var glyphTint: Color
    var showsBolt = false
    var duration: TimeInterval = 2.8

    var banner: IslandBanner {
        IslandBanner(
            id: id,
            style: .compact(leading: Self.wingWidth, trailing: Self.wingWidth),
            duration: duration,
            leading: AnyView(BatteryBannerLeading(alert: self)),
            trailing: AnyView(BatteryBannerTrailing(alert: self))
        )
    }

    /// The charger went in or out.
    static func power(_ state: BatteryState) -> BatteryAlert {
        let percent = "\(state.level)%"
        if state.isPluggedIn && state.isCharging {
            return BatteryAlert(
                id: powerID, label: "Charging", symbol: "bolt.fill",
                value: percent, valueColor: BatteryPalette.green,
                level: state.level, glyphTint: state.tint, showsBolt: true
            )
        }
        if state.isPluggedIn {
            // Held at a charge limit, or already full: power is flowing, but the
            // battery is not taking it, so no green and no bolt.
            return BatteryAlert(
                id: powerID, label: "Connected", symbol: "powerplug.fill",
                value: percent, level: state.level, glyphTint: state.tint
            )
        }
        return BatteryAlert(
            id: powerID, label: "On Battery", symbol: "bolt.slash.fill",
            value: percent, level: state.level, glyphTint: state.tint
        )
    }

    static func low(_ state: BatteryState) -> BatteryAlert {
        BatteryAlert(
            id: lowID, label: "Low Battery", labelColor: BatteryPalette.red,
            symbol: "exclamationmark.triangle.fill",
            value: "\(state.level)%", valueColor: BatteryPalette.red,
            level: state.level, glyphTint: BatteryPalette.red, duration: 4
        )
    }

    static func charged(_ state: BatteryState) -> BatteryAlert {
        BatteryAlert(
            id: chargedID, label: "Charged", labelColor: BatteryPalette.green,
            symbol: "checkmark.circle.fill",
            value: "\(state.level)%", valueColor: BatteryPalette.green,
            level: state.level, glyphTint: BatteryPalette.green
        )
    }

    static func lowPower(_ state: BatteryState) -> BatteryAlert {
        let on = state.isLowPowerMode
        return BatteryAlert(
            id: lowPowerID, label: "Low Power", symbol: "gauge.with.dots.needle.33percent",
            value: on ? "On" : "Off", valueColor: on ? BatteryPalette.yellow : .white,
            level: state.level, glyphTint: on ? BatteryPalette.yellow : state.tint,
            showsBolt: state.isCharging
        )
    }
}

/// Left of the camera: what happened, in words. Where a banner's left side gets no
/// room for words (the opened island's header gives it 22 pt), a symbol says it.
struct BatteryBannerLeading: View {
    let alert: BatteryAlert

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 44 {
                Text(alert.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(alert.labelColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.leading, BatteryAlert.outerPadding)
                    .padding(.trailing, BatteryAlert.innerPadding)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            } else {
                Image(systemName: alert.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(alert.valueColor)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .animation(.smooth(duration: 0.3), value: alert)
    }
}

/// Right of the camera: the level, then the glyph.
struct BatteryBannerTrailing: View {
    let alert: BatteryAlert

    var body: some View {
        HStack(spacing: 5) {
            Text(alert.value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(alert.valueColor)
                .lineLimit(1)
                .contentTransition(.numericText())
            BatteryGlyph(level: alert.level, tint: alert.glyphTint, showsBolt: alert.showsBolt)
                .frame(width: BatteryAlert.glyphSize.width, height: BatteryAlert.glyphSize.height)
        }
        .padding(.trailing, BatteryAlert.outerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.smooth(duration: 0.3), value: alert)
    }
}

// MARK: - Home

/// The home page's battery tile: the glyph, the level, and what the battery is doing.
struct BatteryHomeTile: View {
    let state: BatteryState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BatteryGlyph(level: state.level, tint: state.tint, showsBolt: state.isCharging)
                .frame(width: 34, height: 16)
            Text("\(state.level)%")
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText(value: Double(state.level)))
                .padding(.top, 6)
            BatteryStatusText(parts: state.statusParts)
        }
        .animation(.smooth(duration: 0.35), value: state)
    }
}

/// The tile for the live reading. The feature removes the tile when there is none.
struct BatteryLiveTile: View {
    let model: BatteryModel

    var body: some View {
        if let state = model.state {
            BatteryHomeTile(state: state)
        }
    }
}

/// "Charging · 1:05 to full" on one line where the tile is wide enough, otherwise one
/// part per line.
private struct BatteryStatusText: View {
    let parts: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(parts.joined(separator: " · "))
            VStack(alignment: .leading, spacing: 1) {
                ForEach(parts, id: \.self) { Text($0) }
            }
            .minimumScaleFactor(0.8)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
    }
}
