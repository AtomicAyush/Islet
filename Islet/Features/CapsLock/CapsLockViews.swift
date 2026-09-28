import AppKit
import SwiftUI

extension FeatureTint {
    /// The word "On": the green of the Caps Lock key's own light, as the iPhone draws
    /// green on black. The symbol beside the notch stays in the island's ink, since a
    /// green mark there means the camera is on.
    static let capsLockOn = FeatureTint.colour(RGB(bytes: 48, 209, 88))
}

enum CapsLockPalette {
    /// Caps Lock off: the words "Caps Lock" and "Off", and, as a symbol, its hollow key.
    static let off = IslandInk.text(0.5)
    static let offSymbol = IslandInk.graphic(0.5)
}

// MARK: - Banner

/// Left of the notch: the Caps Lock symbol and its name, filled and in full ink while on,
/// hollow and grey once off. Where there is no room for the name, or even the insets
/// (the opened island's header gives it 24 points), the symbol.
struct CapsLockBannerLeading: View {
    let isOn: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: CapsLockBannerLayout.symbolSpacing) {
                symbol
                Text(CapsLockBannerLayout.name)
                    .font(Font(CapsLockBannerLayout.font))
                    .foregroundStyle(.island(isOn ? .text(1) : CapsLockPalette.off))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, CapsLockBannerLayout.outerInset)
            .padding(.trailing, CapsLockBannerLayout.innerInset)
            symbol
                .padding(.leading, CapsLockBannerLayout.outerInset)
                .padding(.trailing, CapsLockBannerLayout.innerInset)
            symbol
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.2), value: isOn)
    }

    private var symbol: some View {
        Image(systemName: CapsLockBannerLayout.symbol(isOn: isOn))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .fontWeight(.semibold)
            .foregroundStyle(.island(isOn ? .graphic(1) : CapsLockPalette.offSymbol))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: CapsLockBannerLayout.symbolSize.width, height: CapsLockBannerLayout.symbolSize.height)
            .accessibilityHidden(true)
    }
}

/// Right of the notch: "On" in the key light's green, or "Off" in grey, against the
/// wing's outer edge. Only as wide as its content: the opened island's header sets it
/// beside the leading symbol, where a view that filled its width would push the two
/// apart.
struct CapsLockBannerTrailing: View {
    let isOn: Bool

    var body: some View {
        Text(CapsLockBannerLayout.status(isOn: isOn))
            .font(Font(CapsLockBannerLayout.font))
            .foregroundStyle(isOn ? .islandAccentText(.capsLockOn) : .island(CapsLockPalette.off))
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.2), value: isOn)
            .padding(.leading, CapsLockBannerLayout.innerInset)
            .padding(.trailing, CapsLockBannerLayout.outerInset)
    }
}

/// The banner's measurements, matching the Focus banner's: 13-point semibold words, a
/// symbol the height of a capital and a half, the same insets. Each side asks only for
/// its own width and sits against the island's outer edge; the island makes both wings
/// as wide as the wider side, the name's, so it stays centred on the notch, and turning
/// Caps Lock off while the banner is up changes a word, not the island's size.
enum CapsLockBannerLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let name = "Caps Lock"
    /// The symbol's box: as tall as the Focus banner's, and only as wide as the glyph,
    /// so the gap to the name is the spacing and no more.
    static let symbolSize = CGSize(width: 16, height: 17)
    static let symbolSpacing: CGFloat = 7
    /// Room between each wing's content and the island's outer edge, and the notch.
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10

    static func symbol(isOn: Bool) -> String { isOn ? "capslock.fill" : "capslock" }
    static func status(isOn: Bool) -> String { isOn ? "On" : "Off" }

    static func widths(isOn: Bool) -> (leading: CGFloat, trailing: CGFloat) {
        (
            outerInset + symbolSize.width + symbolSpacing + textWidth(name) + innerInset,
            innerInset + textWidth(status(isOn: isOn)) + outerInset
        )
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it,
    /// which would otherwise truncate a word that just fits.
    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}
