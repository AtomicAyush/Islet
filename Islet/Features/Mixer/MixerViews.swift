import SwiftUI

extension FeatureTint {
    /// The levels' bars: white on the black island.
    static let mixer = FeatureTint.neutral
}

/// The Mixer's colours that mean something, as macOS draws its system orange, red and
/// yellow in dark mode, which is what the Mixer has always drawn on the black island.
/// They never take the accent; on other islands they are only fitted for contrast.
enum MixerColour {
    /// A level past 100%: louder than the app plays by itself.
    static let boost = RGB(bytes: 255, 146, 48)
    /// A muted app.
    static let muted = RGB(bytes: 255, 66, 69)
    /// A level that could not be set, or access Islet has not been given.
    static let caution = RGB(bytes: 255, 214, 0)
}

extension IslandTheme {
    /// An accent so near the boost's orange that the two parts of a boosted bar would
    /// run together: the bar up to 100% is then drawn in the island's ink instead.
    var mixerAccentLikeBoost: Bool {
        let source = accentSource(.mixer)
        return source != ink && source.couldBeTaken(for: MixerColour.boost)
    }

    /// The bar up to 100%, as a style and as the colour it is drawn in, measured
    /// against the track it lies on.
    var mixerLevel: (style: IslandStyle, colour: RGB) {
        let source = accentSource(.mixer)
        if source == ink || mixerAccentLikeBoost { return (.islandGraphic(on: .mixerTrack), ink) }
        return (.islandAccent(.mixer, on: .mixerTrack), fitted(source, on: .mixerTrack))
    }
}

extension IslandBackdrop {
    /// A level's track: the bar and the part past 100% lie on it.
    static let mixerTrack = IslandBackdrop.track(0.18)
}

// MARK: - Pieces

struct MixerAppIcon: View {
    let model: MixerModel
    let app: MixerSource
    let size: CGFloat

    var body: some View {
        Image(nsImage: model.icon(for: app))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// The playing apps' icons overlapping, the newest in front.
struct MixerIconStack: View {
    let model: MixerModel
    var size: CGFloat = 18
    @Environment(\.islandTheme) private var theme

    static let limit = 3
    /// How much of an icon the next one covers.
    private static let overlap: CGFloat = 0.4

    static func width(count: Int, size: CGFloat = 18) -> CGFloat {
        let shown = CGFloat(min(max(count, 1), limit))
        return size + (shown - 1) * size * (1 - overlap)
    }

    var body: some View {
        let shown = Array(model.apps.suffix(Self.limit).enumerated())
        HStack(spacing: -size * Self.overlap) {
            ForEach(shown, id: \.element.id) { index, app in
                MixerAppIcon(model: model, app: app, size: size)
                    // A halo of the island's own colour, parting each icon from the one
                    // behind it.
                    .shadow(color: theme.background.opacity(0.8), radius: 1.5)
                    .zIndex(Double(index))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.islandMorph, value: shown.map(\.element.id))
    }
}

/// The level as a bar, dragged to change it. The part past 100% is orange, with a
/// tick where 100% is, and a light catch there so it is easy to find again.
struct MixerSlider: View {
    let model: MixerModel
    let app: MixerSource
    var thickness: CGFloat = 6
    @State private var isDragging = false
    @Environment(\.islandTheme) private var theme

    /// Levels this close to 100% snap to it.
    private static let detent = 0.04

    var body: some View {
        let level = model.level(for: app)
        let muted = model.isMuted(app)
        let height = isDragging ? thickness + 3 : thickness
        let bar = theme.mixerLevel

        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let unity = width / CGFloat(MixerModel.maximum)
            let filled = width * CGFloat(level / MixerModel.maximum)

            ZStack(alignment: .leading) {
                Rectangle().fill(.islandSurface(0.18))
                Rectangle()
                    .fill(bar.style.dimmedLevel(muted ? 0.3 : 1, on: .mixerTrack))
                    .frame(width: min(filled, unity))
                if filled > unity {
                    Rectangle()
                        .fill(IslandStyle.islandFitted(MixerColour.boost, on: .mixerTrack).dimmedLevel(muted ? 0.3 : 1, on: .mixerTrack))
                        .frame(width: filled - unity)
                        .offset(x: unity)
                }
            }
            .frame(height: height)
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                // Over the bar, the colour that stands out on it; over the track, the ink.
                Capsule()
                    .fill(filled > unity ? .islandOnFill(bar.colour).opacity(0.45) : .islandGraphic(0.45, on: .mixerTrack))
                    .frame(width: 2, height: height + 4)
                    .offset(x: unity - 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        model.setLevel(Self.level(at: value.location.x, width: width), for: app, isFinal: false)
                    }
                    .onEnded { value in
                        model.setLevel(Self.level(at: value.location.x, width: width), for: app, isFinal: true)
                        isDragging = false
                    }
            )
        }
        .frame(height: 18)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
        .onDisappear {
            // The island can close, or the app stop playing, under a drag; the drag
            // then never ends, so the level it reached is settled here.
            if isDragging { model.setLevel(model.level(for: app), for: app, isFinal: true) }
        }
        .accessibilityElement()
        .accessibilityLabel("\(app.name) volume")
        .accessibilityValue(MixerPercent.text(level))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            model.setLevel(level + step, for: app, isFinal: true)
        }
    }

    private static func level(at x: CGFloat, width: CGFloat) -> Double {
        let raw = Double(min(max(x / width, 0), 1)) * MixerModel.maximum
        return abs(raw - 1) < detent ? 1 : raw
    }
}

enum MixerPercent {
    /// "85%".
    static func text(_ level: Double) -> String {
        "\(Int((level * 100).rounded()))%"
    }
}

// MARK: - Presentations

struct MixerCompactLeading: View {
    let model: MixerModel

    var body: some View {
        MixerIconStack(model: model, size: 18)
    }
}

/// The app on top of the icon stack, by name — the island picks one to show rather
/// than a count — and "+1" for the others playing too.
struct MixerCompactTrailing: View {
    let model: MixerModel

    static let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let maximumNameWidth: CGFloat = 110
    static let inset: CGFloat = 10

    /// The width the name and the count need, for the activity's wing.
    static func width(featured: String?, others: Int) -> CGFloat {
        let name = featured.map {
            min(ceil(($0 as NSString).size(withAttributes: [.font: nameFont]).width) + 2, maximumNameWidth)
        } ?? 0
        let count = others > 0 ? 6 + ceil(("+\(others)" as NSString).size(withAttributes: [.font: nameFont]).width) + 2 : 0
        return name + count + 2 * inset
    }

    var body: some View {
        let others = max(0, model.apps.count - 1)
        HStack(spacing: 6) {
            if let featured = model.apps.last {
                Text(featured.name)
                    .font(Font(Self.nameFont))
                    .foregroundStyle(.islandPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.maximumNameWidth, alignment: .trailing)
                    .id(featured.id)
                    .transition(.opacity)
            }
            if others > 0 {
                Text("+\(others)")
                    .font(Font(Self.nameFont))
                    .foregroundStyle(.islandText(0.55))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .fixedSize()
            }
        }
        .animation(.islandMorph, value: model.apps.map(\.id))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, Self.inset)
    }
}

/// The detached bubble: whichever app started last, which is seldom the one the
/// island itself is showing.
struct MixerMinimal: View {
    let model: MixerModel

    var body: some View {
        // The bubble sits beside whatever holds the island — usually the song playing —
        // so it shows another of the apps playing, not that one again.
        let inIsland = ActivityCenter.shared.primary?.appBundleIdentifier
        if let app = model.apps.last(where: { $0.id != inIsland }) ?? model.apps.last {
            MixerAppIcon(model: model, app: app, size: 20)
                .id(app.id)
                .transition(.opacity)
        } else {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.islandGraphic(0.55))
        }
    }
}

/// The opened island: a row for each app, four at a time, scrolling past that.
struct MixerExpanded: View {
    let model: MixerModel

    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 6
    static let visibleRows = 4
    static let noteHeight: CGFloat = 30
    private static let topInset: CGFloat = 6

    static func height(rows: Int, hasNote: Bool) -> CGFloat {
        let shown = CGFloat(min(max(rows, 1), visibleRows))
        let list = shown * rowHeight + (shown - 1) * rowSpacing
        return topInset + list + (hasNote ? rowSpacing + noteHeight : 0)
    }

    var body: some View {
        let apps = model.apps
        let shown = CGFloat(min(max(apps.count, 1), Self.visibleRows))

        VStack(spacing: Self.rowSpacing) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(apps) { app in
                        MixerRow(model: model, app: app)
                            .frame(height: Self.rowHeight)
                            .transition(.opacity)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: shown * Self.rowHeight + (shown - 1) * Self.rowSpacing)

            if let note = model.note {
                MixerNoteView(note: note)
                    .frame(height: Self.noteHeight)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, Self.topInset)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.islandMorph, value: apps.map(\.id))
        .onAppear { model.refreshAccess() }
    }
}

private struct MixerRow: View {
    let model: MixerModel
    let app: MixerSource

    var body: some View {
        let muted = model.isMuted(app)

        HStack(spacing: 12) {
            MixerAppIcon(model: model, app: app, size: 26)
            Text(app.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.islandPrimary)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            MixerSlider(model: model, app: app)
            level(muted: muted)
                .frame(width: 44, alignment: .trailing)
            RoundButton(
                symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                tint: muted ? .fitted(MixerColour.muted) : .text(1),
                diameter: 28
            ) {
                model.toggleMute(app)
            }
            .accessibilityLabel(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
    }

    @ViewBuilder
    private func level(muted: Bool) -> some View {
        if model.failed.contains(app.id) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.islandFitted(MixerColour.caution))
                .help("Islet couldn't set \(app.name)'s volume")
        } else {
            Text(muted ? "Muted" : MixerPercent.text(model.level(for: app)))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.islandText(0.55))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Why levels are not being applied, and what to do about it.
private struct MixerNoteView: View {
    let note: MixerModel.Note

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.islandText(0.55))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            if note == .denied, let url = AudioCapturePermission.settingsURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("Open Settings")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.islandText(1, on: .surface(0.14)))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(.islandSurface(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    private var symbol: String {
        switch note {
        case .unsupported: "info.circle.fill"
        case .requesting: "hand.raised.fill"
        case .denied: "lock.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: IslandStyle {
        switch note {
        case .unsupported, .requesting: .islandGraphic(0.55)
        case .denied, .failed: .islandFitted(MixerColour.caution)
        }
    }

    private var text: String {
        switch note {
        case .unsupported:
            "Setting each app's volume needs macOS 14.2 or later."
        case .requesting:
            "Allow Islet to record system audio, and it can set each app's volume."
        case .denied:
            "Allow Islet under System Audio Recording Only to set each app's volume."
        case .failed(let names):
            "Islet couldn't set the volume of \(names.formatted(.list(type: .and)))."
        }
    }
}

// MARK: - Home

/// The home page tile, while anything plays: each app with a small slider. Clicking
/// an icon mutes the app. Three apps fit the tile; more scroll.
struct MixerHomeTile: View {
    let model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sound", systemImage: "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.islandText(0.55, on: .homeTile))
                .lineLimit(1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(model.apps) { app in
                        MixerHomeRow(model: model, app: app)
                    }
                }
                // Room for the last row's mute badge, which hangs below its icon.
                .padding(.bottom, 3)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct MixerHomeRow: View {
    let model: MixerModel
    let app: MixerSource
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let muted = model.isMuted(app)
        let badge = theme.fitted(MixerColour.muted, on: .homeTile)

        HStack(spacing: 8) {
            Button {
                model.toggleMute(app)
            } label: {
                MixerAppIcon(model: model, app: app, size: 18)
                    .opacity(muted ? 0.45 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if muted {
                            // White on the red badge on the black island, as it always
                            // was; elsewhere whichever of black and white reads on it.
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 6, weight: .bold))
                                .foregroundStyle(theme.isDefault ? .islandPrimary : .islandOnFill(badge))
                                .frame(width: 11, height: 11)
                                .background(Circle().fill(.islandFill(badge)))
                                .offset(x: 3, y: 3)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(muted ? "Unmute \(app.name)" : "Mute \(app.name)")

            MixerSlider(model: model, app: app, thickness: 5)
        }
        .frame(height: 18)
    }
}

// MARK: - Settings

struct MixerSettings: View {
    let model: MixerModel
    /// Lets the island follow the toggle straight away.
    let onShowWhenSeveralChange: () -> Void
    @AppStorage(MixerPrefs.showWhenSeveral) private var showWhenSeveral = MixerPrefs.showWhenSeveralDefault

    var body: some View {
        Toggle("Show when several apps play at once", isOn: $showWhenSeveral)
            .onChange(of: showWhenSeveral) { onShowWhenSeveralChange() }

        LabeledContent("System audio recording") {
            access
        }
        if model.access == .denied {
            Text("Setting each app's volume passes its sound through Islet. Turn Islet on under System Audio Recording Only, in Privacy & Security › Screen & System Audio Recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button("Reset all app volumes") { model.resetAll() }
            .disabled(!model.hasCustomLevels)
            .onAppear { model.refreshAccess() }
    }

    @ViewBuilder
    private var access: some View {
        switch model.access {
        case .unsupported:
            Text("Needs macOS 14.2 or later").foregroundStyle(.secondary)
        case .unknown:
            Text("Asked when you first change an app's volume").foregroundStyle(.secondary)
        case .requesting:
            Text("Waiting for your answer…").foregroundStyle(.secondary)
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            if let url = AudioCapturePermission.settingsURL {
                Button("Open System Settings…") { NSWorkspace.shared.open(url) }
            } else {
                Text("Not allowed").foregroundStyle(.secondary)
            }
        }
    }
}
