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
    @AppStorage(Prefs.Key.islandFill) private var islandFill = IslandFill.standardPref
    @AppStorage(Prefs.Key.islandRing) private var islandRing = IslandRing.offPref
    @AppStorage(Prefs.Key.holdMotionWhenCaptured) private var holdMotionWhenCaptured = true
    /// Shown in a custom well while a swatch is chosen instead: a grey that is none of
    /// the swatches, so the well never looks like a second choice of the same colour,
    /// and opening the picker starts from something sensible rather than from white.
    private static let customStart = RGB(hex: 0x8E8E93)

    var body: some View {
        let theme = IslandTheme.cached(islandPref: islandColour, accentPref: accentColour, fillPref: islandFill)
        let island = RGB(hex: islandColour) ?? .black
        let fill = IslandFill(pref: islandFill)
        let ring = IslandRing(pref: islandRing)
        let hasNotch = NSScreen.screens.contains(where: \.hasNotch)
        let isCustomIsland = !IslandColourPreset.allCases.contains { $0.colour == island }
        let customAccent: RGB? = {
            guard case .colour(let chosen) = theme.accent,
                  !AccentChoice.presets.contains(where: { $0.colour == chosen }) else { return nil }
            return chosen
        }()

        Group {
            IslandThemePreview(theme: theme, hasNotch: hasNotch, ring: ring)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .settingsSearchTarget(id)

            LabeledContent("Fill") {
                Picker("Fill", selection: Binding(
                    get: { FillKind(fill) },
                    set: { kind in islandFill = kind.fill(keeping: fill).prefValue }
                )) {
                    ForEach(FillKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .settingsSearchHighlight(id)

            if let palette = fill.palette {
                FillRows(id: id, theme: theme, fill: fill, palette: palette) { islandFill = $0.prefValue }
            } else {
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
            }
            if !theme.isBlack, hasNotch {
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

            LabeledContent("Ring") {
                Picker("Ring", selection: Binding(
                    get: { RingKind(ring) },
                    set: { kind in islandRing = kind.ring(keeping: ring, accent: theme.accent).map(\.prefValue) ?? IslandRing.offPref }
                )) {
                    ForEach(RingKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .settingsSearchHighlight(id)
            if let ring {
                RingRows(id: id, ring: ring, fill: fill) { islandRing = $0.prefValue }
            }

            if fill.isRotating || ring.map({ if case .rotating = $0.colouring { true } else { false } }) == true {
                Toggle("Hold still while the screen is shared or recorded", isOn: $holdMotionWhenCaptured)
                    .settingsSearchHighlight(id)
                Caption("Colours hold still with Reduce Motion or Low Power Mode on.")
            }

            LabeledContent("Back to black and feature colours") {
                Button("Reset") {
                    islandColour = IslandTheme.standardIslandPref
                    accentColour = IslandTheme.standardAccentPref
                    islandFill = IslandFill.standardPref
                    islandRing = IslandRing.offPref
                }
                .disabled(theme.isDefault && ring == nil)
            }
            .settingsSearchHighlight(id)
        }
    }
}

/// Appearance › Fill, as the segmented control offers it.
private enum FillKind: CaseIterable {
    case solid, gradient, rotating

    init(_ fill: IslandFill) {
        switch fill {
        case .solid: self = .solid
        case .gradient: self = .gradient
        case .rotating: self = .rotating
        }
    }

    var title: String {
        switch self {
        case .solid: "Solid"
        case .gradient: "Gradient"
        case .rotating: "Rotating"
        }
    }

    /// This kind of fill, keeping the palette and tone already chosen, if any.
    func fill(keeping current: IslandFill) -> IslandFill {
        let palette = current.palette ?? IslandPalette(preset: .rainbow)
        let tone = current.tone ?? .auto
        switch self {
        case .solid: return .solid
        case .gradient: return .gradient(palette, tone, .down)
        case .rotating: return .rotating(palette, tone, .slow)
        }
    }
}

/// Appearance › Ring, as the segmented control offers it.
private enum RingKind: CaseIterable {
    case off, steady, rotating

    init(_ ring: IslandRing?) {
        switch ring?.colouring {
        case nil: self = .off
        case .steady: self = .steady
        case .rotating: self = .rotating
        }
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .steady: "Steady"
        case .rotating: "Rotating"
        }
    }

    /// This kind of ring, keeping how it looks. A steady ring starts in the accent, or
    /// Pink; a rotating one in the rainbow.
    func ring(keeping current: IslandRing?, accent: AccentChoice) -> IslandRing? {
        let start: IslandRing.Colouring
        switch self {
        case .off: return nil
        case .steady:
            if case .colour(let chosen) = accent {
                start = .steady(chosen)
            } else {
                start = .steady(AccentChoice.presets[0].colour)
            }
        case .rotating: start = .rotating(.palette(IslandPalette(preset: .rainbow)))
        }
        var ring = current ?? IslandRing(colouring: start)
        ring.colouring = start
        return ring
    }
}

/// The rows for a fill of several colours: its palette, its tone, which way it runs or
/// how fast, and which colours are drawn deeper or brighter than chosen.
private struct FillRows: View {
    let id: String
    let theme: IslandTheme
    let fill: IslandFill
    let palette: IslandPalette
    let set: (IslandFill) -> Void

    var body: some View {
        LabeledContent("Palette") {
            PalettePicker(palette: palette) { set(fill.with(palette: $0, tone: .auto)) }
        }
        .settingsSearchHighlight(id)

        LabeledContent("Tone") {
            Picker("Tone", selection: Binding(get: { theme.tone }, set: { set(fill.with(tone: $0)) })) {
                Text("Deep").tag(IslandTone.deep)
                Text("Bright").tag(IslandTone.bright)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .settingsSearchHighlight(id)

        switch fill {
        case .gradient(_, _, let direction):
            LabeledContent("Direction") {
                Picker("Direction", selection: Binding(get: { direction }, set: { set(fill.with(direction: $0)) })) {
                    ForEach(IslandGradientDirection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .settingsSearchHighlight(id)
        case .rotating(_, _, let speed):
            LabeledContent("Speed") {
                SpeedPicker(speed: speed) { set(fill.with(speed: $0)) }
            }
            .settingsSearchHighlight(id)
        case .solid:
            EmptyView()
        }

        let drawn = palette.colours.map { theme.drawn(fillColour: $0) }
        if drawn != palette.colours {
            LabeledContent("Drawn as") {
                HStack(spacing: 4) {
                    ForEach(Array(drawn.enumerated()), id: \.offset) { _, colour in
                        Capsule().fill(colour.color).frame(width: 18, height: 10)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("The colours as drawn")
            }
            Caption(Self.drawnCaption(chosen: palette.colours, drawn: drawn, isLight: theme.isLight))
        }
    }

    /// Names the colours that are drawn clearly darker or lighter than chosen, so the
    /// person knows which of them cannot share the island's words as they are.
    static func drawnCaption(chosen: [RGB], drawn: [RGB], isLight: Bool) -> String {
        let moved = zip(chosen, drawn).filter { a, b in
            max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)) > 0.12
        }
        var names: [String] = []
        for (colour, _) in moved where !names.contains(colour.name) { names.append(colour.name) }
        let words = isLight ? "black" : "white"
        guard !names.isEmpty else {
            return "Drawn a little \(isLight ? "brighter" : "deeper") so words read on every colour."
        }
        let list = ListFormatter.localizedString(byJoining: names)
        return "\(list.prefix(1).uppercased() + list.dropFirst()) \(names.count == 1 && moved.count == 1 ? "is" : "are") drawn \(isLight ? "lighter" : "darker") so \(words) words read on every colour."
    }
}

/// The rows for a ring: its colour or colours, how fast they travel, and how thick,
/// glowing and bright it is.
private struct RingRows: View {
    let id: String
    let ring: IslandRing
    let fill: IslandFill
    let set: (IslandRing) -> Void

    var body: some View {
        switch ring.colouring {
        case .steady(let colour):
            let isPreset = AccentChoice.presets.contains { $0.colour == colour }
            LabeledContent("Ring colour") {
                HStack(spacing: 8) {
                    ForEach(AccentChoice.presets, id: \.name) { preset in
                        Swatch(fill: AnyShapeStyle(preset.colour.color), name: preset.name, isSelected: colour == preset.colour) {
                            set(ring.with(colouring: .steady(preset.colour)))
                        }
                    }
                    ColorPicker("Custom ring colour", selection: Binding(
                        get: { (isPreset ? RGB(hex: 0x8E8E93) : colour).color },
                        set: { if let picked = RGB(NSColor($0)) { set(ring.with(colouring: .steady(picked))) } }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .help("Any colour")
                    .modifier(CustomWellRing(isSelected: !isPreset))
                }
            }
            .settingsSearchHighlight(id)
            if let clash = SystemHue.guarded.first(where: { colour.couldBeTaken(for: $0.dark) }) {
                Caption("This ring colour is close to the \(clash.meaning) Islet uses, so the two may be mistaken for each other.")
            }
        case .rotating(let palette):
            LabeledContent("Palette") {
                HStack(spacing: 8) {
                    if fill.palette != nil {
                        PaletteSwatch(colours: fill.palette?.colours ?? [], name: "Island's colours",
                                      isSelected: palette == .island) {
                            set(ring.with(colouring: .rotating(.island)))
                        }
                    }
                    // The island's colours on a solid island are drawn as Rainbow
                    // (`IslandRing.colours(on:)`), and shown so.
                    PalettePicker(palette: {
                        switch palette {
                        case .palette(let p): p
                        case .island: fill.palette == nil ? IslandPalette(preset: .rainbow) : nil
                        }
                    }()) {
                        set(ring.with(colouring: .rotating(.palette($0))))
                    }
                }
            }
            .settingsSearchHighlight(id)
            if palette == .island, fill.palette == nil {
                Caption("The island's own colours need a Gradient or Rotating fill, so the ring runs through Rainbow until it has one.")
            }
            LabeledContent("Speed") {
                SpeedPicker(speed: ring.speed) { speed in
                    var next = ring
                    next.speed = speed
                    set(next)
                }
            }
            .settingsSearchHighlight(id)
        }

        LabeledContent("Thickness") {
            Picker("Thickness", selection: Binding(get: { ring.thickness }, set: { thickness in
                var next = ring
                next.thickness = thickness
                set(next)
            })) {
                ForEach(IslandRingThickness.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .settingsSearchHighlight(id)
        LabeledContent("Glow") {
            Slider(value: Binding(get: { ring.glow }, set: { glow in
                var next = ring
                next.glow = glow
                set(next)
            }), in: IslandRing.glowRange) {
                Text("Glow")
            } minimumValueLabel: {
                Text("Off")
            } maximumValueLabel: {
                Text("Strong")
            }
            .labelsHidden()
            .frame(width: 220)
        }
        .settingsSearchHighlight(id)
        LabeledContent("Brightness") {
            Slider(value: Binding(get: { ring.brightness }, set: { brightness in
                var next = ring
                next.brightness = brightness
                set(next)
            }), in: IslandRing.brightnessRange) {
                Text("Brightness")
            } minimumValueLabel: {
                Text("40%")
            } maximumValueLabel: {
                Text("100%")
            }
            .labelsHidden()
            .frame(width: 220)
        }
        .settingsSearchHighlight(id)
        Caption("The ring runs round the island's edge and round the bubbles beside it. Under a notch it runs down from the menu bar, round the island and back up; at rest the island is the notch, so it has none there.")
    }
}

private extension IslandRing {
    func with(colouring: Colouring) -> IslandRing {
        var ring = self
        ring.colouring = colouring
        return ring
    }
}

private struct SpeedPicker: View {
    let speed: IslandMotionSpeed
    let set: (IslandMotionSpeed) -> Void

    var body: some View {
        Picker("Speed", selection: Binding(get: { speed }, set: set)) {
            ForEach(IslandMotionSpeed.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// The palette presets as small gradient capsules, and a custom palette of two to six
/// colour wells, with + and − to add and take away a colour.
private struct PalettePicker: View {
    /// The palette chosen, if it is one of these.
    let palette: IslandPalette?
    let choose: (IslandPalette) -> Void

    var body: some View {
        let custom = palette.flatMap { $0.preset == nil ? $0.colours : nil }
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(IslandPalettePreset.allCases) { preset in
                    PaletteSwatch(colours: preset.colours, name: preset.name, isSelected: palette?.preset == preset) {
                        choose(IslandPalette(preset: preset))
                    }
                }
                PaletteSwatch(colours: custom ?? [RGB(hex: 0x8E8E93)], name: "Custom", isSelected: custom != nil) {
                    let start = Array((palette?.colours ?? IslandPalettePreset.sunset.colours).prefix(IslandPalette.customRange.upperBound))
                    if let custom = IslandPalette(custom: start) { choose(custom) }
                }
            }
            if let custom {
                HStack(spacing: 6) {
                    ForEach(Array(custom.enumerated()), id: \.offset) { index, colour in
                        ColorPicker("Colour \(index + 1)", selection: Binding(
                            get: { colour.color },
                            set: { picked in
                                guard let picked = RGB(NSColor(picked)) else { return }
                                var colours = custom
                                colours[index] = picked
                                if let next = IslandPalette(custom: colours) { choose(next) }
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                    Button {
                        if let next = IslandPalette(custom: Array(custom.dropLast())) { choose(next) }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(custom.count <= IslandPalette.customRange.lowerBound)
                    .help("Take away the last colour")
                    Button {
                        if let next = IslandPalette(custom: custom + [custom[custom.count - 1].mixed(toward: custom[0], 0.5)]) {
                            choose(next)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(custom.count >= IslandPalette.customRange.upperBound)
                    .help("Add a colour")
                }
            }
        }
    }
}

/// One palette, as a small capsule of its colours.
private struct PaletteSwatch: View {
    let colours: [RGB]
    let name: String
    let isSelected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Capsule()
                .fill(LinearGradient(colors: colours.map(\.color), startPoint: .leading, endPoint: .trailing))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                .frame(width: 28, height: 14)
                .padding(3)
                .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension RGB {
    /// A plain name for the colour, for a caption.
    var name: String {
        let (hue, saturation) = hueAndSaturation
        if saturation < 0.2 {
            return luminance > 0.6 ? "white" : luminance < 0.05 ? "black" : "grey"
        }
        switch hue {
        case ..<15, 345...: return "red"
        case ..<45: return "orange"
        case ..<70: return "yellow"
        case ..<165: return "green"
        case ..<200: return "teal"
        case ..<255: return "blue"
        case ..<290: return "purple"
        default: return "pink"
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
///
/// A fill of several colours and the ring are drawn by the island's own paint, so they
/// move as the island's do, and hold still while the Settings window is covered or
/// closed. With either, a small compact island beside it shows the ring on the smallest
/// shape it runs round.
struct IslandThemePreview: View {
    let theme: IslandTheme
    var hasNotch = true
    var ring: IslandRing? = nil
    static let size = CGSize(width: 300, height: 118)

    var body: some View {
        if theme.isMulticolour || ring != nil {
            HStack(alignment: .top, spacing: 16) {
                opened
                CompactPreview(theme: theme, hasNotch: hasNotch, ring: ring)
            }
        } else {
            opened
        }
    }

    @ViewBuilder
    private var opened: some View {
        let notch = CGSize(width: 96, height: 22)
        let gap: CGFloat = hasNotch ? 0 : 4
        let islandShape = hasNotch
            ? IslandShape(earRadius: 8, bottomRadius: 22)
            : IslandShape(earRadius: 0, bottomRadius: 22, topRadius: 22)

        ZStack(alignment: .top) {
            // The menu bar, in its light appearance.
            Rectangle().fill(Color(white: 0.93)).frame(height: notch.height)

            ZStack(alignment: .top) {
                if theme.isMulticolour {
                    IslandPaint(style: theme.paintStyle)
                } else {
                    islandShape.fill(theme.background)
                }
                if let ring {
                    IslandRingView(ring: ring, edge: IslandEdge(shape: islandShape), room: IslandRingRoom(band: 3.5, glow: 6))
                }
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

/// The island compact beside the preview: a Timer's symbol and time either side of the
/// notch, or of the middle of the pill without one.
private struct CompactPreview: View {
    let theme: IslandTheme
    let hasNotch: Bool
    let ring: IslandRing?

    var body: some View {
        let notch = CGSize(width: 64, height: 22)
        let shape = hasNotch
            ? IslandShape(earRadius: 6, bottomRadius: 11)
            : IslandShape(earRadius: 0, bottomRadius: 11, topRadius: 11)
        ZStack(alignment: .top) {
            Rectangle().fill(Color(white: 0.93)).frame(height: notch.height)
            ZStack {
                if theme.isMulticolour {
                    IslandPaint(style: theme.paintStyle)
                } else {
                    shape.fill(theme.background)
                }
                if let ring {
                    IslandRingView(ring: ring, edge: IslandEdge(shape: shape), room: IslandRingRoom(band: 2, glow: 2))
                }
                HStack {
                    Image(systemName: "timer").foregroundStyle(.islandAccent(.timer))
                    Spacer()
                    Text("3:12").monospacedDigit().foregroundStyle(.islandAccentText(.timer))
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 14)
            }
            .frame(width: 140, height: hasNotch ? notch.height : 20)
            .clipShape(shape)
            .padding(.top, hasNotch ? 0 : 1)
            if hasNotch {
                UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7, style: .continuous)
                    .fill(Color.black)
                    .frame(width: notch.width, height: notch.height)
            }
        }
        .frame(width: 150, height: IslandThemePreview.size.height, alignment: .top)
        .environment(\.islandTheme, theme)
        .environment(\.colorScheme, theme.colorScheme)
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
