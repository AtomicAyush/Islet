import CoreAudio
import Foundation

/// What Islet changed on one microphone to mute it, and what it found there, so that it
/// can be put back: by Unmute, as the feature stops or Islet quits, or, after a crash,
/// the next time Islet starts.
struct MicMuteRecord: Codable, Equatable, Sendable {
    /// The device's UID, which outlives its ID across reconnections and audio server
    /// restarts.
    var uid: String
    /// The input's own mute as Islet found it, where Islet muted with it, or wrote to
    /// it before turning to the levels.
    var mute: Bool?
    /// The input levels as Islet found them, where it turned them right down: the
    /// microphone's silence, where there are any.
    var levels: [Level] = []

    struct Level: Codable, Equatable, Sendable {
        var element: AudioObjectPropertyElement
        var level: Float32
    }

    var isEmpty: Bool { mute == nil && levels.isEmpty }
}

/// Where the records are kept between launches: Islet's defaults, or memory for tests.
protocol MicMuteStore: AnyObject, Sendable {
    func load() -> [MicMuteRecord]
    func save(_ records: [MicMuteRecord])
}

final class DefaultsMicMuteStore: MicMuteStore, @unchecked Sendable {
    static let key = "micMute.changes"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [MicMuteRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([MicMuteRecord].self, from: data)) ?? []
    }

    func save(_ records: [MicMuteRecord]) {
        if records.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// How a microphone is muted.
enum MicMuteWay: Equatable, Sendable {
    /// With its own mute, which puts nothing else out of place.
    case mute
    /// By turning its input level right down, for a microphone with no mute of its own.
    case level
}

/// The Mac's input, as Mic Mute shows it.
struct MicMuteSnapshot: Equatable, Sendable {
    /// Whether Islet's mute is on.
    var isMuted = false
    /// The Mac's input now, or `nil` with no microphone at all.
    var microphone: Microphone?

    struct Microphone: Equatable, Sendable {
        var name: String
        /// How Islet mutes it, or `nil` where it cannot.
        var way: MicMuteWay?
    }
}

/// What came of a request, or of something changing without one, for the island to say.
enum MicMuteEvent: Equatable, Sendable {
    case muted
    case unmuted
    /// Islet's mute came off without Islet: the microphone was unmuted or turned up
    /// elsewhere, by its own button, another app or Sound settings.
    case unmutedElsewhere
    /// The microphone named, the Mac's input or the one it has just moved to, has no
    /// mute or level that silences it. Islet's mute is off.
    case cannotMute(String?)
}

/// Mutes the Mac's input, for every app recording from it, and keeps it muted as the
/// input moves from one microphone to another, until it is unmuted.
///
/// A microphone is muted with its own mute where it has one that can be set and holds.
/// Failing that, its input level goes right down, on its main channel or on each one,
/// but only where that is silence: a level whose floor the device puts above
/// `silentFloor` is a gain, still hearing the room at zero, and such a microphone is
/// said to be one Islet cannot mute rather than shown muted while it hears. What was
/// found is recorded, and saved, before anything is changed, so that however Islet
/// ends, the microphone can be put back.
///
/// Putting back only undoes what is still as Islet left it: a mute turned off or a
/// level turned up since then was someone else's doing, and stays. The same goes while
/// muted: the held microphone is followed, and if it is unmuted or turned up elsewhere
/// (its own button, another app, Sound settings), Islet's mute follows, off, puts back
/// the rest of what it changed, and says so, rather than show a microphone as muted
/// while it hears.
///
/// Nothing here opens a microphone, so nothing here lights the orange dot: an app
/// recording keeps its microphone open and hears silence, and macOS keeps its dot lit.
/// Every Core Audio call is made on the engine's own serial queue.
final class MicMuteEngine: @unchecked Sendable {
    typealias Report = @MainActor @Sendable (MicMuteSnapshot, MicMuteEvent?) -> Void

    /// A level at or below this is taken as right down.
    static let silentLevel: Float32 = 0.001
    /// A level whose floor is above this many decibels is not silenced by turning it
    /// right down. The MacBook's own microphone bottoms out at −12 dB.
    static let silentFloor: Float32 = -60
    /// The longest `stop()` waits for microphones to be put back. Islet may be quitting,
    /// and what is left undone is put back when it next starts.
    static let stopWait: DispatchTimeInterval = .seconds(2)

    let hardware: any MicHardware
    private let store: any MicMuteStore
    private let queue = DispatchQueue(label: "Islet.MicMute", qos: .userInitiated)

    // Confined to `queue`.
    private var report: Report?
    private var isMuted = false
    private var records: [MicMuteRecord] = []
    /// The microphone held muted, and followed for changes made elsewhere.
    private var held: Held?
    private var lastSnapshot: MicMuteSnapshot?

    private struct Held: Equatable {
        var id: AudioObjectID
        var uid: String
    }

    /// Puts back what an Islet that crashed or was killed while muted left behind; a
    /// microphone not connected now is put back once it is, while the engine runs.
    init(hardware: any MicHardware, store: any MicMuteStore) {
        self.hardware = hardware
        self.store = store
        queue.async { [self] in
            records = store.load()
            if !records.isEmpty { putBack(explicitly: false) }
        }
    }

    // MARK: Running

    /// Listens, then reads the input once: listening first means no change can slip in
    /// between.
    func start(report: @escaping Report) {
        queue.async { [self] in
            guard self.report == nil else { return }
            self.report = report
            listen()
            lastSnapshot = nil
            settle()
        }
    }

    /// Unmutes, putting every microphone back as Islet found it, and stops listening.
    /// Waits for that, up to `stopWait`, since Islet may be quitting.
    func stop() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            report = nil
            isMuted = false
            held = nil
            hardware.stopListening()
            putBack(explicitly: false)
            done.signal()
        }
        _ = done.wait(timeout: .now() + Self.stopWait)
    }

    /// Mutes or unmutes the Mac's input. `completion` gets what came of it, or `nil`
    /// when the engine is not running.
    func setMuted(_ muted: Bool, completion: @escaping @MainActor @Sendable (MicMuteEvent?) -> Void) {
        queue.async { [self] in
            var event: MicMuteEvent?
            if report != nil {
                event = muted ? mute() : unmute()
                publish(nil)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(event) }
            }
        }
    }

    // MARK: Muting

    private func mute() -> MicMuteEvent {
        isMuted = true
        guard let device = hardware.defaultInput(), let uid = hardware.uid(of: device) else {
            // No microphone at all: nothing hears, and the next to arrive is muted.
            hold(nil)
            return .muted
        }
        guard silence(device, uid: uid) else {
            // Nothing is muted, so nothing stays changed.
            isMuted = false
            hold(nil)
            putBack(explicitly: false)
            return .cannotMute(hardware.name(of: device))
        }
        hold(Held(id: device, uid: uid))
        // One the input left while it was not connected, come back since.
        putBack(explicitly: false, except: uid)
        return .muted
    }

    /// Unmute leaves the microphone on, even one that was muted already when Islet
    /// muted it: that is what the person asked for.
    private func unmute() -> MicMuteEvent {
        isMuted = false
        hold(nil)
        putBack(explicitly: true)
        return .unmuted
    }

    /// Silences `device`: with its own mute where it has one that holds, else by
    /// turning its levels right down. What it finds is recorded and saved first. A
    /// record already there, from a mute not yet put back (the microphone went away
    /// and came back, or the audio server restarted), keeps what was found the first
    /// time rather than Islet's own silence. Returns whether the microphone is silent.
    private func silence(_ device: AudioObjectID, uid: String) -> Bool {
        var record = records.first { $0.uid == uid } ?? MicMuteRecord(uid: uid)
        var wroteMute = false

        if record.levels.isEmpty, let found = hardware.mute(of: device) {
            if record.mute == nil { record.mute = found }
            keep(record)
            if found { return true }
            wroteMute = hardware.setMute(true, of: device)
            if wroteMute, hardware.mute(of: device) == true { return true }
            // Refused, or taken and not heeded (or not yet: a Bluetooth microphone may
            // take a moment): the levels instead. A mute that was taken stays on the
            // record, so that it is undone too should it hold after all.
            if !wroteMute { record.mute = nil }
        }

        let controls = hardware.levelControls(of: device)
        let silences = !controls.isEmpty && controls.allSatisfy { ($0.floorDecibels ?? -.infinity) <= Self.silentFloor }
        if record.levels.isEmpty, silences {
            let found = controls.compactMap { control in
                hardware.level(of: device, element: control.element).map { MicMuteRecord.Level(element: control.element, level: $0) }
            }
            // Every channel or none: one left out would go on hearing.
            if found.count == controls.count { record.levels = found }
        }
        guard silences, !record.levels.isEmpty else {
            abandon(record, on: device, undoingMute: wroteMute)
            return false
        }
        keep(record)
        for saved in record.levels {
            _ = hardware.setLevel(0, of: device, element: saved.element)
        }
        if isSilent(device, record) == true { return true }
        abandon(record, on: device, undoingMute: wroteMute)
        return false
    }

    /// Nothing silences `device`: whatever went down on the way goes back up, the mute
    /// Islet wrote comes off, and the microphone is forgotten.
    private func abandon(_ record: MicMuteRecord, on device: AudioObjectID, undoingMute: Bool) {
        if undoingMute { _ = hardware.setMute(false, of: device) }
        restore(MicMuteRecord(uid: record.uid, levels: record.levels), on: device, explicitly: false)
        forget(record.uid)
    }

    /// Whether `device` is still as Islet left it: its levels right down, where Islet
    /// turned them down, or else its mute on. `nil` where a read fails and none that
    /// worked shows it hearing: that proves nothing either way, since a microphone going
    /// away or changing its Bluetooth profile fails reads for a moment while it may
    /// still be muted.
    private func isSilent(_ device: AudioObjectID, _ record: MicMuteRecord) -> Bool? {
        guard record.levels.isEmpty else {
            let levels = record.levels.map { hardware.level(of: device, element: $0.element) }
            if levels.contains(where: { ($0 ?? 0) > Self.silentLevel }) { return false }
            return levels.contains(nil) ? nil : true
        }
        guard record.mute != nil else { return false }
        return hardware.mute(of: device)
    }

    /// Puts back what `record` says Islet changed, where it is still as Islet left it.
    /// A microphone found muted stays muted, unless `explicitly`, for Unmute.
    private func restore(_ record: MicMuteRecord, on device: AudioObjectID, explicitly: Bool) {
        if let found = record.mute, explicitly || !found, hardware.mute(of: device) == true {
            _ = hardware.setMute(false, of: device)
        }
        for saved in record.levels {
            guard let now = hardware.level(of: device, element: saved.element), now <= Self.silentLevel else { continue }
            _ = hardware.setLevel(saved.level, of: device, element: saved.element)
        }
    }

    /// Puts back every microphone Islet changed that is connected, bar `uid`'s, and
    /// forgets them; one not connected keeps its record until it is.
    private func putBack(explicitly: Bool, except uid: String? = nil) {
        let before = records
        records = records.filter { record in
            guard record.uid != uid, let device = hardware.device(uid: record.uid) else { return true }
            restore(record, on: device, explicitly: explicitly)
            return false
        }
        if records != before { store.save(records) }
    }

    private func keep(_ record: MicMuteRecord) {
        var next = records.filter { $0.uid != record.uid }
        if !record.isEmpty { next.append(record) }
        guard next != records else { return }
        records = next
        store.save(records)
    }

    private func forget(_ uid: String) {
        guard records.contains(where: { $0.uid == uid }) else { return }
        records.removeAll { $0.uid == uid }
        store.save(records)
    }

    private func hold(_ next: Held?) {
        held = next
        hardware.follow(next?.id)
    }

    // MARK: Changes

    private func listen() {
        hardware.listen(on: queue) { [weak self] change in self?.heard(change) }
    }

    private func heard(_ change: MicChange) {
        guard report != nil else { return }
        switch change {
        case .devices:
            settle()
        case .level:
            heldChanged()
        case .restarted:
            // The audio server started afresh: every listener it knew is gone, and its
            // devices may be back under new IDs, their mute and levels as it
            // remembers them. The microphone is muted again from its record.
            hold(nil)
            hardware.stopListening()
            listen()
            settle()
        }
    }

    /// Brings things in line with the Mac's input as it is now. While muted, the input
    /// is held muted, a new one muted in its turn, and every other microphone Islet
    /// changed is put back; while not, all of them are. The input moving to a
    /// microphone that cannot be muted ends the mute, and says so.
    private func settle() {
        var event: MicMuteEvent?
        if isMuted {
            if let device = hardware.defaultInput(), let uid = hardware.uid(of: device) {
                let input = Held(id: device, uid: uid)
                if input != held {
                    if silence(device, uid: uid) {
                        hold(input)
                    } else {
                        isMuted = false
                        hold(nil)
                        event = .cannotMute(hardware.name(of: device))
                    }
                }
            } else {
                // No microphone at all: nothing hears, and the next to arrive is muted.
                hold(nil)
            }
        }
        putBack(explicitly: false, except: isMuted ? held?.uid : nil)
        publish(event)
    }

    /// The held microphone's mute or level changed. Islet's own writes leave it silent;
    /// anything else that unmuted it is followed, and left as it is. What Islet changed
    /// that is still as it left it goes back, though: the other channels of one turned
    /// up on a single channel, or a mute that held late, after Islet had turned to the
    /// levels, would otherwise stay down with nothing left on record to undo them.
    ///
    /// A microphone that has gone, or whose reads fail, is not taken for unmuted: the
    /// device list's own change settles that, and the record stays for its return.
    private func heldChanged() {
        guard isMuted, let held, let record = records.first(where: { $0.uid == held.uid }),
              hardware.uid(of: held.id) == held.uid,
              isSilent(held.id, record) == false
        else { return }
        isMuted = false
        hold(nil)
        restore(record, on: held.id, explicitly: false)
        forget(held.uid)
        publish(.unmutedElsewhere)
    }

    // MARK: Reporting

    private func publish(_ event: MicMuteEvent?) {
        guard let report else { return }
        let snapshot = read()
        guard snapshot != lastSnapshot || event != nil else { return }
        lastSnapshot = snapshot
        DispatchQueue.main.async {
            MainActor.assumeIsolated { report(snapshot, event) }
        }
    }

    private func read() -> MicMuteSnapshot {
        guard let device = hardware.defaultInput(), let uid = hardware.uid(of: device) else {
            return MicMuteSnapshot(isMuted: isMuted)
        }
        let way: MicMuteWay?
        if isMuted, let record = records.first(where: { $0.uid == uid }) {
            way = record.levels.isEmpty ? .mute : .level
        } else if hardware.mute(of: device) != nil {
            way = .mute
        } else {
            let controls = hardware.levelControls(of: device)
            way = !controls.isEmpty && controls.allSatisfy { ($0.floorDecibels ?? -.infinity) <= Self.silentFloor } ? .level : nil
        }
        return MicMuteSnapshot(isMuted: isMuted, microphone: .init(name: hardware.name(of: device) ?? "Microphone", way: way))
    }
}
