import AppKit
import SwiftUI

/// Shortcuts in the island, the way the iPhone shows them: while one runs, its icon
/// left of the notch and a spinner right of it, then a tick or a cross as it ends;
/// opened, its name, how long it has been going and, for a run Islet started, Stop.
/// What a shortcut Islet ran hands back comes up in a card. The home page keeps up to
/// six shortcuts a click away.
///
/// Runs go through the `shortcuts` command line tool (`ShortcutsTool`), which the Focus
/// toggle uses too. Runs started anywhere else are noticed through the Shortcuts
/// database (`ShortcutRunMonitor`), which needs Full Disk Access, as do the shortcuts'
/// icons; without it the feature shows names on a plain tile and only Islet's own runs.
/// Nothing is ever asked for: Settings says what access would add.
@MainActor
final class ShortcutsFeature: Feature {
    let id = "shortcuts"
    let title = "Shortcuts"
    let symbol = "square.2.layers.3d.fill"
    let summary = "Shortcuts as they run, beside the notch, and your favourites on the home page."

    /// A shortcut run from Islet may take a while (a download, a dialog waiting for an
    /// answer); one still going after ten minutes is stopped, so it cannot run on
    /// unseen for ever.
    static let runTimeout: TimeInterval = 10 * 60
    static let resultBannerID = "shortcuts.result"
    /// Long enough to read a few lines; resting the pointer on the card starts it again.
    static let resultDuration: TimeInterval = 15

    let catalogue: ShortcutCatalogue
    let runs = ShortcutRuns()
    private let tool: ShortcutsTool
    private let directory: URL
    private let notification: Notification.Name
    private let monitor: ShortcutRunMonitor
    /// The islands on screen, whose opened state decides when a result's card can show.
    private let islands: @MainActor () -> [IslandViewModel]
    private lazy var activity = ShortcutsActivity(runs: runs) { [weak self] id in self?.stopRun(id: id) }

    private var isRunning = false
    private var isTileShown = false
    /// The sizes the activity was last published with.
    private var publishedSizes: ShortcutsActivity.Sizes?
    private var signals: ShortcutsDatabaseSignals?
    private var observers: [NSObjectProtocol] = []
    /// Islet's own runs, by run id.
    private var tasks: [String: Task<Void, Never>] = [:]
    private var sampleTasks: [String: Task<Void, Never>] = [:]
    private var resultTask: Task<Void, Never>?
    private var resultBanner: IslandBanner?

    /// `directory` is the Shortcuts database's, and `notification` the name its saves
    /// are announced under; tests point them, and `islands`, at their own.
    init(
        tool: ShortcutsTool = .system,
        directory: URL = ShortcutsDatabase.defaultDirectory,
        notification: Notification.Name = ShortcutsDatabase.saveNotification,
        monitor: ShortcutRunMonitor? = nil,
        islands: @escaping @MainActor () -> [IslandViewModel] = { IslandManager.shared.controllers.values.map(\.model) }
    ) {
        self.tool = tool
        self.directory = directory
        self.notification = notification
        self.islands = islands
        catalogue = ShortcutCatalogue(tool: tool, directory: directory)
        self.monitor = monitor ?? ShortcutRunMonitor(directory: directory)
        runs.onChange = { [weak self] in self?.sync() }
        self.monitor.onStart = { [weak self] event in self?.startedElsewhere(event) }
        self.monitor.onEnd = { [weak self] identifier, state in self?.endedElsewhere(identifier, state) }
    }

    func start() {
        isRunning = true
        let defaults = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        // Back from Shortcuts, perhaps with a new shortcut, or from System Settings,
        // perhaps with Full Disk Access.
        let activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers = [defaults, activation]

        let signals = ShortcutsDatabaseSignals(
            directory: directory,
            notification: notification,
            onSave: { [weak self] save in self?.saved(save) },
            onFilesChanged: { [weak self] in self?.filesChanged() }
        )
        signals.start()
        self.signals = signals
        catalogue.onAccessChange = { [weak self] in self?.accessChanged() }
        catalogue.refresh(relist: true)
        sync()
    }

    func stop() {
        isRunning = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        signals?.stop()
        signals = nil
        monitor.stop()
        // Shortcuts Islet started are stopped with it, and say nothing more.
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        sampleTasks.values.forEach { $0.cancel() }
        sampleTasks.removeAll()
        resultTask?.cancel()
        resultTask = nil
        runs.removeAll { _ in true }
        catalogue.onAccessChange = {}
        catalogue.reset()
        sync()
        ActivityCenter.shared.dismissBanner(id: Self.resultBannerID)
        resultBanner = nil
    }

    func settingsView() -> AnyView? {
        AnyView(ShortcutsSettingsView(catalogue: catalogue))
    }

    /// Sample shortcuts, not the person's, and nothing runs: each goes through what a
    /// run looks like, from its start to its tick, cross or result.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Shortcut running") { [weak self] in
                self?.preview(.sampleLights, for: 8, ending: .succeeded)
            },
            FeaturePreview(title: "Shortcut finished") { [weak self] in
                self?.preview(.sampleWater, for: 2.5, ending: .succeeded)
            },
            FeaturePreview(title: "Shortcut failed") { [weak self] in
                self?.preview(.sampleResize, for: 2.5, ending: .failed(.failed))
            },
            FeaturePreview(title: "Shortcut with a result") { [weak self] in
                self?.preview(.sampleAgenda, for: 2, ending: .succeeded, output: .sampleAgenda)
            },
        ]
    }

    /// `islet://shortcuts/run?id=<identifier>` or `?name=<name>` runs a shortcut, as
    /// its button on the home tile does. The identifier is the one
    /// `shortcuts list --show-identifiers` prints.
    func handle(_ url: URL) -> Bool {
        guard url.path() == "/run" else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let identifier = value("id") {
            run(catalogue.shortcut(identifier: identifier)
                ?? ShortcutInfo(identifier: identifier.uppercased(), name: value("name") ?? "Shortcut"))
        } else if let name = value("name") {
            // By identifier where the name is known, so it is the shortcut the list
            // shows; otherwise the tool looks the name up itself.
            run(catalogue.shortcut(named: name) ?? ShortcutInfo(identifier: nil, name: name))
        } else {
            return false
        }
        return true
    }

    // MARK: Running

    /// Runs `shortcut` from Islet. A second click while it is still going is taken as
    /// impatience rather than a wish for two runs.
    func run(_ shortcut: ShortcutInfo) {
        guard !runs.running.contains(where: { $0.origin == .islet && $0.shortcut.id == shortcut.id }) else { return }
        let id = UUID().uuidString
        runs.begin(ShortcutRun(id: id, shortcut: shortcut, startedAt: Date(), origin: .islet))
        tasks[id] = Task { [weak self, tool] in
            // SIGINT first, so Stop asks the runner to cancel the shortcut rather than
            // cutting the tool off.
            let result = await tool.run(shortcut.target, timeout: Self.runTimeout, capturesOutput: true, interruptsFirst: true)
            self?.finished(id: id, shortcut: shortcut, result: result)
        }
    }

    private func finished(id: String, shortcut: ShortcutInfo, result: ShortcutRunResult) {
        tasks[id] = nil
        // Asked for the shortcut's output, the tool might fail after the shortcut itself
        // ran to the end (in writing the output out, say). The shortcut's own record says
        // which, where it can be read.
        if case .failed(.failed) = result, let identifier = shortcut.identifier, catalogue.access == .granted,
           let started = runs.run(id: id)?.startedAt {
            let directory = directory
            let recorded = {
                await Task.detached(priority: .utility) {
                    ShortcutsDatabase.commandLineOutcome(identifier: identifier, since: started.addingTimeInterval(-2), directory: directory)
                }.value
            }
            Task { [weak self] in
                var state = await recorded()
                // The outcome is written a moment after the runner finishes; a record
                // still open is given that moment.
                if case .value(.running?) = state {
                    try? await Task.sleep(for: .seconds(0.4))
                    state = await recorded()
                }
                let ranToTheEnd = if case .value(.succeeded?) = state { true } else { false }
                self?.settle(id: id, shortcut: shortcut, result: ranToTheEnd ? .succeeded(nil) : result)
            }
            return
        }
        settle(id: id, shortcut: shortcut, result: result)
    }

    private func settle(id: String, shortcut: ShortcutInfo, result: ShortcutRunResult) {
        switch result {
        case .succeeded(let output):
            guard runs.finish(id: id, phase: .succeeded) else { return }
            if let output, isRunning { presentResult(output, for: shortcut) }
        case .failed(let failure):
            runs.finish(id: id, phase: .failed(failure))
        case .cancelled:
            runs.finish(id: id, phase: .stopped)
        }
    }

    /// Stop, from the opened island. Only Islet's own runs (and samples) offer it.
    private func stopRun(id: String) {
        guard let run = runs.run(id: id), run.canStop else { return }
        switch run.origin {
        case .islet:
            // The task ends with `.cancelled` once the tool has been told to stop.
            tasks[id]?.cancel()
        case .sample:
            sampleTasks[id]?.cancel()
            sampleTasks[id] = nil
            runs.finish(id: id, phase: .stopped)
        case .elsewhere:
            break
        }
    }

    // MARK: Runs started elsewhere

    private var showsRuns: Bool { ShortcutsPrefs.bool(ShortcutsPrefs.showRuns, default: true) }
    private var showsOutsideRuns: Bool { ShortcutsPrefs.bool(ShortcutsPrefs.showOutsideRuns, default: true) }

    /// The monitor runs only while its runs would be shown, and the database can be read.
    private func syncMonitor() {
        let wanted = isRunning && showsRuns && showsOutsideRuns && catalogue.access == .granted
        if wanted, !monitor.isRunning {
            monitor.start()
        } else if !wanted, monitor.isRunning {
            monitor.stop()
            runs.removeAll { if case .elsewhere = $0.origin { true } else { false } }
        }
    }

    private func startedElsewhere(_ event: ShortcutRunEvent) {
        guard var shortcut = event.shortcut else { return }
        // The database knows the shortcut; the list knows its folder.
        if let identifier = shortcut.identifier, let listed = catalogue.shortcut(identifier: identifier) {
            shortcut.folder = listed.folder
        }
        runs.begin(ShortcutRun(
            id: Self.elsewhereID(event.identifier), shortcut: shortcut,
            startedAt: event.date ?? Date(), origin: .elsewhere(source: event.source)
        ))
    }

    private func endedElsewhere(_ identifier: String, _ state: ShortcutRunEvent.State?) {
        let phase: ShortcutRun.Phase = switch state {
        case .succeeded?: .succeeded
        case .failed?: .failed(nil)
        case .running?, nil: .vanished
        }
        runs.finish(id: Self.elsewhereID(identifier), phase: phase)
    }

    private static func elsewhereID(_ identifier: String) -> String { "elsewhere." + identifier }

    // MARK: Database

    private func saved(_ save: ShortcutsDatabaseSave) {
        guard isRunning else { return }
        if save.touchesShortcuts { catalogue.databaseChanged() }
        monitor.saved(runEvents: save.runEvents)
    }

    private func filesChanged() {
        guard isRunning else { return }
        catalogue.databaseChanged()
        monitor.filesChanged()
    }

    private func refresh() {
        guard isRunning else { return }
        catalogue.refresh(relist: true)
        signals?.rearmIfNeeded()
    }

    private func accessChanged() {
        if catalogue.access == .granted { signals?.rearmIfNeeded() }
        syncMonitor()
    }

    private func settingsChanged() {
        syncMonitor()
        sync()
    }

    // MARK: Island

    /// Puts the activity and the home tile in line with the runs and the settings.
    private func sync() {
        let center = ActivityCenter.shared

        // A preview shows whatever the settings say: it is there to be seen.
        let wantsActivity = runs.isActive && (runs.hasSamples || (isRunning && showsRuns))
        if wantsActivity {
            let sizes = activity.sizes
            if !center.isShowing(id: activity.id) || sizes != publishedSizes {
                publishedSizes = sizes
                center.show(activity)
            }
        } else if center.isShowing(id: activity.id) {
            center.end(id: activity.id)
            publishedSizes = nil
        }

        guard isRunning != isTileShown else { return }
        isTileShown = isRunning
        if isRunning {
            center.setHomeWidget(HomeWidget(
                id: id, order: 47, view: AnyView(ShortcutsHomeTile(
                    catalogue: catalogue, runs: runs,
                    run: { [weak self] shortcut in self?.run(shortcut) },
                    choose: { ShortcutsSettingsView.open() }
                ))
            ))
        } else {
            center.removeHomeWidget(id: id)
        }
    }

    /// How often a result waiting on an island opened elsewhere looks again.
    static let resultRecheck: TimeInterval = 0.5

    /// What a shortcut gave back, in a card, once its tick has shown.
    ///
    /// The opened island draws no banners, so a card presented under it would spend
    /// its time unseen. An island open on the home page or on the run itself, where
    /// the tick has just shown, closes for the card: that is where a shortcut run from
    /// the home tile leaves the pointer, and the card is what the click was for. One
    /// open on anything else (music, a timer) is not taken from under the pointer: the
    /// card waits for it to close, and only then starts its time.
    private func presentResult(_ output: ShortcutOutput, for shortcut: ShortcutInfo) {
        resultTask?.cancel()
        resultTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ShortcutRuns.settleDuration))
            while !Task.isCancelled, self?.isOpenOnAnotherPage == true {
                try? await Task.sleep(for: .seconds(Self.resultRecheck))
            }
            guard let self, !Task.isCancelled else { return }
            resultTask = nil
            for island in islands() where island.isExpanded { island.collapse() }
            let center = ActivityCenter.shared
            let banner = IslandBanner(
                id: Self.resultBannerID,
                style: .card(width: ShortcutResultLayout.width, height: ShortcutResultLayout.height(for: output)),
                duration: Self.resultDuration,
                content: AnyView(ShortcutResultCard(shortcut: shortcut, output: output) { [weak self] in
                    self?.keepResult()
                } dismiss: {
                    center.dismissBanner(id: Self.resultBannerID)
                })
            )
            resultBanner = banner
            center.present(banner)
        }
    }

    /// Whether an island is open on a page other than home or the runs'.
    private var isOpenOnAnotherPage: Bool {
        islands().contains { island in
            island.isExpanded && island.resolvedFocus != IslandViewModel.homeFocus && island.resolvedFocus != activity.id
        }
    }

    /// The pointer is on the result card: its time starts again, so it does not go
    /// while being read or copied.
    private func keepResult() {
        guard let resultBanner, ActivityCenter.shared.banner?.id == Self.resultBannerID else { return }
        ActivityCenter.shared.present(resultBanner)
    }

    // MARK: Previews

    private func preview(
        _ shortcut: ShortcutInfo, for seconds: TimeInterval, ending phase: ShortcutRun.Phase, output: ShortcutOutput? = nil
    ) {
        let id = "sample." + UUID().uuidString
        runs.begin(ShortcutRun(id: id, shortcut: shortcut, startedAt: Date(), origin: .sample))
        sampleTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            sampleTasks[id] = nil
            guard runs.finish(id: id, phase: phase) else { return }
            if let output { presentResult(output, for: shortcut) }
        }
    }
}

@MainActor
final class ShortcutsActivity: IslandActivity {
    /// What the island's size depends on; a change re-publishes the activity.
    struct Sizes: Equatable {
        var trailing: CGFloat?
    }

    let id = "shortcuts"
    let symbol = "square.2.layers.3d.fill"
    let runs: ShortcutRuns
    let stop: (String) -> Void

    init(runs: ShortcutRuns, stop: @escaping (String) -> Void) {
        self.runs = runs
        self.stop = stop
    }

    /// Wider on the right while several run, for their count beside the spinner.
    var sizes: Sizes { Sizes(trailing: runs.count > 1 ? ShortcutsLayout.countedTrailingWidth : nil) }

    var compactTrailingWidth: CGFloat? { sizes.trailing }
    var expandedHeight: CGFloat { ShortcutsLayout.expandedHeight }

    func compactLeading() -> AnyView { AnyView(ShortcutsCompactLeading(runs: runs)) }
    func compactTrailing() -> AnyView { AnyView(ShortcutsCompactTrailing(runs: runs)) }
    func minimal() -> AnyView { AnyView(ShortcutsMinimal(runs: runs)) }
    func expanded() -> AnyView { AnyView(ShortcutsExpanded(runs: runs, stop: stop)) }
}

/// The feature's preference keys, shared by the feature and its settings. Unset keys
/// read as their defaults, the same ones the settings toggles declare.
enum ShortcutsPrefs {
    static let showRuns = "shortcuts.showRuns"
    static let showOutsideRuns = "shortcuts.showOutsideRuns"
    /// The home tile's shortcuts: their identifiers, one per line, in order.
    static let pinned = "shortcuts.pinned"
    static let pinnedLimit = 6

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static func identifiers(_ stored: String) -> [String] {
        var seen = Set<String>()
        let identifiers = stored
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return Array(identifiers.prefix(pinnedLimit))
    }

    static func stored(_ identifiers: [String]) -> String {
        identifiers.joined(separator: "\n")
    }
}

/// Sample shortcuts for previews, made up, with icons as Shortcuts would draw them.
extension ShortcutInfo {
    static let sampleLights = ShortcutInfo(
        identifier: "0B5E1C2A-7F3D-4E8B-9A61-2C4D5E6F7A8B", name: "Morning Lights",
        icon: ShortcutIcon(symbol: "lightbulb.fill", colour: ShortcutPalette.yellow)
    )
    static let sampleWater = ShortcutInfo(
        identifier: "5D7A2F10-3C4B-4E61-8F92-7A6B5C4D3E2F", name: "Log Water",
        icon: ShortcutIcon(symbol: "drop.fill", colour: ShortcutPalette.cyan)
    )
    static let sampleResize = ShortcutInfo(
        identifier: "9E8D7C6B-5A49-4382-A716-B5C4D3E2F1A0", name: "Resize Images",
        icon: ShortcutIcon(symbol: "photo.fill", colour: ShortcutPalette.orange)
    )
    static let sampleAgenda = ShortcutInfo(
        identifier: "3A2B1C0D-9E8F-4A7B-B6C5-D4E3F2A1B0C9", name: "Today's Agenda",
        icon: ShortcutIcon(symbol: "calendar", colour: ShortcutPalette.red)
    )
}

extension ShortcutOutput {
    static let sampleAgenda = ShortcutOutput(text: """
        9:30  Stand-up
        11:00  Design review with the platform team
        13:00  Lunch
        16:30  Pick up the dry cleaning
        """)
}
