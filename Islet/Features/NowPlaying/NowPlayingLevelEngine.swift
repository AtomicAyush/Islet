import CoreAudio
import Foundation

/// Keeps a tap on the sound of the app Now Playing is showing, for as long as it is
/// told to, and feeds it to the meter.
///
/// The app's audio processes are found the way the mixer finds them: each of the
/// HAL's process objects is put down to its app by `AudioAppResolver`, so a browser's
/// media helpers count as the browser. When the mixer is already playing that app at
/// a level of its own, the meter follows the mixer's tap rather than tapping the app
/// a second time; otherwise the engine makes a `NowPlayingAudioTap` of its own.
///
/// A tap is kept only while one of the app's processes is sending sound to an output,
/// as the mixer judges an app to be playing. Now Playing can say an app plays while it
/// sends nothing through this Mac — Spotify on a Connect speaker, Music on AirPlay
/// speakers of its own, a muted tab — and a tap would then hear only silence, with
/// macOS's recording indicator on for nothing. Nor is an output followed whose latency
/// is longer than the bars can wait for.
///
/// The tap is made again when the app's processes, the output device or its sample
/// rate change (Music switches the rate for lossless tracks), and made or dropped as
/// the app's processes start and stop sending sound, all of which the HAL announces,
/// gathered into one look 0.3 s after the first change. A tap that fails is not tried
/// again until one of those changes; nor is anything tried at all unless macOS
/// already allows system audio recording, since making a tap is what would have it
/// ask.
///
/// Everything runs on one serial queue, the HAL's listeners included.
@available(macOS 15.0, *)
final class NowPlayingLevelEngine: @unchecked Sendable {
    typealias Report = @MainActor @Sendable (NowPlayingLevelStatus) -> Void

    private static let settle: TimeInterval = 0.3
    private static let systemProperties = [
        MixerHAL.address(kAudioHardwarePropertyProcessObjectList),
        MixerHAL.address(kAudioHardwarePropertyDefaultOutputDevice),
        MixerHAL.address(kAudioHardwarePropertyServiceRestarted),
    ]
    /// The HAL never announces a change of a process's IsRunningOutput, only of these,
    /// so they are what the app's processes are watched for, as the mixer does.
    private static let processProperties = [
        MixerHAL.address(kAudioProcessPropertyIsRunning),
        MixerHAL.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput),
    ]

    let meter: NowPlayingLevelMeter
    private let queue = DispatchQueue(label: "Islet.NowPlaying.levels", qos: .userInitiated)

    // Everything below is confined to `queue`.
    private var app: String?
    private var report: Report?
    private var lastStatus: NowPlayingLevelStatus?
    /// Bumped whenever the app followed changes, so work scheduled before does nothing.
    private var session = 0
    private var listener: AudioObjectPropertyListenerBlock?
    /// The output device whose sample rate is watched.
    private var watchedOutput: AudioObjectID?
    /// The app's processes, watched for starting and stopping output.
    private var watchedProcesses: Set<AudioObjectID> = []
    private var mixerObserver: NSObjectProtocol?
    private var refreshPending = false
    /// Each process object's app id, looked up once; `""` for one that belongs to no app.
    private var owners: [AudioObjectID: String] = [:]
    /// The followed app's name, as its processes give it, for naming the tap.
    private var appName: String?
    private var tap: NowPlayingAudioTap?
    /// The mixer tap the meter follows instead, by id.
    private var mixerTap: Int?
    /// The output's sample rate when the tap followed now was taken up.
    private var followedRate: Float64?
    /// What a tap could not be made over; not tried again until that changes.
    private var failed: VolumeTap.Signature?
    /// Ids for Now Playing's own taps, counting down from -1, so sound still on its
    /// way from a tap just destroyed never counts as the next one's.
    private var tapsMade = 0

    init(meter: NowPlayingLevelMeter) {
        self.meter = meter
    }

    /// Follows `appID`'s sound, or nothing. `report` hears how it goes.
    func follow(_ appID: String?, report: @escaping Report) {
        queue.async { [self] in
            guard appID != app else { return }
            disconnect()
            app = appID
            self.report = report
            lastStatus = nil
            guard appID != nil else {
                send(.idle)
                return
            }
            connect()
        }
    }

    // MARK: Listening

    private func connect() {
        let session = self.session
        let listener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard let self, self.session == session else { return }
            let restarted = (0..<Int(count)).contains {
                addresses[$0].mSelector == kAudioHardwarePropertyServiceRestarted
            }
            if restarted {
                // The audio server started afresh: every tap, process and listener it
                // knew is gone. Start over.
                self.disconnect()
                self.connect()
            } else {
                self.scheduleRefresh()
            }
        }
        self.listener = listener
        for property in Self.systemProperties {
            var address = property
            AudioObjectAddPropertyListenerBlock(MixerHAL.system, &address, queue, listener)
        }
        mixerObserver = NotificationCenter.default.addObserver(
            forName: MixerTaps.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.session == session else { return }
                self.scheduleRefresh()
            }
        }
        refresh()
    }

    private func disconnect() {
        session &+= 1
        refreshPending = false
        dropTap()
        if let listener {
            for property in Self.systemProperties {
                var address = property
                AudioObjectRemovePropertyListenerBlock(MixerHAL.system, &address, queue, listener)
            }
        }
        watchRate(of: nil)
        watchProcesses([])
        listener = nil
        if let mixerObserver { NotificationCenter.default.removeObserver(mixerObserver) }
        mixerObserver = nil
        failed = nil
        owners = [:]
        appName = nil
        meter.forget()
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

    // MARK: Tapping

    /// Brings the tap in line with the app's processes, the output, and the mixer.
    private func refresh() {
        guard let app else { return }
        // Asked every time: permission can be withdrawn at any moment, and a tap made
        // without it would have macOS ask when nobody asked for anything. Refused, there
        // is nothing to watch for until the next play asks again.
        guard AudioCapturePermission.check() == .granted else {
            disconnect()
            send(.failed)
            return
        }
        guard let output = MixerOutputDevice.current() else {
            dropTap()
            send(.idle)
            return
        }
        watchRate(of: output.id)
        let rate = MixerHAL.read(Float64(0), kAudioDevicePropertyNominalSampleRate, of: output.id) ?? 48_000

        let processes = processes(of: app)
        // Listened to before they are read, so a start in between is not missed.
        watchProcesses(processes)
        // A browser's media process can start a moment after it says it plays; and an
        // app playing elsewhere sends nothing here to listen to.
        guard processes.contains(where: Self.isRunningOutput) else {
            dropTap()
            send(.idle)
            return
        }
        let latency = NowPlayingAudioTap.latency(of: output)
        guard latency <= NowPlayingLevelMeter.longestLatency else {
            dropTap()
            send(.idle)
            return
        }

        if let running = MixerTaps.running.first(where: { $0.appID == app && $0.isHeard }) {
            // The mixer's device runs at the output's rate, as it is now.
            if mixerTap != running.tap || followedRate != rate {
                dropTap()
                meter.follow(running.tap, sampleRate: rate, latency: latency)
                mixerTap = running.tap
                followedRate = rate
            }
            send(.running)
            return
        }
        if mixerTap != nil { dropTap() }

        let signature = VolumeTap.Signature(processes: processes, outputUID: output.uid)
        if tap?.signature == signature, followedRate == rate {
            send(.running)
            return
        }
        if failed == signature {
            send(.failed)
            return
        }
        dropTap()
        failed = nil
        tapsMade += 1
        do {
            let made = try NowPlayingAudioTap.make(
                appName: appName ?? app, signature: signature, output: output, meter: meter, id: -tapsMade
            )
            meter.follow(made.id, sampleRate: made.sampleRate, latency: latency)
            do {
                try made.start()
            } catch {
                meter.stopFollowing()
                made.destroy()
                throw error
            }
            tap = made
            followedRate = rate
            send(.running)
        } catch {
            failed = signature
            send(.failed)
        }
    }

    private func dropTap() {
        meter.stopFollowing()
        mixerTap = nil
        followedRate = nil
        tap?.destroy()
        tap = nil
    }

    /// Moves the sample-rate listener to `device`, or takes it off.
    private func watchRate(of device: AudioObjectID?) {
        guard device != watchedOutput else { return }
        var address = MixerHAL.address(kAudioDevicePropertyNominalSampleRate)
        if let watchedOutput, let listener {
            AudioObjectRemovePropertyListenerBlock(watchedOutput, &address, queue, listener)
        }
        watchedOutput = device
        if let device, let listener {
            AudioObjectAddPropertyListenerBlock(device, &address, queue, listener)
        }
    }

    /// Moves the process listeners to `processes`, or takes them all off. Fails
    /// harmlessly for a process that has already gone.
    private func watchProcesses(_ processes: [AudioObjectID]) {
        let wanted = listener == nil ? [] : Set(processes)
        guard wanted != watchedProcesses else { return }
        for id in watchedProcesses.subtracting(wanted) {
            setListening(false, to: id)
        }
        for id in wanted.subtracting(watchedProcesses) {
            setListening(true, to: id)
        }
        watchedProcesses = wanted
    }

    private func setListening(_ isOn: Bool, to process: AudioObjectID) {
        guard let listener else { return }
        for property in Self.processProperties {
            var address = property
            if isOn {
                AudioObjectAddPropertyListenerBlock(process, &address, queue, listener)
            } else {
                AudioObjectRemovePropertyListenerBlock(process, &address, queue, listener)
            }
        }
    }

    /// A failed read, as for a process that just went away, counts as not playing.
    private static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        (MixerHAL.read(UInt32(0), kAudioProcessPropertyIsRunningOutput, of: process) ?? 0) != 0
    }

    /// The app's audio processes, lowest first, as the mixer lists them.
    private func processes(of app: String) -> [AudioObjectID] {
        let current = MixerHAL.objects(kAudioHardwarePropertyProcessObjectList, of: MixerHAL.system)
        let present = Set(current)
        owners = owners.filter { present.contains($0.key) }
        var mine: [AudioObjectID] = []
        for id in current {
            let owner: String
            if let known = owners[id] {
                owner = known
            } else {
                let source = MixerHAL.read(pid_t(0), kAudioProcessPropertyPID, of: id)
                    .flatMap { AudioAppResolver.source(for: $0) }
                owner = source?.id ?? ""
                owners[id] = owner
                if owner == app, appName == nil { appName = source?.name }
            }
            if owner == app { mine.append(id) }
        }
        return mine.sorted()
    }

    private func send(_ status: NowPlayingLevelStatus) {
        guard status != lastStatus, let report else { return }
        lastStatus = status
        DispatchQueue.main.async {
            MainActor.assumeIsolated { report(status) }
        }
    }
}
