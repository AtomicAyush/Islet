import AppKit
import Network
import Observation

/// The place, its forecast, and when to fetch the next one.
///
/// Nothing is fetched until there is a place: a city picked in Settings, or this Mac's
/// location once the person has turned that on and macOS has allowed it. With one, the
/// forecast is fetched as the feature starts (unless the one kept from last time is
/// still fresh), then every fifteen minutes while the Mac is awake, a few seconds after
/// it wakes, and when the network comes back after a fetch failed for want of it. A
/// failure tries again after a minute, then two, four and so on up to an hour, and the
/// last good forecast stays up meanwhile, with its age once it is old. While the
/// feature is off, nothing runs at all.
///
/// This Mac's location is found once when the person turns it on, and again before a
/// fetch once the last reading is an hour old, for a Mac that has moved; a reading that
/// fails leaves the last one in use, and is not tried again for another hour.
@MainActor
@Observable
final class WeatherModel {
    /// The city picked in Settings.
    private(set) var pickedPlace: WeatherPlace?
    /// Where this Mac was last found.
    private(set) var macPlace: WeatherPlace?
    /// Whether the forecast is for this Mac's location rather than the picked city.
    private(set) var usesThisMac = false
    private(set) var locationAccess = WeatherLocationAccess.undetermined
    private(set) var isLocating = false
    /// The latest forecast for the place, fetched now or kept from before.
    private(set) var forecast: WeatherForecast?
    private(set) var isFetching = false
    /// Why the last attempt failed, until one succeeds.
    private(set) var failure: WeatherFailure?
    /// Stand-ins shown by previews in place of the real place and forecast.
    private(set) var sample: (place: WeatherPlace, forecast: WeatherForecast)?

    /// Called when rain is about to start.
    @ObservationIgnored var onRain: (WeatherRainAlert) -> Void = { _ in }
    /// Called when a preview's sample comes or goes.
    @ObservationIgnored var onSampleChange: () -> Void = {}

    /// A forecast is fetched this often.
    static let interval: TimeInterval = 15 * 60
    /// After a wake, the network is given this long to come up.
    static let wakeDelay: TimeInterval = 5
    static let firstRetry: TimeInterval = 60
    static let longestRetry: TimeInterval = 60 * 60
    /// This Mac's location is found again once the last reading is this old.
    static let relocateAfter: TimeInterval = 60 * 60
    /// The tile gives a forecast's age once it is older than this: three missed fetches.
    static let staleAfter: TimeInterval = 45 * 60

    @ObservationIgnored let search: WeatherPlaceSearch
    @ObservationIgnored private let client: OpenMeteo
    @ObservationIgnored private let locator: any WeatherLocating
    @ObservationIgnored private let triggers: any WeatherTriggers
    @ObservationIgnored private let clock: any WeatherClock
    @ObservationIgnored private let store: WeatherStore

    @ObservationIgnored private var isStarted = false
    /// Bumped by every fetch, a change of place and stopping, so an answer that comes
    /// back after any of those is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var timer: WeatherTimer?
    @ObservationIgnored private var sampleTimer: WeatherTimer?
    /// Failed fetches since the last good one.
    @ObservationIgnored private(set) var failures = 0
    @ObservationIgnored private var rainWatch: WeatherRainWatch
    /// When this Mac was last looked for, found or not. Kept apart from the place's
    /// `located`, which Settings shows, so a look that failed is never passed off as a
    /// reading.
    @ObservationIgnored private var lastLocateAttempt: Date?

    init(
        client: OpenMeteo = OpenMeteo(),
        locator: (any WeatherLocating)? = nil,
        triggers: (any WeatherTriggers)? = nil,
        clock: (any WeatherClock)? = nil,
        defaults: UserDefaults = .standard,
        searchDelay: TimeInterval = 0.35
    ) {
        self.client = client
        self.locator = locator ?? WeatherLocator()
        self.triggers = triggers ?? WeatherSystemTriggers()
        self.clock = clock ?? WeatherSystemClock()
        store = WeatherStore(defaults: defaults)
        search = WeatherPlaceSearch(client: client, delay: searchDelay)
        pickedPlace = store.pickedPlace
        macPlace = store.macPlace
        usesThisMac = store.usesThisMac
        rainWatch = store.rainWatch
        forecast = store.forecast
        lastLocateAttempt = store.lastLocateAttempt
    }

    /// The place the forecast is for, if there is one.
    var place: WeatherPlace? { usesThisMac ? macPlace : pickedPlace }

    /// The forecast for the place, if one is known.
    var placeForecast: WeatherForecast? {
        guard let place, let forecast, place.matches(forecast) else { return nil }
        return forecast
    }

    /// What the tile shows: a preview's sample while one runs, else the real thing.
    var tile: WeatherTileState {
        if let sample { return .forecast(sample.place, sample.forecast) }
        if usesThisMac {
            switch locationAccess {
            case .undetermined: return .allowLocation
            case .denied, .restricted: return .locationOff
            case .allowed: break
            }
        }
        guard let place else {
            guard usesThisMac else { return .choosePlace }
            if let failure, !isLocating { return .failed(nil, failure) }
            return .locating
        }
        if let forecast = placeForecast { return .forecast(place, forecast) }
        if let failure, !isFetching { return .failed(place, failure) }
        return .loading(place)
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        pickedPlace = store.pickedPlace
        macPlace = store.macPlace
        usesThisMac = store.usesThisMac
        forecast = store.forecast
        rainWatch = store.rainWatch
        lastLocateAttempt = store.lastLocateAttempt
        if usesThisMac { locationAccess = locator.access }
        triggers.start(
            wake: { [weak self] in self?.woke() },
            sleep: { [weak self] in self?.willSleep() },
            networkReturned: { [weak self] in self?.networkReturned() }
        )
        resume()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        generation &+= 1
        fetchTask?.cancel()
        fetchTask = nil
        isFetching = false
        isLocating = false
        timer?.cancel()
        timer = nil
        endSample()
        triggers.stop()
        search.clear()
    }

    /// Fetches now, from `islet://weather/refresh`, unless a fetch is under way.
    func refresh() {
        guard isStarted else { return }
        fetch(relocating: true)
    }

    /// Carries on from a fresh forecast kept from before, or fetches one.
    private func resume() {
        guard isStarted, place != nil || usesThisMac else { return }
        if let forecast = placeForecast, age(of: forecast) < Self.interval, !needsLocating {
            evaluateRain(forecast)
            schedule(after: Self.interval - age(of: forecast))
        } else {
            fetch(relocating: true)
        }
    }

    // MARK: Place

    /// A city picked from the search in Settings.
    func choose(_ place: WeatherPlace) {
        pickedPlace = place
        store.pickedPlace = place
        search.clear()
        if !usesThisMac { placeChanged() }
    }

    /// Turns "Use this Mac's location" on or off. Turning it on asks macOS for access
    /// the first time, then finds the Mac.
    ///
    /// Either way the place has changed, so whatever was under way for the old one is
    /// dropped first, even while macOS is still to ask: a forecast for the city just
    /// left, arriving after, would otherwise be kept and could warn of its rain.
    func setUsesThisMac(_ on: Bool) {
        guard on != usesThisMac else { return }
        usesThisMac = on
        store.usesThisMac = on
        if on {
            locationAccess = locator.access
            // A reading of its own, however recent the last: the person may have moved
            // since, and turning this on is the moment they expect it.
            macPlace = nil
            store.macPlace = nil
        }
        // Fetches nothing until macOS allows it; `requestLocationAccess` carries on.
        placeChanged()
        if on, locationAccess == .undetermined { requestLocationAccess() }
    }

    /// Asks macOS for access to the Mac's location, from a click.
    func requestLocationAccess() {
        guard usesThisMac, !isLocating else { return }
        isLocating = true
        Task { [weak self, locator] in
            let access = await locator.requestAccess()
            guard let self else { return }
            self.isLocating = false
            self.locationAccess = access
            guard self.usesThisMac, access == .allowed else { return }
            self.macPlace = nil
            self.store.macPlace = nil
            self.placeChanged()
        }
    }

    /// Re-reads location access, which can change in System Settings at any time
    /// without telling the app. Asks nothing.
    func refreshLocationAccess() {
        guard usesThisMac else { return }
        let access = locator.access
        guard access != locationAccess else { return }
        locationAccess = access
        if access == .allowed { placeChanged() }
    }

    /// A new place: whatever was under way for the old one is dropped, and its forecast
    /// with it, and a forecast is fetched for the new one straight away.
    private func placeChanged() {
        generation &+= 1
        fetchTask?.cancel()
        fetchTask = nil
        isFetching = false
        isLocating = false
        failures = 0
        failure = nil
        timer?.cancel()
        timer = nil
        if forecast != nil, placeForecast == nil {
            forecast = nil
            store.forecast = nil
        }
        rainWatch = WeatherRainWatch()
        store.rainWatch = rainWatch
        guard isStarted else { return }
        fetch(relocating: true)
    }

    /// Whether this Mac should be found before the next fetch: always while there is no
    /// reading, on the failures' own backoff, and otherwise once the last reading, or
    /// the last look that failed to improve on it, is an hour old.
    private var needsLocating: Bool {
        guard usesThisMac, locationAccess == .allowed else { return false }
        guard let located = macPlace?.located else { return true }
        let lastLook = max(located, lastLocateAttempt ?? located)
        return clock.now.timeIntervalSince(lastLook) >= Self.relocateAfter
    }

    // MARK: Fetching

    /// Fetches the forecast, first finding this Mac again if its reading is old.
    private func fetch(relocating: Bool) {
        guard isStarted, !isFetching, !isLocating else { return }
        if usesThisMac, locationAccess != .allowed { return }
        if relocating, needsLocating {
            locateThenFetch()
            return
        }
        guard let place else {
            if usesThisMac { failed(.noLocation) }
            return
        }
        timer?.cancel()
        timer = nil
        isFetching = true
        generation &+= 1
        let generation = generation
        let started = clock.now
        fetchTask = Task { [weak self, client] in
            do {
                let forecast = try await client.forecast(for: place, at: started)
                self?.fetched(forecast, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.generation else { return }
                self.isFetching = false
                self.failed(error as? WeatherFailure ?? .offline)
            }
        }
    }

    private func locateThenFetch() {
        isLocating = true
        let generation = generation
        Task { [weak self, locator] in
            let reading = try? await locator.locate()
            guard let self, self.isStarted, generation == self.generation, self.usesThisMac else { return }
            self.isLocating = false
            // Tried, found or not: a reading that fails leaves the old one standing for
            // another hour rather than be asked for again before every fetch.
            self.lastLocateAttempt = self.clock.now
            self.store.lastLocateAttempt = self.clock.now
            if let reading {
                let found = WeatherPlace.thisMac(latitude: reading.latitude, longitude: reading.longitude, at: self.clock.now)
                // Approximate readings wander by a kilometre or two. One that close to the
                // last is the same place, and keeps its forecast rather than fetch another
                // for a spot next door.
                var place = self.macPlace.map { $0.isNear(found) ? $0 : found } ?? found
                place.located = self.clock.now
                self.macPlace = place
                self.store.macPlace = place
            }
            self.fetch(relocating: false)
        }
    }

    private func fetched(_ forecast: WeatherForecast, generation: Int) {
        guard isStarted, generation == self.generation else { return }
        isFetching = false
        fetchTask = nil
        failures = 0
        failure = nil
        self.forecast = forecast
        store.forecast = forecast
        evaluateRain(forecast)
        schedule(after: Self.interval)
    }

    private func failed(_ failure: WeatherFailure) {
        fetchTask = nil
        failures += 1
        self.failure = failure
        schedule(after: Self.retryDelay(after: failures))
    }

    /// A minute after the first failure, doubling after each one after it, up to an hour.
    static func retryDelay(after failures: Int) -> TimeInterval {
        let doublings = Double(min(max(failures - 1, 0), 12))
        return min(longestRetry, firstRetry * pow(2, doublings))
    }

    private func schedule(after delay: TimeInterval) {
        timer?.cancel()
        timer = clock.schedule(after: max(0, delay)) { [weak self] in
            self?.timer = nil
            self?.fetch(relocating: true)
        }
    }

    private func age(of forecast: WeatherForecast) -> TimeInterval {
        max(0, clock.now.timeIntervalSince(forecast.fetched))
    }

    // MARK: Events

    /// The Mac woke: a forecast in a few seconds, once the network is back, unless the
    /// one there is still fresh.
    private func woke() {
        guard isStarted, place != nil || usesThisMac else { return }
        if failures == 0, let forecast = placeForecast, age(of: forecast) < Self.interval {
            schedule(after: Self.interval - age(of: forecast))
        } else {
            schedule(after: Self.wakeDelay)
        }
    }

    /// Nothing is fetched while the Mac sleeps; waking fetches.
    private func willSleep() {
        timer?.cancel()
        timer = nil
    }

    /// The network came back: worth a try straight away if the last one failed, or a
    /// fetch is due.
    private func networkReturned() {
        guard isStarted, !isFetching, place != nil || usesThisMac else { return }
        let isDue = placeForecast.map { age(of: $0) >= Self.interval } ?? true
        guard failures > 0 || isDue else { return }
        fetch(relocating: true)
    }

    // MARK: Rain

    /// Warns of rain about to start, from a forecast fresh enough to say.
    private func evaluateRain(_ forecast: WeatherForecast) {
        let now = clock.now
        guard age(of: forecast) < Self.interval + 5 * 60 else { return }
        let alert = rainWatch.update(forecast.rainOutlook(at: now), at: now)
        store.rainWatch = rainWatch
        if let alert { onRain(alert) }
    }

    // MARK: Previews

    /// Shows a stand-in place and forecast for a while, as if they were real.
    func showSample(_ place: WeatherPlace, _ forecast: WeatherForecast, for duration: TimeInterval) {
        sampleTimer?.cancel()
        sample = (place, forecast)
        sampleTimer = clock.schedule(after: duration) { [weak self] in self?.endSample() }
        onSampleChange()
    }

    private func endSample() {
        sampleTimer?.cancel()
        sampleTimer = nil
        guard sample != nil else { return }
        sample = nil
        onSampleChange()
    }
}

/// What the home tile has to show.
enum WeatherTileState {
    /// No city picked, and this Mac's location not asked for.
    case choosePlace
    /// This Mac's location is asked for, and macOS has not been asked yet.
    case allowLocation
    /// This Mac's location is asked for, and turned off in System Settings.
    case locationOff
    case locating
    case loading(WeatherPlace)
    /// No forecast for the place; the place is `nil` when this Mac could not be found.
    case failed(WeatherPlace?, WeatherFailure)
    case forecast(WeatherPlace, WeatherForecast)
}

// MARK: - Search

/// The place search in Settings: Open-Meteo's place names, looked up a moment after
/// typing stops. Only the words typed are sent.
@MainActor
@Observable
final class WeatherPlaceSearch {
    enum State: Equatable {
        case idle
        case searching
        case done
        case failed(WeatherFailure)
    }

    private(set) var text = ""
    private(set) var results: [WeatherPlace] = []
    private(set) var state = State.idle

    /// Fewer letters than this match too much to be worth sending.
    static let shortest = 2

    @ObservationIgnored private let client: OpenMeteo
    @ObservationIgnored private let delay: TimeInterval
    @ObservationIgnored private var task: Task<Void, Never>?

    init(client: OpenMeteo, delay: TimeInterval) {
        self.client = client
        self.delay = delay
    }

    /// The field changed: looks the words up once typing pauses.
    func update(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        task?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.shortest else {
            results = []
            state = .idle
            return
        }
        state = .searching
        let delay = delay
        task = Task { [weak self, client] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            do {
                let places = try await client.search(query, language: Self.language)
                guard !Task.isCancelled else { return }
                self?.results = places
                self?.state = .done
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.results = []
                self?.state = .failed(error as? WeatherFailure ?? .offline)
            }
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        text = ""
        results = []
        state = .idle
    }

    /// The Mac's first language, for place names in it where Open-Meteo has them.
    static var language: String {
        let code = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        return code ?? "en"
    }
}

// MARK: - Storage

/// What the feature keeps between launches, in the app's defaults: the places, the
/// last good forecast, and the rain it has warned of.
struct WeatherStore {
    let defaults: UserDefaults

    var pickedPlace: WeatherPlace? {
        get { read(WeatherPrefs.place) }
        nonmutating set { write(newValue, WeatherPrefs.place) }
    }

    var macPlace: WeatherPlace? {
        get { read(WeatherPrefs.macPlace) }
        nonmutating set { write(newValue, WeatherPrefs.macPlace) }
    }

    var usesThisMac: Bool {
        get { defaults.bool(forKey: WeatherPrefs.usesThisMac) }
        nonmutating set { defaults.set(newValue, forKey: WeatherPrefs.usesThisMac) }
    }

    var lastLocateAttempt: Date? {
        get { defaults.object(forKey: WeatherPrefs.lastLocateAttempt) as? Date }
        nonmutating set { defaults.set(newValue, forKey: WeatherPrefs.lastLocateAttempt) }
    }

    var forecast: WeatherForecast? {
        get { read(WeatherPrefs.forecast) }
        nonmutating set { write(newValue, WeatherPrefs.forecast) }
    }

    var rainWatch: WeatherRainWatch {
        get { read(WeatherPrefs.rainWatch) ?? WeatherRainWatch() }
        nonmutating set { write(newValue, WeatherPrefs.rainWatch) }
    }

    private func read<Value: Decodable>(_ key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    private func write<Value: Encodable>(_ value: Value?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Time and events

/// Something to cancel: a wait set with `WeatherClock`.
struct WeatherTimer {
    let cancel: () -> Void
}

/// The time, and waits on the main queue. Only a test replaces it.
@MainActor
protocol WeatherClock: AnyObject {
    var now: Date { get }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> WeatherTimer
}

/// The real clock. Waits are kept in wall-clock time, so one that passes while the Mac
/// sleeps is over on wake, rather than that much later.
@MainActor
final class WeatherSystemClock: WeatherClock {
    var now: Date { Date() }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> WeatherTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler {
            timer.cancel()
            MainActor.assumeIsolated { action() }
        }
        timer.schedule(wallDeadline: .now() + delay, leeway: .seconds(1))
        timer.resume()
        return WeatherTimer { timer.cancel() }
    }
}

/// The Mac waking and going to sleep, and its network coming back. Only a test
/// replaces it.
@MainActor
protocol WeatherTriggers: AnyObject {
    func start(
        wake: @escaping @MainActor () -> Void,
        sleep: @escaping @MainActor () -> Void,
        networkReturned: @escaping @MainActor () -> Void
    )
    func stop()
}

/// NSWorkspace's sleep and wake, and the network path as Network sees it.
@MainActor
final class WeatherSystemTriggers: WeatherTriggers {
    private var observers: [NSObjectProtocol] = []
    private var monitor: NWPathMonitor?

    func start(
        wake: @escaping @MainActor () -> Void,
        sleep: @escaping @MainActor () -> Void,
        networkReturned: @escaping @MainActor () -> Void
    ) {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { wake() }
            },
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { sleep() }
            },
        ]
        // Only a return counts: the first report says how things are, not that they changed.
        let monitor = NWPathMonitor()
        let memory = PathMemory()
        monitor.pathUpdateHandler = { path in
            let isSatisfied = path.status == .satisfied
            defer { memory.wasSatisfied = isSatisfied }
            guard memory.wasSatisfied == false, isSatisfied else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { networkReturned() } }
        }
        monitor.start(queue: DispatchQueue(label: "com.ayush.Islet.weather.network", qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        monitor?.cancel()
        monitor = nil
    }
}

/// Whether the network was up at its last report. Only the monitor's own queue, which
/// runs one report at a time, touches it.
private final class PathMemory: @unchecked Sendable {
    var wasSatisfied: Bool?
}
