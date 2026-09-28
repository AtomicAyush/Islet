import AppKit
import SwiftUI

/// Settings › General › Appearance: the island's colour and the one accent colour, with
/// a small island drawn in them. The Settings window itself keeps following macOS.
struct AppearanceSection: View {
    var body: some View {
        Section("Appearance") {
            GeneralRow.appearance
        }
    }
}

/// The Appearance section's rows, a General row of their own so that a search finds
/// them (`GeneralRow.appearance`).
struct AppearanceRows: View {
    let id: String
    @AppStorage(Prefs.Key.islandColour) private var islandColour = IslandTheme.standardIslandPref
    @AppStorage(Prefs.Key.accentColour) private var accentColour = IslandTheme.standardAccentPref
    /// Shown in a custom well while a swatch is chosen instead: a grey that is none of
    /// the swatches, so the well never looks like a second choice of the same colour,
    /// and opening the picker starts from something sensible rather than from white.
    private static let customStart = RGB(hex: 0x8E8E93)

    var body: some View {
        let theme = IslandTheme.cached(islandPref: islandColour, accentPref: accentColour)
        let island = RGB(hex: islandColour) ?? .black
        let hasNotch = NSScreen.screens.contains(where: \.hasNotch)
        let isCustomIsland = !IslandColourPreset.allCases.contains { $0.colour == island }
        let customAccent: RGB? = {
            guard case .colour(let chosen) = theme.accent,
                  !AccentChoice.presets.contains(where: { $0.colour == chosen }) else { return nil }
            return chosen
        }()

        Group {
            IslandThemePreview(theme: theme, hasNotch: hasNotch)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .settingsSearchTarget(id)

            LabeledContent("Island colour") {
                HStack(spacing: 8) {
                    ForEach(IslandColourPreset.allCases) { preset in
                        Swatch(fill: AnyShapeStyle(preset.colour.color), name: preset.name,
                               isSelected: island == preset.colour) {
                            islandColour = preset.colour.hex
                        }
                    }
                    ColorPicker("Custom island colour", selection: Binding(
                        get: { (isCustomIsland ? island : Self.customStart).color },
                        set: { if let picked = RGB(NSColor($0)) { islandColour = picked.hex } }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .help("Any colour")
                    .modifier(CustomWellRing(isSelected: isCustomIsland))
                }
            }
            .settingsSearchHighlight(id)
            if island != .black, hasNotch {
                Caption("The camera housing is always black, so at rest the island stays black and still looks like the notch. When it shows something, the colour grows out around it.")
            }
            if theme.isLight {
                Caption("On a light island, words and symbols are drawn in black.")
            }
            if let clash = theme.islandClash {
                Caption("This island colour is close to the \(clash.meaning), so on it that colour is drawn darker or lighter to stand apart from the island.")
            }

            LabeledContent("Accent") {
                HStack(spacing: 8) {
                    Swatch(fill: AnyShapeStyle(FeatureColoursSwatch.gradient), name: "Feature colours",
                           isSelected: theme.accent == .featureColours) {
                        accentColour = AccentChoice.featureColours.prefValue
                    }
                    ForEach(AccentChoice.presets, id: \.name) { preset in
                        Swatch(fill: AnyShapeStyle(preset.colour.color), name: preset.name,
                               isSelected: theme.accent == .colour(preset.colour)) {
                            accentColour = AccentChoice.colour(preset.colour).prefValue
                        }
                    }
                    Swatch(fill: AnyShapeStyle(MonoSwatch.gradient), name: "Mono: the island's text colour",
                           isSelected: theme.accent == .mono) {
                        accentColour = AccentChoice.mono.prefValue
                    }
                    ColorPicker("Custom accent", selection: Binding(
                        get: { (customAccent ?? Self.customStart).color },
                        set: { if let picked = RGB(NSColor($0)) { accentColour = AccentChoice.colour(picked).prefValue } }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .help("Any colour")
                    .modifier(CustomWellRing(isSelected: customAccent != nil))
                }
            }
            .settingsSearchHighlight(id)
            Caption("Symbols, rings, progress and what's selected. The camera and microphone lights, battery, failure, warning, Focus, Presentation Mode, network and Pomodoro break colours keep their own, as do your banners' and calendars' colours, and any colour is darkened or lightened just enough to stand out on the island.")
            if let clash = theme.accentClash {
                Caption("This accent is close to the \(clash.meaning) Islet uses, so the two may be mistaken for each other.")
            }

            LabeledContent("Back to black and feature colours") {
                Button("Reset") {
                    islandColour = IslandTheme.standardIslandPref
                    accentColour = IslandTheme.standardAccentPref
                }
                .disabled(theme.isDefault)
            }
            .settingsSearchHighlight(id)
        }
    }
}

/// A small caption under a setting.
private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// The selection ring round a custom colour well while its own colour is the one
/// chosen, as a swatch has.
private struct CustomWellRing: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One round colour choice.
private struct Swatch: View {
    let fill: AnyShapeStyle
    let name: String
    let isSelected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private enum FeatureColoursSwatch {
    /// A few of the features' own colours, round the swatch.
    static let gradient = AngularGradient(colors: [
        RGB(1.0, 0.62, 0.04).color, RGB(hex: 0x0A84FF).color, RGB(hex: 0xD97757).color,
        RGB(0.75, 0.35, 0.95).color, RGB(1.0, 0.62, 0.04).color,
    ], center: .center)
}

private enum MonoSwatch {
    static let gradient = LinearGradient(stops: [
        .init(color: .white, location: 0.5), .init(color: .black, location: 0.5),
    ], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension SystemHue {
    /// What this hue means on the island, for the Settings caption.
    var meaning: String {
        switch self {
        case .green: "green of the camera light"
        case .orange: "orange of the microphone light and of warnings"
        case .purple: "purple of screen recording"
        case .blue: "blue of location use"
        case .red: "red of failures and low battery"
        default: rawValue
        }
    }
}

/// A small opened island drawn in `theme`, under a strip of menu bar: the words,
/// symbols, a ring, a level and a selected tab, so a colour can be judged before it is
/// used. With a notch it hangs from the bar with the black camera housing at its top, as
/// the island does; without one it floats below the bar, all in the colour.
struct IslandThemePreview: View {
    let theme: IslandTheme
    var hasNotch = true
    static let size = CGSize(width: 300, height: 118)

    var body: some View {
        let notch = CGSize(width: 96, height: 22)
        let gap: CGFloat = hasNotch ? 0 : 4
        let islandShape = hasNotch
            ? IslandShape(earRadius: 8, bottomRadius: 22)
            : IslandShape(earRadius: 0, bottomRadius: 22, topRadius: 22)

        ZStack(alignment: .top) {
            // The menu bar, in its light appearance.
            Rectangle().fill(Color(white: 0.93)).frame(height: notch.height)

            ZStack(alignment: .top) {
                islandShape.fill(theme.background)
                PreviewContent()
                    .padding(.top, hasNotch ? notch.height + 6 : 14)
                    .padding(.horizontal, 22)
            }
            .frame(width: 264, height: Self.size.height - gap)
            .clipShape(islandShape)
            .padding(.top, gap)

            if hasNotch {
                // The camera housing, black whatever the island's colour.
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                    .fill(Color.black)
                    .frame(width: notch.width, height: notch.height)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .environment(\.islandTheme, theme)
        .environment(\.colorScheme, theme.colorScheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A preview of the island in these colours")
    }
}

/// What the preview island shows: a timer with its ring, a line of secondary words, a
/// level, a button on a chip, and a row of tabs with one selected.
private struct PreviewContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(.islandDecorative(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: 0.7)
                        .stroke(.islandAccent(.timer), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Tea").font(.system(size: 12, weight: .semibold)).foregroundStyle(.islandPrimary)
                    Text("Nearly ready").font(.system(size: 10)).foregroundStyle(.islandText(0.55))
                }
                Spacer(minLength: 4)
                Text("3:12").font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.islandAccentText(.timer))
                Text("Stop")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.islandText(1, on: .surface(0.14)))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.islandSurface(0.14)))
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(.islandGraphic(0.55))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.islandDecorative(0.2))
                        Capsule().fill(.islandAccent(.shell)).frame(width: proxy.size.width * 0.6)
                    }
                }
                .frame(height: 5)
                HStack(spacing: 2) {
                    ForEach(Array(["house.fill", "music.note", "timer"].enumerated()), id: \.offset) { index, symbol in
                        Image(systemName: symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(index == 0 ? AnyShapeStyle(.islandPrimary) : AnyShapeStyle(.islandGraphic(0.45)))
                            .frame(width: 22, height: 18)
                            .background(Capsule().fill(index == 0 ? AnyShapeStyle(.islandSurface(0.16)) : AnyShapeStyle(.clear)))
                    }
                }
            }
        }
    }
}
