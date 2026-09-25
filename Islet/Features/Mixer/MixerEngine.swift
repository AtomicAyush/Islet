import CoreAudio
import Foundation

/// What the engine last found.
struct MixerReading: Equatable, Sendable {
    /// Apps producing sound, in the order they started.
    var playing: [MixerSource] = []
    /// Apps whose level could not be applied, by id.
    var failed: Set<String> = []
    /// One of those apps' taps was refused in a way that points at permission.
    var refused = false
}

/// Finds the apps producing sound, and plays any the person has turned up or down
/// at their own level.
///
/// Apps come from the HAL's process objects (macOS 14.2 and later), each put down to
/// the app it plays for by `AudioAppResolver`; an app is playing while any of its
/// processes runs output. The HAL never notifies a change of IsRunningOutput, only of
/// IsRunning and of the output devices a process uses, so those are what each
/// process is watched for, and IsRunningOutput is asked again when they change.
/// Changes come in bursts; they are gathered into one refresh 0.3 s after the first,
/// and only the processes that changed are asked, each question being a round trip
/// to the audio server.
///
/// An app with a level of its own gets a `VolumeTap`, made the moment it starts
/// playing rather than at the refresh, since until then it plays at full volume. The
/// tap keeps running for a while after the app stops, so a pause between songs does
/// not let a burst through when it resumes; after that its IO stops, and nothing
/// runs until the app plays again.
///
/// Everything runs on one serial queue, the listeners included: the first CoreAudio
/// call in a process can take half a second.
final class MixerEngine: @unchecked Sendable {
    typealias Deliver = @MainActor @Sendable (MixerReading) -> Void

    /// How long changes are gathered before a refresh.
    private static let settle: TimeInterval = 0.3
    /// How long a tap keeps running after its app stops playing.
    private static let idleHold: TimeInterval = 30

    private static let systemProperties = [
        MixerHAL.address(kAudioHardwarePropertyProcessObjectList),
        MixerHAL.address(kAudioHardwarePropertyDefaultOutputDevice),
        MixerHAL.address(kAudioHardwarePropertyServiceRestarted),
    ]
    private static let processProperties = [
        MixerHAL.address(kAudioProcessPropertyIsRunning),
        MixerHAL.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput),
    ]

    private struct AudioProcess {
        /// `nil` for a process that belongs to no listed app; those are not watched.
        let app: MixerSource?
        var isPlaying: Bool
        let listener: AudioObjectPropertyListenerBlock?
    }

    /// An app's audio processes, together.
    private struct AppAudio {
        let source: MixerSource
        var processes: [AudioObjectID]
        var isPlaying: Bool
    }

    /// A tap that could not be made, and what it was to be made over.
    private struct TapFailure {
        let signature: VolumeTap.Signature
        /// Refused in a way that points at permission.
        let refused: Bool
    }

    private let queue = DispatchQueue(label: "Islet.Mixer.audio", qos: .userInitiated)

    // Everything below is confined to `queue`.
    private var deliver: Deliver?
    /// Bumped whenever the engine disconnects, so a refresh scheduled before does nothing.
    private var session = 0
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var processes: [AudioObjectID: AudioProcess] = [:]
    private var changedProcesses: Set<AudioObjectID> = []
    private var listChanged = false
    private var outputChanged = false
    private var refreshPending = false
    private var output: MixerOutputDevice?
    /// When each playing app started, as a running count, so the list keeps its order.
    private var startOrder: [String: Int] = [:]
    private var starts = 0
    private var levels: [String: Float] = [:]
    private var tapsAllowed = false
    private var taps: [String: VolumeTap] = [:]
    private var idleStops: [String: DispatchWorkItem] = [:]
    /// Apps whose tap failed; not tried again until what it was to be made over
    /// changes, or the person sets the level again.
    private var failures: [String: TapFailure] = [:]
    private var lastReading: MixerReading?

    // MARK: Control

    /// Starts watching. `deliver` gets the first reading, then every change. Does
    /// nothing before macOS 14.2, which has no process objects.
    func start(deliver: @escaping Deliver) {
        queue.async { [self] in
            guard self.deliver == nil else { return }
            guard #available(macOS 14.2, *) else { return }
            self.deliver = deliver
            connect()
        }
    }

    /// Stops watching and hands every app's sound back to its normal path.
    func stop() {
        queue.async { [self] in
            guard deliver != nil else { return }
            disconnect()
            deliver = nil
            levels = [:]
            tapsAllowed = false
        }
    }

    /// The level of every app that should not play at 100%, 0 for a muted one, and
    /// whether taps may be made at all. `retrying` names an app the person has just
    /// set again, so a failed tap for it is tried once more.
    func apply(levels: [String: Float], allowed: Bool, retrying id: String? = nil) {
        queue.async { [self] in
            self.levels = levels
            tapsAllowed = allowed
            if let id { failures[id] = nil }
            guard deliver != nil else { return }
            let apps = appAudio()
            reconcileTaps(apps)
            report(apps)
        }
    }

    /// Whether system audio recording is allowed, without asking.
    func checkAccess(_ answer: @escaping @MainActor @Sendable (MixerAccess) -> Void) {
        queue.async {
            let access = AudioCapturePermission.check()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { answer(access) }
            }
        }
    }

    /// Asks for system audio recording, which shows macOS's prompt if it has not been
    /// answered. `answer` gets the answer, or `nil` when there is no way to ask
    /// before making a tap. Off the engine's queue, which must not wait on a person.
    func requestAccess(_ answer: @escaping @MainActor @Sendable (Bool?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let reply: @Sendable (Bool?) -> Void = { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { answer(granted) }
                }
            }
            if !AudioCapturePermission.ask({ reply($0) }) { reply(nil) }
        }
    }

    // MARK: Listening

    private func connect() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard let self else { return }
            for index in 0..<Int(count) { self.systemChanged(addresses[index].mSelector) }
        }
        systemListener = listener
        Self.setListening(true, listener, to: MixerHAL.system, for: Self.systemProperties, on: queue)
        output = MixerOutputDevice.current()
        listChanged = true
        refresh()
    }

    private func disconnect() {
        session &+= 1
        refreshPending = false
        for id in Array(taps.keys) { removeTap(id) }
        if let systemListener {
            Self.setListening(false, systemListener, to: MixerHAL.system, for: Self.systemProperties, on: queue)
        }
        systemListener = nil
        for (id, process) in processes {
            if let listener = process.listener {
                Self.setListening(false, listener, to: id, for: Self.processProperties, on: queue)
            }
        }
        processes = [:]
        changedProcesses = []
        listChanged = false
        outputChanged = false
        output = nil
        startOrder = [:]
        failures = [:]
        lastReading = nil
    }

    private func systemChanged(_ selector: AudioObjectPropertySelector) {
        guard deliver != nil else { return }
        switch selector {
        case kAudioHardwarePropertyProcessObjectList:
            listChanged = true
        case kAudioHardwarePropertyDefaultOutputDevice:
            outputChanged = true
        case kAudioHardwarePropertyServiceRestarted:
            // The audio server started afresh: every process, tap and listener it knew
            // is gone. Start over, keeping the levels.
            disconnect()
            connect()
            return
        default:
            return
        }
        scheduleRefresh()
    }

    private func processChanged(_ id: AudioObjectID) {
        guard deliver != nil, let app = processes[id]?.app else { return }
        if tapsAllowed, levels[app.id] != nil {
            let playing = Self.isRunningOutput(id)
            processes[id]?.isPlaying = playing
            if playing { reconcile(app.id, app: appAudio()[app.id]) }
        } else {
            changedProcesses.insert(id)
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        let session = self.session
        queue.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            guard let self, self.session == session else { return }
            self.refreshPending = false
            self.refresh()
        }
    }

    // MARK: Reading

    private func refresh() {
        guard deliver != nil else { return }
        if listChanged {
            listChanged = false
            syncProcessList()
        }
        for id in changedProcesses where processes[id] != nil {
            processes[id]?.isPlaying = Self.isRunningOutput(id)
        }
        changedProcesses.removeAll()
        if outputChanged {
            outputChanged = false
            output = MixerOutputDevice.current()
        }

        let apps = appAudio()
        for (id, app) in apps where app.isPlaying && startOrder[id] == nil {
            starts += 1
            startOrder[id] = starts
        }
        for id in startOrder.keys where apps[id]?.isPlaying != true {
            startOrder[id] = nil
        }
        reconcileTaps(apps)
        report(apps)
    }

    /// Watches processes that arrived and forgets those that went. A process is
    /// listened to before it is first read, so a start in between is not missed.
    private func syncProcessList() {
        let current = MixerHAL.objects(kAudioHardwarePropertyProcessObjectList, of: MixerHAL.system)
        let present = Set(current)
        for (id, process) in processes where !present.contains(id) {
            if let listener = process.listener {
                Self.setListening(false, listener, to: id, for: Self.processProperties, on: queue)
            }
            processes[id] = nil
            changedProcesses.remove(id)
        }
        for id in current where processes[id] == nil {
            guard let pid = MixerHAL.read(pid_t(0), kAudioProcessPropertyPID, of: id),
                  let app = AudioAppResolver.source(for: pid)
            else {
                processes[id] = AudioProcess(app: nil, isPlaying: false, listener: nil)
                continue
            }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.processChanged(id) }
            Self.setListening(true, listener, to: id, for: Self.processProperties, on: queue)
            processes[id] = AudioProcess(app: app, isPlaying: Self.isRunningOutput(id), listener: listener)
        }
    }

    /// Every listed app with audio processes. The lowest process names the app, so
    /// the answer is the same however the processes are ordered.
    private func appAudio() -> [String: AppAudio] {
        var apps: [String: AppAudio] = [:]
        for id in processes.keys.sorted() {
            guard let process = processes[id], let source = process.app else { continue }
            if apps[source.id] == nil {
                apps[source.id] = AppAudio(source: source, processes: [], isPlaying: false)
            }
            apps[source.id]?.processes.append(id)
            if process.isPlaying { apps[source.id]?.isPlaying = true }
        }
        return apps
    }

    private func report(_ apps: [String: AppAudio]) {
        guard let deliver else { return }
        let playing = apps.values
            .filter(\.isPlaying)
            .sorted { (startOrder[$0.source.id] ?? 0) < (startOrder[$1.source.id] ?? 0) }
            .map(\.source)
        let reading = MixerReading(
            playing: playing,
            failed: Set(failures.keys),
            refused: failures.values.contains { $0.refused }
        )
        guard reading != lastReading else { return }
        lastReading = reading
        DispatchQueue.main.async {
            MainActor.assumeIsolated { deliver(reading) }
        }
    }

    // MARK: Taps

    private func reconcileTaps(_ apps: [String: AppAudio]) {
        // An app back at 100% has nothing left to fail.
        failures = failures.filter { levels[$0.key] != nil }
        for id in Set(taps.keys).union(levels.keys) {
            reconcile(id, app: apps[id])
        }
    }

    /// Brings one app's tap in line with its level, its processes and the output.
    private func reconcile(_ id: String, app: AppAudio?) {
        guard tapsAllowed, let level = levels[id], let app, let output else {
            removeTap(id)
            failures[id] = nil
            return
        }
        let signature = VolumeTap.Signature(processes: app.processes, outputUID: output.uid)
        if failures[id]?.signature == signature { return }
        failures[id] = nil

        if let current = taps[id], current.signature != signature {
            // The app's processes or the output changed. The new tap starts before the
            // old one goes, so the app's sound never escapes at full volume between.
            taps[id] = nil
            cancelIdleStop(id)
            if current.isRunning || app.isPlaying,
               let replacement = makeTap(id, app: app, output: output, level: level, signature: signature) {
                taps[id] = replacement
                if current.isRunning { startTap(id) }
            }
            current.destroy()
        }
        if taps[id] == nil, app.isPlaying, failures[id] == nil {
            taps[id] = makeTap(id, app: app, output: output, level: level, signature: signature)
        }
        guard let tap = taps[id] else { return }

        tap.setGain(level)
        if app.isPlaying {
            cancelIdleStop(id)
            if !tap.isRunning { startTap(id) }
        } else if tap.isRunning, idleStops[id] == nil {
            scheduleIdleStop(id)
        }
    }

    private func makeTap(
        _ id: String, app: AppAudio, output: MixerOutputDevice, level: Float, signature: VolumeTap.Signature
    ) -> VolumeTap? {
        // Permission can be withdrawn or reset at any time. A tap made without it
        // would silence the app rather than set its level, and one made before it is
        // answered would have macOS ask when the person did not just move a slider.
        switch AudioCapturePermission.check() {
        case .granted:
            break
        case .unknown where !AudioCapturePermission.asksAhead:
            break
        default:
            recordFailure(id, signature: signature, error: VolumeTap.Failure.refused)
            return nil
        }
        do {
            return try VolumeTap.make(app: app.source, signature: signature, output: output, gain: level)
        } catch {
            recordFailure(id, signature: signature, error: error)
            return nil
        }
    }

    private func startTap(_ id: String) {
        guard let tap = taps[id] else { return }
        do {
            try tap.start()
        } catch {
            recordFailure(id, signature: tap.signature, error: error)
            tap.destroy()
            taps[id] = nil
        }
    }

    private func recordFailure(_ id: String, signature: VolumeTap.Signature, error: Error) {
        var refused = false
        if case VolumeTap.Failure.refused = error { refused = true }
        failures[id] = TapFailure(signature: signature, refused: refused)
    }

    private func removeTap(_ id: String) {
        cancelIdleStop(id)
        taps.removeValue(forKey: id)?.destroy()
    }

    private func scheduleIdleStop(_ id: String) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.idleStops[id] = nil
            guard self.appAudio()[id]?.isPlaying != true else { return }
            self.taps[id]?.stop()
        }
        idleStops[id] = work
        queue.asyncAfter(deadline: .now() + Self.idleHold, execute: work)
    }

    private func cancelIdleStop(_ id: String) {
        idleStops.removeValue(forKey: id)?.cancel()
    }

    // MARK: CoreAudio

    /// Fails harmlessly for an object that has already gone.
    private static func setListening(
        _ isOn: Bool,
        _ listener: @escaping AudioObjectPropertyListenerBlock,
        to object: AudioObjectID,
        for properties: [AudioObjectPropertyAddress],
        on queue: DispatchQueue
    ) {
        for property in properties {
            var address = property
            if isOn {
                AudioObjectAddPropertyListenerBlock(object, &address, queue, listener)
            } else {
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
            }
        }
    }

    /// A failed read, as for a process that just went away, counts as not playing.
    private static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        (MixerHAL.read(UInt32(0), kAudioProcessPropertyIsRunningOutput, of: process) ?? 0) != 0
    }
}
