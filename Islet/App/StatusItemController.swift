import AppKit

/// The menu bar item: open the island, preview each feature, reach Settings, quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private var observer: NSObjectProtocol?

    override init() {
        super.init()
        sync()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    private func sync() {
        if Prefs.showMenuBarIcon, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Islet")
            image?.isTemplate = true
            item.button?.image = image
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !Prefs.showMenuBarIcon, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    // Rebuilt on every open so previews reflect the features as they are now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(action("Open Island", #selector(openIsland)))

        let previews = NSMenu()
        for feature in FeatureRegistry.shared.features where !feature.previews.isEmpty {
            if !previews.items.isEmpty { previews.addItem(.separator()) }
            let header = NSMenuItem(title: feature.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            previews.addItem(header)
            for preview in feature.previews {
                let item = PreviewMenuItem(preview: preview)
                item.target = self
                item.action = #selector(runPreview(_:))
                previews.addItem(item)
            }
        }
        if !previews.items.isEmpty {
            let parent = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
            parent.submenu = previews
            menu.addItem(parent)
        }

        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit Islet", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openIsland() {
        IslandManager.shared.focusedController?.model.expand()
    }

    @objc private func runPreview(_ sender: PreviewMenuItem) {
        sender.preview.run()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private final class PreviewMenuItem: NSMenuItem {
    let preview: FeaturePreview

    init(preview: FeaturePreview) {
        self.preview = preview
        super.init(title: preview.title, action: nil, keyEquivalent: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }
}
