import SwiftUI

/// Presentation Mode: while the screen is shared or recorded, a call is on, or Keynote
/// or PowerPoint plays a slideshow, the island holds back what would show the person's
/// own things to everyone watching — messages from scripts and Claude Code, screenshots,
/// downloads, the clipboard, event titles, the song and its lyrics — and says afterwards,
/// once, how many alerts it held back. The volume, the brightness, a battery running low
/// and the like still show, and the island opens on hover as ever, its clipboard and
/// calendar tiles hidden. A mark beside the notch says it is on; clicked, it says why,
/// "Screen shared by Zoom", and offers to turn it off until that ends. It can be turned
/// on by hand too, with `islet://presentation/on` or the Presentation Mode action in
/// Shortcuts, and then stays on until turned off.
///
/// What is held back is up to Settings, and each feature marks what is personal in
/// what it shows (`IslandBanner.personal`); the island does the holding
/// (`ActivityCenter.heldBack`). Whether the screen is shared or a call is on comes from
/// the privacy monitor the Camera, Microphone & More feature uses, which it shares
/// (`PrivacyMonitor.demand`), and a slideshow from `SlideshowWatcher`.
@MainActor
final class PresentationFeature: Feature {
    let id = "presentation"
    let title = "Presentation Mode"
    let symbol = "eye.slash.fill"
    let summary = "Holds back personal alerts while you share your screen, are on a call or play a slideshow."

    /// Turning on and off, and the word afterwards, share one id, so one replaces the
    /// other rather than stacking.
    static let bannerID = "presentation"
    /// How long "On" and "Off" stay: long enough to read two words.
    private static let bannerDuration: TimeInterval = 1.6
    /// The word afterwards, which nobody asked for, stays longer.
    private static let summaryDuration: TimeInterval = 4

    let model: PresentationModel
    private let sources: PresentationSources
    private var isRunning = false
    private var defaultsObserver: NSObjectProtocol?
    /// What the privacy monitor is asked to watch, and whether the slideshow watcher
    /// runs, so settings are only applied when they change.
    private var privacySensors: Set<PrivacyMonitor.Sensor> = []
    private var watchesSlideshows = false
    /// The newest privacy readings, to be read again when the apps ignored change.
    private var lastUsage: PrivacyUsage?
    private var ignoredScreenApps: [String] = []
    /// Whether the island was holding back when last rendered.
    private var wasHolding = false

    /// `model` and `sources` stand in for the clock and the Mac in tests.
    init(model: PresentationModel? = nil, sources: PresentationSources? = nil) {
        let model = model ?? PresentationModel()
        self.model = model
        self.sources = sources ?? .live
        model.onChange = { [weak self] in self?.render() }
    }

    func start() {
        isRunning = true
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        applySettings()
    }

    func stop() {
        isRunning = false
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = nil
        if !privacySensors.isEmpty { sources.stopPrivacy() }
        privacySensors = []
        lastUsage = nil
        ignoredScreenApps = []
        if watchesSlideshows { sources.stopSlideshow() }
        watchesSlideshows = false
        model.reset()
        render()
        ActivityCenter.shared.dismissBanner(id: Self.bannerID)
    }

    func settingsView() -> AnyView? {
        AnyView(PresentationSettingsView())
    }

    /// Samples standing in for the real state for eight seconds: the mark, its card, and
    /// the tiles as they hide. The apps named ship with macOS. Banners that come up
    /// meanwhile are held back as they would be.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Screen shared") { [model] in
                model.showPreview(PresentationModel.State(isOn: true, reasons: [.screen(apps: [PresentationApp(name: "QuickTime Player")])]))
            },
            FeaturePreview(title: "On a call") { [model] in
                model.showPreview(PresentationModel.State(isOn: true, reasons: [.call(app: "FaceTime")]))
            },
            FeaturePreview(title: "Playing a slideshow") { [model] in
                model.showPreview(PresentationModel.State(isOn: true, reasons: [.slideshow(.keynote)]))
            },
            // Active, unlike the real one, so a quiet Focus doesn't drop the sample asked for.
            FeaturePreview(title: "Alerts held back") { [weak self] in
                self?.announce(.summary(3), interruption: .active)
            },
        ]
    }

    /// `islet://presentation/on`, `/off` and `/toggle`, which say what they did.
    func handle(_ url: URL) -> Bool {
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard let action = PresentationAction(rawValue: path) else { return false }
        perform(action, announcing: true)
        return true
    }

    /// Turns it on or off by hand. Returns whether it is on afterwards, or `nil` while
    /// the feature is off. What `PresentationModeIntent` runs.
    @discardableResult
    func perform(_ action: PresentationAction, announcing: Bool = true) -> Bool? {
        guard isRunning else { return nil }
        let turnsOn = switch action {
        case .on: true
        case .off: false
        case .toggle: !model.state.isOn
        }
        if turnsOn {
            model.turnOn()
            if announcing { announce(.on) }
        } else {
            let held = heldSoFar
            model.turnOff()
            // Anything held back is said instead (`render`).
            if announcing, held == 0 { announce(.off) }
        }
        return model.state.isOn
    }

    /// The card's button: off, until what turned it on ends.
    func turnOffFromCard() {
        perform(.off, announcing: false)
    }

    /// The card's other button: never to turn on for an app capturing the screen again,
    /// one that does so all the time. Settings list it, and can take it off again.
    func ignoreFromCard(_ app: PresentationApp) {
        guard let id = app.bundleIdentifier else { return }
        let ignored = PresentationPrefs.ignoredScreenAppIDs
        guard !ignored.contains(id) else { return }
        sources.saveIgnoredScreenApps(ignored + [id])
        applySettings()
    }

    // MARK: Settings

    private func applySettings() {
        guard isRunning else { return }
        let triggers = PresentationPrefs.enabledTriggers
        model.setEnabled(triggers)

        var sensors: Set<PrivacyMonitor.Sensor> = []
        if triggers.contains(.screen) { sensors.insert(.screen) }
        if triggers.contains(.call) { sensors.formUnion([.camera, .microphone]) }
        if sensors != privacySensors {
            privacySensors = sensors
            if sensors.isEmpty {
                sources.stopPrivacy()
                model.read(.screen, nil)
                model.read(.call, nil)
            } else {
                sources.watchPrivacy(sensors) { [weak self] usage in self?.privacyRead(usage) }
            }
        }

        // An app newly ignored stops counting at once; one no longer ignored counts
        // from now, as any new reading does.
        let ignored = PresentationPrefs.ignoredScreenAppIDs
        if ignored != ignoredScreenApps {
            ignoredScreenApps = ignored
            if let lastUsage, privacySensors.contains(.screen) {
                if let reason = sources.screen(lastUsage) {
                    model.read(.screen, reason)
                } else {
                    model.clear(.screen)
                }
            }
        }

        let slideshows = triggers.contains(.slideshow)
        if slideshows != watchesSlideshows {
            watchesSlideshows = slideshows
            if slideshows {
                sources.watchSlideshow { [weak self] app in self?.model.read(.slideshow, app.map { .slideshow($0) }) }
            } else {
                sources.stopSlideshow()
                model.read(.slideshow, nil)
            }
        }
        // Which kinds are held back may have changed too.
        render()
    }

    private func privacyRead(_ usage: PrivacyUsage) {
        lastUsage = usage
        model.read(.screen, privacySensors.contains(.screen) ? sources.screen(usage) : nil)
        model.read(.call, privacySensors.contains(.camera) ? sources.call(usage) : nil)
    }

    // MARK: Island

    /// The mark beside the notch while it is on, and the hold. As it ends, the island
    /// says how many alerts it held back, if any, once.
    private func render() {
        let center = ActivityCenter.shared
        let shown = model.shown
        let isHolding = (isRunning || model.preview != nil) && shown.isOn

        if isHolding {
            // Closest to the notch, before a Focus. It never brings up an island that
            // would otherwise hide: while presenting, the less of it the better.
            center.setIndicator(StatusIndicator(
                id: id, color: PresentationPalette.tint, order: -2, symbol: symbol, keepsIslandShown: false,
                label: (["Presentation Mode"] + shown.reasons.map(\.text)).joined(separator: " — "),
                detail: IndicatorDetail(id: id, title: title, maxWidth: PresentationIndicatorCard.maxWidth) { [model, weak self] in
                    AnyView(PresentationIndicatorCard(
                        model: model, center: .shared,
                        turnOff: { self?.turnOffFromCard() },
                        ignore: { self?.ignoreFromCard($0) }
                    ))
                }
            ))
        } else {
            center.removeIndicator(id: id)
        }

        let held = wasHolding && !isHolding ? heldSoFar : 0
        let kinds = isHolding ? PresentationPrefs.heldBackKinds : []
        if kinds != center.heldBack {
            withAnimation(.islandMorph) { center.heldBack = kinds }
        }
        // A share that has only just started keeps personal banners waiting, until it
        // counts or turns out to have been a moment's.
        let mayHold = isRunning && !isHolding && model.preview == nil && model.isPending ? PresentationPrefs.heldBackKinds : []
        if mayHold != center.mayHoldBack { center.mayHoldBack = mayHold }
        wasHolding = isHolding
        if held > 0 { announce(.summary(held)) }
    }

    /// How many alerts the island has held back since presenting began: none while it
    /// holds nothing back, whatever an earlier stretch left counted.
    private var heldSoFar: Int {
        let center = ActivityCenter.shared
        return wasHolding && !center.heldBack.isEmpty ? center.heldBackCount : 0
    }

    private func announce(_ announcement: PresentationAnnouncement, interruption: BannerInterruption? = nil) {
        let widths = PresentationBannerLayout.widths(for: announcement)
        ActivityCenter.shared.present(IslandBanner(
            id: Self.bannerID,
            style: .compact(leading: widths.leading, trailing: widths.trailing),
            duration: announcement.isSummary ? Self.summaryDuration : Self.bannerDuration,
            haptic: false,
            // The word afterwards is nice to know, never needed now: a Focus that asks
            // for quiet drops it. "On" and "Off" answer the person.
            interruption: interruption ?? (announcement.isSummary ? .passive : .active),
            leading: AnyView(PresentationBannerLeading(announcement: announcement)),
            trailing: AnyView(PresentationBannerTrailing(announcement: announcement))
        ))
    }
}

/// On, off or the other way, by hand: from a URL, the Shortcuts action or the card.
enum PresentationAction: String, CaseIterable, Sendable {
    case on, off, toggle
}

/// Where the feature's readings come from, and where the card's choice of apps to
/// ignore goes: the Mac and the defaults, or a test's stand-ins.
@MainActor
struct PresentationSources {
    /// Watches the privacy sensors given, calling back with the readings now and after
    /// every change.
    var watchPrivacy: (Set<PrivacyMonitor.Sensor>, @escaping (PrivacyUsage) -> Void) -> Void
    var stopPrivacy: () -> Void
    var watchSlideshow: (@escaping (SlideshowApp?) -> Void) -> Void
    var stopSlideshow: () -> Void
    /// What the readings say, for tests that name apps without bundles on disk.
    var screen: (PrivacyUsage) -> PresentationReason? = { PresentationSignals.screen(in: $0) }
    var call: (PrivacyUsage) -> PresentationReason? = { PresentationSignals.call(in: $0) }
    var saveIgnoredScreenApps: ([String]) -> Void = { PresentationPrefs.setIgnoredScreenApps($0) }

    static var live: PresentationSources {
        let slideshows = SlideshowWatcher()
        return PresentationSources(
            watchPrivacy: { sensors, report in
                PrivacyMonitor.shared.demand(sensors, for: "presentation", report: report)
            },
            stopPrivacy: { PrivacyMonitor.shared.withdraw("presentation") },
            watchSlideshow: { report in slideshows.start(report: report) },
            stopSlideshow: { slideshows.stop() }
        )
    }
}

/// This feature's options, shared by the feature and its settings. Unset keys read as
/// their defaults, the same ones the settings toggles declare.
enum PresentationPrefs {
    static func trigger(_ trigger: PresentationTrigger) -> String { "presentation.trigger.\(trigger.rawValue)" }
    static func heldBack(_ kind: PersonalContent) -> String { "presentation.hold.\(kind.rawValue)" }

    /// Every trigger is on at first.
    static let triggerDefault = true

    /// Held back at first: all but device names, which are rarely more than a first name
    /// and are worth seeing as headphones connect mid-call.
    static func heldBackDefault(_ kind: PersonalContent) -> Bool { kind != .devices }

    static var enabledTriggers: Set<PresentationTrigger> {
        Set(PresentationTrigger.allCases.filter { bool(trigger($0), default: triggerDefault) })
    }

    static var heldBackKinds: Set<PersonalContent> {
        Set(PersonalContent.allCases.filter { bool(heldBack($0), default: heldBackDefault($0)) })
    }

    /// Apps whose capture of the screen never turns it on: those that capture it all the
    /// time for a reason of their own, DisplayLink's driver for a monitor on a dock to
    /// begin with. Bundle identifiers; an app's helpers, whose identifiers sit under the
    /// app's, count as it.
    static let ignoredScreenApps = "presentation.ignoredScreenApps"
    static let defaultIgnoredScreenApps = ["com.displaylink"]

    static var ignoredScreenAppIDs: [String] {
        UserDefaults.standard.stringArray(forKey: ignoredScreenApps) ?? defaultIgnoredScreenApps
    }

    static func setIgnoredScreenApps(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: ignoredScreenApps)
    }

    /// Whether `bundleIdentifier` is one of `ids`, or a helper under one.
    static func matches(_ bundleIdentifier: String?, _ ids: [String]) -> Bool {
        guard let bundleIdentifier else { return false }
        return ids.contains { bundleIdentifier == $0 || bundleIdentifier.hasPrefix($0 + ".") }
    }

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}
