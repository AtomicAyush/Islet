import SwiftUI

extension IslandBanner {
    /// The banner as a row under the compact island, for while it rides there
    /// (`ActivityCenter.bannerRidesUnder`): its two sides side by side, in the row the
    /// volume takes, as tall as that. `nil` for a card, which has no sides to lay out.
    ///
    /// The row asks for the room its two sides' content takes (`rowWidths`, or else
    /// the widths the sides ask for beside the notch), with no notch between them:
    /// less than the banner itself takes, so a row never widens the island as far as
    /// the banner would have. Whatever a side does with long words beside the notch
    /// (a Show in Islet title cut short), it does in the row too. It has the banner's
    /// id, so a banner updated in place (the same id, new words) is the same row, with
    /// new words.
    var row: IslandAttachment? {
        guard case .compact(let leading, let trailing) = style else { return nil }
        let widths = rowWidths ?? (leading: leading, trailing: trailing)
        return IslandAttachment(
            id: id,
            // Whole points, so the island's edges stay on the pixel grid when the row
            // sets its width.
            width: ceil(widths.leading + widths.trailing),
            duration: duration,
            content: AnyView(IslandBannerRow(banner: self, leading: widths.leading, trailing: widths.trailing))
        )
    }
}

/// A compact banner in the row under the compact island: its left side, then its
/// right, as one line centred on the notch.
///
/// Beside the notch, each side sits against the island's outer edge in the width it
/// asked for, with an inset at either end of it. Side by side here, each keeps its
/// width and its insets: the line has the same room at both ends, whichever side is
/// the wider, and the two sides' inner insets make the gap between them, where the
/// notch was. The island widens for the row where it must, so the line always has
/// the room it asks for.
struct IslandBannerRow: View {
    let banner: IslandBanner
    let leading: CGFloat
    let trailing: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            banner.leading.frame(width: leading)
            banner.trailing.frame(width: trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
