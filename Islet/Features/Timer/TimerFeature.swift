import AppKit
import SwiftUI

/// A countdown that lives in the island, started from the home page or the menu bar.
///
/// This is the smallest complete feature and the pattern the others follow: a model
/// that knows nothing about the island, an `IslandActivity` that presents it, a home
/// widget, a banner for the moment it matters, and previews.
@MainActor
final class TimerFeature: Feature {
    let id = "timer"
    let title = "Timer"
    let symbol = "timer"
    let summary = "A countdown beside the notch, started from the opened island."

    private let model = TimerModel()
    private lazy var activity = TimerActivity(model: model)
    private var isRunning = false

    @AppStorage("timer.sound") private var sound = "Glass"
    static let sounds = ["Glass", "Hero", "Ping", "Purr", "Submarine", "Funk", "None"]

    init() {
        model.onChange = { [weak self] in self?.sync() }
        model.onFinish = { [weak self] in self?.finished() }
    }

    func start() {
        isRunning = true
        ActivityCenter.shared.setHomeWidget(
            HomeWidget(id: "timer", order: 30, view: AnyView(TimerHomeTile(model: model)))
        )
        sync()
    }

    func stop() {
        isRunning = false
        model.cancel()
        ActivityCenter.shared.end(id: activity.id)
        ActivityCenter.shared.removeHomeWidget(id: "timer")
        ActivityCenter.shared.dismissBanner(id: "timer.done")
    }

    func settingsView() -> AnyView? {
        AnyView(TimerSettings())
    }

    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "10-second timer") { [weak self] in self?.preview(seconds: 10) },
            FeaturePreview(title: "5-minute timer") { [weak self] in self?.preview(seconds: 5 * 60) },
        ]
    }

    /// `islet://timer/start?minutes=5` (or `seconds=`), `islet://timer/pause`,
    /// `/resume`, `/cancel`.
    func handle(_ url: URL) -> Bool {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> Double? {
            query.first { $0.name == name }?.value.flatMap(Double.init)
        }
        switch url.path() {
        case "/start":
            let seconds = value("seconds") ?? (value("minutes") ?? 5) * 60
            guard seconds.isFinite, seconds > 0, seconds <= TimerModel.longest else { return false }
            model.start(seconds)
        case "/pause": model.pause()
        case "/resume": model.resume()
        case "/cancel": model.cancel()
        default: return false
        }
        return true
    }

    /// Shows a sample countdown — but never over a timer the person started: that one
    /// is shown instead.
    private func preview(seconds: TimeInterval) {
        if model.isActive {
            IslandManager.shared.focusedController?.model.expand(focus: activity.id)
        } else {
            model.start(seconds, remember: false)
        }
    }

    private func sync() {
        let center = ActivityCenter.shared
        if model.isActive {
            if !center.isShowing(id: activity.id) { center.show(activity) }
        } else {
            center.end(id: activity.id)
        }
    }

    private func finished() {
        if sound != "None" { NSSound(named: NSSound.Name(sound))?.play() }
        let center = ActivityCenter.shared
        center.present(IslandBanner(
            id: "timer.done",
            style: .card(width: 380, height: 64),
            duration: 8,
            content: AnyView(TimerDoneCard(model: model) {
                center.dismissBanner(id: "timer.done")
            })
        ))
    }
}

@MainActor
final class TimerActivity: IslandActivity {
    let id = "timer"
    let priority = ActivityPriority.high
    let symbol = "timer"
    let model: TimerModel

    init(model: TimerModel) { self.model = model }

    var compactTrailingWidth: CGFloat? { 58 }
    var expandedHeight: CGFloat { 76 }

    func compactLeading() -> AnyView { AnyView(TimerCompactLeading(model: model)) }
    func compactTrailing() -> AnyView { AnyView(TimerCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(TimerMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(TimerExpanded(model: model)) }
}

private struct TimerSettings: View {
    @AppStorage("timer.sound") private var sound = "Glass"

    var body: some View {
        Picker("Sound when done", selection: $sound) {
            ForEach(TimerFeature.sounds, id: \.self) { Text($0).tag($0) }
        }
        .onChange(of: sound) { _, name in
            if name != "None" { NSSound(named: NSSound.Name(name))?.play() }
        }
    }
}
