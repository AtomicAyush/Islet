import AppKit
import SwiftUI

enum HiddenMenuBarIconsPalette {
    /// The iPhone's purple in its dark appearance: the feature's label and symbol.
    static let accent = Color(red: 191 / 255, green: 90 / 255, blue: 242 / 255)
    /// An icon that would not open, and the request for Accessibility.
    static let problem = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
    static let secondary = Color.white.opacity(0.5)
}

enum HiddenMenuBarIconsLayout {
    /// The home tile's icons, and the room between them: three to a row in the
    /// narrowest tile, as the Shortcuts tile has.
    static let tileIcon: CGFloat = 26
    static let tileSpacing: CGFloat = 7
    /// Rows of icons on the tile, under its header.
    static let tileRows = 2

    /// The page's cells: an icon and its name, four to a row.
    static let pageColumns = 4
    static let pageIcon: CGFloat = 22
    static let pageCellHeight: CGFloat = 32
    static let pageSpacing: CGFloat = 4
    /// Rows the page grows to hold before the rest is a scroll away.
    static let pageMaxRows = 4
    /// The hairline between the hidden icons and those in sight, with the room around it.
    static let pageDivider: CGFloat = 5
    /// The fade at the foot of a page that scrolls.
    static let pageFade: CGFloat = 14
    /// The page's padding and header, above and below the cells.
    private static let pageChrome: CGFloat = 4 + 16 + 8 + 8

    /// Rows of cells for `icons`: the hidden ones, then those in sight on rows of
    /// their own.
    static func pageRows(for icons: [HiddenMenuBarIcon]) -> Int {
        let hidden = icons.filter(\.isHidden).count
        return rows(hidden) + rows(icons.count - hidden)
    }

    /// Whether the page has more rows than it grows to hold.
    static func pageScrolls(for icons: [HiddenMenuBarIcon]) -> Bool {
        pageRows(for: icons) > pageMaxRows
    }

    /// The page's height below the notch row: its header and rows enough for `icons`,
    /// up to `pageMaxRows`, with half the next row showing through the fade when there
    /// are more, to say so; never less than the home page's, so turning to it from the
    /// tile does not shrink the island under the pointer.
    static func pageHeight(for icons: [HiddenMenuBarIcon]) -> CGFloat {
        let rows = pageRows(for: icons)
        let shown = CGFloat(min(max(rows, 1), pageMaxRows))
        let isDivided = icons.contains(where: \.isHidden) && icons.contains { !$0.isHidden }
        let divider = isDivided && rows <= pageMaxRows ? pageDivider + pageSpacing : 0
        let peek = rows > pageMaxRows ? pageSpacing + pageCellHeight / 2 : 0
        let cells = shown * pageCellHeight + (shown - 1) * pageSpacing
        return max(IslandLayout.homeHeight, pageChrome + cells + divider + peek)
    }

    private static func rows(_ count: Int) -> Int {
        (count + pageColumns - 1) / pageColumns
    }

    /// How many icons the tile shows in `width`, and whether the last cell has to say
    /// how many more there are instead.
    static func tileCells(count: Int, width: CGFloat) -> (icons: Int, more: Int) {
        let columns = max(1, Int((width + tileSpacing) / (tileIcon + tileSpacing)))
        let cells = columns * tileRows
        if count <= cells { return (count, 0) }
        return (cells - 1, count - (cells - 1))
    }
}

// MARK: - Icons

/// An item's icon: its app's, a symbol for the system's own, or a made-up app's.
struct MenuBarIconGlyph: View {
    let glyph: HiddenMenuBarIcon.Glyph
    let size: CGFloat

    var body: some View {
        Group {
            switch glyph {
            case .app(let pid):
                if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    plate(symbol: SystemMenuExtras.fallbackSymbol, fill: .white.opacity(0.14))
                }
            case .symbol(let symbol):
                plate(symbol: symbol, fill: .white.opacity(0.14))
            case .sample(let symbol, let hue):
                plate(symbol: symbol, fill: Color(hue: hue, saturation: 0.62, brightness: 0.85), gloss: true)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// A symbol on a rounded square, inset a little as an app icon's artwork is inset
    /// within its frame, so the two sit side by side at one size.
    private func plate(symbol: String, fill: Color, gloss: Bool = false) -> some View {
        let inset = size * 0.08
        let side = size - 2 * inset
        let shape = RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
        return ZStack {
            shape.fill(fill)
            if gloss {
                shape.fill(LinearGradient(
                    colors: [.white.opacity(0.16), .white.opacity(0)], startPoint: .top, endPoint: .bottom
                ))
            }
            Image(systemName: SystemMenuExtras.drawable(symbol))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(gloss ? 1 : 0.9))
                .frame(width: side * 0.56, height: side * 0.5)
        }
        .frame(width: side, height: side)
    }
}

/// The name and, where it adds anything, what the item says about itself.
private func tooltip(_ icon: HiddenMenuBarIcon) -> String {
    guard let detail = icon.detail else { return icon.name }
    return "\(icon.name) — \(detail)"
}

private func placementWords(_ placement: HiddenMenuBarIcon.Placement) -> String {
    switch placement {
    case .noRoom: "no room in the menu bar"
    case .underNotch: "under the notch"
    case .shown: "in the menu bar"
    case .switchedOff: "switched off"
    }
}

// MARK: - Home

/// The home page tile: the icons out of sight, each a click from its menu. The
/// hovered icon's name takes the header's place; the header opens the page with all
/// of them, as does the last cell where there are more than fit. Without
/// Accessibility it says so, and offers the way to allow it. With none out of sight,
/// and Settings asking for the icons in sight too, it is plainly the menu bar's.
struct HiddenMenuBarIconsTile: View {
    let model: HiddenMenuBarIconsModel
    let open: () -> Void
    @State private var hovered: String?

    /// `hovered` starts an icon as if the pointer were on it, for renders of the tile.
    init(model: HiddenMenuBarIconsModel, hovered: String? = nil, open: @escaping () -> Void) {
        self.model = model
        self.open = open
        _hovered = State(initialValue: hovered)
    }

    var body: some View {
        let icons = model.listed
        VStack(alignment: .leading, spacing: 8) {
            header(icons: icons)
            if model.needsAccess {
                HiddenMenuBarAccessNotice(compact: true)
            } else {
                GeometryReader { geo in
                    grid(icons, width: geo.size.width)
                }
            }
        }
    }

    private func header(icons: [HiddenMenuBarIcon]) -> some View {
        let name = icons.first { $0.id == hovered }?.name
        // Out of sight, whatever else Settings asks the tile to list.
        let count = icons.filter(\.isHidden).count
        let isHiddenList = count > 0 || model.needsAccess
        let symbol = isHiddenList ? "menubar.arrow.up.rectangle" : "menubar.rectangle"
        let (title, shortTitle) = isHiddenList ? ("Hidden Icons", "Hidden") : ("Menu Bar", "Menu Bar")
        return Button(action: open) {
            HStack(spacing: 5) {
                Group {
                    if let name {
                        Text(name)
                            .foregroundStyle(.white)
                    } else {
                        // The tile's width depends on how many other tiles are up; the
                        // symbol goes first, then half the title.
                        ViewThatFits(in: .horizontal) {
                            Label(title, systemImage: symbol)
                            Label(shortTitle, systemImage: symbol)
                            Text(shortTitle)
                            Image(systemName: symbol)
                        }
                        .foregroundStyle(HiddenMenuBarIconsPalette.accent)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                if name == nil, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 18, height: 16)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isHiddenList ? "Show every hidden icon" : "Show every menu bar icon")
        .accessibilityLabel(isHiddenList ? "Hidden menu bar icons, \(count)" : "Menu bar icons")
        .accessibilityHint("Shows them all")
    }

    private func grid(_ icons: [HiddenMenuBarIcon], width: CGFloat) -> some View {
        let layout = HiddenMenuBarIconsLayout.self
        let cells = layout.tileCells(count: icons.count, width: width)
        let columns = Array(
            repeating: GridItem(.fixed(layout.tileIcon), spacing: layout.tileSpacing),
            count: max(1, Int((width + layout.tileSpacing) / (layout.tileIcon + layout.tileSpacing)))
        )
        return LazyVGrid(columns: columns, alignment: .leading, spacing: layout.tileSpacing) {
            ForEach(icons.prefix(cells.icons)) { icon in
                button(icon)
            }
            if cells.more > 0 {
                Button(action: open) {
                    Text("+\(cells.more)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: layout.tileIcon, height: layout.tileIcon)
                        .background(
                            RoundedRectangle(cornerRadius: layout.tileIcon * 0.26, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show them all")
                .accessibilityLabel("\(cells.more) more")
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: icons.map(\.id))
    }

    private func button(_ icon: HiddenMenuBarIcon) -> some View {
        let isHovered = hovered == icon.id
        return Button {
            model.press(icon)
        } label: {
            MenuBarIconGlyph(glyph: icon.glyph, size: HiddenMenuBarIconsLayout.tileIcon)
                .opacity(icon.isEnabled ? 1 : 0.4)
                .scaleEffect(isHovered && icon.isEnabled ? 1.08 : 1)
                .animation(.islandHover, value: isHovered)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!icon.isEnabled)
        .help(tooltip(icon))
        .accessibilityLabel("\(icon.name), \(placementWords(icon.placement))")
        .accessibilityHint("Opens its menu")
        .onHover { inside in
            if inside {
                hovered = icon.id
            } else if hovered == icon.id {
                hovered = nil
            }
        }
    }
}

// MARK: - Page

/// Every icon out of sight, with its name, four to a row; the icons in sight follow
/// a hairline where Settings asks for them too. A click opens the icon's menu.
struct HiddenMenuBarIconsPage: View {
    let model: HiddenMenuBarIconsModel
    @State private var hovered: String?

    /// `hovered` starts a cell as if the pointer were on it, for renders of the page.
    init(model: HiddenMenuBarIconsModel, hovered: String? = nil) {
        self.model = model
        _hovered = State(initialValue: hovered)
    }

    var body: some View {
        let icons = model.listed
        let hidden = icons.filter(\.isHidden)
        let inSight = icons.filter { !$0.isHidden }
        let scrolls = HiddenMenuBarIconsLayout.pageScrolls(for: icons)
        VStack(alignment: .leading, spacing: 8) {
            header(count: hidden.count, isHiddenList: !hidden.isEmpty || icons.isEmpty || model.needsAccess)
                .padding(.horizontal, 8)
            if model.needsAccess {
                HiddenMenuBarAccessNotice(compact: false)
                    .padding(.horizontal, 8)
            } else if icons.isEmpty {
                Text(model.hasLooked || model.sample != nil ? "Every menu bar icon is in sight." : "Looking…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: HiddenMenuBarIconsLayout.pageSpacing) {
                        cells(hidden)
                        if !hidden.isEmpty, !inSight.isEmpty {
                            Rectangle()
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, (HiddenMenuBarIconsLayout.pageDivider - 1) / 2)
                        }
                        cells(inSight)
                    }
                    // Room below the last row, so scrolled to the end it clears the fade.
                    .padding(.bottom, scrolls ? HiddenMenuBarIconsLayout.pageFade : 0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: icons.map(\.id))
                }
                // No scroller: the fade at the foot says there is more, as the
                // clipboard page's does.
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .mask(
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: scrolls ? HiddenMenuBarIconsLayout.pageFade : 0)
                    }
                )
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Permission is given in System Settings, so it is looked at again each time
        // the page opens.
        .onAppear { model.refreshAccess() }
    }

    /// Titled for the hidden icons, unless there are none and the page lists the icons
    /// in sight instead.
    private func header(count: Int, isHiddenList: Bool) -> some View {
        HStack(spacing: 6) {
            Label(
                isHiddenList ? "Hidden Menu Bar Icons" : "Menu Bar Icons",
                systemImage: isHiddenList ? "menubar.arrow.up.rectangle" : "menubar.rectangle"
            )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HiddenMenuBarIconsPalette.accent)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 4)
        }
        .frame(height: 16)
    }

    @ViewBuilder
    private func cells(_ icons: [HiddenMenuBarIcon]) -> some View {
        if !icons.isEmpty {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: HiddenMenuBarIconsLayout.pageSpacing),
                    count: HiddenMenuBarIconsLayout.pageColumns
                ),
                spacing: HiddenMenuBarIconsLayout.pageSpacing
            ) {
                ForEach(icons) { icon in
                    HiddenMenuBarPageCell(icon: icon, isHovered: hovered == icon.id) { model.press(icon) }
                        .onHover { inside in
                            if inside {
                                hovered = icon.id
                            } else if hovered == icon.id {
                                hovered = nil
                            }
                        }
                }
            }
        }
    }
}

private struct HiddenMenuBarPageCell: View {
    let icon: HiddenMenuBarIcon
    let isHovered: Bool
    let press: () -> Void

    var body: some View {
        Button(action: press) {
            HStack(spacing: 8) {
                MenuBarIconGlyph(glyph: icon.glyph, size: HiddenMenuBarIconsLayout.pageIcon)
                Text(icon.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(icon.isHidden ? 1 : 0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .opacity(icon.isEnabled ? 1 : 0.4)
            .padding(.horizontal, 6)
            .frame(height: HiddenMenuBarIconsLayout.pageCellHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(isHovered && icon.isEnabled ? 0.09 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!icon.isEnabled)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .help(tooltip(icon))
        .accessibilityLabel("\(icon.name), \(placementWords(icon.placement))")
        .accessibilityHint("Opens its menu")
    }
}

// MARK: - Access

/// Islet cannot see the menu bar's icons without Accessibility. Allow asks macOS,
/// which shows its prompt and opens the list, as Grant Access does in Settings: only
/// ever on this click. On the tile it is kept to two short lines, the pane's long name
/// (on macOS 27) left to the tooltip, so the tile is no taller than its neighbours.
private struct HiddenMenuBarAccessNotice: View {
    let compact: Bool

    private static let explanation =
        "Islet needs \(AccessibilityAccess.paneName) to see which icons the menu bar hides, and to open them."

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HiddenMenuBarIconsPalette.problem)
                    .accessibilityHidden(true)
                Text(compact ? "Needs permission." : Self.explanation)
                    .font(.system(size: compact ? 10.5 : 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Self.explanation)
            }
            .help(compact ? Self.explanation : "")
            Button {
                AccessibilityAccess().request()
            } label: {
                Text("Allow…")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .foregroundStyle(.white)
                    .frame(maxWidth: compact ? .infinity : nil)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Add Islet to the \(AccessibilityAccess.paneName) list in System Settings")
        }
    }
}

// MARK: - Banner

/// An icon's menu would not open (its app gone, or the item refusing the click): the
/// icon and its name left of the notch, "Won't Open" right of it.
struct HiddenMenuBarFailureLeading: View {
    let icon: HiddenMenuBarIcon

    /// Where there is no room for the name, or even the insets (the opened island's
    /// header gives it 24 points), the icon alone.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: HiddenMenuBarBannerLayout.spacing) {
                glyph
                Text(icon.name)
                    .font(Font(HiddenMenuBarBannerLayout.font))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: HiddenMenuBarBannerLayout.maximumNameWidth, alignment: .leading)
            }
            .padding(.leading, HiddenMenuBarBannerLayout.outerInset)
            .padding(.trailing, HiddenMenuBarBannerLayout.innerInset)
            glyph
                .padding(.leading, HiddenMenuBarBannerLayout.outerInset)
                .padding(.trailing, HiddenMenuBarBannerLayout.innerInset)
            glyph
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glyph: some View {
        MenuBarIconGlyph(glyph: icon.glyph, size: HiddenMenuBarBannerLayout.icon)
    }
}

struct HiddenMenuBarFailureTrailing: View {
    var body: some View {
        Text(HiddenMenuBarBannerLayout.status)
            .font(Font(HiddenMenuBarBannerLayout.font))
            .foregroundStyle(HiddenMenuBarIconsPalette.problem)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, HiddenMenuBarBannerLayout.innerInset)
            .padding(.trailing, HiddenMenuBarBannerLayout.outerInset)
    }
}

/// The banner's measurements, matching the other compact banners (Focus's): 13-point
/// semibold words, the same insets.
enum HiddenMenuBarBannerLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let icon: CGFloat = 20
    static let spacing: CGFloat = 7
    static let maximumNameWidth: CGFloat = 136
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10
    static let status = "Won't Open"

    static func widths(for icon: HiddenMenuBarIcon) -> (leading: CGFloat, trailing: CGFloat) {
        (
            outerInset + self.icon + spacing + min(textWidth(icon.name), maximumNameWidth) + innerInset,
            innerInset + textWidth(status) + outerInset
        )
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it.
    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}

// MARK: - Settings

struct HiddenMenuBarIconsSettings: View {
    let access: AccessibilityAccess
    @AppStorage(HiddenMenuBarIconsPrefs.includesIconsInView) private var includesIconsInView = false

    var body: some View {
        LabeledContent {
            if access.isGranted {
                Label {
                    Text("Allowed")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
            } else {
                Button("Grant Access…") { access.request() }
            }
        } label: {
            Text(AccessibilityAccess.paneName)
            Text(access.isGranted
                 ? "Islet reads the menu bar's icons as the island opens, and opens one's menu when you click it."
                 : "Needed to see the menu bar's icons and open their menus. Until then, the home page says so.")
            if !access.isGranted {
                // The trap Volume & Brightness explains too: macOS keeps the permission
                // for the exact copy of the app it was given to, and still shows it
                // switched on for a newer one.
                Text("Already switched on in System Settings? That permission belongs to an earlier copy of Islet. Select Islet in the \(AccessibilityAccess.paneName) list, remove it with −, then click Grant Access again.")
            }
        }
        .onAppear { access.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access.refresh()
        }

        Toggle(isOn: $includesIconsInView) {
            Text("Also show icons that fit")
            Text("The icons in the menu bar follow the hidden ones. Icons switched off in System Settings are left out either way.")
        }
    }
}
