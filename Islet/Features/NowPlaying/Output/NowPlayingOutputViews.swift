import SwiftUI

// MARK: - Button

/// The player's way to the outputs, at the end of its controls as on the iPhone's
/// island: the AirPods or receiver the sound is going to, or AirPlay's symbol for the
/// Mac's own speakers and the rest. Lit while its panel is open, like the library's
/// buttons.
struct NowPlayingOutputButton: View {
    let outputs: OutputPickerModel
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    static let diameter: CGFloat = 26

    var body: some View {
        Button(action: action) {
            Image(systemName: outputs.buttonSymbol)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(isSelected ? Color.black : .white.opacity(isHovering ? 1 : 0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Circle().fill(isSelected ? Color.white : .white.opacity(isHovering ? 0.18 : 0.11)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.2), value: outputs.buttonSymbol)
        .help(outputs.current.map { "Playing on \($0.name)" } ?? "Output")
        .accessibilityLabel("Output")
        .accessibilityValue(outputs.current?.name ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Panel

/// The outputs, as the Sound menu lists them: the volume of the one in use, then
/// every output with a checkmark on that one and AirPods' listening mode and spatial
/// audio under theirs, and last a way to AirPlay receivers, which only Sound settings
/// may list.
struct NowPlayingOutputPanel: View {
    let model: NowPlayingModel
    let outputs: OutputPickerModel

    var body: some View {
        VStack(spacing: 4) {
            OutputVolumeSlider(outputs: outputs)
                .padding(.horizontal, 8)

            if let failure = outputs.failure {
                OutputFailureLine(text: failure)
                    .padding(.horizontal, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ScrollViewReader { proxy in
                // A handful of outputs, all made at once, so the current one's
                // margins can be scrolled to wherever its row is.
                PanelList(isLazy: false) {
                    ForEach(OutputLine.lines(outputs.devices, controls: outputs.controls)) { line in
                        switch line {
                        case .header(let title):
                            PanelHeader(title: title)
                        case .device(let device):
                            row(device)
                                .background {
                                    if device.id == outputs.currentID { CurrentOutputMargin() }
                                }
                        case .controls(let device):
                            HeadsetControlsView(device: device, outputs: outputs, isCurrent: device.id == outputs.currentID)
                                .transition(.opacity)
                        case .soundSettings:
                            AirPlayRow { outputs.openSoundSettings() }
                        }
                    }
                }
                // The checkmark in view: an AirPlay receiver can be below the fold,
                // and headsets' controls, read only once the panel is up, push the
                // rows under them down when they come.
                .onAppear { scrollToCurrent(proxy) }
                .onChange(of: outputs.currentID) { scrollToCurrent(proxy) }
                .onChange(of: outputs.controls.keys.sorted()) { scrollToCurrent(proxy) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { outputs.panelAppeared() }
        .onDisappear { outputs.panelDisappeared() }
    }

    /// Scrolls no further than it takes to show the current output's listening modes,
    /// where it has them, and then its row: a list too short for both keeps the row.
    ///
    /// The row's scroll waits a turn. Of two scrolls asked for in one update SwiftUI
    /// makes only the last, measured from where the list was, so the modes' scroll
    /// would be dropped and a headset lower in the list shown without its modes.
    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(CurrentModesMargin.id)
        DispatchQueue.main.async { proxy.scrollTo(CurrentOutputMargin.id) }
    }

    private func row(_ device: OutputDevice) -> some View {
        OutputRow(
            device: device,
            battery: device.headsetAddress.flatMap { outputs.batteries[$0] },
            isCurrent: device.id == outputs.currentID,
            isBusy: device.id == outputs.pendingID,
            model: model
        ) {
            outputs.select(device)
        }
    }
}

/// What the list scrolls to for the current output: its row with the depth of the
/// list's faded edge added above and below. Scrolling no further than it takes to
/// show this leaves the row clear of the fade, and a list that already shows it
/// where it is.
private struct CurrentOutputMargin: View {
    static let id = "currentOutput"

    var body: some View {
        Color.clear
            .frame(height: OutputRow.height + 2 * PanelList<EmptyView>.fade)
            .id(Self.id)
            .allowsHitTesting(false)
    }
}

/// What the list scrolls to for the current output's listening modes: the row of
/// them, with a note under it, and the depth of the list's faded edge below. It
/// sits right under the output's row, whose own margin covers above.
///
/// The modes' height changes with the note, so the margin is measured from them.
/// A negative padding would not do: the list scrolls to the padding's own frame,
/// the modes' height, and would leave the note under the faded edge.
struct CurrentModesMargin: View {
    static let id = "currentOutputModes"

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .frame(height: proxy.size.height + PanelList<EmptyView>.fade)
                .id(Self.id)
        }
        .allowsHitTesting(false)
    }
}

/// A line of the panel's list: a header, an output, a headset's controls, or the way
/// to Sound settings.
///
/// One list rather than one per section, as Up Next has, because a stack per
/// section showed stale rows when rows moved between sections.
enum OutputLine: Identifiable {
    case header(String)
    case device(OutputDevice)
    /// A headset's listening mode and spatial audio, under its row.
    case controls(OutputDevice)
    case soundSettings

    var id: String {
        switch self {
        case .header(let title): "header.\(title)"
        case .device(let device): "device.\(device.uid)"
        case .controls(let device): "controls.\(device.uid)"
        case .soundSettings: "soundSettings"
        }
    }

    /// The Sound menu's sections. AirPlay gets a header of its own only while a
    /// receiver is playing, since otherwise its one row would sit alone under it and
    /// push the common case, speakers and a headset, past the panel's height.
    static func lines(_ devices: [OutputDevice], controls: [String: HeadsetControls] = [:]) -> [OutputLine] {
        let airPlay = devices.filter(\.kind.isAirPlay)
        var lines: [OutputLine] = [.header("Output")]
        for device in devices where !device.kind.isAirPlay {
            lines.append(.device(device))
            if controls[device.uid] != nil { lines.append(.controls(device)) }
        }
        if !airPlay.isEmpty {
            lines.append(.header("AirPlay"))
            lines += airPlay.map(OutputLine.device)
        }
        lines.append(.soundSettings)
        return lines
    }
}

/// An output: its picture in a disc, lit when sound is going there, its name, a
/// headset's battery under it, and the checkmark.
private struct OutputRow: View {
    let device: OutputDevice
    let battery: HeadsetBattery?
    let isCurrent: Bool
    let isBusy: Bool
    let model: NowPlayingModel
    let action: () -> Void
    @State private var isHovering = false
    @AppStorage(NowPlayingPrefs.tintWaveform) private var tinted = NowPlayingPrefs.tintWaveformDefault

    static let height: CGFloat = 38

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                OutputIcon(symbol: device.symbol, isLit: isCurrent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    if let battery, !battery.isEmpty {
                        OutputBatteryLine(battery: battery)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(model.tint(tinted))
                        .accessibilityLabel("Current output")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: OutputRow.height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(isHovering && !isCurrent ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.2), value: isCurrent)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// The last row: AirPlay receivers are in Sound settings, which this opens.
private struct AirPlayRow: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                OutputIcon(symbol: OutputPickerModel.airPlaySymbol, isLit: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AirPlay receivers")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Choose one in Sound Settings")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 8)
            .frame(height: OutputRow.height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open Sound Settings")
    }
}

/// An output's picture on a disc, the size of the library's artwork: white on grey,
/// or black on white for the one in use, as the Sound menu lights it.
private struct OutputIcon: View {
    let symbol: String
    let isLit: Bool

    var body: some View {
        HeadsetGlyph(symbol: symbol, width: 16, height: 14, weight: .semibold)
            .foregroundStyle(isLit ? Color.black : .white.opacity(0.85))
            .frame(width: 30, height: 30)
            .background(Circle().fill(isLit ? Color.white : Color(white: 0.2)))
            .accessibilityHidden(true)
    }
}

/// A headset's levels in a line under its name, as the Sound menu shows them:
/// "L 97%  R 100%  Case 81%", or one level for headphones that report one.
private struct OutputBatteryLine: View {
    let battery: HeadsetBattery

    var body: some View {
        HStack(spacing: 8) {
            ForEach(battery.readings) { reading in
                HStack(spacing: 3) {
                    if let label = reading.label {
                        Text(label).foregroundStyle(.white.opacity(0.45))
                    } else {
                        Image(systemName: "battery.75percent").foregroundStyle(.white.opacity(0.45))
                    }
                    Text("\(reading.level)%")
                        .foregroundStyle(reading.level <= 20 ? HeadsetPalette.red : .white.opacity(0.7))
                }
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

/// The current output's volume, dragged like the scrubber: thicker while held, and
/// followed without a round trip, the writes behind it coalesced by the model. Grey
/// and still for an output with no volume of its own, and before the level is known.
private struct OutputVolumeSlider: View {
    let outputs: OutputPickerModel
    @State private var dragLevel: Double?

    var body: some View {
        let volume = outputs.volume
        let isSettable = volume?.isSettable ?? false
        let level = dragLevel ?? (volume.map { $0.isMuted ? 0 : $0.level } ?? 0)

        HStack(spacing: 10) {
            Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.fill")
                .frame(width: 16)
            track(level: level, isSettable: isSettable)
            Image(systemName: "speaker.wave.3.fill")
                .frame(width: 20)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.55))
        .frame(height: 22)
        .opacity(isSettable ? 1 : 0.45)
        .animation(.smooth(duration: 0.2), value: volume)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((level * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            guard let volume = outputs.volume else { return }
            let step = direction == .increment ? 1.0 / 16 : -1.0 / 16
            outputs.setVolume(volume.level + step)
        }
    }

    private func track(level: Double, isSettable: Bool) -> some View {
        let thickness: CGFloat = dragLevel == nil ? 5 : 8
        return GeometryReader { geo in
            let width = max(1, geo.size.width)
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.2))
                Rectangle().fill(.white).frame(width: width * min(1, max(0, level)))
            }
            .frame(height: thickness)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let level = min(1, max(0, value.location.x / width))
                        dragLevel = level
                        outputs.setVolume(level)
                    }
                    .onEnded { value in
                        outputs.setVolume(min(1, max(0, value.location.x / width)))
                        dragLevel = nil
                    }
            )
        }
        .allowsHitTesting(isSettable)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragLevel == nil)
    }
}

/// Why the last pick did not take, for a few seconds.
private struct OutputFailureLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HeadsetPalette.red)
            Text(text)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
