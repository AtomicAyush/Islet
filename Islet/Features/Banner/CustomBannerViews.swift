import AppKit
import SwiftUI

extension CustomBanner {
    /// The banner as the island shows it, under `id`.
    func islandBanner(id: String) -> IslandBanner {
        switch style {
        case .compact:
            IslandBanner(
                id: id,
                style: .compact(
                    leading: CustomBannerLayout.leadingWidth(for: self),
                    trailing: CustomBannerLayout.trailingWidth(for: self)
                ),
                duration: duration,
                interruption: interruption,
                personal: .messages,
                leading: AnyView(CustomBannerLeading(banner: self)),
                trailing: AnyView(CustomBannerTrailing(banner: self))
            )
        case .card:
            IslandBanner(
                id: id,
                style: .card(width: CustomBannerLayout.cardWidth, height: CustomBannerLayout.cardHeight(for: self)),
                duration: duration,
                interruption: interruption,
                personal: .messages,
                content: AnyView(CustomBannerCard(banner: self))
            )
        }
    }

    var symbolColor: Color { tint?.color ?? .white }

    /// The subtitle beside the notch: in the banner's colour, like a Focus's "On", or
    /// in the grey of the island's other quieter words when it has none.
    var subtitleColor: Color { tint?.color ?? .white.opacity(0.6) }
}

/// A banner's symbol, fitted into a box so wide symbols (a hammer, a car) take no more
/// room than round ones.
struct CustomBannerSymbol: View {
    let banner: CustomBanner
    var size: CGSize

    var body: some View {
        Image(systemName: banner.symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .fontWeight(.semibold)
            .foregroundStyle(banner.symbolColor)
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }
}

// MARK: - Compact

/// Left of the notch: the symbol, and the title when a subtitle takes the right. Where
/// there is no room for the title, or even the insets (the opened island's header gives
/// this side 24 points, and the right side takes the title), the symbol alone.
struct CustomBannerLeading: View {
    let banner: CustomBanner

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if let title = CustomBannerLayout.leadingText(for: banner) {
                HStack(spacing: CustomBannerLayout.symbolSpacing) {
                    symbol
                    Text(verbatim: title)
                        .font(Font(CustomBannerLayout.font))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: CustomBannerLayout.maximumTextWidth, alignment: .leading)
                }
                .padding(.leading, CustomBannerLayout.outerInset)
                .padding(.trailing, CustomBannerLayout.innerInset)
            }
            symbol
                .padding(.leading, CustomBannerLayout.outerInset)
                .padding(.trailing, CustomBannerLayout.innerInset)
            symbol
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: some View {
        CustomBannerSymbol(banner: banner, size: CustomBannerLayout.symbolSize)
    }
}

/// Right of the notch: the subtitle, or the title when there is none, against the
/// wing's outer edge. Only as wide as its words: the opened island's header sets it
/// beside the leading symbol, where a view that filled its width would push the two
/// apart.
///
/// The header leaves the left side room for the symbol alone, so there the title
/// comes over to this side: before the subtitle when both fit, and on its own,
/// truncated if it must be, when they do not. The subtitle alone would leave "12 s"
/// with no word of what took twelve seconds.
struct CustomBannerTrailing: View {
    let banner: CustomBanner
    @Environment(\.isInIslandHeader) private var isInHeader

    var body: some View {
        if isInHeader {
            ViewThatFits(in: .horizontal) {
                if let subtitle = banner.subtitle {
                    HStack(spacing: CustomBannerLayout.headerSeparatorSpacing) {
                        words(banner.title, color: .white)
                        words("·", color: .white.opacity(0.4))
                        words(subtitle, color: banner.subtitleColor)
                    }
                    .fixedSize()
                    .modifier(Insets())
                }
                words(banner.title, color: .white)
                    .modifier(Insets())
            }
        } else {
            let text = CustomBannerLayout.trailingText(for: banner)
            words(text, color: banner.subtitle == nil ? .white : banner.subtitleColor)
                .frame(width: CustomBannerLayout.shownTextWidth(text), alignment: .trailing)
                .modifier(Insets())
        }
    }

    private func words(_ text: String, color: Color) -> some View {
        Text(verbatim: text)
            .font(Font(CustomBannerLayout.font))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private struct Insets: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(.leading, CustomBannerLayout.innerInset)
                .padding(.trailing, CustomBannerLayout.outerInset)
        }
    }
}

extension EnvironmentValues {
    /// Set on the compact banner the opened island shows in its header, beside its
    /// tabs. The header gives the banner's left side 24 points, room for a symbol and
    /// no words, so a banner whose left side says something can say it on the right.
    @Entry var isInIslandHeader = false
}

// MARK: - Card

/// The card: the symbol in a disc of its colour, as the timer's bell is, beside the
/// title and, under it, the subtitle on up to three lines. Nothing in it is a button,
/// and no text in it is a link.
struct CustomBannerCard: View {
    let banner: CustomBanner

    var body: some View {
        HStack(spacing: CustomBannerLayout.cardSpacing) {
            CustomBannerSymbol(banner: banner, size: CustomBannerLayout.cardSymbolSize)
                .frame(width: CustomBannerLayout.cardDiscDiameter, height: CustomBannerLayout.cardDiscDiameter)
                .background(Circle().fill(banner.symbolColor.opacity(0.18)))

            VStack(alignment: .leading, spacing: CustomBannerLayout.cardLineGap) {
                Text(verbatim: banner.title)
                    .font(Font(CustomBannerLayout.cardTitleFont))
                    .foregroundStyle(.white)
                    .lineLimit(CustomBannerLayout.cardTitleLines)
                if let subtitle = banner.subtitle {
                    Text(verbatim: subtitle)
                        .font(Font(CustomBannerLayout.cardSubtitleFont))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(CustomBannerLayout.cardSubtitleLines)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Layout

/// The banner's measurements, matching the island's other banners: 13-point semibold
/// words and a symbol the size of a Focus's beside the notch, with the same insets; a
/// 380-point card like the timer's, its symbol in a 44-point disc.
///
/// Beside the notch, a banner with a subtitle reads like a Focus announcing itself —
/// symbol and title on the left, subtitle on the right. One without reads like the
/// iPhone's own short alerts, symbol on the left and its words on the right, rather
/// than leave the right side empty. Each side asks only for its own width; the island
/// makes both wings as wide as the wider, so it stays centred on the notch.
enum CustomBannerLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let symbolSize = CGSize(width: 22, height: 17)
    static let symbolSpacing: CGFloat = 7
    /// About twenty characters of either side's words before they truncate, which keeps
    /// the island's wings short of the menu bar's middle on the smallest notched screen.
    static let maximumTextWidth: CGFloat = 150
    /// Room between each wing's content and the island's outer edge, and the notch.
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10
    /// Either side of the dot between the title and the subtitle in the opened island's
    /// header.
    static let headerSeparatorSpacing: CGFloat = 5

    /// Left of the notch: the title, when a subtitle takes the right.
    static func leadingText(for banner: CustomBanner) -> String? {
        banner.subtitle == nil ? nil : banner.title
    }

    /// Right of the notch: the subtitle, or the title when there is none.
    static func trailingText(for banner: CustomBanner) -> String {
        banner.subtitle ?? banner.title
    }

    static func leadingWidth(for banner: CustomBanner) -> CGFloat {
        var width = outerInset + symbolSize.width + innerInset
        if let text = leadingText(for: banner) {
            width += symbolSpacing + shownTextWidth(text)
        }
        return width
    }

    static func trailingWidth(for banner: CustomBanner) -> CGFloat {
        innerInset + shownTextWidth(trailingText(for: banner)) + outerInset
    }

    /// The width a side's words are given: all they need, up to the maximum.
    static func shownTextWidth(_ text: String) -> CGFloat {
        min(textWidth(text, font: font), maximumTextWidth)
    }

    // Card.

    static let cardWidth: CGFloat = 380
    static let cardDiscDiameter: CGFloat = 44
    static let cardSymbolSize = CGSize(width: 24, height: 22)
    static let cardSpacing: CGFloat = 14
    static let cardTitleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let cardSubtitleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let cardTitleLines = 2
    static let cardSubtitleLines = 3
    static let cardLineGap: CGFloat = 2
    /// Above and below the disc, or the text when that is taller.
    static let cardPadding: CGFloat = 10

    /// The text's column: the card, less the island's insets either side, the disc and
    /// the gap after it.
    static var cardTextWidth: CGFloat {
        cardWidth - IslandLayout.expandedInset.leading - IslandLayout.expandedInset.trailing
            - cardDiscDiameter - cardSpacing
    }

    /// Tall enough for the title's lines and the subtitle's, or the disc, whichever is
    /// more, so a longer subtitle gets a taller card rather than a cut-off one.
    static func cardHeight(for banner: CustomBanner) -> CGFloat {
        var text = textHeight(banner.title, font: cardTitleFont, lines: cardTitleLines)
        if let subtitle = banner.subtitle {
            text += cardLineGap + textHeight(subtitle, font: cardSubtitleFont, lines: cardSubtitleLines)
        }
        return ceil(max(cardDiscDiameter, text) + 2 * cardPadding)
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it,
    /// which would otherwise truncate words that just fit.
    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }

    /// The height of `text` wrapped to the card's column, at most `lines` lines. It is
    /// wrapped a little narrower than the column, so where AppKit and SwiftUI would
    /// break a line differently the card errs taller, never short.
    private static func textHeight(_ text: String, font: NSFont, lines: Int) -> CGFloat {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: cardTextWidth - 6, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font]
        )
        let count = min(lines, max(1, Int((bounds.height / lineHeight).rounded())))
        return CGFloat(count) * lineHeight
    }
}
