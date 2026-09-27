import SwiftUI

/// The weather where you are, on the home page: the conditions and the temperature now,
/// the day's high and low, and when rain is next due. When rain is about to start and
/// it is dry now, a word beside the notch, once for each spell of rain: "Rain in about
/// 10 min". Over music or a timer, that rides in a row under it.
///
/// Forecasts come from Open-Meteo, free and with no account. Nothing is sent until the
/// person searches for a place in Settings or turns on this Mac's own location: the
/// words searched for, with the Mac's language, and after that only the place's
/// coordinates, rounded to about a kilometre.
@MainActor
final class WeatherFeature: Feature {
    let id = "weather"
    let title = "Weather"
    let symbol = "cloud.sun.fill"
    let summary = "The temperature on the home page, and a word before rain starts."

    /// Where the tile goes on the home page, until the person puts it somewhere else.
    static let tileOrder = 25
    var homeTile: HomeTileInfo? { HomeTileInfo(self, order: Self.tileOrder) }

    static let bannerID = "weather.rain"
    /// Long enough to read twice: it comes unasked.
    static let bannerDuration: TimeInterval = 5.5

    let model: WeatherModel
    private var isRunning = false
    private var isWidgetShown = false

    init(model: WeatherModel? = nil) {
        self.model = model ?? WeatherModel()
        self.model.onRain = { [weak self] alert in self?.rainSoon(alert) }
        self.model.onSampleChange = { [weak self] in self?.syncHomeWidget() }
    }

    func start() {
        isRunning = true
        model.start()
        syncHomeWidget()
    }

    func stop() {
        isRunning = false
        model.stop()
        syncHomeWidget()
        ActivityCenter.shared.dismissBanner(id: Self.bannerID)
    }

    func settingsView() -> AnyView? {
        AnyView(WeatherSettings(model: model))
    }

    /// Made-up places and forecasts, never the person's. The tiles stand in for the
    /// real one for ten seconds; open the island to see them.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Rain in 10 minutes") {
                let now = Date()
                ActivityCenter.shared.present(Self.banner(
                    WeatherRainAlert(start: now.addingTimeInterval(10 * 60), fall: .rain, seen: now),
                    interruption: .active
                ))
            },
            FeaturePreview(title: "Home tile, sunny") { [weak self] in
                self?.previewTile(WeatherSamples.sunny())
            },
            FeaturePreview(title: "Home tile, rain on the way") { [weak self] in
                self?.previewTile(WeatherSamples.rainSoon())
            },
        ]
    }

    /// `islet://weather/refresh` fetches the forecast now.
    func handle(_ url: URL) -> Bool {
        guard url.path() == "/refresh" else { return false }
        model.refresh()
        return true
    }

    // MARK: Island

    /// The tile is there while the feature runs, or a preview shows one.
    private func syncHomeWidget() {
        let wanted = isRunning || model.sample != nil
        // A preview's tile shows even if the person hid it.
        ActivityCenter.shared.setPreviewing(model.sample != nil, homeTile: id)
        guard wanted != isWidgetShown else { return }
        isWidgetShown = wanted
        if wanted {
            ActivityCenter.shared.setHomeWidget(HomeWidget(
                id: id, order: Self.tileOrder, view: AnyView(WeatherHomeTile(model: model))
            ))
        } else {
            ActivityCenter.shared.removeHomeWidget(id: id)
        }
    }

    private func rainSoon(_ alert: WeatherRainAlert) {
        guard isRunning, WeatherPrefs.bool(WeatherPrefs.warnsOfRain, default: true) else { return }
        ActivityCenter.shared.present(Self.banner(alert))
    }

    /// The warning as a compact banner: the symbol and "Rain" left of the camera, when
    /// it starts right of it. Rain on the way is nice to know rather than needed now, so
    /// a Focus that asks for quiet drops it; the spell counts as warned of all the same,
    /// since a warning shown once the Focus ends could come after the rain.
    static func banner(_ alert: WeatherRainAlert, interruption: BannerInterruption = .passive) -> IslandBanner {
        let minutes = WeatherRainWords.minutes(until: alert.start, from: alert.seen)
        return IslandBanner(
            id: bannerID,
            style: .compact(
                leading: WeatherBannerLayout.leadingWidth(alert.fall),
                trailing: WeatherBannerLayout.trailingWidth(WeatherRainWords.soon(minutes))
            ),
            duration: bannerDuration,
            haptic: false,
            interruption: interruption,
            leading: AnyView(WeatherBannerLeading(fall: alert.fall)),
            trailing: AnyView(WeatherBannerTrailing(fall: alert.fall, minutes: minutes))
        )
    }

    private func previewTile(_ sample: (place: WeatherPlace, forecast: WeatherForecast)) {
        model.showSample(sample.place, sample.forecast, for: 10)
        IslandManager.shared.focusedController?.model.expand(focus: IslandViewModel.homeFocus)
    }
}

/// The feature's preference keys. Unset keys read as their defaults, the same ones the
/// settings controls declare.
enum WeatherPrefs {
    /// `WeatherScale`'s raw value.
    static let scale = "weather.scale"
    static let warnsOfRain = "weather.warnsOfRain"
    static let usesThisMac = "weather.usesThisMac"
    /// The city picked in Settings, and where this Mac was last found, as JSON.
    static let place = "weather.place"
    static let macPlace = "weather.macPlace"
    /// When this Mac was last looked for, found or not.
    static let lastLocateAttempt = "weather.lastLocateAttempt"
    /// The last good forecast, and the rain spell last warned of, as JSON.
    static let forecast = "weather.forecast"
    static let rainWatch = "weather.rainWatch"

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}
