import Foundation

/// Made-up menu bar icons for previews and renders: apps that do not exist, drawn as
/// symbols on coloured squares, among the system's own items. None is anyone's, and
/// clicking one opens nothing.
enum HiddenMenuBarIconsSamples {
    /// A few icons out of sight, as a MacBook with a long menu in front might have,
    /// and the system's own in sight after them.
    static var few: [HiddenMenuBarIcon] {
        HiddenMenuBarIcons.ordered([
            app("Tea Timer", symbol: "cup.and.saucer.fill", hue: 0.07, placement: .noRoom),
            app("Crate Sync", symbol: "tray.full.fill", hue: 0.58, placement: .noRoom),
            app("Paper Boat", symbol: "paperplane.fill", hue: 0.53, placement: .underNotch, x: 680),
            app("Clip Jar", symbol: "scissors", hue: 0.33, placement: .underNotch, x: 712),
            system("Bluetooth", symbol: "dot.radiowaves.left.and.right", placement: .underNotch, x: 744),
        ] + inSight)
    }

    /// More than the tile has room for, so its last cell counts the rest.
    static var many: [HiddenMenuBarIcon] {
        HiddenMenuBarIcons.ordered([
            app("Tea Timer", symbol: "cup.and.saucer.fill", hue: 0.07, placement: .noRoom),
            app("Crate Sync", symbol: "tray.full.fill", hue: 0.58, placement: .noRoom),
            app("Fan Speed", symbol: "thermometer.medium", hue: 0.0, placement: .noRoom),
            app("Nightlight", symbol: "lightbulb.fill", hue: 0.13, placement: .noRoom),
            app("Leaf Notes", symbol: "leaf.fill", hue: 0.36, placement: .noRoom),
            app("Paper Boat", symbol: "paperplane.fill", hue: 0.53, placement: .underNotch, x: 670),
            app("Clip Jar", symbol: "scissors", hue: 0.33, placement: .underNotch, x: 700),
            system("Bluetooth", symbol: "dot.radiowaves.left.and.right", placement: .underNotch, x: 730),
            system("Focus", symbol: "moon.fill", placement: .underNotch, x: 760),
        ] + inSight)
    }

    /// An icon for the banner that says one would not open.
    static var refusing: HiddenMenuBarIcon { few[1] }

    private static var inSight: [HiddenMenuBarIcon] {
        [
            system("Wi-Fi", symbol: "wifi", placement: .shown, x: 1264),
            system("Battery", symbol: "battery.75percent", placement: .shown, x: 1296),
            system("Control Center", symbol: "switch.2", placement: .shown, x: 1330),
            system("Clock", symbol: "clock", placement: .shown, x: 1360),
        ]
    }

    private static func app(
        _ name: String, symbol: String, hue: Double, placement: HiddenMenuBarIcon.Placement, x: CGFloat? = nil
    ) -> HiddenMenuBarIcon {
        HiddenMenuBarIcon(
            id: "sample." + name, name: name, detail: nil,
            glyph: .sample(symbol: symbol, hue: hue), placement: placement, x: x
        )
    }

    private static func system(
        _ name: String, symbol: String, placement: HiddenMenuBarIcon.Placement, x: CGFloat
    ) -> HiddenMenuBarIcon {
        HiddenMenuBarIcon(
            id: "sample." + name, name: name, detail: nil,
            glyph: .symbol(symbol), placement: placement, x: x
        )
    }
}
