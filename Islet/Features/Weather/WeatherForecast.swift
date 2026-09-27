import Foundation

/// A place to show the weather for: a city picked in Settings, or where this Mac was
/// last found to be.
///
/// Its coordinates are rounded to two decimal places, about a kilometre, as soon as they
/// are known. That is all a forecast needs, and all that is ever kept or sent.
struct WeatherPlace: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        /// Picked from a search in Settings.
        case search
        /// Where this Mac is.
        case thisMac
    }

    /// What this Mac's location is called on the tile. It is never looked up by name:
    /// that would send the coordinates somewhere else too.
    static let thisMacName = "My Location"

    var name: String
    /// Where the name is, to tell one Springfield from another: "Illinois, United
    /// States". `nil` for this Mac.
    var detail: String?
    private(set) var latitude: Double
    private(set) var longitude: Double
    var source: Source
    /// When this Mac's location was found; `nil` for a place picked from a search.
    var located: Date?

    init(
        name: String, detail: String? = nil, latitude: Double, longitude: Double,
        source: Source = .search, located: Date? = nil
    ) {
        self.name = name
        self.detail = detail
        self.latitude = Self.rounded(latitude)
        self.longitude = Self.rounded(longitude)
        self.source = source
        self.located = located
    }

    /// This Mac's location, found at `date`.
    static func thisMac(latitude: Double, longitude: Double, at date: Date) -> WeatherPlace {
        WeatherPlace(name: thisMacName, latitude: latitude, longitude: longitude, source: .thisMac, located: date)
    }

    static func rounded(_ degrees: Double) -> Double {
        (degrees * 100).rounded() / 100
    }

    /// The coordinates as they are sent: "41.88", "-87.63".
    var query: (latitude: String, longitude: String) {
        (String(format: "%.2f", latitude), String(format: "%.2f", longitude))
    }

    /// Within about five kilometres: close enough for the same forecast.
    func isNear(_ other: WeatherPlace) -> Bool {
        abs(other.latitude - latitude) < 0.05 && abs(other.longitude - longitude) < 0.05
    }

    /// Whether `forecast` was asked for at this place.
    func matches(_ forecast: WeatherForecast) -> Bool {
        abs(forecast.latitude - latitude) < 0.001 && abs(forecast.longitude - longitude) < 0.001
    }
}

/// What Open-Meteo said about a place, as it is kept: the weather now, the day's high
/// and low, and how much will fall in each step ahead. Temperatures stay in Celsius, as
/// they came, and are converted only to be shown.
struct WeatherForecast: Codable, Equatable, Sendable {
    /// When it was fetched.
    var fetched: Date
    /// The coordinates it was asked for, as sent.
    var latitude: Double
    var longitude: Double
    var current: WeatherNow
    /// Today first, where the place is.
    var days: [WeatherDay]
    /// Quarter-hours ahead, soonest first: fine enough to say when rain will start.
    var quarterHours: [WeatherStep]
    /// Hours ahead, for where the quarter-hours run out, or were not given.
    var hours: [WeatherStep]

    /// The day `date` falls in, else the latest one before it: a forecast kept from
    /// yesterday still has something to say, though its age says how much.
    func day(at date: Date) -> WeatherDay? {
        days.last { $0.start <= date } ?? days.first
    }
}

struct WeatherNow: Codable, Equatable, Sendable {
    /// When the reading is for: the start of the quarter-hour it was fetched in.
    var time: Date
    /// Degrees Celsius.
    var temperature: Double
    /// The WMO weather interpretation code (`WeatherCondition`).
    var code: Int
    var isDay: Bool
    /// Millimetres in the quarter-hour before `time`.
    var precipitation: Double

    var condition: WeatherCondition { WeatherCondition(code: code, isDay: isDay) }
}

struct WeatherDay: Codable, Equatable, Sendable {
    /// Midnight where the place is.
    var start: Date
    /// Degrees Celsius.
    var high: Double
    var low: Double
}

/// How much falls in one step of the forecast. Open-Meteo gives each step's total
/// against the time the step ends.
struct WeatherStep: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
    /// Millimetres of water: rain, and snow as it would be melted.
    var precipitation: Double
    /// Centimetres of snow.
    var snowfall: Double
}

/// Why there is no new forecast, or no search results. None of these is kept: the next
/// attempt tries again.
enum WeatherFailure: Error, Equatable, Sendable {
    /// No connection, or Open-Meteo's address could not be found.
    case offline
    /// Open-Meteo took too long to answer.
    case timedOut
    /// Open-Meteo asked for a moment (it answers 429 when too many requests come).
    case busy
    /// Any other answer that was not a forecast.
    case server(Int)
    /// An answer that could not be read.
    case unreadable
    /// This Mac's location could not be found.
    case noLocation

    /// What the tile and Settings say about it.
    var message: String {
        switch self {
        case .offline: "Can’t reach Open-Meteo"
        case .timedOut: "Open-Meteo took too long"
        case .busy: "Open-Meteo is busy"
        case .server(let status): "Open-Meteo couldn’t answer (\(status))"
        case .unreadable: "The forecast couldn’t be read"
        case .noLocation: "Can’t find this Mac’s location"
        }
    }
}

// MARK: - Open-Meteo

/// Carries a GET request and brings back the body and the HTTP status. Only a test
/// replaces it.
protocol WeatherTransport: Sendable {
    func get(_ url: URL) async throws -> (data: Data, status: Int)
}

/// Open-Meteo (open-meteo.com): forecasts and place names, free, with no key and no
/// account.
///
/// A forecast is asked for by the place's coordinates, rounded to two decimals, and
/// nothing else; a search sends only the words typed into it, and the language to
/// answer in. Temperatures come in Celsius whatever Islet shows, so a change of scale
/// needs no new forecast.
struct OpenMeteo: Sendable {
    static let forecastBase = URL(string: "https://api.open-meteo.com/v1/forecast")!
    static let searchBase = URL(string: "https://geocoding-api.open-meteo.com/v1/search")!
    /// Two hours of quarter-hours: enough to see rain coming, from the quarter-hour
    /// now is in.
    static let quarterHoursAhead = 9
    /// Half a day of hours, for the tile's next rain once the quarter-hours run out.
    static let hoursAhead = 12
    /// The most places a search lists.
    static let searchLimit = 6

    var transport: any WeatherTransport = OpenMeteoSession()

    /// The forecast for `place`, stamped as fetched at `date`.
    func forecast(for place: WeatherPlace, at date: Date) async throws -> WeatherForecast {
        let (data, status) = try await get(Self.forecastURL(for: place))
        guard status == 200 else { throw Self.failure(status) }
        return try Self.forecast(from: data, for: place, fetched: date)
    }

    /// Places whose names start with `text`, most populous first, named in `language`.
    func search(_ text: String, language: String) async throws -> [WeatherPlace] {
        let (data, status) = try await get(Self.searchURL(for: text, language: language))
        guard status == 200 else { throw Self.failure(status) }
        return try Self.places(from: data)
    }

    static func forecastURL(for place: WeatherPlace) -> URL {
        let query = place.query
        var components = URLComponents(url: forecastBase, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: query.latitude),
            URLQueryItem(name: "longitude", value: query.longitude),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,precipitation"),
            URLQueryItem(name: "minutely_15", value: "precipitation,snowfall"),
            URLQueryItem(name: "hourly", value: "precipitation,snowfall"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_minutely_15", value: String(quarterHoursAhead)),
            URLQueryItem(name: "forecast_hours", value: String(hoursAhead)),
            URLQueryItem(name: "forecast_days", value: "2"),
            // Days start at the place's midnight, so "today" is the place's own.
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        return components.url!
    }

    static func searchURL(for text: String, language: String) -> URL {
        var components = URLComponents(url: searchBase, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "name", value: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "count", value: String(searchLimit)),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components.url!
    }

    /// Reads the forecast asked for at `place`. It is kept under the coordinates asked
    /// for, not the nearby point of Open-Meteo's grid it answers for. A step or a day
    /// with a missing value is left out; without the temperature and conditions now
    /// there is nothing to show, so that is unreadable.
    static func forecast(from data: Data, for place: WeatherPlace, fetched: Date) throws -> WeatherForecast {
        guard let response = try? JSONDecoder().decode(ForecastResponse.self, from: data),
              let current = response.current,
              let temperature = current.temperature, temperature.isFinite,
              let code = current.code
        else { throw WeatherFailure.unreadable }

        let days: [WeatherDay] = response.daily.map { daily in
            daily.time.indices.compactMap { index in
                guard let high = daily.high.value(at: index), let low = daily.low.value(at: index) else { return nil }
                return WeatherDay(start: Date(timeIntervalSince1970: daily.time[index]), high: high, low: low)
            }
        } ?? []

        return WeatherForecast(
            fetched: fetched,
            latitude: place.latitude,
            longitude: place.longitude,
            current: WeatherNow(
                time: Date(timeIntervalSince1970: current.time),
                temperature: temperature,
                code: code,
                isDay: (current.isDay ?? 1) != 0,
                precipitation: current.precipitation ?? 0
            ),
            days: days,
            quarterHours: steps(response.minutely15, length: 15 * 60),
            hours: steps(response.hourly, length: 60 * 60)
        )
    }

    /// Reads a search's places. Open-Meteo leaves `results` out when nothing matches.
    static func places(from data: Data) throws -> [WeatherPlace] {
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            throw WeatherFailure.unreadable
        }
        return (response.results ?? []).compactMap { result in
            guard let name = result.name, !name.isEmpty,
                  let latitude = result.latitude, let longitude = result.longitude,
                  (-90...90).contains(latitude), (-180...180).contains(longitude)
            else { return nil }
            // "Illinois, United States"; a region named like its city is not repeated.
            let parts = [result.admin1, result.country].compactMap { $0 }.filter { !$0.isEmpty && $0 != name }
            return WeatherPlace(
                name: name, detail: parts.isEmpty ? nil : parts.joined(separator: ", "),
                latitude: latitude, longitude: longitude
            )
        }
    }

    private static func steps(_ series: ForecastResponse.Series?, length: TimeInterval) -> [WeatherStep] {
        guard let series else { return [] }
        return series.time.indices.compactMap { index in
            guard let amount = series.precipitation.value(at: index), amount >= 0 else { return nil }
            let end = Date(timeIntervalSince1970: series.time[index])
            let snow = series.snowfall.value(at: index) ?? 0
            return WeatherStep(start: end.addingTimeInterval(-length), end: end, precipitation: amount, snowfall: max(0, snow))
        }
    }

    private func get(_ url: URL) async throws -> (data: Data, status: Int) {
        do {
            return try await transport.get(url)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? WeatherFailure.timedOut : WeatherFailure.offline
        }
    }

    private static func failure(_ status: Int) -> WeatherFailure {
        status == 429 || status == 503 ? .busy : .server(status)
    }

    // MARK: Answers

    /// A forecast as Open-Meteo sends it with `timeformat=unixtime`. Any value may be
    /// null; the lists run side by side with their `time`.
    struct ForecastResponse: Decodable {
        struct Current: Decodable {
            var time: TimeInterval
            var temperature: Double?
            var code: Int?
            var isDay: Int?
            var precipitation: Double?

            enum CodingKeys: String, CodingKey {
                case time
                case temperature = "temperature_2m"
                case code = "weather_code"
                case isDay = "is_day"
                case precipitation
            }
        }

        struct Series: Decodable {
            var time: [TimeInterval]
            var precipitation: [Double?]?
            var snowfall: [Double?]?
        }

        struct Daily: Decodable {
            var time: [TimeInterval]
            var high: [Double?]?
            var low: [Double?]?

            enum CodingKeys: String, CodingKey {
                case time
                case high = "temperature_2m_max"
                case low = "temperature_2m_min"
            }
        }

        var current: Current?
        var minutely15: Series?
        var hourly: Series?
        var daily: Daily?

        enum CodingKeys: String, CodingKey {
            case current, hourly, daily
            case minutely15 = "minutely_15"
        }
    }

    struct SearchResponse: Decodable {
        struct Result: Decodable {
            var name: String?
            var latitude: Double?
            var longitude: Double?
            var country: String?
            var admin1: String?
        }

        var results: [Result]?
    }
}

private extension Optional where Wrapped == [Double?] {
    /// The finite value at `index`, if there is one.
    func value(at index: Int) -> Double? {
        guard let values = self, values.indices.contains(index), let value = values[index], value.isFinite else { return nil }
        return value
    }
}

/// The real transport: a session of its own with no cookies and no cache, and short
/// timeouts, so a forecast that is not coming gives up and tries again later rather
/// than hang on.
struct OpenMeteoSession: WeatherTransport {
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Islet \(version) (https://github.com/AtomicAyush/Islet)"
    }()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
