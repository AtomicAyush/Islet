import AppKit
import CoreAudio
import Observation
import SwiftUI

/// Where the Mac's sound plays, for the player's output button and panel: the
/// outputs the Sound menu would list, which one is in use, its volume while the panel
/// is open, and switching to another.
///
/// Everything comes from Core Audio listeners, so nothing runs while nothing changes.
/// The checkmark is only ever where Core Audio says sound is going: a switch is not
/// taken as done until the device list has been read back after it.
///
/// AirPlay receivers are not listed. macOS gives the list, and the way to send the
/// Mac's sound to one, only to its own processes (the AVFoundation entitlements behind
/// the Sound menu cannot be claimed by an app signed as Islet is), so the panel sends
/// people to Sound settings for them. A receiver already playing shows up in Core Audio,
/// and then it is listed like any other output, and can be switched away from.
///
/// AirPods' listening mode and spatial audio sit under their row while a panel is
/// open, followed live from wherever they are changed. They are only ever set by a
/// click on them: nothing is written as the panel opens or a headset connects.
@MainActor
@Observable
final class OutputPickerModel {
    private(set) var devices: [OutputDevice] = []
    /// Where sound plays now, which may be a device the list leaves out.
    private(set) var currentID: AudioObjectID?
    /// The current output's volume, kept only while a panel is open.
    private(set) var volume: OutputVolume?
    /// Headsets' levels, keyed by `OutputDevice.headsetAddress`, read as a panel opens.
    private(set) var batteries: [String: HeadsetBattery] = [:]
    /// The output just picked, shown busy until Core Audio has answered.
    private(set) var pendingID: AudioObjectID?
    /// What went wrong with the last pick, for a few seconds.
    private(set) var failure: String?
    private(set) var isPreviewing = false
    /// Headsets' listening modes and spatial audio, by `OutputDevice.uid`, kept only
    /// while a panel is open.
    private(set) var controls: [String: HeadsetControls] = [:]
    /// The listening mode or spatial audio just asked of a headset, by UID: its row
    /// takes no more clicks until Core Audio reports it, or for a second at most.
    private(set) var pendingListeningModes: [String: ListeningMode] = [:]
    private(set) var pendingSpatialAudio: [String: SpatialAudioMode] = [:]
    /// The headsets, by address, seen in Off: see `listeningModes(for:)`.
    private(set) var headsetsAllowingOff: Set<String>

    var current: OutputDevice? {
        devices.first { $0.id == currentID }
    }

    /// The button's symbol: the AirPods or receiver sound is going to, as the
    /// iPhone's route button shows them, else AirPlay's.
    var buttonSymbol: String {
        switch current?.kind {
        case .headset, .builtInHeadphones, .airPlay: current?.symbol ?? Self.airPlaySymbol
        default: Self.airPlaySymbol
        }
    }

    static let airPlaySymbol = "airplayaudio"
    /// Sound settings, on its list of outputs, which AirPlay receivers are part of.
    static let soundSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?output")!

    // Stand-ins for tests; each defaults to the real thing.
    @ObservationIgnored var readLevels: @MainActor () -> [String: HeadsetBattery] = { BluetoothLevels.shared.read() }
    @ObservationIgnored var readProfile: @Sendable () async -> [BluetoothProfile.Device]? = {
        await BluetoothProfile.connectedDevices()
    }
    @ObservationIgnored var openURL: @MainActor (URL) -> Void = { url in
        // As the library panel's settings button does: close, then open.
        IslandManager.shared.focusedController?.model.collapse()
        NSWorkspace.shared.open(url)
    }

    @ObservationIgnored private let makeHardware: () -> any OutputHardware
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var session: OutputSession?
    @ObservationIgnored private var isRunning = false
    /// Panels on screen: one per island window showing the player with it open.
    @ObservationIgnored private var openPanels = 0
    @ObservationIgnored private var failureTask: Task<Void, Never>?
    @ObservationIgnored private var profileTask: Task<Void, Never>?
    @ObservationIgnored private var lastProfileRead = Date.distantPast
    /// The headsets, by UID, seen in Off and waiting out `offSettle` to be remembered.
    @ObservationIgnored private var offChecks: Set<String> = []
    /// The listening mode last asked of each headset, by UID.
    @ObservationIgnored private var requestedListeningModes: [String: ListeningMode] = [:]

    /// How long a failure stays up.
    private static let failureLength: Duration = .seconds(4)
    /// system_profiler is a process launch; once in this long is plenty for levels
    /// that move a percent every few minutes.
    private static let profileInterval: TimeInterval = 60
    /// The longest a headset's control waits to hear back. A listening mode is
    /// heard at once; spatial audio the headset turns down is never heard at all.
    private static let controlWait: Duration = .seconds(1)
    /// How long a headset stays in Off before it is taken to allow Off, so that a
    /// passing report of it, as a headset connects say, is not; and how long after
    /// Off is asked for the headset must still be in it for Off to stay offered.
    static let offSettle: Duration = .seconds(2)
    static let allowsOffKey = "nowPlaying.output.headsetsAllowingOff"

    init(
        hardware: @escaping () -> any OutputHardware = { CoreAudioOutputHardware() },
        defaults: UserDefaults = .standard
    ) {
        makeHardware = hardware
        self.defaults = defaults
        headsetsAllowingOff = Set(defaults.stringArray(forKey: Self.allowsOffKey) ?? [])
    }

    // MARK: Running

    /// Follows the outputs from now on. Cheap while nothing changes: the listeners
    /// only wake on a device coming or going, or sound moving.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        guard !isPreviewing else { return }
        begin(OutputSession(hardware: makeHardware()))
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        guard !isPreviewing else { return }
        end()
    }

    // MARK: Panel

    /// A panel came on screen: its volume and headsets' levels are wanted now.
    func panelAppeared() {
        openPanels += 1
        guard openPanels == 1 else { return }
        session?.followVolume(of: currentID)
        followControls()
        refreshBatteries()
    }

    func panelDisappeared() {
        guard openPanels > 0 else { return }
        openPanels -= 1
        guard openPanels == 0 else { return }
        session?.followVolume(of: nil)
        session?.followControls(of: [])
        volume = nil
        controls = [:]
        profileTask?.cancel()
        profileTask = nil
        clearFailure()
    }

    // MARK: Actions

    /// Sends the Mac's sound to `device`. One pick at a time; the checkmark moves once
    /// Core Audio says it has, and a pick that fails says so under the slider.
    func select(_ device: OutputDevice) {
        guard let session, pendingID == nil, device.id != currentID else { return }
        clearFailure()
        pendingID = device.id
        session.select(device) { [weak self, weak session] result, snapshot in
            guard let self, let session, session === self.session else { return }
            self.pendingID = nil
            self.apply(snapshot)
            if let message = result.message(for: device) { self.fail(message) }
        }
    }

    /// The slider moved. Shown at once; the writes behind it are coalesced, so a
    /// drag across the track costs a handful of round trips, not one per point.
    func setVolume(_ level: Double) {
        guard let session, let currentID, var volume, volume.isSettable else { return }
        volume.level = min(max(level, 0), 1)
        volume.isMuted = volume.level == 0
        self.volume = volume
        session.setVolume(volume.level, of: currentID)
    }

    /// AirPlay receivers, and anything else only macOS may list, are in Sound settings.
    func openSoundSettings() {
        openURL(Self.soundSettingsURL)
    }

    // MARK: Headset controls

    /// The listening modes to offer `device`, in the Sound menu's order. AirPods
    /// offer Off only with a setting of theirs turned on that no other app may read,
    /// so Off is offered while it is the mode, and after that for a headset once seen
    /// in it for a couple of seconds, until asking for it fails; otherwise asking for
    /// Off could land the AirPods in Transparency.
    func listeningModes(for device: OutputDevice) -> [ListeningMode] {
        guard let state = controls[device.uid]?.listening else { return [] }
        let allowsOff = device.headsetAddress.map(headsetsAllowingOff.contains) ?? false
        return state.offered(allowsOff: allowsOff)
    }

    /// Sets `device`'s listening mode, on a click. Noise Cancellation and Adaptive
    /// with a bud out are not asked for (see `ListeningMode.needsBothInEar`); the
    /// panel says what to do instead.
    func setListeningMode(_ mode: ListeningMode, for device: OutputDevice) {
        guard let session, pendingListeningModes[device.uid] == nil,
              let state = controls[device.uid]?.listening, state.isSettable,
              state.current != mode, listeningModes(for: device).contains(mode)
        else { return }
        guard !mode.needsBothInEar || state.isWorn else {
            fail(Self.wearHint(for: device, toUse: [mode]))
            return
        }
        clearFailure()
        pendingListeningModes[device.uid] = mode
        requestedListeningModes[device.uid] = mode
        session.setListeningMode(mode, of: device.uid) { [weak self, weak session] result in
            guard let self, let session, session === self.session else { return }
            if mode == .off { self.confirmOff(after: result, for: device) }
            guard result != .done else { return }
            self.pendingListeningModes[device.uid] = nil
            if let message = Self.message(for: result, setting: mode.title, on: device, mode: mode) { self.fail(message) }
        }
        release(after: Self.controlWait) { [weak self] in
            guard self?.pendingListeningModes[device.uid] == mode else { return }
            self?.pendingListeningModes[device.uid] = nil
        }
    }

    /// Sets `device`'s spatial audio, on a click, for the app being spatialized.
    func setSpatialAudio(_ mode: SpatialAudioMode, for device: OutputDevice) {
        guard let session, pendingSpatialAudio[device.uid] == nil,
              let state = controls[device.uid]?.spatial, state.isSettable, state.app > 0,
              state.mode != mode, state.offered.contains(mode)
        else { return }
        clearFailure()
        pendingSpatialAudio[device.uid] = mode
        session.setSpatialAudio(mode, for: state.content, of: device.uid) { [weak self, weak session] result in
            guard let self, let session, session === self.session else { return }
            guard result != .done else { return }
            self.pendingSpatialAudio[device.uid] = nil
            if let message = Self.message(for: result, setting: state.content.title, on: device) { self.fail(message) }
        }
        release(after: Self.controlWait) { [weak self] in
            guard self?.pendingSpatialAudio[device.uid] == mode else { return }
            self?.pendingSpatialAudio[device.uid] = nil
        }
    }

    /// What to do before Noise Cancellation or Adaptive can be had: "Put both
    /// AirPods in to use Adaptive and Noise Cancellation", or for over-ear headphones
    /// "Put AirPods Max on to use Noise Cancellation".
    static func wearHint(for device: OutputDevice, toUse modes: [ListeningMode]) -> String {
        let hint = switch device.kind {
        case .headset(.airpodsMax), .headset(.beatsHeadphones): "Put \(device.shortName) on"
        case .headset(.airpods), .headset(.airpodsGen3), .headset(.airpodsPro): "Put both AirPods in"
        default: "Put both earbuds in"
        }
        let titles = modes.map(\.title)
        return titles.isEmpty ? hint : "\(hint) to use \(ListFormatter.localizedString(byJoining: titles))"
    }

    private static func message(
        for result: HeadsetControlResult, setting title: String, on device: OutputDevice, mode: ListeningMode? = nil
    ) -> String? {
        switch result {
        case .done: nil
        case .gone: "\(device.shortName) is no longer connected"
        case .needsBothInEar: wearHint(for: device, toUse: mode.map { [$0] } ?? [])
        // The plug-in's own in-ear refusal, which only a listening mode gets.
        case .refused(kAudioHardwareIllegalOperationError) where mode != nil: wearHint(for: device, toUse: mode.map { [$0] } ?? [])
        case .unavailable, .refused(kAudioHardwareUnsupportedOperationError): "\(title) isn’t available right now"
        case .refused(kAudioHardwareNotRunningError): "Couldn’t reach \(device.shortName)"
        case .refused: "Couldn’t change \(mode == nil ? title : "the listening mode")"
        }
    }

    private func release(after delay: Duration, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            body()
        }
    }

    /// The headsets in the list that may have controls, while a panel is open.
    private func followControls() {
        guard openPanels > 0 else { return }
        session?.followControls(of: devices.filter(\.mayHaveControls).map(\.uid))
    }

    // MARK: Previews

    /// Made-up outputs, to try the panel without touching the Mac's sound: until
    /// `endPreview()`, picking one or moving the slider changes only the samples.
    func beginPreview() {
        // Whatever ran before, real outputs or an earlier preview's, gives way. An
        // open panel's slider picks up the samples' volume once they have been read.
        end()
        isPreviewing = true
        let sample = SampleOutputHardware()
        begin(OutputSession(hardware: sample))
        batteries = sample.batteries
    }

    func endPreview() {
        guard isPreviewing else { return }
        end()
        isPreviewing = false
        if isRunning { begin(OutputSession(hardware: makeHardware())) }
    }

    // MARK: Updates

    private func begin(_ session: OutputSession) {
        self.session = session
        session.start { [weak self, weak session] event in
            guard let self, let session, session === self.session else { return }
            switch event {
            case .snapshot(let snapshot):
                self.apply(snapshot)
            case .volume(let device, let volume):
                guard self.openPanels > 0, device == self.currentID else { return }
                if self.volume != volume { self.volume = volume }
            case .controls(let controls):
                guard self.openPanels > 0 else { return }
                self.apply(controls)
            }
        }
    }

    private func end() {
        session?.stop()
        session = nil
        devices = []
        currentID = nil
        volume = nil
        batteries = [:]
        pendingID = nil
        controls = [:]
        pendingListeningModes = [:]
        pendingSpatialAudio = [:]
        requestedListeningModes = [:]
        profileTask?.cancel()
        profileTask = nil
        clearFailure()
    }

    private func apply(_ snapshot: OutputSnapshot) {
        let listChanged = devices != snapshot.devices
        if listChanged { devices = snapshot.devices }
        if currentID != snapshot.currentID {
            currentID = snapshot.currentID
            // The slider follows sound to its new output, keeping the last level
            // for the moment until the new one is read, rather than blinking empty.
            if openPanels > 0 { session?.followVolume(of: currentID) }
            if currentID == nil { volume = nil }
        }
        // A headset that connects while the panel is open gets its levels and its
        // controls, and one that reconnected is followed under its new ID.
        if listChanged, openPanels > 0 {
            refreshBatteries()
            followControls()
        }
    }

    /// A control is no longer waiting once Core Audio reports what was asked.
    private func apply(_ controls: [String: HeadsetControls]) {
        for (uid, mode) in pendingListeningModes where controls[uid]?.listening?.current == mode {
            pendingListeningModes[uid] = nil
        }
        for (uid, mode) in pendingSpatialAudio where controls[uid]?.spatial?.mode == mode {
            pendingSpatialAudio[uid] = nil
        }
        if self.controls != controls { self.controls = controls }
        noticeOff()
    }

    /// A headset in Off is remembered as allowing it once it is still in Off
    /// `offSettle` later.
    private func noticeOff() {
        guard !isPreviewing else { return }
        for device in devices where controls[device.uid]?.listening?.current == .off {
            guard let address = device.headsetAddress, !headsetsAllowingOff.contains(address),
                  offChecks.insert(device.uid).inserted
            else { continue }
            release(after: Self.offSettle) { [weak self] in
                guard let self else { return }
                self.offChecks.remove(device.uid)
                guard !self.isPreviewing, self.controls[device.uid]?.listening?.current == .off else { return }
                self.setAllowsOff(true, for: address)
            }
        }
    }

    /// Off asked for and refused, or not the headset's mode `offSettle` later while
    /// it is still the last mode asked for: the AirPods do not allow it after all,
    /// and it is not offered again until seen. Not reaching them says nothing either
    /// way.
    private func confirmOff(after result: HeadsetControlResult, for device: OutputDevice) {
        guard !isPreviewing, let address = device.headsetAddress else { return }
        switch result {
        case .refused(let status) where status != kAudioHardwareNotRunningError:
            setAllowsOff(false, for: address)
        case .done:
            release(after: Self.offSettle) { [weak self] in
                guard let self, !self.isPreviewing, self.requestedListeningModes[device.uid] == .off,
                      let current = self.controls[device.uid]?.listening?.current, current != .off
                else { return }
                self.setAllowsOff(false, for: address)
            }
        default:
            break
        }
    }

    private func setAllowsOff(_ allows: Bool, for address: String) {
        var allowing = headsetsAllowingOff
        if allows { allowing.insert(address) } else { allowing.remove(address) }
        guard allowing != headsetsAllowingOff else { return }
        headsetsAllowingOff = allowing
        defaults.set(allowing.sorted(), forKey: Self.allowsOffKey)
    }

    // MARK: Battery

    /// Exact levels from Bluetooth where Islet may read them; otherwise, or for a
    /// headset Bluetooth has no levels for yet, system_profiler's.
    private func refreshBatteries() {
        guard !isPreviewing else { return }
        let headsets = devices.compactMap(\.headsetAddress)
        guard !headsets.isEmpty else { return }
        var levels = batteries
        for (address, battery) in readLevels() where headsets.contains(address) {
            levels[address] = battery
        }
        if levels != batteries { batteries = levels }

        let missing = headsets.contains { levels[$0]?.isEmpty ?? true }
        guard missing, profileTask == nil,
              Date().timeIntervalSince(lastProfileRead) > Self.profileInterval
        else { return }
        let read = readProfile
        profileTask = Task { [weak self] in
            let profile = await read()
            guard !Task.isCancelled, let self else { return }
            self.profileTask = nil
            self.lastProfileRead = Date()
            guard !self.isPreviewing, let profile else { return }
            var levels = self.batteries
            for device in profile {
                guard let address = device.address, !device.battery.isEmpty,
                      levels[address]?.isEmpty ?? true else { continue }
                levels[address] = device.battery
            }
            if levels != self.batteries { self.batteries = levels }
        }
    }

    // MARK: Failure

    private func fail(_ message: String) {
        failureTask?.cancel()
        withAnimation(.islandMorph) { failure = message }
        failureTask = Task { [weak self] in
            try? await Task.sleep(for: Self.failureLength)
            guard !Task.isCancelled else { return }
            self?.clearFailure()
        }
    }

    private func clearFailure() {
        failureTask?.cancel()
        failureTask = nil
        guard failure != nil else { return }
        withAnimation(.islandMorph) { failure = nil }
    }
}

// MARK: - Switching

/// The outputs and which one is in use, read together.
struct OutputSnapshot: Equatable, Sendable {
    var devices: [OutputDevice]
    var currentID: AudioObjectID?

    static func read(_ hardware: any OutputHardware) -> OutputSnapshot {
        OutputSnapshot(
            devices: OutputCatalog.outputs(from: hardware.candidates()),
            currentID: hardware.defaultOutput()
        )
    }
}

/// How a pick went.
enum OutputSwitchResult: Equatable, Sendable {
    case switched
    /// The device went between the list being drawn and the click: AirPods put back
    /// in their case, a receiver that stopped.
    case gone
    /// Core Audio would not have it.
    case refused(OSStatus)
    /// Core Audio took it, but sound is still going elsewhere.
    case didNotTake

    func message(for device: OutputDevice) -> String? {
        switch self {
        case .switched: nil
        case .gone: "\(device.shortName) is no longer connected"
        case .refused, .didNotTake: "Couldn’t switch to \(device.shortName)"
        }
    }

    /// Moves the Mac's sound to `device`, the way the Sound menu does: its default
    /// output. Alerts and sound effects go along only if they were playing where the
    /// sound was, so a choice of a fixed alert device in Sound settings is kept. The
    /// input is left alone: macOS already moves the microphone to AirPods and back.
    static func perform(to device: OutputDevice, on hardware: any OutputHardware) -> OutputSwitchResult {
        guard hardware.uid(of: device.id) == device.uid else { return .gone }
        let previous = hardware.defaultOutput()
        let alerts = hardware.defaultSystemOutput()
        let status = hardware.setDefaultOutput(device.id)
        guard status == noErr else { return .refused(status) }
        if let previous, alerts == previous, device.canBeSystemDefault {
            _ = hardware.setDefaultSystemOutput(device.id)
        }
        return hardware.defaultOutput() == device.id ? .switched : .didNotTake
    }
}

/// One run of the picker's hardware: its serial queue, the listeners and the
/// coalescing of what they hear. The model makes a new one for each start and each
/// preview, and drops what an old one reports.
final class OutputSession: @unchecked Sendable {
    enum Event: Sendable {
        case snapshot(OutputSnapshot)
        case volume(AudioObjectID, OutputVolume?)
        /// The followed headsets' controls, by UID; one with none is left out.
        case controls([String: HeadsetControls])
    }

    typealias Report = @MainActor @Sendable (Event) -> Void

    let hardware: any OutputHardware
    private let queue = DispatchQueue(label: "Islet.NowPlaying.output", qos: .userInitiated)

    // Confined to `queue`.
    private var report: Report?
    private var scanScheduled = false
    private var volumeScheduled = false
    private var controlsScheduled = false
    private var followed: AudioObjectID?
    /// The UIDs of the headsets whose controls are followed.
    private var controlled: [String] = []
    /// The slider's latest level and the device it is for, waiting to be written.
    private var pendingLevel: (level: Double, device: AudioObjectID)?

    /// Connecting AirPods changes the device list two or three times in quick
    /// succession (output, input, then the default output); one look after the
    /// burst is enough.
    static let settle: TimeInterval = 0.25
    /// Volume keys held down step the level every few tens of milliseconds.
    static let volumeSettle: TimeInterval = 0.05
    /// A spatial audio change moves two or three properties at once.
    static let controlsSettle: TimeInterval = 0.05

    init(hardware: any OutputHardware) {
        self.hardware = hardware
    }

    /// Listens, then reads the outputs once: listening first means no change can
    /// slip in between. The first Core Audio call in a process sets up the audio
    /// system, which takes a few hundred milliseconds, so even this stays off the
    /// main thread.
    func start(report: @escaping Report) {
        queue.async { [self] in
            self.report = report
            listen()
            send(.snapshot(OutputSnapshot.read(hardware)))
        }
    }

    func stop() {
        queue.async { [self] in
            report = nil
            followed = nil
            controlled = []
            hardware.stopListening()
        }
    }

    func followVolume(of device: AudioObjectID?) {
        queue.async { [self] in
            followed = device
            hardware.followVolume(of: device)
            if let device { send(.volume(device, hardware.volume(of: device))) }
        }
    }

    /// Follows these headsets' listening modes and spatial audio, by UID, reporting
    /// them now and whenever they change; none stops.
    func followControls(of uids: [String]) {
        queue.async { [self] in
            controlled = uids
            readControls()
        }
    }

    /// Sets a headset's listening mode, found by its UID now. Its controls are read
    /// again after, whatever came of it, for the listener may never hear a write the
    /// headset turned down.
    func setListeningMode(
        _ mode: ListeningMode, of uid: String,
        completion: @escaping @MainActor @Sendable (HeadsetControlResult) -> Void
    ) {
        queue.async { [self] in
            let result = hardware.device(uid: uid).map { hardware.setListeningMode(mode, of: $0) } ?? .gone
            finish(result, completion)
        }
    }

    func setSpatialAudio(
        _ mode: SpatialAudioMode, for content: SpatialContent, of uid: String,
        completion: @escaping @MainActor @Sendable (HeadsetControlResult) -> Void
    ) {
        queue.async { [self] in
            let result = hardware.device(uid: uid).map { hardware.setSpatialAudio(mode, for: content, of: $0) } ?? .gone
            finish(result, completion)
        }
    }

    private func finish(_ result: HeadsetControlResult, _ completion: @escaping @MainActor @Sendable (HeadsetControlResult) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { completion(result) }
        }
        scheduleControlsRead()
    }

    func select(_ device: OutputDevice, completion: @escaping @MainActor @Sendable (OutputSwitchResult, OutputSnapshot) -> Void) {
        queue.async { [self] in
            let result = OutputSwitchResult.perform(to: device, on: hardware)
            let snapshot = OutputSnapshot.read(hardware)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result, snapshot) }
            }
        }
    }

    func setVolume(_ level: Double, of device: AudioObjectID) {
        queue.async { [self] in
            let isQueued = pendingLevel != nil
            pendingLevel = (level, device)
            guard !isQueued else { return }
            // Behind whatever else is queued, so a burst of drags lands as one write.
            queue.async { [self] in
                guard let pending = pendingLevel else { return }
                pendingLevel = nil
                _ = hardware.setVolume(pending.level, of: pending.device)
            }
        }
    }

    // MARK: Listening

    private func listen() {
        hardware.listen(on: queue) { [weak self] change in
            // Already on the queue.
            self?.heard(change)
        }
    }

    private func heard(_ change: OutputChange) {
        switch change {
        case .devices:
            scheduleScan()
        case .volume:
            scheduleVolumeRead()
        case .controls:
            scheduleControlsRead()
        case .restarted:
            // Its devices may be back under new IDs. Off and on again leaves one set
            // of listeners, whether or not the restart kept the old ones, and the
            // scan puts the slider on the output's new ID; headsets are looked up
            // by UID again.
            hardware.stopListening()
            listen()
            if let followed { hardware.followVolume(of: followed) }
            scheduleScan()
            scheduleVolumeRead()
            scheduleControlsRead()
        }
    }

    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + Self.settle) { [self] in
            scanScheduled = false
            send(.snapshot(OutputSnapshot.read(hardware)))
        }
    }

    private func scheduleVolumeRead() {
        guard !volumeScheduled, followed != nil else { return }
        volumeScheduled = true
        queue.asyncAfter(deadline: .now() + Self.volumeSettle) { [self] in
            volumeScheduled = false
            guard let followed else { return }
            send(.volume(followed, hardware.volume(of: followed)))
        }
    }

    private func scheduleControlsRead() {
        guard !controlsScheduled, !controlled.isEmpty else { return }
        controlsScheduled = true
        queue.asyncAfter(deadline: .now() + Self.controlsSettle) { [self] in
            controlsScheduled = false
            readControls()
        }
    }

    /// Looks each headset up by UID, reads its controls, and listens to what the
    /// read found under the ID it has now. Which properties to listen to is known
    /// only from the read, so a listener just put on reads them once more, for a
    /// change made from the stem or Control Center in between.
    private func readControls() {
        var listened: [AudioObjectID: [HeadsetProperty]] = [:]
        var controls: [String: HeadsetControls] = [:]
        for uid in controlled {
            guard let device = hardware.device(uid: uid), let reading = hardware.readHeadset(device) else { continue }
            listened[device] = reading.listened
            controls[uid] = reading.controls
        }
        if hardware.followControls(listened) { scheduleControlsRead() }
        send(.controls(controls))
    }

    private func send(_ event: Event) {
        guard let report else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { report(event) }
        }
    }
}
