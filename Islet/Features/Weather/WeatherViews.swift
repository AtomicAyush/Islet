import AppKit
import SwiftUI

/// The iPhone's system colours, as its Weather app uses them on black.
enum WeatherPalette {
    /// The tile's heading.
    static let sky = Color(red: 100 / 255, green: 210 / 255, blue: 1)
    /// Rain on the way.
    static let rain = Color(red: 90 / 255, green: 200 / 255, blue: 250 / 255)
}

/// A condition's symbol in its own colours, as the iPhone's Weather draws them.
struct WeatherSymbol: View {
    let name: String
    var size: CGFloat

    var body: some View {
        Image(systemName: name)
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white)
            .accessibilityHidden(true)
    }
}

// MARK: - Banner

/// The warning's measurements, matching the island's other banners: 13-point semibold
/// words and a symbol the size of a Focus's beside the notch, with the same insets.
/// Each side asks only for its own width; the island makes both wings as wide as the
/// wider, so it stays centred on the notch.
enum WeatherBannerLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let symbolSize = CGSize(width: 22, height: 17)
    static let symbolSpacing: CGFloat = 7
    /// Room between each side's content and the island's outer edge, and the notch.
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10

    /// The symbol and the word.
    static func leadingWidth(_ fall: WeatherFall) -> CGFloat {
        outerInset + symbolSize.width + symbolSpacing + textWidth(fall.word) + innerInset
    }

    /// When it starts.
    static func trailingWidth(_ when: String) -> CGFloat {
        innerInset + textWidth(when) + outerInset
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it,
    /// which would otherwise cut short words that just fit.
    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}

/// Left of the notch: the symbol and "Rain". Where there is no room for the word (the
/// opened island's header gives this side 24 points, and the right side says it all),
/// the symbol alone.
struct WeatherBannerLeading: View {
    let fall: WeatherFall

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WeatherBannerLayout.symbolSpacing) {
                symbol
                Text(fall.word)
                    .font(Font(WeatherBannerLayout.font))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.leading, WeatherBannerLayout.outerInset)
            .padding(.trailing, WeatherBannerLayout.innerInset)
            symbol
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: some View {
        Image(systemName: fall.symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .symbolRenderingMode(.multicolor)
            .fontWeight(.semibold)
            .frame(width: WeatherBannerLayout.symbolSize.width, height: WeatherBannerLayout.symbolSize.height)
            .accessibilityHidden(true)
    }
}

/// Right of the notch: when it starts, in rain's blue.
///
/// The opened island's header leaves the left side room for the symbol alone, so there
/// the word comes over to this side, which is narrower than the closed island's and
/// narrower still beside a wider notch: "Rain in about 10 min" where that fits, "Rain in
/// 10 min" where it does not, and at the least "in 10 min", truncated if it must be.
/// Whatever does not fit would otherwise spill left, under the camera, and take the
/// symbol with it.
struct WeatherBannerTrailing: View {
    let fall: WeatherFall
    let minutes: Int
    @Environment(\.isInIslandHeader) private var isInHeader

    var body: some View {
        Group {
            if isInHeader {
                ViewThatFits(in: .horizontal) {
                    warning(WeatherRainWords.soon(minutes))
                        .fixedSize()
                        .modifier(Insets())
                    warning(WeatherRainWords.soonShort(minutes))
                        .fixedSize()
                        .modifier(Insets())
                    Text(WeatherRainWords.soonShort(minutes))
                        .foregroundStyle(WeatherPalette.rain)
                        .truncationMode(.tail)
                        .modifier(Insets())
                }
            } else {
                let when = WeatherRainWords.soon(minutes)
                Text(when)
                    .foregroundStyle(WeatherPalette.rain)
                    .frame(width: WeatherBannerLayout.textWidth(when), alignment: .trailing)
                    .modifier(Insets())
            }
        }
        .font(Font(WeatherBannerLayout.font))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(fall.word) \(WeatherRainWords.soon(minutes))")
    }

    /// The word in white, then when in rain's blue.
    private func warning(_ when: String) -> Text {
        Text("\(Text(fall.word).foregroundStyle(.white)) \(Text(when).foregroundStyle(WeatherPalette.rain))")
    }

    private struct Insets: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(.leading, WeatherBannerLayout.innerInset)
                .padding(.trailing, WeatherBannerLayout.outerInset)
        }
    }
}

// MARK: - Home

/// The home page's weather: the place, the temperature and a symbol for the conditions,
/// the day's high and low, and when rain is next due. Until there is a place, a way to
/// choose one.
struct WeatherHomeTile: View {
    let model: WeatherModel

    var body: some View {
        TimelineView(.everyMinute) { context in
            WeatherTileView(
                state: model.tile, now: context.date,
                chooseFromSettings: WeatherSettings.open,
                allowLocation: { model.requestLocationAccess() },
                retry: { model.refresh() }
            )
        }
        .onAppear { model.refreshLocationAccess() }
    }
}

/// The tile for one state at one moment, so it can be drawn from anything.
struct WeatherTileView: View {
    let state: WeatherTileState
    let now: Date
    var chooseFromSettings: () -> Void = {}
    var allowLocation: () -> Void = {}
    var retry: () -> Void = {}
    @AppStorage(WeatherPrefs.scale) private var scaleName = WeatherScale.automatic.rawValue

    private var scale: WeatherScale { WeatherScale(rawValue: scaleName) ?? .automatic }

    var body: some View {
        switch state {
        case .forecast(let place, let forecast):
            WeatherForecastTile(place: place, forecast: forecast, now: now, scale: scale)
        case .choosePlace:
            WeatherPrompt(title: "Weather", message: "Choose a place for the forecast", action: "Choose…", perform: chooseFromSettings)
        case .allowLocation:
            WeatherPrompt(title: "Weather", message: "Needs this Mac’s location", action: "Allow…", perform: allowLocation)
        case .locationOff:
            WeatherPrompt(title: "Weather", message: "Location access is off", action: "Settings…") {
                WeatherSettings.openLocationPrivacy()
            }
        case .locating:
            WeatherPrompt(title: WeatherPlace.thisMacName, symbol: "location.fill", message: "Finding this Mac…")
        case .loading(let place):
            WeatherPrompt(title: place.name, symbol: place.headingSymbol, message: "Getting the forecast…")
        case .failed(let place, let failure):
            // A place keeps the heading it has while loading and once its forecast is
            // in; the feature's own symbol is only for when there is none.
            WeatherPrompt(
                title: place?.name ?? "Weather", symbol: place == nil ? "cloud.sun.fill" : place?.headingSymbol,
                message: failure.message, action: "Try Again", perform: retry
            )
        }
    }
}

private extension WeatherPlace {
    /// The heading's symbol: the location arrow for this Mac, as on the iPhone.
    var headingSymbol: String? { source == .thisMac ? "location.fill" : nil }
}

private struct WeatherHeading: View {
    let title: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(title).lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(WeatherPalette.sky)
    }
}

/// The forecast: "18°" beside the symbol, "H:22° L:12°" under it, then when rain is
/// due, or the conditions in words, or how old the forecast is once it is old.
struct WeatherForecastTile: View {
    let place: WeatherPlace
    let forecast: WeatherForecast
    let now: Date
    let scale: WeatherScale

    var body: some View {
        let condition = forecast.current.condition
        VStack(alignment: .leading, spacing: 0) {
            WeatherHeading(title: place.name, symbol: place.headingSymbol)
            HStack(alignment: .center, spacing: 6) {
                Text(scale.text(forecast.current.temperature))
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                // A box of its own, so a tall symbol (rain, a storm) does not push the
                // lines under it down.
                WeatherSymbol(name: condition.symbol, size: 22)
                    .frame(width: 32, height: 30)
            }
            .padding(.top, 4)
            if let day = forecast.day(at: now) {
                Text("H:\(scale.text(day.high))  L:\(scale.text(day.low))")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            footer(condition)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func footer(_ condition: WeatherCondition) -> some View {
        if now.timeIntervalSince(forecast.fetched) >= WeatherModel.staleAfter {
            Text("As of \(Self.age(forecast.fetched, now: now))")
                .foregroundStyle(.white.opacity(0.4))
        } else if case .starting(let start, let fall) = forecast.rainOutlook(at: now) {
            ViewThatFits(in: .horizontal) {
                ForEach(WeatherRainWords.tile(fall, start: start, from: now), id: \.self) { words in
                    Text(words)
                }
            }
            .foregroundStyle(WeatherPalette.rain)
        } else {
            Text(condition.name)
                .foregroundStyle(.white.opacity(0.55))
                .minimumScaleFactor(0.8)
        }
    }

    /// "9:40 AM" today; "Sep 26" before.
    static func age(_ fetched: Date, now: Date) -> String {
        if Calendar.current.isDate(fetched, inSameDayAs: now) {
            return fetched.formatted(date: .omitted, time: .shortened)
        }
        return fetched.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The tile before there is a forecast to show: what is missing, and a button to do
/// something about it where there is something to do.
private struct WeatherPrompt: View {
    let title: String
    var symbol: String? = "cloud.sun.fill"
    let message: String
    var action: String?
    var perform: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WeatherHeading(title: title, symbol: symbol)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action: perform) {
                    Text(action)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Settings

struct WeatherSettings: View {
    let model: WeatherModel
    @AppStorage(WeatherPrefs.scale) private var scale = WeatherScale.automatic.rawValue
    @AppStorage(WeatherPrefs.warnsOfRain) private var warnsOfRain = true

    /// Opens Settings on this feature, from the home tile: the island closes, since
    /// Settings is where the person is going.
    static func open() {
        IslandManager.shared.focusedController?.model.collapse()
        SettingsWindowController.shared.show(tab: "activities")
    }

    static func openLocationPrivacy() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    var body: some View {
        Toggle(isOn: Binding(get: { model.usesThisMac }, set: { model.setUsesThisMac($0) })) {
            Text("Use this Mac’s location")
            Text(locationCaption)
        }
        if model.usesThisMac, model.locationAccess == .denied || model.locationAccess == .restricted {
            LabeledContent("Location access") {
                HStack {
                    Text(model.locationAccess == .denied ? "Off" : "Restricted").foregroundStyle(.secondary)
                    Button("Open Privacy Settings…") { Self.openLocationPrivacy() }
                }
            }
        }
        if !model.usesThisMac {
            WeatherPlacePicker(model: model, search: model.search)
        }
        Picker("Temperature", selection: $scale) {
            ForEach(WeatherScale.allCases) { scale in
                Text(scale.title()).tag(scale.rawValue)
            }
        }
        Toggle(isOn: $warnsOfRain) {
            Text("Warn before rain starts")
            Text("A word beside the notch when rain is due within half an hour and it’s dry now, once for each spell of rain.")
        }
        Text("Forecasts and place names come from Open-Meteo.com, which is sent only the place’s coordinates, rounded to about a kilometre, and the words you search for, with this Mac’s language.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .onAppear { model.refreshLocationAccess() }
    }

    private var locationCaption: String {
        guard model.usesThisMac else {
            return "Found roughly, and at most once an hour. Or pick a city below."
        }
        switch model.locationAccess {
        case .undetermined:
            return model.isLocating ? "Waiting for macOS to ask…" : "macOS asks whether Islet may."
        case .denied:
            return "Location access is off for Islet in Privacy & Security."
        case .restricted:
            return "Location access is restricted on this Mac."
        case .allowed:
            if model.isLocating { return "Finding this Mac…" }
            if let located = model.macPlace?.located {
                return "Found at \(located.formatted(date: .omitted, time: .shortened)), roughly."
            }
            return "Found roughly, and at most once an hour."
        }
    }
}

/// The city in use, and a search for another.
private struct WeatherPlacePicker: View {
    let model: WeatherModel
    let search: WeatherPlaceSearch

    var body: some View {
        LabeledContent("Place") {
            if let place = model.pickedPlace {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(place.name)
                    if let detail = place.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("None").foregroundStyle(.secondary)
            }
        }
        TextField(
            "Search for a city",
            text: Binding(get: { search.text }, set: { search.update($0) }),
            prompt: Text("City name")
        )
        switch search.state {
        case .idle:
            EmptyView()
        case .searching:
            LabeledContent("Searching…") { ProgressView().controlSize(.small) }
                .foregroundStyle(.secondary)
        case .failed(let failure):
            Text(failure.message).foregroundStyle(.secondary)
        case .done:
            if search.results.isEmpty {
                Text("No places found").foregroundStyle(.secondary)
            }
            ForEach(Array(search.results.enumerated()), id: \.offset) { _, place in
                Button {
                    model.choose(place)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.name)
                            if let detail = place.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
