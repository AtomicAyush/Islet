import Foundation

/// Rain, or snow: what the warning and the tile call it.
enum WeatherFall: String, Codable, Sendable {
    case rain
    case snow

    var word: String { self == .snow ? "Snow" : "Rain" }
    var symbol: String { self == .snow ? "cloud.snow.fill" : "cloud.rain.fill" }
}

/// What the forecast says about rain from a given moment.
enum WeatherRainOutlook: Equatable, Sendable {
    /// The forecast does not reach this moment, so it cannot say.
    case unknown
    /// Nothing falling, and nothing in the forecast ahead.
    case dry
    /// Falling now.
    case falling(WeatherFall)
    /// Dry now, and due to start at `start`.
    case starting(at: Date, WeatherFall)
}

extension WeatherForecast {
    /// The least a step must bring to count: a tenth of a millimetre, the least
    /// Open-Meteo reports.
    static let wetAmount = 0.1
    /// How long the reading now counts as now: two quarter-hours.
    static let currentLifetime: TimeInterval = 30 * 60

    /// The steps from `date` on, soonest first: the quarter-hours while they last, then
    /// the hours after them. Where an hour overlaps the last quarter-hour, only its part
    /// past that counts, since the quarter-hours say more exactly what happens before.
    /// Without a quarter-hour that `date` falls in (none given, or none left), the
    /// hours alone.
    func steps(from date: Date) -> [WeatherStep] {
        let quarters = quarterHours.filter { $0.end > date }
        guard let first = quarters.first, first.start <= date, let covered = quarters.last?.end else {
            return hours.filter { $0.end > date }
        }
        let later = hours.filter { $0.end > covered }.map { step in
            var step = step
            step.start = max(step.start, covered)
            return step
        }
        return quarters + later
    }

    /// Whether rain (or snow) is falling at `date`, due, or neither. It counts as
    /// falling when the step `date` falls in brings any, or the reading now, while it
    /// is recent, says something fell in the last quarter-hour or is falling.
    func rainOutlook(at date: Date) -> WeatherRainOutlook {
        let isRecent = date.timeIntervalSince(current.time) < Self.currentLifetime && date >= current.time.addingTimeInterval(-60)
        if isRecent, current.precipitation >= Self.wetAmount || current.condition.isPrecipitation {
            return .falling(current.condition.isSnow ? .snow : .rain)
        }
        let ahead = steps(from: date)
        guard let now = ahead.first, now.start <= date else { return .unknown }
        if now.isWet { return .falling(now.fall) }
        guard let next = ahead.first(where: \.isWet) else { return .dry }
        return .starting(at: next.start, next.fall)
    }
}

extension WeatherStep {
    var isWet: Bool { precipitation >= WeatherForecast.wetAmount }

    /// Snow when most of what falls is snow. Open-Meteo counts seven centimetres of
    /// snow as ten millimetres of water.
    var fall: WeatherFall {
        snowfall * 10 / 7 >= precipitation / 2 && snowfall > 0 ? .snow : .rain
    }
}

extension WeatherCondition {
    var isSnow: Bool { [71, 73, 75, 77, 85, 86].contains(code) }
}

/// A warning that rain is about to start.
struct WeatherRainAlert: Equatable, Sendable {
    var start: Date
    var fall: WeatherFall
    /// When it was seen coming, which the minutes to go are counted from.
    var seen: Date
}

/// Decides when rain is worth a warning: once for each spell, as it is about to start,
/// and never while it is falling.
///
/// A spell is rain with no dry gap of `spellGap` or more in it. Rain due within `lead`
/// warns if it starts a new spell; rain the forecast puts off a little, or rain coming
/// back after a short lull, is the same spell, and warns no more. Rain already falling
/// when it is first seen starts a spell too, unwarned, so a lull in it warns of
/// nothing. The watch is kept between launches, so starting Islet again says nothing
/// twice.
struct WeatherRainWatch: Codable, Equatable, Sendable {
    /// How far ahead rain is warned of.
    static let lead: TimeInterval = 30 * 60
    /// How long it must stay dry before rain counts as a new spell.
    static let spellGap: TimeInterval = 30 * 60

    /// The latest moment the spell was due or seen falling; `nil` between spells.
    private(set) var spell: Date?

    /// Takes in the outlook at `date`. Returns the rain to warn of, if this is the time.
    mutating func update(_ outlook: WeatherRainOutlook, at date: Date) -> WeatherRainAlert? {
        switch outlook {
        case .falling:
            spell = max(spell ?? date, date)
            return nil
        case .starting(let start, let fall) where start.timeIntervalSince(date) <= Self.lead:
            if let spell, start.timeIntervalSince(spell) < Self.spellGap {
                self.spell = max(spell, start)
                return nil
            }
            spell = start
            return WeatherRainAlert(start: start, fall: fall, seen: date)
        case .starting, .dry:
            if let spell, date.timeIntervalSince(spell) >= Self.spellGap { self.spell = nil }
            return nil
        case .unknown:
            return nil
        }
    }
}

/// The words for rain on the way, as the banner and the tile say them.
enum WeatherRainWords {
    /// Minutes until `start`, to the nearest five and never less than five: the
    /// forecast is only as exact as its quarter-hours.
    static func minutes(until start: Date, from date: Date) -> Int {
        let minutes = start.timeIntervalSince(date) / 60
        return max(5, Int((minutes / 5).rounded()) * 5)
    }

    /// "in about 10 min"
    static func soon(until start: Date, from date: Date) -> String {
        soon(minutes(until: start, from: date))
    }

    static func soon(_ minutes: Int) -> String { "in about \(minutes) min" }

    /// "in 10 min", where "about" leaves too little room.
    static func soonShort(_ minutes: Int) -> String { "in \(minutes) min" }

    /// For the tile, longest first, for as much as fits: "Rain in about 20 min" then
    /// "Rain in 20 min" within the hour, "Rain around 3 PM" then "Rain at 3 PM" after
    /// it. Nothing past the forecast's half day.
    static func tile(_ fall: WeatherFall, start: Date, from date: Date) -> [String] {
        let wait = start.timeIntervalSince(date)
        if wait < 60 * 60 {
            let minutes = minutes(until: start, from: date)
            return ["\(fall.word) \(soon(minutes))", "\(fall.word) \(soonShort(minutes))"]
        }
        let time = clockTime(start)
        return ["\(fall.word) around \(time)", "\(fall.word) at \(time)"]
    }

    /// "3 PM" on the hour and "3:15 PM" otherwise, or "15:00" and "15:15" where the
    /// clock runs to 24: an hour alone would read "15", or "15 Uhr".
    static func clockTime(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        if pattern.contains("a"), Calendar.current.component(.minute, from: date) == 0 {
            return date.formatted(Date.FormatStyle(locale: locale).hour())
        }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
    }
}
