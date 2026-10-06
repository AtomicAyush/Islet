import SwiftUI

/// What a feature's symbols, rings, progress, highlights and selected states are drawn
/// in while Appearance › Accent is "Feature colours". Under any other accent they take
/// that accent instead.
///
/// A feature declares its own tint once, in its own folder, as tuned for the black
/// island:
///
///     extension FeatureTint {
///         static let timer = FeatureTint.colour(RGB(1.0, 0.62, 0.04))
///     }
///
/// and draws with `.islandAccent(.timer)`. A feature whose highlights are white today
/// declares `.neutral`.
///
/// A colour that says something rather than highlighting (a phase, a mode, a state)
/// must not take the accent. One of the system's meaningful colours is named once, in
/// the feature's folder, as a `SystemHue` (`static let presentation = SystemHue.teal`)
/// and drawn with `.islandHue(_:)`; if an accent could be taken for it beside the notch,
/// it goes in `SystemHue.guarded` too. A colour of the feature's own that must stay put
/// is drawn with `.islandFitted(_:)`. A level that is fine takes
/// `IslandTheme.restingLevel(_:)`, so an accent near a low battery's red never looks like
/// one; a button filled with the feature's colour takes `IslandTheme.filledButton(_:)`
/// for its fill and its word.
enum FeatureTint: Hashable, Sendable {
    /// The island's ink: white on the black island, black on a light one.
    case neutral
    /// A colour of the feature's own.
    case colour(RGB)
}

extension FeatureTint {
    /// The shell's own highlights (tabs, page dots, the home page): the island's ink.
    static let shell = FeatureTint.neutral
}

extension IslandTheme {
    /// A level that is fine, as a headset's or a mouse's battery ring shows it: the
    /// feature's own colour, or the accent standing in for it, unless that could be taken
    /// for a low battery's red or a warning's orange, when it is the island's ink.
    /// With `minimum: Contrast.text` it is the level's words.
    func restingLevel(_ tint: FeatureTint, minimum: Double = Contrast.graphic, on backdrop: IslandBackdrop = .island) -> IslandInk {
        let source = accentSource(tint)
        if [SystemHue.lowBattery, .warning].contains(where: { source.couldBeTaken(for: $0.dark) }) {
            return minimum == Contrast.text ? .text(1, on: backdrop) : .graphic(1, on: backdrop)
        }
        return .accent(tint, minimum: minimum, on: backdrop)
    }

    /// A button filled with a feature's colour, or the accent in its place, and its word
    /// (`filledMark(_:)`).
    func filledButton(_ tint: FeatureTint) -> (fill: Color, label: Color) {
        filledMark(accentSource(tint))
    }

    /// A mark filled with `colour` and a word or symbol on it: the colour, fitted to the
    /// island, and the label in black or white, whichever reads on it (the fill moving
    /// away from the label if neither does). The default theme keeps the colour as it is
    /// and the label white, as the island always drew them, but on the ink itself (a
    /// feature without a colour of its own), where the label is black.
    func filledMark(_ colour: RGB) -> (fill: Color, label: Color) {
        if isDefault { return (colour.color, colour == ink ? .black : inkColor) }
        let pair = onFill(fitted(colour))
        return (pair.fill.color, pair.label.color)
    }
}
