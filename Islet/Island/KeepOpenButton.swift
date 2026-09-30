import SwiftUI

/// A page's Keep Open, in its header (`IslandViewModel.toggleKeepingOpen(_:for:)`): the
/// clipboard's, and the input box's. Not to be confused with a clipboard item's pin: a
/// capsule as Clear is, with the lock open; on, the lock shut on a wash of the page's
/// accent, so it shows at a glance that the island is held open.
struct KeepOpenButton: View {
    let isOn: Bool
    /// The page's colour, washed behind the shut lock.
    let tint: FeatureTint
    /// What the island is kept open for, as its help and VoiceOver say it: "to drag one
    /// item after another".
    let purpose: String
    /// The help while on: how else it is let go.
    var letGoHelp = "Let the island close again (Esc)"
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let wash = isOn ? (isHovering ? 0.3 : 0.22) : (isHovering ? 0.2 : 0.12)
        Button(action: action) {
            label
                .padding(.horizontal, 7)
                .frame(height: 16)
                .modifier(Colours(isOn: isOn, isHovering: isHovering, wash: wash, tint: tint))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isOn ? letGoHelp : "Keep the island open, \(purpose)")
        .accessibilityLabel("Keep Open")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(isOn ? "Lets the island close again" : "Keeps the island open, \(purpose)")
    }

    private var label: some View {
        HStack(spacing: 3) {
            // As wide open as shut, so nothing beside it moves as it turns.
            Image(systemName: isOn ? "lock.fill" : "lock.open")
                .font(.system(size: 8.5, weight: .bold))
                .frame(width: 11)
            Text("Keep Open")
                .font(.system(size: 10, weight: .semibold))
        }
    }

    private struct Colours: ViewModifier {
        let isOn: Bool
        let isHovering: Bool
        let wash: Double
        let tint: FeatureTint

        func body(content: Content) -> some View {
            if isOn {
                content.islandWashed(.accent(tint, minimum: Contrast.text), wash: wash, in: Capsule())
            } else {
                content
                    .foregroundStyle(.islandText(isHovering ? 0.95 : 0.7, on: IslandBackdrop.island.stacked(wash)))
                    .background(Capsule().fill(.islandSurface(wash, on: .island)))
            }
        }
    }
}
