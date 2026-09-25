import Foundation
import Observation

/// An app using a sensor. Identified by its bundle, so a helper process (a browser's
/// audio service, an Electron app's renderer) counts as the app itself. A process
/// that lives in no app bundle, and belongs to no app that could be found, has no
/// bundle and is known by a name alone.
struct PrivacyApp: Hashable, Sendable {
    let bundlePath: String?
    let name: String

    init(bundlePath: String) {
        self.bundlePath = bundlePath
        var name = FileManager.default.displayName(atPath: bundlePath)
        if name.hasSuffix(".app") { name.removeLast(4) }
        self.name = name
    }

    init(name: String) {
        bundlePath = nil
        self.name = name
    }
}

/// One sensor right now: whether it is in use and, when macOS lets that be seen, by
/// which apps. In use with no apps means in use by something that cannot be named.
struct PrivacyUse: Equatable, Sendable {
    var inUse = false
    var apps: [PrivacyApp] = []

    static func inUse(_ apps: PrivacyApp...) -> PrivacyUse {
        PrivacyUse(inUse: true, apps: apps)
    }
}

/// What is in use right now.
struct PrivacyUsage: Equatable, Sendable {
    var camera = PrivacyUse()
    var microphone = PrivacyUse()
    /// The screen being captured: recorded, shared or mirrored.
    var screen = PrivacyUse()
    /// What the Mac plays being recorded, by an app other than Islet.
    var systemAudio = PrivacyUse()
    var location = PrivacyUse()
    /// The Sound Mixer passing an app's sound through at its own level, which macOS
    /// counts as recording what the Mac plays. It is Islet's own doing and expected,
    /// so it never lights anything; the home page mentions it only in its list of
    /// several sensors in use.
    var soundMixer = false

    subscript(sensor: PrivacyMonitor.Sensor) -> PrivacyUse {
        get {
            switch sensor {
            case .camera: camera
            case .microphone: microphone
            case .screen: screen
            case .systemAudio: systemAudio
            case .location: location
            }
        }
        set {
            switch sensor {
            case .camera: camera = newValue
            case .microphone: microphone = newValue
            case .screen: screen = newValue
            case .systemAudio: systemAudio = newValue
            case .location: location = newValue
            }
        }
    }

    /// The sensors in use, in the order the home page lists them.
    var sensorsInUse: [PrivacyMonitor.Sensor] {
        PrivacyMonitor.Sensor.allCases.filter { self[$0].inUse }
    }
}

/// Knows which sensors are in use, and by which apps, without permission to use any:
/// it only watches whether some process is running them.
///
/// Whether a sensor is on comes from the system itself: CoreMediaIO for cameras, Core
/// Audio for microphones, WindowServer for the screen. Those never say who, except
/// Core Audio for a microphone. The rest of the names, and whether location or the
/// Mac's own sound is being recorded at all, come from the system log, which macOS
/// shows only to administrators (`PrivacyNameTracker`). The log never turns a sensor
/// on or off where the system can say; it only puts names to it.
///
/// Readings settle for a moment before they are published, so a device that blinks
/// on and off while an app sets up does not flicker the island.
@MainActor
@Observable
final class PrivacyMonitor {
    enum Sensor: CaseIterable, Hashable, Sendable {
        case camera, microphone, screen, systemAudio, location
    }

    /// Something began using a sensor.
    struct Start: Equatable {
        var sensor: Sensor
        /// The app that began, when it can be named.
        var app: PrivacyApp?
    }

    /// What to show: the settled readings, or a preview standing in for them.
    private(set) var usage = PrivacyUsage()
    /// Whether apps can be named from the system log, for Settings to explain when
    /// they cannot.
    private(set) var names = PrivacyNameTracker.Status.off

    /// Called after `usage` changes, and when a start held back for its app's name is
    /// let go. `started` is set when a sensor or app newly started, but not for one
    /// that was already busy when watching began.
    @ObservationIgnored var onChange: (_ started: Start?) -> Void = { _ in }

    @ObservationIgnored private let cameraWatcher = PrivacyCameraWatcher()
    @ObservationIgnored private let microphoneWatcher = PrivacyMicrophoneWatcher()
    @ObservationIgnored private let screenWatcher = PrivacyScreenWatcher()
    @ObservationIgnored private let nameTracker = PrivacyNameTracker()

    /// The sensors being watched. Recording what the Mac plays is watched with the
    /// screen, as the two share macOS's purple dot.
    @ObservationIgnored private var watched: Set<Sensor> = []
    /// Bumped on every start and stop, so a reading already on its way to the main
    /// queue from an earlier watch is recognised and dropped.
    @ObservationIgnored private var generations: [Sensor: Int] = [:]
    @ObservationIgnored private var namesGeneration = 0

    // The newest readings, not yet settled.
    @ObservationIgnored private var cameraOn = false
    @ObservationIgnored private var microphone = PrivacyMicrophoneWatcher.Reading()
    @ObservationIgnored private var screenCaptured: Bool?
    @ObservationIgnored private var named = PrivacyNames()

    @ObservationIgnored private var settled = PrivacyUsage()
    /// Sensors being watched whose first reading has not arrived.
    @ObservationIgnored private var awaitingFirst: Set<Sensor> = []
    /// Sensors whose first reading is in: whatever they show was already so.
    @ObservationIgnored private var baseline: Set<Sensor> = []
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    /// A start whose app the log has not named yet, held back briefly so the banner
    /// can say who rather than only what.
    @ObservationIgnored private var heldStart: Start?
    @ObservationIgnored private var heldTask: Task<Void, Never>?

    @ObservationIgnored private var preview: PrivacyUsage?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    /// How long a start waits for the log to name its app.
    static let nameWait: Duration = .seconds(1)

    /// Starts or stops watching each sensor. Safe to call with unchanged values.
    func watch(camera: Bool, microphone: Bool, screen: Bool, location: Bool) {
        var wanted: Set<Sensor> = []
        if camera { wanted.insert(.camera) }
        if microphone { wanted.insert(.microphone) }
        if screen { wanted.formUnion([.screen, .systemAudio]) }
        if location { wanted.insert(.location) }
        guard wanted != watched else { return }
        let before = Self.watchers(for: watched)
        let running = Self.watchers(for: wanted)
        baseline.formUnion(Self.joiningRunningWatchers(from: watched, to: wanted))
        watched = wanted

        for sensor in [Sensor.camera, .microphone, .screen] where running.contains(sensor) != before.contains(sensor) {
            let generation = (generations[sensor] ?? 0) &+ 1
            generations[sensor] = generation
            if running.contains(sensor) {
                awaitingFirst.insert(sensor)
                startWatcher(sensor, generation: generation)
            } else {
                stopWatcher(sensor)
                awaitingFirst.remove(sensor)
            }
        }

        // The log is needed for names of the camera and the screen, and for whether
        // the Mac's sound or location is in use at all. Microphones name themselves.
        let logged = wanted.subtracting([.microphone])
        namesGeneration &+= 1
        if logged.isEmpty {
            nameTracker.stop()
            named = PrivacyNames()
            names = .off
        } else {
            let generation = namesGeneration
            nameTracker.watch(logged, report: { [weak self] names in
                self?.namesRead(names, generation: generation)
            }, status: { [weak self] status in
                guard let self, generation == namesGeneration else { return }
                names = status
            })
        }
        scheduleSettle()
    }

    /// Stops watching and forgets everything, a running preview included.
    func stop() {
        watch(camera: false, microphone: false, screen: false, location: false)
        settleTask?.cancel()
        heldTask?.cancel()
        heldStart = nil
        previewTask?.cancel()
        preview = nil
        settled = PrivacyUsage()
        baseline = []
        usage = PrivacyUsage()
    }

    /// Shows `sample` in place of the real readings for eight seconds, touching no
    /// device.
    func showPreview(_ sample: PrivacyUsage) {
        previewTask?.cancel()
        preview = sample
        publish(started: nil)
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            preview = nil
            publish(started: nil)
        }
    }

    // MARK: Watchers

    /// The system watchers `sensors` need. The microphone's is needed for the Mac's
    /// sound too, even with the microphone's own dot turned off: the audio server
    /// reports both alike, and only Core Audio can say which is which.
    nonisolated static func watchers(for sensors: Set<Sensor>) -> Set<Sensor> {
        var watchers = sensors.intersection([.camera, .microphone, .screen])
        if sensors.contains(.systemAudio) { watchers.insert(.microphone) }
        return watchers
    }

    /// Sensors newly watched whose watcher is running already, for another sensor:
    /// the microphone's, turned on while the Mac's sound was watched with it. No first
    /// reading is coming for them, so what they show now is taken as already so, as a
    /// first reading's would be, rather than announced as starting.
    nonisolated static func joiningRunningWatchers(from old: Set<Sensor>, to new: Set<Sensor>) -> Set<Sensor> {
        new.subtracting(old).intersection(watchers(for: old))
    }

    private func startWatcher(_ sensor: Sensor, generation: Int) {
        switch sensor {
        case .camera:
            cameraWatcher.start { [weak self] inUse in
                self?.cameraRead(inUse, generation: generation)
            }
        case .microphone:
            microphoneWatcher.start { [weak self] reading in
                self?.microphoneRead(reading, generation: generation)
            }
        case .screen:
            screenWatcher.start { [weak self] captured in
                self?.screenRead(captured, generation: generation)
            }
        case .systemAudio, .location:
            break
        }
    }

    private func stopWatcher(_ sensor: Sensor) {
        switch sensor {
        case .camera:
            cameraWatcher.stop()
            cameraOn = false
        case .microphone:
            microphoneWatcher.stop()
            microphone = PrivacyMicrophoneWatcher.Reading()
        case .screen:
            screenWatcher.stop()
            screenCaptured = nil
        case .systemAudio, .location:
            break
        }
    }

    // MARK: Readings

    private func isCurrent(_ sensor: Sensor, _ generation: Int) -> Bool {
        generations[sensor] == generation && Self.watchers(for: watched).contains(sensor)
    }

    /// Notes a sensor's first reading, and says whether this was it.
    @discardableResult
    private func firstReading(_ sensor: Sensor) -> Bool {
        guard awaitingFirst.remove(sensor) != nil else { return false }
        baseline.insert(sensor)
        return true
    }

    private func cameraRead(_ inUse: Bool, generation: Int) {
        guard isCurrent(.camera, generation) else { return }
        let first = firstReading(.camera)
        // The log's camera clients are only trusted between the camera's edges.
        if inUse != cameraOn { nameTracker.cameraChanged(on: inUse, at: Date(), atStart: first) }
        cameraOn = inUse
        scheduleSettle()
    }

    private func microphoneRead(_ reading: PrivacyMicrophoneWatcher.Reading, generation: Int) {
        guard isCurrent(.microphone, generation) else { return }
        firstReading(.microphone)
        microphone = reading
        // A call ending changes this; what the audio server said was recording is
        // held to Core Audio again, in case its own word of the stop was missed.
        nameTracker.recheckRecorders()
        scheduleSettle()
    }

    private func screenRead(_ captured: Bool?, generation: Int) {
        guard isCurrent(.screen, generation) else { return }
        let first = firstReading(.screen)
        if first, captured == true {
            nameTracker.screenChanged(captured: true, at: Date(), atStart: true)
        } else if let captured, let was = screenCaptured, captured != was {
            nameTracker.screenChanged(captured: captured, at: Date(), atStart: false)
        }
        screenCaptured = captured
        scheduleSettle()
    }

    private func namesRead(_ names: PrivacyNames, generation: Int) {
        guard generation == namesGeneration else { return }
        named = names
        scheduleSettle()
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    private func settle() {
        let before = settled
        settled = Self.usage(
            watching: watched, camera: cameraOn, microphone: microphone, screen: screenCaptured,
            names: named, ownPID: getpid()
        )
        var started = Self.start(from: before, to: settled, ignoring: baseline)
        baseline = []

        // A held start whose app has since been named goes out now, named, unless
        // another sensor's start is going out (one banner at a time); one whose sensor
        // has gone again is dropped.
        if let held = heldStart {
            let use = settled[held.sensor]
            if !use.inUse {
                releaseHeldStart(announce: false)
            } else if let app = use.apps.first {
                releaseHeldStart(announce: false)
                if started == nil || started?.sensor == held.sensor { started = Start(sensor: held.sensor, app: app) }
            }
        }
        // The camera and the screen are named from the log, which can lag the system's
        // own reading by a moment: an unnamed start waits for it, briefly.
        if let start = started, start.app == nil, start.sensor != .microphone, names == .running, heldStart == nil {
            heldStart = start
            started = nil
            heldTask = Task { [weak self] in
                try? await Task.sleep(for: Self.nameWait)
                guard !Task.isCancelled else { return }
                self?.releaseHeldStart(announce: true)
            }
        }
        publish(started: started)
    }

    private func releaseHeldStart(announce: Bool) {
        heldTask?.cancel()
        heldTask = nil
        guard let held = heldStart else { return }
        heldStart = nil
        if announce, preview == nil, settled[held.sensor].inUse {
            onChange(Start(sensor: held.sensor, app: settled[held.sensor].apps.first))
        }
    }

    private func publish(started: Start?) {
        let next = preview ?? settled
        guard next != usage else {
            // Nothing new to draw, but a start still needs announcing.
            if let started, preview == nil { onChange(started) }
            return
        }
        usage = next
        onChange(preview == nil ? started : nil)
    }

    // MARK: Decisions

    /// Puts the system's readings and the log's names together. The system says what
    /// is on; the log only names it, and for location and the Mac's own sound, which
    /// the system does not report, says what is on too.
    ///
    /// What the audio server reports as recording is the Mac's sound unless Core Audio
    /// shows that process recording a microphone. While a microphone is in use by
    /// processes Core Audio cannot point to, nothing the audio server reports can be
    /// told apart from it, so none of it counts as the Mac's sound: a missed purple dot
    /// rather than a false one. Islet's own recording is the Sound Mixer's, which never
    /// counts. Control Center's own list stands in for names the other sources could
    /// not give.
    ///
    /// WindowServer's flag counts captures macOS leaves unmarked, AirPlay's mirroring
    /// among them. While the log says those are all there is, and nobody is named, the
    /// screen is not taken to be captured: macOS shows no dot for it either.
    nonisolated static func usage(
        watching: Set<Sensor>, camera: Bool, microphone: PrivacyMicrophoneWatcher.Reading, screen: Bool?,
        names: PrivacyNames, ownPID: pid_t
    ) -> PrivacyUsage {
        var usage = PrivacyUsage()
        func fallback(_ apps: [PrivacyApp], _ sensor: Sensor) -> [PrivacyApp] {
            apps.isEmpty ? names.controlCenter[sensor] ?? [] : apps
        }

        if watching.contains(.camera), camera {
            usage.camera = PrivacyUse(inUse: true, apps: fallback(names.camera, .camera))
        }
        if watching.contains(.microphone), microphone.inUse {
            usage.microphone = PrivacyUse(inUse: true, apps: fallback(merged(microphone.apps, names.capturedMicrophone), .microphone))
        }
        if watching.contains(.screen), screen ?? !names.screen.isEmpty {
            let apps = fallback(names.screen, .screen)
            if !(names.screenUnmarked && apps.isEmpty) {
                usage.screen = PrivacyUse(inUse: true, apps: apps)
            }
        }
        if watching.contains(.systemAudio) {
            let ambiguous = microphone.inUse && microphone.pids.isEmpty
            let others = ambiguous ? [] : names.recorders.filter { recorder in
                recorder.pid != ownPID
                    && !microphone.pids.contains(recorder.pid)
                    && !(recorder.app.map(microphone.apps.contains) ?? false)
            }
            usage.soundMixer = names.recorders.contains { $0.pid == ownPID }
            if !others.isEmpty || !names.capturedAudio.isEmpty {
                let apps = merged(others.compactMap(\.app), names.capturedAudio)
                usage.systemAudio = PrivacyUse(inUse: true, apps: fallback(apps, .systemAudio))
            }
        }
        if watching.contains(.location) {
            usage.location = names.location
        }
        return usage
    }

    /// What newly started between two readings: a sensor coming on, or a new app
    /// on one already on. Only the camera, the microphone and the screen are
    /// announced, the camera first. A camera no one can be named for borrows the app
    /// that started recording at the same moment, as a call starts both.
    nonisolated static func start(from old: PrivacyUsage, to new: PrivacyUsage, ignoring quiet: Set<Sensor>) -> Start? {
        func newApp(_ sensor: Sensor) -> PrivacyApp? {
            quiet.contains(sensor) ? nil : new[sensor].apps.first { !old[sensor].apps.contains($0) }
        }
        for sensor in [Sensor.camera, .microphone, .screen] where !quiet.contains(sensor) && new[sensor].inUse {
            let app = newApp(sensor) ?? (sensor == .camera && !old.camera.inUse ? newApp(.microphone) : nil)
            if !old[sensor].inUse { return Start(sensor: sensor, app: app) }
            if let app = newApp(sensor) { return Start(sensor: sensor, app: app) }
        }
        return nil
    }

    private nonisolated static func merged(_ first: [PrivacyApp], _ second: [PrivacyApp]) -> [PrivacyApp] {
        var apps = first
        for app in second where !apps.contains(app) { apps.append(app) }
        return apps
    }
}
