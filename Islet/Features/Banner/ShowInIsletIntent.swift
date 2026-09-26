import AppIntents
import Foundation

/// Show in Islet, the Shortcuts action: the banner `islet://banner` puts up, with its
/// parameters as fields to fill in rather than a URL to encode.
///
/// It runs inside Islet, in the background: Islet has no window to bring forward, and
/// a banner is no reason to take the keyboard from whatever has it. Shortcuts launches
/// Islet first if it is not running. What it is given is checked exactly as a URL's
/// parameters are, and goes through the same throttle.
struct ShowInIsletIntent: AppIntent {
    static let title: LocalizedStringResource = "Show in Islet"
    static let description = IntentDescription(
        "Puts up a banner in the island: beside the notch, or as a card below it.",
        categoryName: "Island"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Title", requestValueDialog: "What should the banner say?")
    var title: String

    @Parameter(title: "Subtitle")
    var subtitle: String?

    @Parameter(
        title: "Symbol",
        description: "The name of an SF Symbol, such as checkmark.circle.fill. A bell if left empty or not found.",
        inputOptions: String.IntentInputOptions(
            keyboardType: .asciiCapable, capitalizationType: .none, autocorrect: false, smartQuotes: false, smartDashes: false
        )
    )
    var symbol: String?

    @Parameter(title: "Colour", default: .white)
    var colour: BannerColour

    @Parameter(title: "Style", default: .compact)
    var style: BannerStyle

    @Parameter(
        title: "Duration",
        description: "Seconds, from 1 to 30. Four beside the notch and six for a card if left empty.",
        inclusiveRange: (1, 30)
    )
    var duration: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$title) in Islet") {
            \.$subtitle
            \.$symbol
            \.$colour
            \.$style
            \.$duration
        }
    }

    /// The feature the banner goes to. Tests hand in one of their own.
    @MainActor static var target: () -> BannerFeature? = { FeatureRegistry.shared.feature(BannerFeature.self) }

    /// The banner the fields describe, checked as a URL's parameters are. `nil` when the
    /// title is only white space.
    var banner: CustomBanner? {
        CustomBanner(title: title, subtitle: subtitle, symbol: symbol, tint: colour.tint, duration: duration, style: style)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let banner else { throw ShowInIsletError.noTitle }
        guard let feature = Self.target() else { throw ShowInIsletError.turnedOff }

        var outcome = feature.show(banner)
        // Launched to run this, Islet may not have started its features yet; one that is
        // turned on is given a moment to.
        let deadline = ContinuousClock.now + .seconds(2)
        while outcome == .off, Self.isTurnedOn(feature), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            outcome = feature.show(banner)
        }
        if outcome == .off { throw ShowInIsletError.turnedOff }
        return .result()
    }

    /// Whether Settings has the feature on, read straight from the defaults with the
    /// feature's own default for an unset key, since while Islet is starting that default
    /// may not be registered yet.
    @MainActor
    private static func isTurnedOn(_ feature: BannerFeature) -> Bool {
        UserDefaults.standard.object(forKey: Prefs.Key.featureEnabled(feature.id)) as? Bool ?? feature.enabledByDefault
    }
}

/// Why Show in Islet did not show a banner, in words Shortcuts shows the person.
enum ShowInIsletError: Error, CustomLocalizedStringResourceConvertible {
    case noTitle
    case turnedOff

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noTitle: "The banner needs a title."
        case .turnedOff: "Show in Islet is turned off in Islet's Settings."
        }
    }
}

extension BannerColour: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Colour"
    static let caseDisplayRepresentations: [BannerColour: DisplayRepresentation] = [
        .white: "White",
        .red: "Red",
        .orange: "Orange",
        .yellow: "Yellow",
        .green: "Green",
        .mint: "Mint",
        .teal: "Teal",
        .cyan: "Cyan",
        .blue: "Blue",
        .indigo: "Indigo",
        .purple: "Purple",
        .pink: "Pink",
        .brown: "Brown",
        .gray: "Grey",
    ]
}

extension BannerStyle: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [BannerStyle: DisplayRepresentation] = [
        .compact: "Beside the Notch",
        .card: "Card",
    ]
}
