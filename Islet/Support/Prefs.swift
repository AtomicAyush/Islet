import Foundation

/// Where the island is drawn when more than one display is attached.
enum DisplayChoice: String, CaseIterable, Identifiable {
    /// The display with a camera notch, or the main display when none has one.
    case notched
    /// Whichever display currently holds the menu bar.
    case main
    /// Every display.
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notched: "Notched display"
        case .main: "Main display"
        case .all: "All displays"
        }
    }
}

/// UserDefaults keys and their defaults. Views bind to these with `@AppStorage`;
/// everything else reads them through the accessors below so there is one spelling
/// of each key.
enum Prefs {
    enum Key {
        static let expandOnHover = "expandOnHover"
        static let hoverDelay = "hoverDelay"
        static let haptics = "haptics"
        static let displays = "displays"
        static let hideInFullScreen = "hideInFullScreen"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let idlePillOnPlainDisplays = "idlePillOnPlainDisplays"

        static func featureEnabled(_ id: String) -> String { "feature.\(id).enabled" }
    }

    @MainActor
    static func register(features: [any Feature]) {
        var defaults: [String: Any] = [
            Key.expandOnHover: true,
            Key.hoverDelay: 0.25,
            Key.haptics: true,
            Key.displays: DisplayChoice.notched.rawValue,
            Key.hideInFullScreen: true,
            Key.showMenuBarIcon: true,
            Key.idlePillOnPlainDisplays: false,
        ]
        for feature in features {
            defaults[Key.featureEnabled(feature.id)] = feature.enabledByDefault
        }
        UserDefaults.standard.register(defaults: defaults)
    }

    private static var store: UserDefaults { .standard }

    static var expandOnHover: Bool { store.bool(forKey: Key.expandOnHover) }
    static var hoverDelay: TimeInterval { store.double(forKey: Key.hoverDelay) }
    static var haptics: Bool { store.bool(forKey: Key.haptics) }
    static var hideInFullScreen: Bool { store.bool(forKey: Key.hideInFullScreen) }
    static var showMenuBarIcon: Bool { store.bool(forKey: Key.showMenuBarIcon) }
    static var idlePillOnPlainDisplays: Bool { store.bool(forKey: Key.idlePillOnPlainDisplays) }

    static var displays: DisplayChoice {
        DisplayChoice(rawValue: store.string(forKey: Key.displays) ?? "") ?? .notched
    }

    @MainActor
    static func isEnabled(_ feature: any Feature) -> Bool {
        store.bool(forKey: Key.featureEnabled(feature.id))
    }
}
