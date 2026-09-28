import SwiftUI

/// AirPods' listening mode and spatial audio, under their row in the output list as
/// the Sound menu has them under AirPods: the modes straight under the name, then
/// "Spatialize Stereo" over its three choices, the current ones lit.
///
/// The modes go without a caption of their own, as in the Sound menu, which keeps
/// them in view as the panel opens on the AirPods: the panel is short, and the list
/// only scrolls as far as the current output's row and its modes.
struct HeadsetControlsView: View {
    let device: OutputDevice
    let outputs: OutputPickerModel
    /// Sound is going to this headset, so the list scrolls to its modes.
    var isCurrent = false

    /// Under the name, clear of the row's picture: the row's inset, its disc and the
    /// gap after it.
    static let inset: CGFloat = 8 + 30 + 10

    var body: some View {
        let controls = outputs.controls[device.uid]
        VStack(alignment: .leading, spacing: 6) {
            if let listening = controls?.listening {
                listeningRow(listening)
                    .background(alignment: .top) {
                        if isCurrent { CurrentModesMargin() }
                    }
            }
            if let spatial = controls?.spatial {
                spatialRow(spatial)
            }
        }
        .padding(.leading, Self.inset)
        .padding(.trailing, 8)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.2), value: controls)
    }

    /// The modes, with Noise Cancellation and Adaptive dimmed and a note under them
    /// while a bud is out: clicking one then only says what to do.
    private func listeningRow(_ state: ListeningModeState) -> some View {
        let modes = outputs.listeningModes(for: device)
        let pending = outputs.pendingListeningModes[device.uid]
        let dimmed = state.isWorn ? [] : modes.filter(\.needsBothInEar)
        return HeadsetChoiceRow(
            label: "Listening mode",
            note: dimmed.isEmpty ? nil : OutputPickerModel.wearHint(for: device, toUse: dimmed),
            isEnabled: state.isSettable,
            choices: modes.map { mode in
                let isDimmed = dimmed.contains(mode)
                return HeadsetChoice(
                    id: "\(mode.rawValue)",
                    title: mode.title,
                    symbol: mode.symbol,
                    isSelected: state.current == mode,
                    isPending: pending == mode,
                    isDimmed: isDimmed,
                    hint: isDimmed ? OutputPickerModel.wearHint(for: device, toUse: [mode]) : nil
                ) {
                    outputs.setListeningMode(mode, for: device)
                }
            }
        )
    }

    private func spatialRow(_ state: SpatialAudioState) -> some View {
        let pending = outputs.pendingSpatialAudio[device.uid]
        return HeadsetChoiceRow(
            label: state.content.title,
            showsLabel: true,
            isEnabled: state.isSettable && state.app > 0,
            choices: state.offered.map { mode in
                HeadsetChoice(
                    id: mode.title,
                    title: mode.title,
                    symbol: mode.symbol(for: state.content),
                    isSelected: state.mode == mode,
                    isPending: pending == mode
                ) {
                    outputs.setSpatialAudio(mode, for: device)
                }
            }
        )
    }
}

/// One of a row's choices.
struct HeadsetChoice: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var isSelected = false
    /// Just clicked, and waiting for the headset.
    var isPending = false
    /// Not to be had as things are; a click says why.
    var isDimmed = false
    /// Why it is dimmed, for the pointer and VoiceOver.
    var hint: String?
    let action: () -> Void
}

/// Choices that share the row's width, the current one black on white as the output
/// list lights the output in use; a caption over them where they need one, and a note
/// under them where there is one.
///
/// A row comes in under the pointer: a headset's controls are read only once the
/// panel is up, and a Spatialize Stereo row appears when music starts, each pushing
/// the rows below down. So a row takes no clicks for its first moment, and a click
/// meant for the row it has just pushed away changes nothing.
struct HeadsetChoiceRow: View {
    /// What VoiceOver calls the row, and its caption when `showsLabel`.
    let label: String
    var showsLabel = false
    var note: String?
    /// Off for a headset whose control is read-only: it is shown, dimmed, and takes
    /// no clicks.
    var isEnabled = true
    let choices: [HeadsetChoice]
    @State private var isSettled = false

    /// Longer than a click already on its way takes to land, and too short to aim one.
    static let settle: Duration = .milliseconds(300)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsLabel {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.islandText(0.55))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }

            HStack(spacing: 2) {
                ForEach(choices) { choice in
                    HeadsetChoiceButton(choice: choice)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.islandSurface(HeadsetChoiceButton.row)))
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.5)
            .allowsHitTesting(isSettled)

            if let note {
                Text(note)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.islandText(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .task {
            try? await Task.sleep(for: Self.settle)
            isSettled = true
        }
    }
}

private struct HeadsetChoiceButton: View {
    let choice: HeadsetChoice
    @State private var isHovering = false
    @Environment(\.islandTheme) private var theme

    static let height: CGFloat = 36
    /// The row's shade, which the choices lie on.
    static let row = 0.08
    /// Under the pointer, the row's shade and the choice's own: what its words are
    /// measured against, so they read either way.
    private static let lit = IslandBackdrop.surface(0.16)

    var body: some View {
        let fill = theme.nowPlayingFill
        // The choice waiting for the headset: softened on the black island, as it
        // always was; elsewhere a full mark.
        let pending = theme.isDefault ? 0.6 : 1
        Button(action: choice.action) {
            VStack(spacing: 2) {
                Image(systemName: choice.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(height: 16)
                Text(choice.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(choice.isSelected ? .islandOnFill(fill) : .islandText(0.85, on: Self.lit))
            .opacity(choice.isDimmed ? 0.35 : 1)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(choice.isSelected ? .islandFill(fill) : .islandSurface(isHovering ? 0.08 : 0))
            )
            .overlay {
                if choice.isPending {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.islandAccent(.nowPlaying).opacity(pending), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(choice.hint ?? choice.title)
        .accessibilityLabel(choice.title)
        .accessibilityHint(choice.hint ?? "")
        .accessibilityAddTraits(choice.isSelected ? .isSelected : [])
    }
}
