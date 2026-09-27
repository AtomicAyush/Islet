import Foundation

/// Made-up places and forecasts for the previews, laid out around the current time the
/// way Open-Meteo lays out a real one.
enum WeatherSamples {
    static let place = WeatherPlace(name: "Maple Bay", detail: "Nowhere in Particular", latitude: 45.12, longitude: -75.34)

    /// A forecast fetched at `date`, with rain (or snow) from the first step that starts
    /// `rainIn` or more after then, if at all, falling for an hour.
    static func forecast(
        code: Int, isDay: Bool = true, temperature: Double, high: Double, low: Double,
        rainIn: TimeInterval? = nil, fall: WeatherFall = .rain, at date: Date = Date()
    ) -> WeatherForecast {
        let quarter: TimeInterval = 15 * 60
        let hour: TimeInterval = 60 * 60
        let thisQuarter = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / quarter).rounded(.down) * quarter)
        let thisHour = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / hour).rounded(.down) * hour)
        let rainStart = rainIn.map { date.addingTimeInterval($0) }

        func step(ending end: Date, length: TimeInterval) -> WeatherStep {
            let start = end.addingTimeInterval(-length)
            let isWet = rainStart.map { start >= $0 && start < $0.addingTimeInterval(hour) } ?? false
            let amount = isWet ? 0.6 * length / quarter : 0
            return WeatherStep(start: start, end: end, precipitation: amount, snowfall: fall == .snow ? amount * 0.7 : 0)
        }

        return WeatherForecast(
            fetched: date,
            latitude: place.latitude,
            longitude: place.longitude,
            current: WeatherNow(time: thisQuarter, temperature: temperature, code: code, isDay: isDay, precipitation: 0),
            days: [WeatherDay(start: Calendar.current.startOfDay(for: date), high: high, low: low)],
            quarterHours: (0..<OpenMeteo.quarterHoursAhead).map {
                step(ending: thisQuarter.addingTimeInterval(Double($0) * quarter), length: quarter)
            },
            hours: (0..<OpenMeteo.hoursAhead).map {
                step(ending: thisHour.addingTimeInterval(Double($0) * hour), length: hour)
            }
        )
    }

    static func sunny() -> (place: WeatherPlace, forecast: WeatherForecast) {
        (place, forecast(code: 1, temperature: 23.4, high: 26.1, low: 14.8))
    }

    /// Cloud now, and rain in ten minutes or so.
    static func rainSoon() -> (place: WeatherPlace, forecast: WeatherForecast) {
        (place, forecast(code: 3, temperature: 16.2, high: 18.9, low: 11.3, rainIn: 10 * 60))
    }
}
