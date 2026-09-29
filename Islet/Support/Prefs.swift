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

/// How the home page lays out tiles that do not fit side by side.
enum HomeLayout: String, CaseIterable, Identifiable {
    /// One row that scrolls sideways.
    case scroll
    /// Whole pages of tiles, turned with dots or a sideways swipe.
    case pages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scroll: "Scroll sideways"
        case .pages: "Pages"
        }
    }
}

/// Which sides of the island further activities' bubbles go on.
enum BubblePlacement: String, CaseIterable, Identifiable {
    /// Right of the island, then left, then right again, in order, each side taking as
    /// many as it has room for.
    case bothSides
    /// Right of the island only.
    case rightOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bothSides: "Both sides"
        case .rightOnly: "Right side only"
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
        static let homeLayout = "homeLayout"
        static let bubblePlacement = "bubblePlacement"
        /// The home page's tiles in the person's order (`HomeTileOrder.placed`).
        static let homeTileOrder = "homeTileOrder"
        /// The home page's tiles the person hid.
        static let hiddenHomeTiles = "hiddenHomeTiles"
        /// Live activities in the person's order for the island (`IslandArrangement`).
        static let islandOrder = "islandOrder"
        static let haptics = "haptics"
        static let displays = "displays"
        static let hideInFullScreen = "hideInFullScreen"
        static let openFromNotchInFullScreen = "openFromNotchInFullScreen"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let idlePillOnPlainDisplays = "idlePillOnPlainDisplays"
        /// The island's colour as "#RRGGBB".
        static let islandColour = "islandColour"
        /// Appearance › Accent: "feature", "mono" or "#RRGGBB".
        static let accentColour = "accentColour"
        /// Appearance › Fill (`IslandFill`).
        static let islandFill = "islandFill"
        /// Appearance › Ring (`IslandRing`): "off" or the ring.
        static let islandRing = "islandRing"
        /// Appearance › Motion: colours hold still while the screen is shared or recorded.
        static let holdMotionWhenCaptured = "holdMotionWhenCaptured"

        static func featureEnabled(_ id: String) -> String { "feature.\(id).enabled" }
    }

    @MainActor
    static func register(features: [any Feature]) {
        var defaults: [String: Any] = [
            Key.expandOnHover: true,
            Key.hoverDelay: 0.25,
            Key.homeLayout: HomeLayout.scroll.rawValue,
            Key.bubblePlacement: BubblePlacement.bothSides.rawValue,
            Key.haptics: true,
            Key.displays: DisplayChoice.notched.rawValue,
            Key.hideInFullScreen: true,
            Key.openFromNotchInFullScreen: true,
            Key.showMenuBarIcon: true,
            Key.idlePillOnPlainDisplays: false,
            Key.islandColour: IslandTheme.standardIslandPref,
            Key.accentColour: IslandTheme.standardAccentPref,
            Key.islandFill: IslandFill.standardPref,
            Key.islandRing: IslandRing.offPref,
            Key.holdMotionWhenCaptured: true,
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
    /// Whether the island, hidden for a full-screen app, still opens from the notch
    /// (on a display without one, from the middle of the top edge).
    static var openFromNotchInFullScreen: Bool { store.bool(forKey: Key.openFromNotchInFullScreen) }
    static var showMenuBarIcon: Bool { store.bool(forKey: Key.showMenuBarIcon) }
    static var idlePillOnPlainDisplays: Bool { store.bool(forKey: Key.idlePillOnPlainDisplays) }

    static var homeLayout: HomeLayout {
        HomeLayout(rawValue: store.string(forKey: Key.homeLayout) ?? "") ?? .scroll
    }

    static var bubblePlacement: BubblePlacement {
        BubblePlacement(rawValue: store.string(forKey: Key.bubblePlacement) ?? "") ?? .bothSides
    }

    /// The island's colours, for AppKit code outside a SwiftUI body. Views read
    /// `\.islandTheme` from the environment instead.
    static var islandTheme: IslandTheme {
        IslandTheme.cached(
            islandPref: store.string(forKey: Key.islandColour) ?? IslandTheme.standardIslandPref,
            accentPref: store.string(forKey: Key.accentColour) ?? IslandTheme.standardAccentPref,
            fillPref: store.string(forKey: Key.islandFill) ?? IslandFill.standardPref
        )
    }

    static var displays: DisplayChoice {
        DisplayChoice(rawValue: store.string(forKey: Key.displays) ?? "") ?? .notched
    }

    @MainActor
    static func isEnabled(_ feature: any Feature) -> Bool {
        store.bool(forKey: Key.featureEnabled(feature.id))
    }
}
