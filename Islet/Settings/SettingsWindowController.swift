import AppKit
import SwiftUI

/// Settings in an ordinary window. Islet runs as an accessory (no Dock icon), so it
/// switches to a regular app while Settings is open — otherwise the window could
/// not take focus or appear in Cmd-Tab — and back when it closes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let search = SettingsSearch()

    func show() {
        if window == nil {
            let window = SettingsWindow(search: search)
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Opens Settings on `tab` ("general", "activities" or "about"), ending a search so
    /// the tab shows rather than waiting behind the results.
    func show(tab: String) {
        search.showTab(tab)
        show()
    }

    /// Opens Settings on General's `row`, scrolled to and lit for a moment.
    func show(_ row: GeneralRow) {
        search.show(row)
        show()
    }

    func windowWillClose(_ notification: Notification) {
        // Opened again, Settings shows its tabs rather than an old search.
        search.clear()
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The Settings window, with a search field in its toolbar that ⌘F reaches from
/// anywhere in the window and Escape empties, wherever the keyboard is.
final class SettingsWindow: NSWindow, NSToolbarDelegate {
    static let searchItemID = NSToolbarItem.Identifier("search")
    /// The tabs' size, below the toolbar.
    static let tabsSize = NSSize(width: 620, height: 560)

    let searchItem = NSSearchToolbarItem(itemIdentifier: SettingsWindow.searchItemID)
    /// The tabs, and the results that stand in for them during a search. Both stay made
    /// and one is hidden, so ending a search puts the tab back as it was, scrolled
    /// where it was, without making its settings again; a hidden one draws nothing and
    /// is out of the keyboard's way.
    let tabsView: NSView
    let resultsView: NSView
    private let search: SettingsSearch

    init(search: SettingsSearch) {
        self.search = search
        let tabs = NSHostingView(rootView: SettingsView().settingsWindowEnvironment(search))
        let results = NSHostingView(rootView: SettingsSearchResults(search: search).settingsWindowEnvironment(search))
        tabsView = tabs
        resultsView = results
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.tabsSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Islet Settings"
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false

        // SwiftUI leaves the toolbar and the window's size to this window: managing the
        // toolbar itself, it would put the tabs there and leave out the search field.
        tabs.sceneBridgingOptions = []
        results.sceneBridgingOptions = []
        tabs.sizingOptions = []
        results.sizingOptions = []
        let content = NSView(frame: NSRect(origin: .zero, size: Self.tabsSize))
        tabs.frame = content.bounds
        tabs.autoresizingMask = [.width, .height]
        content.addSubview(tabs)
        // Below the toolbar and cut off there, as the tabs' own box is, rather than
        // scrolling under the window's buttons and title.
        results.translatesAutoresizingMaskIntoConstraints = false
        results.clipsToBounds = true
        results.isHidden = true
        content.addSubview(results)
        contentView = content

        let field = searchItem.searchField
        field.placeholderString = "Search Settings"
        field.setAccessibilityLabel("Search Settings")
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(searchFieldChanged(_:))
        searchItem.preferredWidthForSearchField = 200
        search.showQuery = { [weak field] text in
            if field?.stringValue != text { field?.stringValue = text }
        }
        search.focusField = { [weak self] in self?.searchItem.beginSearchInteraction() }
        search.searchingChanged = { [weak self] searching in
            self?.tabsView.isHidden = searching
            self?.resultsView.isHidden = !searching
        }

        let toolbar = NSToolbar(identifier: "IsletSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar
        toolbarStyle = .unified

        if let below = contentLayoutGuide as? NSLayoutGuide {
            NSLayoutConstraint.activate([
                results.topAnchor.constraint(equalTo: below.topAnchor),
                results.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                results.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                results.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        // The tabs' size below the toolbar, which the content runs up under.
        let toolbarHeight = frame.height - contentLayoutRect.height
        setFrame(NSRect(origin: frame.origin, size: NSSize(width: Self.tabsSize.width, height: Self.tabsSize.height + toolbarHeight)),
                 display: false)
    }

    @objc private func searchFieldChanged(_ field: NSSearchField) {
        search.search(field.stringValue)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Caps Lock and the function key don't count against ⌘F.
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            search.focus()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Escape with the keyboard on a control, or on nothing: controls pass on the keys
    /// they don't use, and it reaches the window here. In the search field, the field
    /// empties itself.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
           search.isSearching {
            search.clear()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Escape in a text field in the results, such as Weather's city search.
    override func cancelOperation(_ sender: Any?) {
        if search.isSearching {
            search.clear()
        } else {
            super.cancelOperation(sender)
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.searchItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        itemIdentifier == Self.searchItemID ? searchItem : nil
    }
}
