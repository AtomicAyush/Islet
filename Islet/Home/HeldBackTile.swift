import SwiftUI

/// What a home tile shows in place of its own content while Presentation Mode holds its
/// kind back (`ActivityCenter.shownHomeWidgets`): that something is there, hidden, and
/// nothing of what it is. It keeps the tile's place and size, so the row does not shift
/// as presenting starts and ends, and takes no clicks.
struct HeldBackTile: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.islandGraphic(0.5, on: IslandBackdrop.homeTile.stacked(0.08)))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.islandSurface(0.08, on: .homeTile)))
            Spacer(minLength: 6)
            Text("Hidden")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.islandText(0.7, on: .homeTile))
                .lineLimit(1)
            Text("While presenting")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.islandText(0.4, on: .homeTile))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hidden while presenting")
    }
}
