import AppKit
import SwiftUI

/// The menu bar icons a MacBook's notch hides, on the home page, each a click from its
/// menu. With a long menu in front, the icons that do not fit beside the notch are
/// pushed behind the camera housing or out of the menu bar altogether, where they can
/// be neither seen nor clicked, however much they are needed.
///
/// Islet finds them through Accessibility, as VoiceOver does (`MenuBarAccessibility`):
/// every app's status items, where each one is, and whether that is under the notch or
/// out of the menu bar; out of it, whether for want of room or because someone switched
/// it off, which only the room left can tell (`HiddenMenuBarIcons.look`). It looks as
/// the island opens (and as the feature starts, or Islet comes to the front), off the
/// main thread, and not again for a couple of seconds; nothing watches the menu bar in
/// between. A click on an icon
/// closes the island and presses the item, as a click in the menu bar would, so its
/// menu opens; the icon drawn is its app's, or, for the system's own items, the symbol
/// closest to theirs, since the item's own picture is only to be had by recording the
/// screen. Without Accessibility the tile says so and offers the way to allow it;
/// nothing is ever asked for on its own.
@MainActor
final class HiddenMenuBarIconsFeature: Feature {
    let id = "hiddenMenuBarIcons"
    let title = "Hidden Menu Bar Icons"
    let symbol = "menubar.arrow.up.rectangle"
    let summary = "Menu bar icons the notch hides, on the home page, a click from their menus."

    /// The page with every hidden icon, where the tile has room for a few, which the
    /// island opens as its focus (`islet://open?focus=hiddenMenuBarIcons`).
    static let pageID = "hiddenMenuBarIcons"
    static let failureBannerID = "hiddenMenuBarIcons.failed"
    /// How long an Accessibility change takes to show in `AXIsProcessTrusted`.
    private static let accessRecheckDelay: TimeInterval = 0.5

    let model: HiddenMenuBarIconsModel
    private let access = AccessibilityAccess()
    private var isRunning = false
    private var isPageShown = false
    /// The height the page was last set at; it grows and shrinks with the list.
    private var pageHeight: CGFloat?
    /// The tile's place on the home page while it is up (`render`).
    private var tileOrder: Int?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var accessRecheck: DispatchWorkItem?
    private var previewTask: Task<Void, Never>?
    /// The islands on screen, which close as an icon's menu opens.
    private let islands: @MainActor () -> [IslandViewModel]

    /// Tests pass a model reading a made-up menu bar, and islands of their own.
    init(
        model: HiddenMenuBarIconsModel? = nil,
        islands: @escaping @MainActor () -> [IslandViewModel] = { IslandManager.shared.controllers.values.map(\.model) }
    ) {
        let model = model ?? HiddenMenuBarIconsModel()
        self.model = model
        self.islands = islands
        model.onChange = { [weak self] in self?.render() }
        model.onPress = { [weak self] in self?.closeIslands() }
        model.onFailure = { [weak self] icon in self?.presentFailure(icon) }
    }

    func start() {
        isRunning = true
        applySettings()
        let local = NotificationCenter.default
        observers.append((local, local.addObserver(
            forName: IslandViewModel.didOpenNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.islandOpened() }
        }))
        observers.append((local, local.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }))
        // Back from System Settings, perhaps with Accessibility.
        observers.append((local, local.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.accessMayHaveChanged() }
        }))
        // Posted when the Accessibility list changes. It is undocumented, so it only
        // hurries things along; opening the island checks again anyway.
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAccessRecheck() }
        }))
        // One look now, so the first time the island opens it already knows.
        model.look(force: true)
        render()
    }

    func stop() {
        isRunning = false
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        observers = []
        accessRecheck?.cancel()
        accessRecheck = nil
        previewTask?.cancel()
        previewTask = nil
        model.reset()
        model.endSample()
        render()
        ActivityCenter.shared.dismissBanner(id: Self.failureBannerID)
    }

    func settingsView() -> AnyView? {
        AnyView(HiddenMenuBarIconsSettings(access: access))
    }

    /// Made-up icons stand in for the real ones while the island stays open, and for
    /// at least eight seconds. Clicking one opens nothing.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Hidden menu bar icons") { [weak self] in
                self?.preview(HiddenMenuBarIconsSamples.few, opening: IslandViewModel.homeFocus)
            },
            FeaturePreview(title: "Every hidden icon") { [weak self] in
                self?.preview(HiddenMenuBarIconsSamples.many, opening: Self.pageID)
            },
            FeaturePreview(title: "Icon that won't open") { [weak self] in
                self?.presentFailure(HiddenMenuBarIconsSamples.refusing, preview: true)
            },
        ]
    }

    // MARK: Island

    /// The page is there to open while the feature runs (or a preview is up), and the
    /// tile on the home page while there is an icon to list, or Accessibility to ask
    /// for. With nothing hidden, the home page is left to the rest.
    private func render() {
        let center = ActivityCenter.shared
        let isAttached = isRunning || model.sample != nil
        let listed = model.listed

        let height = HiddenMenuBarIconsLayout.pageHeight(for: listed)
        if isAttached != isPageShown || (isAttached && height != pageHeight) {
            isPageShown = isAttached
            if isAttached {
                pageHeight = height
                center.setPage(IslandPage(
                    id: Self.pageID, symbol: symbol, height: height,
                    view: AnyView(HiddenMenuBarIconsPage(model: model))
                ))
            } else {
                pageHeight = nil
                center.removePage(id: Self.pageID)
            }
        }

        let wantsTile = isAttached && (model.needsAccess || !listed.isEmpty)
        // With icons out of sight, which is when the tile matters, ahead of the timer,
        // so a busy home row does not push it out of sight as well. Otherwise (only the
        // icons in sight listed, or Accessibility to ask for), after Shortcuts: both
        // are a click from something that is not on screen.
        let order = wantsTile ? (listed.contains(where: \.isHidden) ? 25 : 48) : nil
        guard order != tileOrder else { return }
        tileOrder = order
        if let order {
            center.setHomeWidget(HomeWidget(
                id: id, order: order,
                view: AnyView(HiddenMenuBarIconsTile(model: model) {
                    IslandManager.shared.focusedController?.model.select(focus: Self.pageID)
                })
            ))
        } else {
            center.removeHomeWidget(id: id)
        }
    }

    private func islandOpened() {
        guard isRunning else { return }
        model.look()
    }

    /// The icon's menu is about to open where the icon is, under the notch or wherever
    /// macOS has put it; the opened island would be over it, and in the way.
    private func closeIslands() {
        for island in islands() where island.isExpanded {
            island.collapse("menu bar icon opened")
        }
    }

    /// A moment's word that the click did nothing: the island has closed for a menu
    /// that never came.
    private func presentFailure(_ icon: HiddenMenuBarIcon, preview: Bool = false) {
        guard isRunning || preview else { return }
        let widths = HiddenMenuBarBannerLayout.widths(for: icon)
        ActivityCenter.shared.present(IslandBanner(
            id: Self.failureBannerID,
            style: .compact(leading: widths.leading, trailing: widths.trailing),
            leading: AnyView(HiddenMenuBarFailureLeading(icon: icon)),
            trailing: AnyView(HiddenMenuBarFailureTrailing())
        ))
    }

    // MARK: Settings and access

    private func applySettings() {
        let includes = HiddenMenuBarIconsPrefs.bool(HiddenMenuBarIconsPrefs.includesIconsInView, default: false)
        if model.includesIconsInView != includes { model.includesIconsInView = includes }
    }

    /// Checks again, and with access looks, unless a look from the last couple of
    /// seconds answers: nothing was listed while access was missing.
    private func accessMayHaveChanged() {
        access.refresh()
        model.look()
    }

    private func scheduleAccessRecheck() {
        accessRecheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.accessMayHaveChanged() }
        }
        accessRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.accessRecheckDelay, execute: work)
    }

    // MARK: Previews

    private func preview(_ icons: [HiddenMenuBarIcon], opening focus: String) {
        model.showSample(icons)
        IslandManager.shared.focusedController?.model.expand(focus: focus)
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            // Not while an island is still open, where the samples would turn into the
            // real icons under the pointer; two minutes at most.
            for _ in 0..<120 {
                guard !Task.isCancelled else { return }
                let isOpen = IslandManager.shared.controllers.values.contains { $0.model.isExpanded }
                if !isOpen { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.model.endSample()
        }
    }
}

/// The feature's preference keys, shared by the feature and its settings. Unset keys
/// read as their defaults, the same ones the settings toggles declare.
enum HiddenMenuBarIconsPrefs {
    /// Whether the icons in sight are listed too, after the hidden ones.
    static let includesIconsInView = "hiddenMenuBarIcons.includesIconsInView"

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}
