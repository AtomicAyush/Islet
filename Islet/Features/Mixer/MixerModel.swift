import AppKit
import Observation

enum MixerPrefs {
    static let showWhenSeveral = "mixer.showWhenSeveral"
    static let showWhenSeveralDefault = true
    /// Levels other than 100%, by app id.
    static let levels = "mixer.levels"
    /// Ids of muted apps.
    static let muted = "mixer.muted"
}

/// The apps producing sound and the level each should play at.
///
/// Levels are remembered by app, so an app turned down stays down the next time it
/// plays. They are only applied once macOS allows Islet to record system audio, and
/// only a volume change — a slider moved, a mute pressed — ever asks for that.
@MainActor
@Observable
final class MixerModel {
    /// Half as loud again as the app plays by itself.
    static let maximum = 1.5
    /// Preview apps' ids start with this; nothing about them is saved or applied.
    static let previewPrefix = "preview."

    enum Note: Equatable {
        case unsupported
        case requesting
        case denied
        /// Apps, by name, whose level could not be applied.
        case failed([String])
    }

    /// Apps producing sound, in the order they started: the real ones, or a preview's.
    var apps: [MixerSource] { previewApps ?? live }
    private(set) var access: MixerAccess = .unknown
    private(set) var failed: Set<String> = []

    private var live: [MixerSource] = []
    private var previewApps: [MixerSource]?
    /// Levels other than 100%; while a slider is dragged, its app's whatever it is,
    /// so the tap is not dropped and remade as the level passes 100%.
    private var levels: [String: Double] = [:]
    private var muted: Set<String> = []

    /// Called whenever the apps, or what the page says under them, change.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let engine = MixerEngine()
    @ObservationIgnored private var isRunning = false
    /// Bumped on every start and stop, so an answer meant for an earlier run is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    /// Set when macOS offers no way to ask ahead: the first volume change makes a tap,
    /// and macOS asks then.
    @ObservationIgnored private var asksWithFirstTap = false

    var isPreviewing: Bool { previewApps != nil }

    var hasCustomLevels: Bool {
        levels.keys.contains { !Self.isPreview($0) } || muted.contains { !Self.isPreview($0) }
    }

    /// What the opened island says under the apps, if anything.
    var note: Note? {
        switch access {
        case .unsupported: return .unsupported
        case .requesting: return .requesting
        case .denied: return .denied
        case .unknown, .granted:
            let names = apps.filter { failed.contains($0.id) }.map(\.name)
            return names.isEmpty ? nil : .failed(names)
        }
    }

    // MARK: Running

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        load()
        guard #available(macOS 14.2, *) else {
            access = .unsupported
            return
        }
        let generation = self.generation
        engine.start { [weak self] reading in
            guard let self, self.isRunning, self.generation == generation else { return }
            self.receive(reading)
        }
        push()
        refreshAccess()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        engine.stop()
        live = []
        failed = []
        // Looked up afresh on the next start, before any remembered level is applied:
        // permission may be withdrawn in between, and a tap made without it silences
        // its app. A question still open is asked again, if need be, by the next change.
        if access != .unsupported { access = .unknown }
    }

    /// Looks again at whether recording is allowed, which may have changed in System
    /// Settings. Never asks.
    func refreshAccess() {
        guard isRunning else { return }
        guard #available(macOS 14.2, *) else { return }
        let generation = self.generation
        engine.checkAccess { [weak self] result in
            guard let self, self.isRunning, self.generation == generation,
                  self.access != .requesting, self.access != result else { return }
            self.access = result
            self.push()
            self.onChange()
        }
    }

    private func receive(_ reading: MixerReading) {
        if live != reading.playing { live = reading.playing }
        let failed = reading.failed.intersection(reading.playing.map(\.id))
        if self.failed != failed { self.failed = failed }
        if reading.refused {
            if asksWithFirstTap, access != .denied {
                access = .denied
                push()
            } else {
                refreshAccess()
            }
        }
        onChange()
    }

    // MARK: Levels

    /// 0...`maximum`, 1 being as the app plays by itself. A muted app keeps its level
    /// for when it is unmuted.
    func level(for app: MixerSource) -> Double {
        levels[app.id] ?? 1
    }

    func isMuted(_ app: MixerSource) -> Bool {
        muted.contains(app.id)
    }

    /// `isFinal` is set when a drag ends: the level is saved then, and a return to
    /// 100% hands the app's sound back to its normal path.
    func setLevel(_ value: Double, for app: MixerSource, isFinal: Bool) {
        let value = min(max(value, 0), Self.maximum)
        levels[app.id] = value
        if muted.contains(app.id) { muted.remove(app.id) }
        if isFinal, abs(value - 1) < 0.001 { levels[app.id] = nil }
        guard !Self.isPreview(app.id) else { return }
        if isFinal { save() }
        levelChanged(isFinal: isFinal)
        push(retrying: isFinal ? app.id : nil)
    }

    func toggleMute(_ app: MixerSource) {
        if muted.contains(app.id) { muted.remove(app.id) } else { muted.insert(app.id) }
        guard !Self.isPreview(app.id) else { return }
        save()
        levelChanged(isFinal: true)
        push(retrying: app.id)
    }

    func resetAll() {
        levels = levels.filter { Self.isPreview($0.key) }
        muted = muted.filter { Self.isPreview($0) }
        save()
        push()
    }

    /// A volume change is the one thing that may ask for permission. Once refused, a
    /// finished change looks again, in case it has since been allowed in Settings.
    private func levelChanged(isFinal: Bool) {
        switch access {
        case .unknown where !asksWithFirstTap: askForAccess()
        case .denied where isFinal: refreshAccess()
        default: break
        }
    }

    private func askForAccess() {
        access = .requesting
        onChange()
        let generation = self.generation
        engine.requestAccess { [weak self] granted in
            guard let self, self.isRunning, self.generation == generation else { return }
            switch granted {
            case true?: self.access = .granted
            case false?: self.access = .denied
            case nil:
                self.access = .unknown
                self.asksWithFirstTap = true
            }
            self.push()
            self.onChange()
        }
    }

    /// Tells the engine every level to apply; a muted app plays at 0.
    private func push(retrying id: String? = nil) {
        guard isRunning, access != .unsupported else { return }
        var applied: [String: Float] = [:]
        for (id, level) in levels where !Self.isPreview(id) { applied[id] = Float(level) }
        for id in muted where !Self.isPreview(id) { applied[id] = 0 }
        let allowed = access == .granted || (access == .unknown && asksWithFirstTap)
        engine.apply(levels: applied, allowed: allowed, retrying: id)
    }

    private func load() {
        let defaults = UserDefaults.standard
        let saved = (defaults.dictionary(forKey: MixerPrefs.levels) as? [String: Double]) ?? [:]
        levels = levels.filter { Self.isPreview($0.key) }
            .merging(saved.mapValues { min(max($0, 0), Self.maximum) }) { current, _ in current }
        muted = muted.filter { Self.isPreview($0) }.union(defaults.stringArray(forKey: MixerPrefs.muted) ?? [])
    }

    private func save() {
        let defaults = UserDefaults.standard
        let kept = levels.filter { !Self.isPreview($0.key) }
        let keptMuted = muted.filter { !Self.isPreview($0) }.sorted()
        if kept.isEmpty {
            defaults.removeObject(forKey: MixerPrefs.levels)
        } else {
            defaults.set(kept, forKey: MixerPrefs.levels)
        }
        if keptMuted.isEmpty {
            defaults.removeObject(forKey: MixerPrefs.muted)
        } else {
            defaults.set(keptMuted, forKey: MixerPrefs.muted)
        }
    }

    // MARK: Icons

    /// Looked up once per app.
    func icon(for app: MixerSource) -> NSImage {
        if let icon = icons[app.id] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: app.bundlePath)
        icons[app.id] = icon
        return icon
    }

    // MARK: Previews

    /// Shows sample apps in place of the real ones. Their levels live only as long as
    /// the preview, and touch no sound.
    func beginPreview(_ apps: [MixerSource], levels sample: [String: Double], muted sampleMuted: Set<String>) {
        clearPreviewLevels()
        previewApps = apps
        levels.merge(sample) { _, new in new }
        muted.formUnion(sampleMuted)
        onChange()
    }

    func endPreview() {
        guard previewApps != nil else { return }
        previewApps = nil
        clearPreviewLevels()
        onChange()
    }

    private func clearPreviewLevels() {
        levels = levels.filter { !Self.isPreview($0.key) }
        muted = muted.filter { !Self.isPreview($0) }
    }

    private static func isPreview(_ id: String) -> Bool {
        id.hasPrefix(previewPrefix)
    }
}
