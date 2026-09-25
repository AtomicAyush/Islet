import AppKit
import SwiftUI

/// Every app producing sound, each at a level of its own, and the island keeping
/// track when more than one plays at once.
///
/// With two or more apps playing, the mixer is a background activity: it has the
/// island only when nothing else does, and otherwise sits in the bubble beside it,
/// showing whichever app started last. Opened, it lists the apps with a slider each
/// (0–150%) and a mute. The home page shows the same sliders while anything plays.
@MainActor
final class MixerFeature: Feature {
    let id = "mixer"
    let title = "Sound Mixer"
    let symbol = "slider.horizontal.3"
    let summary = "Every app playing sound, each with its own volume, and a bubble when two play at once."

    private let model = MixerModel()
    private lazy var activity = MixerActivity(model: model)
    private var isRunning = false
    private var homeWidgetShown = false
    /// The sizes the activity was last published with.
    private var publishedSizes: MixerActivity.Sizes?
    private var hideWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?

    @AppStorage(MixerPrefs.showWhenSeveral) private var showWhenSeveral = MixerPrefs.showWhenSeveralDefault

    /// How long the activity stays after fewer than two apps play: a browser stops
    /// its sound for a moment between videos, and the island should not blink.
    private static let hold: TimeInterval = 1.5
    private static let previewLength: TimeInterval = 10

    init() {
        model.onChange = { [weak self] in self?.sync() }
    }

    func start() {
        isRunning = true
        model.start()
        sync()
    }

    func stop() {
        isRunning = false
        model.stop()
        previewWork?.cancel()
        previewWork = nil
        model.endPreview()
        cancelHide()
        let center = ActivityCenter.shared
        center.end(id: activity.id)
        center.removeHomeWidget(id: id)
        homeWidgetShown = false
        publishedSizes = nil
    }

    func settingsView() -> AnyView? {
        AnyView(MixerSettings(model: model) { [weak self] in self?.sync() })
    }

    /// Sample apps for 10 seconds, then whatever is really playing. The sliders move
    /// but touch no sound.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Two apps playing") { [weak self] in
                self?.preview(MixerSamples.twoApps)
            },
            FeaturePreview(title: "Three apps playing") { [weak self] in
                self?.preview(MixerSamples.threeApps)
            },
        ]
    }

    // MARK: State

    /// Puts up or takes down the activity and the home tile to match the model.
    private func sync() {
        let center = ActivityCenter.shared
        let isPreviewing = model.isPreviewing
        let count = isRunning || isPreviewing ? model.apps.count : 0

        if count > 0 {
            if !homeWidgetShown {
                center.setHomeWidget(HomeWidget(
                    id: id, order: 15, weight: 1.5, view: AnyView(MixerHomeTile(model: model))
                ))
                homeWidgetShown = true
            }
        } else if homeWidgetShown {
            center.removeHomeWidget(id: id)
            homeWidgetShown = false
        }

        let wanted = count >= 2 && (showWhenSeveral || isPreviewing)
        if wanted {
            cancelHide()
            let sizes = activity.sizes
            if !center.isShowing(id: activity.id) || sizes != publishedSizes {
                publishedSizes = sizes
                center.show(activity)
            }
        } else if center.isShowing(id: activity.id) {
            // Fewer than two playing: hold a moment in case one comes straight back.
            // Turned off, stopped or a preview over, it goes at once.
            if count == 1, isRunning, showWhenSeveral {
                if hideWork == nil { scheduleHide() }
            } else {
                cancelHide()
                endActivity()
            }
        }
    }

    private func scheduleHide() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideWork = nil
                if self.model.apps.count < 2 { self.endActivity() }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func endActivity() {
        ActivityCenter.shared.end(id: activity.id)
        publishedSizes = nil
    }

    // MARK: Previews

    private func preview(_ sample: MixerSamples.Sample) {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.previewWork = nil
                self?.model.endPreview()
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewLength, execute: work)
        model.beginPreview(sample.apps, levels: sample.levels, muted: sample.muted)
    }
}

@MainActor
final class MixerActivity: IslandActivity {
    /// What the island's size depends on; a change re-publishes the activity.
    struct Sizes: Equatable {
        var leading: CGFloat
        var expanded: CGFloat
    }

    let id = "mixer"
    let priority = ActivityPriority.background
    let symbol = "slider.horizontal.3"
    let model: MixerModel

    init(model: MixerModel) { self.model = model }

    var sizes: Sizes {
        Sizes(
            leading: max(44, MixerIconStack.width(count: model.apps.count) + 16),
            expanded: MixerExpanded.height(rows: model.apps.count, hasNote: model.note != nil)
        )
    }

    var compactLeadingWidth: CGFloat? { sizes.leading }
    var compactTrailingWidth: CGFloat? { 56 }
    var expandedHeight: CGFloat { sizes.expanded }

    func compactLeading() -> AnyView { AnyView(MixerCompactLeading(model: model)) }
    func compactTrailing() -> AnyView { AnyView(MixerCompactTrailing(model: model)) }
    func minimal() -> AnyView { AnyView(MixerMinimal(model: model)) }
    func expanded() -> AnyView { AnyView(MixerExpanded(model: model)) }
}

/// Apps that ship with macOS, so their icons are always there.
@MainActor
private enum MixerSamples {
    struct Sample {
        var apps: [MixerSource]
        var levels: [String: Double] = [:]
        var muted: Set<String> = []
    }

    static var twoApps: Sample {
        let music = app("com.apple.Music", name: "Music", fallback: "/System/Applications/Music.app")
        let safari = app("com.apple.Safari", name: "Safari", fallback: "/Applications/Safari.app")
        return Sample(apps: [music, safari], levels: [safari.id: 0.6])
    }

    static var threeApps: Sample {
        let music = app("com.apple.Music", name: "Music", fallback: "/System/Applications/Music.app")
        let safari = app("com.apple.Safari", name: "Safari", fallback: "/Applications/Safari.app")
        let faceTime = app("com.apple.FaceTime", name: "FaceTime", fallback: "/System/Applications/FaceTime.app")
        return Sample(
            apps: [music, safari, faceTime],
            levels: [music.id: 0.45, safari.id: 1.25],
            muted: [faceTime.id]
        )
    }

    private static func app(_ bundleID: String, name: String, fallback: String) -> MixerSource {
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path ?? fallback
        return MixerSource(id: MixerModel.previewPrefix + bundleID, name: name, bundlePath: path)
    }
}
