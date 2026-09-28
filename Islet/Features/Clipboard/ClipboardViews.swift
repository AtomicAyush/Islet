import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension FeatureTint {
    /// The feature's label and symbols: the iPhone's cyan in its dark appearance.
    static let clipboard = FeatureTint.colour(RGB(bytes: 100, 210, 255))
    /// A pinned item's pin, in the orange Notes pins with.
    static let clipboardPin = FeatureTint.colour(RGB(bytes: 255, 159, 10))
}

enum ClipboardPalette {
    /// Wanting permission: a warning, so never the accent.
    static let permission = SystemHue.warning
    /// "Copied".
    static let copied = SystemHue.success
    /// The time, a link's address, a picture's size and the tile's hint.
    static let secondary = 0.5
    /// The shade of the ink behind the header's chevron.
    static let chip = 0.12
}

enum ClipboardLayout {
    /// The page's height below the notch row: its header and five rows, with the rest
    /// a scroll away. The opened island stays well inside its 330-point window.
    static let pageHeight: CGFloat = 204
    static let pageRowHeight: CGFloat = 34
    static let tileRowHeight: CGFloat = 20
    /// How far a tile row's hover highlight reaches past its content.
    static let tileRowInset: CGFloat = 5
    /// The fade at the foot of the page's list.
    static let fade: CGFloat = 14
    /// Rows on the home tile, which has room for three under its header.
    static let tileRows = 3
}

// MARK: - Home

/// The home page tile: the last three things copied, newest first, each a click from
/// being copied again. The header opens the page with everything. A copy that could
/// not be read for want of permission puts a row asking for it in the oldest's place.
struct ClipboardHomeTile: View {
    let model: ClipboardModel
    let open: () -> Void

    var body: some View {
        let history = model.shown
        let wantsAccess = model.wantsAccess
        let recent = history.recent(ClipboardLayout.tileRows - (wantsAccess ? 1 : 0))
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 4) {
                header(count: history.items.count)
                    .padding(.bottom, 2)
                VStack(alignment: .leading, spacing: 4) {
                    if wantsAccess {
                        ClipboardTileAccessRow(model: model)
                            .transition(.opacity)
                        // With nothing kept yet, there is room to say why.
                        if recent.isEmpty {
                            Text(ClipboardAccessText.hint(model.access, model: model))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.islandText(ClipboardPalette.secondary, on: .homeTile))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, ClipboardLayout.tileRowInset + 20)
                                .padding(.trailing, ClipboardLayout.tileRowInset)
                                .transition(.opacity)
                        }
                    }
                    ForEach(recent) { item in
                        ClipboardTileRow(item: item, model: model, now: context.date)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                // Rows light up a little past their content under the pointer; their
                // content lines up with the header's.
                .padding(.horizontal, -ClipboardLayout.tileRowInset)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: recent.map(\.id))
            .animation(.easeOut(duration: 0.2), value: wantsAccess)
        }
    }

    private func header(count: Int) -> some View {
        Button(action: open) {
            HStack(spacing: 5) {
                // The tile's width depends on how many other tiles are up; the title
                // goes before anything else does.
                ViewThatFits(in: .horizontal) {
                    Label("Clipboard", systemImage: "doc.on.clipboard.fill")
                    Image(systemName: "doc.on.clipboard.fill")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.islandAccentText(.clipboard, on: .homeTile))
                .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.islandText(0.55, on: .homeTile))
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.islandGraphic(0.55, on: IslandBackdrop.homeTile.stacked(ClipboardPalette.chip)))
                    .frame(width: 18, height: 16)
                    .background(Capsule().fill(.islandSurface(ClipboardPalette.chip, on: .homeTile)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show everything copied")
        .accessibilityLabel("Clipboard, \(count) \(count == 1 ? "item" : "items")")
        .accessibilityHint("Shows everything copied")
    }
}

/// One item on the home tile: the app it came from, a line of it, and when. Click to
/// copy it again.
private struct ClipboardTileRow: View {
    let item: ClipboardItem
    let model: ClipboardModel
    let now: Date
    @State private var isHovering = false

    var body: some View {
        let isCopied = model.justCopied == item.id
        Button {
            model.copy(item)
        } label: {
            HStack(spacing: 6) {
                ClipboardAppIcon(source: item.source, size: 14)
                ClipboardSummary(content: item.content, size: .tile)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // "Copied" takes the time's place, and the text gives way to it.
                if isCopied {
                    CopiedBadge(backdrop: .homeTile)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.islandAccent(.clipboardPin, on: .homeTile))
                            .accessibilityHidden(true)
                    }
                    Text(ClipboardTime.short(item.copiedAt, now: now))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.islandText(ClipboardPalette.secondary, on: .homeTile))
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, ClipboardLayout.tileRowInset)
            .frame(height: ClipboardLayout.tileRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.islandDecorative(isHovering ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: isCopied)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .clipboardMenu(item: item, model: model)
        .accessibilityLabel(ClipboardSpeech.label(for: item, now: now))
        .accessibilityHint("Copies it again")
    }
}

/// The tile's request for permission: Allow, where macOS has not asked yet, or the
/// way to Privacy & Security, where Islet has still to be turned on. Allow waits for a
/// copy it may read, since macOS asks only as one is read.
private struct ClipboardTileAccessRow: View {
    let model: ClipboardModel

    var body: some View {
        let access = model.access
        let detail = ClipboardAccessText.detail(access, model: model)
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.islandHue(ClipboardPalette.permission, on: .homeTile))
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            // Longest first; the narrowest tile has room for about ten letters.
            ViewThatFits(in: .horizontal) {
                ForEach(ClipboardAccessText.tile(access, canAsk: model.canAsk), id: \.self) { Text($0) }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.islandText(0.9, on: .homeTile))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            ClipboardCapsuleButton(title: ClipboardAccessText.tileButton(access), help: detail, backdrop: .homeTile) {
                model.requestAccess()
            }
            .disabled(!ClipboardAccessText.canClick(model))
        }
        .padding(.horizontal, ClipboardLayout.tileRowInset)
        .frame(height: ClipboardLayout.tileRowHeight)
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ClipboardAccessText.title(access))
        .accessibilityHint(detail)
        .accessibilityAction { model.requestAccess() }
    }
}

// MARK: - Page

/// Everything copied, pinned items first: the page the tile opens. Click a row to copy
/// it again; the pin keeps it at the top, and across restarts.
struct ClipboardPage: View {
    let model: ClipboardModel
    @State private var hovered: UUID?

    /// `hovered` starts a row as if the pointer were on it, for renders of the page.
    init(model: ClipboardModel, hovered: UUID? = nil) {
        self.model = model
        _hovered = State(initialValue: hovered)
    }

    var body: some View {
        let history = model.shown
        let items = history.items

        // A preview's made-up history needs no permission.
        let access = model.sample == nil ? model.access : .allowed
        VStack(alignment: .leading, spacing: 6) {
            header(count: items.count, canClear: items.contains { !$0.isPinned })
                .padding(.horizontal, 8)

            if items.isEmpty {
                if access == .allowed {
                    empty
                } else {
                    ClipboardAccessNotice(model: model, access: access)
                }
            } else {
                if access != .allowed {
                    ClipboardAccessBar(model: model, access: access)
                        .padding(.horizontal, 8)
                }
                TimelineView(.everyMinute) { context in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                // A hairline where the pinned items end.
                                if index > 0, !item.isPinned, items[index - 1].isPinned {
                                    Rectangle()
                                        .fill(.islandDecorative(0.1))
                                        .frame(height: 1)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                }
                                ClipboardPageRow(
                                    item: item, model: model, now: context.date, isHovered: hovered == item.id
                                )
                                .onHover { inside in
                                    if inside {
                                        hovered = item.id
                                    } else if hovered == item.id {
                                        hovered = nil
                                    }
                                }
                            }
                        }
                        // Room below the last row, so scrolled to the end it clears the fade.
                        .padding(.bottom, ClipboardLayout.fade)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: items.map(\.id))
                    }
                    // No scroller, even with a mouse connected, where macOS would keep
                    // one up in a gutter of its own: the fade at the foot says there is
                    // more, as the home row's edges do.
                    .scrollIndicators(.never)
                    .mask(
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: ClipboardLayout.fade)
                        }
                    )
                }
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Permission is given in System Settings, so it is looked at again each time
        // the page opens.
        .onAppear { model.refreshAccess() }
    }

    private func header(count: Int, canClear: Bool) -> some View {
        HStack(spacing: 6) {
            Label("Clipboard", systemImage: "doc.on.clipboard.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.islandAccentText(.clipboard))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.islandText(0.55))
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            if count > 0 {
                Text("Click to copy · Right-click for more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.islandText(0.35))
                    .lineLimit(1)
            }
            if canClear {
                ClipboardCapsuleButton(title: "Clear", help: "Clear everything but pinned items") { model.clear() }
            }
        }
        .frame(height: 18)
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Text("Nothing copied yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.islandText(0.6))
            Text("Text, links, pictures and files you copy show up here.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.islandText(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One item on the page: the app it came from, what it is, and when it was copied.
/// With the pointer on it, a pin and a cross take the time's place; a pinned item
/// shows its pin beside the time.
private struct ClipboardPageRow: View {
    let item: ClipboardItem
    let model: ClipboardModel
    let now: Date
    let isHovered: Bool

    /// The trailing column: wide enough for the two buttons, which is wider than any
    /// time with its pin, so nothing beside it moves as they swap. "Copied" is wider
    /// still, and the text gives way to it for the moment it is up.
    static let trailingWidth: CGFloat = 44

    var body: some View {
        let isCopied = model.justCopied == item.id
        HStack(spacing: 10) {
            ClipboardAppIcon(source: item.source, size: 20)
            ClipboardSummary(content: item.content, size: .page)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing(isCopied: isCopied)
                .frame(minWidth: Self.trailingWidth, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .frame(height: ClipboardLayout.pageRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.islandDecorative(isHovered ? 0.09 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.copy(item) }
        .clipboardMenu(item: item, model: model)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.18), value: isCopied)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ClipboardSpeech.label(for: item, now: now))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.copy(item) }
        .accessibilityAction(named: item.isPinned ? "Unpin" : "Pin") { model.setPinned(item, !item.isPinned) }
        .accessibilityAction(named: "Remove") { model.remove(item) }
    }

    /// The time (with the pin, if pinned); the pin and cross buttons under the
    /// pointer; "Copied" in place of either for a moment.
    private func trailing(isCopied: Bool) -> some View {
        ZStack(alignment: .trailing) {
            if isHovered, !isCopied {
                HStack(spacing: 2) {
                    RowButton(
                        symbol: item.isPinned ? "pin.slash" : "pin",
                        tint: item.isPinned ? .islandAccent(.clipboardPin) : .islandGraphic(0.75),
                        help: item.isPinned ? "Unpin" : "Pin to the top"
                    ) {
                        model.setPinned(item, !item.isPinned)
                    }
                    RowButton(symbol: "xmark", tint: .islandGraphic(0.75), help: "Remove") {
                        model.remove(item)
                    }
                }
                .transition(.opacity)
            } else if !isCopied {
                HStack(spacing: 4) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.islandAccent(.clipboardPin))
                            .accessibilityHidden(true)
                    }
                    Text(ClipboardTime.short(item.copiedAt, now: now))
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.islandText(ClipboardPalette.secondary))
                        .fixedSize()
                }
                .transition(.opacity)
            }
            if isCopied {
                CopiedBadge()
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }
}

private struct RowButton: View {
    let symbol: String
    let tint: IslandStyle
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.islandDecorative(isHovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// "Copied", in green with a tick, where the time was.
private struct CopiedBadge: View {
    /// What the badge lies on: the home tile, or the page, which is the island itself.
    var backdrop: IslandBackdrop = .island
    @Environment(\.islandTheme) private var theme

    private static let wash = 0.16

    var body: some View {
        // The capsule is a wash of the green as it is, the farthest it can be from the
        // island's ink, which leaves the words on it the most room; they are fitted
        // against the capsule as it lies on the tile or the island.
        let green = ClipboardPalette.copied.dark
        let capsule = IslandBackdrop.fill(green.composited(Self.wash, over: theme.colour(of: backdrop)))
        Label("Copied", systemImage: "checkmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.islandHueText(ClipboardPalette.copied, on: capsule))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .frame(height: 16)
            .background(Capsule().fill(green.color.opacity(Self.wash)))
            .fixedSize()
            .accessibilityLabel("Copied")
    }
}

/// A word in a capsule: the page's Clear, and Allow where permission is wanted. Turned
/// off, it fades, as the plain style leaves it looking live.
private struct ClipboardCapsuleButton: View {
    let title: String
    let help: String
    /// What the capsule lies on: the home tile, or the page, which is the island itself.
    var backdrop: IslandBackdrop = .island
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let isLit = isHovering && isEnabled
        let wash = isLit ? 0.2 : (isEnabled ? 0.12 : 0.07)
        let behind = backdrop.stacked(wash)
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                // Turned off, it is a control still to be seen rather than words to read.
                .foregroundStyle(isEnabled ? IslandStyle.islandText(isLit ? 0.95 : 0.7, on: behind) : .islandGraphic(0.35, on: behind))
                .frame(height: 16)
                .background(Capsule().fill(.islandSurface(wash, on: backdrop)))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

// MARK: - Permission

/// The page, empty for want of permission: what is wanted, and the button that sees
/// to it.
private struct ClipboardAccessNotice: View {
    let model: ClipboardModel
    let access: ClipboardAccess

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.islandHue(ClipboardPalette.permission))
                .accessibilityHidden(true)
            Text(ClipboardAccessText.title(access))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.islandText(0.85))
            Text(ClipboardAccessText.detail(access, model: model))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.islandText(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            ClipboardCapsuleButton(title: ClipboardAccessText.button(access), help: ClipboardAccessText.detail(access, model: model)) {
                model.requestAccess()
            }
            .disabled(!ClipboardAccessText.canClick(model))
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A line above the list, while new copies go unread for want of permission.
private struct ClipboardAccessBar: View {
    let model: ClipboardModel
    let access: ClipboardAccess
    @Environment(\.islandTheme) private var theme

    /// The bar: a wash of the warning's orange, which the hand and the words on it are
    /// measured against.
    private static let wash = 0.1

    var body: some View {
        let bar = IslandBackdrop.fill(theme.fitted(ClipboardPalette.permission.dark).composited(Self.wash, over: theme.island))
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.islandHue(ClipboardPalette.permission, on: bar))
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(ClipboardAccessText.title(access))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.islandText(0.8, on: bar))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ClipboardCapsuleButton(title: ClipboardAccessText.button(access), help: ClipboardAccessText.detail(access, model: model)) {
                model.requestAccess()
            }
            .disabled(!ClipboardAccessText.canClick(model))
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.islandHue(ClipboardPalette.permission).opacity(Self.wash))
        )
        .help(ClipboardAccessText.detail(access, model: model))
    }
}

/// What is said about permission, on the tile, the page and in Settings. Until Islet
/// is allowed, nothing new is kept; macOS asks only as something is read, which Islet
/// does, for the alert, when Allow is clicked.
@MainActor
enum ClipboardAccessText {
    static func title(_ access: ClipboardAccess) -> String {
        switch access {
        case .allowed: "Islet can keep what you copy"
        case .notAsked: "Allow Islet to keep what you copy"
        case .asks: "Allow Islet in System Settings to keep what you copy"
        case .denied: "Islet can’t see what you copy"
        }
    }

    static func detail(_ access: ClipboardAccess, model: ClipboardModel) -> String {
        switch access {
        case .allowed:
            ""
        case .notAsked where model.askFailed:
            "macOS didn’t ask. Copy something else, then click Allow again."
        case .notAsked where !model.canAsk:
            "macOS asks as Islet reads a copy. Copy something, then click Allow, and allow Islet when macOS asks."
        case .notAsked:
            "macOS asks before an app reads what other apps copy. Click Allow, and allow Islet when macOS asks."
        case .asks:
            "Turn Islet on under Privacy & Security › Paste from Other Apps. Until then, nothing new is kept."
        case .denied:
            "Paste from Other Apps is off for Islet in Privacy & Security. Turn it on, and what you copy shows up here."
        }
    }

    /// Why, in a line or two, for the home tile.
    static func hint(_ access: ClipboardAccess, model: ClipboardModel) -> String {
        switch access {
        case .notAsked where !model.canAsk: "macOS asks only as Islet reads a copy, so Allow needs a new one."
        case .notAsked: "macOS asks before an app reads what other apps copy."
        case .asks: "Turn Islet on under Privacy & Security › Paste from Other Apps."
        case .allowed, .denied: ""
        }
    }

    /// The tile's line, longest first, for as much as fits.
    static func tile(_ access: ClipboardAccess, canAsk: Bool) -> [String] {
        switch access {
        case .notAsked where !canAsk: ["Copy something, then Allow", "Copy, then Allow", "Copy first"]
        case .notAsked: ["Allow Islet to keep copies", "Keep copies?"]
        case .asks: ["Allow Islet in Settings to keep copies", "Allow in Settings", "Not allowed"]
        case .allowed, .denied: [""]
        }
    }

    /// Allow, the same word everywhere; the way to System Settings, in a word on the
    /// tile, where room is short.
    static func tileButton(_ access: ClipboardAccess) -> String {
        access == .notAsked ? button(access) : "Settings"
    }

    static func button(_ access: ClipboardAccess) -> String {
        access == .notAsked ? "Allow…" : "Open Settings"
    }

    /// Whether the button does anything now: not while macOS's alert is up, nor, with
    /// Allow, while there is no copy to ask with.
    static func canClick(_ model: ClipboardModel) -> Bool {
        !model.isAsking && (model.access != .notAsked || model.canAsk)
    }
}

extension View {
    /// Copy, pin, remove, and for a link or files the way to them.
    fileprivate func clipboardMenu(item: ClipboardItem, model: ClipboardModel) -> some View {
        modifier(ClipboardMenu(item: item, model: model))
    }
}

/// An item's menu (`clipboardMenu`). On the home page it also arranges the page, as the
/// page's own menu would, since this one takes the right-click there.
private struct ClipboardMenu: ViewModifier {
    let item: ClipboardItem
    let model: ClipboardModel
    @Environment(\.editHomePage) private var editHomePage

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Copy") { model.copy(item) }
            Button(item.isPinned ? "Unpin" : "Pin") { model.setPinned(item, !item.isPinned) }
            switch item.content {
            case .link(let url, _):
                Button("Open Link") { model.open(url) }
            case .files(let urls):
                Button("Show in Finder") { model.reveal(urls) }
            default:
                EmptyView()
            }
            Divider()
            Button("Remove") { model.remove(item) }
            if let editHomePage {
                Divider()
                Button("Edit Home Page") { editHomePage() }
            }
        }
    }
}

// MARK: - Content

/// What an item is, in a row: a line or two of text, a link's title and address, a
/// picture's thumbnail and size, or a file's icon and name.
struct ClipboardSummary: View {
    enum Size {
        /// One line, for the home tile.
        case tile
        /// Up to two lines, for the page.
        case page
    }

    let content: ClipboardContent
    let size: Size

    private var isPage: Bool { size == .page }
    /// The tile's rows lie on the home tile; the page's on the island itself.
    private var backdrop: IslandBackdrop { isPage ? .island : .homeTile }
    private var primary: IslandStyle { .islandText(0.9, on: backdrop) }
    private var secondary: IslandStyle { .islandText(ClipboardPalette.secondary, on: backdrop) }
    private var primaryFont: Font { .system(size: isPage ? 12 : 11, weight: .medium) }
    private var secondaryFont: Font { .system(size: 10.5, weight: .medium) }

    var body: some View {
        switch content {
        case .text(let text):
            Text(ClipboardText.preview(text))
                .font(primaryFont)
                .foregroundStyle(primary)
                .lineLimit(isPage ? 2 : 1)
                .truncationMode(.tail)

        case .link(let url, let title):
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: isPage ? 11 : 9, weight: .semibold))
                    .foregroundStyle(.islandAccent(.clipboard, on: backdrop))
                    .accessibilityHidden(true)
                if isPage {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title ?? ClipboardText.host(of: url))
                            .font(primaryFont)
                            .foregroundStyle(primary)
                        // An address says most at its two ends: the site, and the page.
                        Text(ClipboardText.address(of: url))
                            .font(secondaryFont)
                            .foregroundStyle(secondary)
                            .truncationMode(.middle)
                    }
                    .lineLimit(1)
                } else {
                    Text(title ?? ClipboardText.host(of: url))
                        .font(primaryFont)
                        .foregroundStyle(primary)
                        .lineLimit(1)
                }
            }

        case .image(let image):
            HStack(spacing: isPage ? 8 : 5) {
                ClipboardThumbnail(image: image, height: isPage ? 26 : 14)
                if isPage {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Image")
                            .font(primaryFont)
                            .foregroundStyle(primary)
                        Text(ClipboardText.dimensions(of: image))
                            .font(secondaryFont)
                            .foregroundStyle(secondary)
                    }
                } else {
                    Text("Image")
                        .font(primaryFont)
                        .foregroundStyle(primary)
                }
            }
            .lineLimit(1)

        case .files(let urls):
            HStack(spacing: isPage ? 8 : 5) {
                if let first = urls.first {
                    ClipboardFileIcon(url: first, size: isPage ? 24 : 14)
                }
                if isPage {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ClipboardText.fileNames(urls))
                            .font(primaryFont)
                            .foregroundStyle(primary)
                            .truncationMode(.middle)
                        Text(ClipboardText.fileDetail(urls))
                            .font(secondaryFont)
                            .foregroundStyle(secondary)
                    }
                } else {
                    Text(ClipboardText.fileNames(urls))
                        .font(primaryFont)
                        .foregroundStyle(primary)
                        .truncationMode(.middle)
                }
            }
            .lineLimit(1)
        }
    }
}

/// A picture's thumbnail, as wide as its shape asks up to twice its height, with the
/// rounded corners of a photo in Messages.
private struct ClipboardThumbnail: View {
    let image: ClipboardImage
    let height: CGFloat

    var body: some View {
        let aspect = image.pixelSize.height > 0 ? image.pixelSize.width / image.pixelSize.height : 1
        let width = min(max(height * aspect, height * 0.6), height * 2)
        Group {
            if let thumbnail = image.thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.islandDecorative(0.12))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: height > 20 ? 5 : 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: height > 20 ? 5 : 3, style: .continuous)
                .strokeBorder(.islandDecorative(0.14), lineWidth: 0.5)
        )
    }
}

/// The app an item was copied from, by its icon; a plain square where it is not known.
struct ClipboardAppIcon: View {
    let source: ClipboardSource?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = ClipboardIcons.shared.app(source?.bundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(.islandDecorative(0.14))
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .help(source?.name ?? "")
        .accessibilityHidden(true)
    }
}

private struct ClipboardFileIcon: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: ClipboardIcons.shared.file(url))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .fileIconBacking(size: size)
            .accessibilityHidden(true)
    }
}

/// App and file icons, kept so rows drawn again do not ask Launch Services again.
@MainActor
final class ClipboardIcons {
    static let shared = ClipboardIcons()

    private let apps = NSCache<NSString, NSImage>()
    private let files = NSCache<NSString, NSImage>()
    /// Bundle identifiers with no app on this Mac.
    private var missing: Set<String> = []

    private init() {}

    func app(_ bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !missing.contains(bundleIdentifier) else { return nil }
        if let icon = apps.object(forKey: bundleIdentifier as NSString) { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            missing.insert(bundleIdentifier)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        apps.setObject(icon, forKey: bundleIdentifier as NSString)
        return icon
    }

    /// The file's own icon while it is there; its kind's, once it has gone.
    func file(_ url: URL) -> NSImage {
        if let icon = files.object(forKey: url.path as NSString) { return icon }
        let icon: NSImage
        if FileManager.default.fileExists(atPath: url.path) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
        }
        files.setObject(icon, forKey: url.path as NSString)
        return icon
    }
}

// MARK: - Words

enum ClipboardText {
    /// The start of a text on one line: runs of spaces, tabs and line breaks become a
    /// single space, so an indented block of code reads as its words.
    static func preview(_ text: String) -> String {
        let start = text.prefix(ClipboardLimits.previewLength)
        return start.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// "apple.com" for www.apple.com; the address itself for a mail link.
    static func host(of url: URL) -> String {
        if url.scheme?.lowercased() == "mailto" { return address(of: url) }
        guard var host = url.host() else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The address without its scheme: "developer.apple.com/documentation".
    static func address(of url: URL) -> String {
        var string = url.absoluteString
        for prefix in ["https://", "http://", "mailto:"] where string.lowercased().hasPrefix(prefix) {
            string.removeFirst(prefix.count)
            break
        }
        if string.hasSuffix("/") { string.removeLast() }
        return string
    }

    /// "1600 × 1000 · PNG".
    static func dimensions(of image: ClipboardImage) -> String {
        let kind = switch image.type.rawValue {
        case "public.jpeg": "JPEG"
        case "public.heic": "HEIC"
        case "com.compuserve.gif": "GIF"
        default: "PNG"
        }
        return "\(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height)) · \(kind)"
    }

    /// "Report.pdf", or "Report.pdf and 2 more".
    static func fileNames(_ urls: [URL]) -> String {
        guard let first = urls.first else { return "" }
        return urls.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) and \(urls.count - 1) more"
    }

    /// Where the file is: "in Documents".
    static func fileDetail(_ urls: [URL]) -> String {
        guard let first = urls.first else { return "" }
        let folder = first.deletingLastPathComponent()
        return "in \(FileManager.default.displayName(atPath: folder.path))"
    }
}

enum ClipboardTime {
    /// "now", "5m", "2h", "3d": the island's short way with time.
    static func short(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}

/// What VoiceOver says for an item.
enum ClipboardSpeech {
    static func label(for item: ClipboardItem, now: Date) -> String {
        var parts: [String] = []
        switch item.content {
        case .text(let text): parts.append("Text: \(ClipboardText.preview(String(text.prefix(120))))")
        case .link(let url, let title): parts.append("Link: \(title ?? ClipboardText.host(of: url))")
        case .image(let image): parts.append("Image, \(Int(image.pixelSize.width)) by \(Int(image.pixelSize.height))")
        case .files(let urls): parts.append(urls.count == 1 ? "File: \(ClipboardText.fileNames(urls))" : "\(urls.count) files")
        }
        if let source = item.source { parts.append("from \(source.name)") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        parts.append(formatter.localizedString(for: item.copiedAt, relativeTo: max(now, item.copiedAt)))
        if item.isPinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Settings

struct ClipboardSettingsView: View {
    let model: ClipboardModel
    @AppStorage(ClipboardPrefs.limit) private var limit = ClipboardPrefs.defaultLimit
    @AppStorage(ClipboardPrefs.keepHistory) private var keepHistory = false
    @AppStorage(ClipboardPrefs.clearOnLock) private var clearOnLock = false
    @State private var isConfirmingForget = false

    var body: some View {
        Group {
            if model.access != .allowed {
                LabeledContent {
                    Button(ClipboardAccessText.button(model.access)) { model.requestAccess() }
                        .disabled(!ClipboardAccessText.canClick(model))
                } label: {
                    Text(ClipboardAccessText.title(model.access))
                    Text(ClipboardAccessText.detail(model.access, model: model))
                }
            }
            options
        }
        // Permission is given in System Settings, so it is looked at again each time
        // this appears.
        .onAppear { model.refreshAccess() }
    }

    @ViewBuilder private var options: some View {
        Picker("Remember", selection: $limit) {
            ForEach(ClipboardPrefs.limits, id: \.self) { count in
                Text("Last \(count) items").tag(count)
            }
        }
        Toggle(isOn: $keepHistory) {
            Text("Keep history between launches")
            Text("Saved in Islet’s Application Support folder, readable only by you and left out of backups. Pictures over 2 MB are kept only while Islet runs. Pinned items are always kept.")
        }
        .onChange(of: keepHistory) { _, _ in model.keepingChanged() }
        Toggle(isOn: $clearOnLock) {
            Text("Clear when the Mac locks")
            Text("Pinned items stay.")
        }
        LabeledContent {
            Button("Clear…") { isConfirmingForget = true }
        } label: {
            Text("Clear everything copied")
            Text("Pinned items too, and whatever is saved.")
        }
        .confirmationDialog("Clear everything copied, pinned items too?", isPresented: $isConfirmingForget) {
            Button("Clear Everything", role: .destructive) { model.forgetEverything() }
        }
        Text("Left out: anything an app marks as secret or only passing through, and anything copied while a password manager is in front. A password manager’s browser extension that marks nothing looks like the browser.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
