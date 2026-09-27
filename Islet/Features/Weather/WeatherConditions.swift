import Foundation

/// The weather as a WMO weather interpretation code says it, the way Open-Meteo reports
/// it, with a symbol and a name for it by day and by night.
///
/// Codes Open-Meteo does not document show as cloud, the likeliest thing to be true.
struct WeatherCondition: Equatable, Sendable {
    let code: Int
    let isDay: Bool

    /// Every code Open-Meteo documents.
    static let knownCodes = [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 99]

    /// An SF Symbol, drawn in its own colours: a yellow sun, blue drops.
    var symbol: String {
        switch code {
        case 0, 1: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55: "cloud.drizzle.fill"
        case 56, 57, 66, 67: "cloud.sleet.fill"
        case 61, 63: "cloud.rain.fill"
        case 65, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95: "cloud.bolt.rain.fill"
        case 96, 99: "cloud.hail.fill"
        default: "cloud.fill"
        }
    }

    /// The name the iPhone's Weather would give it: "Sunny" by day, "Clear" by night.
    var name: String {
        switch code {
        case 0: isDay ? "Sunny" : "Clear"
        case 1: isDay ? "Mostly Sunny" : "Mostly Clear"
        case 2: "Partly Cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing Drizzle"
        case 61, 63: "Rain"
        case 65: "Heavy Rain"
        case 66, 67: "Freezing Rain"
        case 71, 73, 77: "Snow"
        case 75: "Heavy Snow"
        case 80, 81: "Showers"
        case 82: "Heavy Showers"
        case 85, 86: "Snow Showers"
        case 95: "Thunderstorms"
        case 96, 99: "Thunderstorms with Hail"
        default: "Cloudy"
        }
    }

    /// Whether something is falling: drizzle, rain, snow, showers or a thunderstorm.
    var isPrecipitation: Bool { (51...99).contains(code) }
}

/// Which scale temperatures are shown in.
enum WeatherScale: String, CaseIterable, Identifiable, Sendable {
    /// The Mac's own, from Temperature in Language & Region settings: Fahrenheit in the
    /// US, Celsius in most other places.
    case automatic
    case celsius
    case fahrenheit

    var id: String { rawValue }

    /// Whether temperatures come out in Fahrenheit on a Mac set up for `locale`.
    func isFahrenheit(locale: Locale = .autoupdatingCurrent) -> Bool {
        switch self {
        case .celsius: false
        case .fahrenheit: true
        case .automatic: UnitTemperature(forLocale: locale, usage: .weather).symbol == UnitTemperature.fahrenheit.symbol
        }
    }

    /// Whole degrees in this scale, from Celsius.
    func degrees(_ celsius: Double, locale: Locale = .autoupdatingCurrent) -> Int {
        guard celsius.isFinite else { return 0 }
        let value = isFahrenheit(locale: locale) ? celsius * 9 / 5 + 32 : celsius
        return Int(value.rounded())
    }

    /// "18°": the scale is said once, in Settings, as the iPhone's Weather does.
    func text(_ celsius: Double, locale: Locale = .autoupdatingCurrent) -> String {
        "\(degrees(celsius, locale: locale))°"
    }

    /// For Settings: "Automatic (°F)", "Celsius", "Fahrenheit".
    func title(locale: Locale = .autoupdatingCurrent) -> String {
        switch self {
        case .automatic: "Automatic (\(Self.automatic.isFahrenheit(locale: locale) ? "°F" : "°C"))"
        case .celsius: "Celsius"
        case .fahrenheit: "Fahrenheit"
        }
    }
}
