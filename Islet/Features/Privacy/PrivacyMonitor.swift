import Foundation
import Observation

/// An app using the microphone. Identified by its bundle, so a helper process
/// (a browser's audio service, an Electron app's renderer) counts as the app itself.
struct PrivacyApp: Equatable, Sendable {
    let bundlePath: String
    let name: String

    init(bundlePath: String) {
        self.bundlePath = bundlePath
        var name = FileManager.default.displayName(atPath: bundlePath)
        if name.hasSuffix(".app") { name.removeLast(4) }
        self.name = name
    }
}

/// What is in use right now.
struct PrivacyUsage: Equatable, Sendable {
    var camera = false
    var microphone = false
    /// Apps recording from the microphone, when macOS can say which: on 14.2 and
    /// later, and only for processes that live inside an app bundle.
    var apps: [PrivacyApp] = []
}

/// Knows whether the camera and microphone are in use, and by which apps, without
/// permission to use either: it only watches whether some process is running them.
/// Readings settle for a moment before they are published, so a device that blinks
/// on and off while an app sets up does not flicker the island.
@MainActor
@Observable
final class PrivacyMonitor {
    enum Sensor: Hashable {
        case camera, microphone
    }

    /// Something began using a sensor.
    struct Start {
        var sensor: Sensor
        /// The app that began recording, when it can be named.
        var app: PrivacyApp?
    }

    /// What to show: the settled readings, or a preview standing in for them.
    private(set) var usage = PrivacyUsage()

    /// Called after `usage` changes. `started` is set when a sensor or app newly
    /// started, but not for one that was already busy when watching began.
    @ObservationIgnored var onChange: (_ started: Start?) -> Void = { _ in }

    @ObservationIgnored private let cameraWatcher = PrivacyCameraWatcher()
    @ObservationIgnored private let microphoneWatcher = PrivacyMicrophoneWatcher()
    @ObservationIgnored private var watchesCamera = false
    @ObservationIgnored private var watchesMicrophone = false
    /// Bumped on every start and stop, so a reading already on its way to the main
    /// queue from an earlier watch is recognised and dropped.
    @ObservationIgnored private var cameraGeneration = 0
    @ObservationIgnored private var microphoneGeneration = 0

    /// The newest readings, not yet settled.
    @ObservationIgnored private var latest = PrivacyUsage()
    @ObservationIgnored private var settled = PrivacyUsage()
    /// Sensors being watched whose first reading has not arrived.
    @ObservationIgnored private var awaitingFirst: Set<Sensor> = []
    /// Sensors whose first reading is in `latest`: whatever they show was already so.
    @ObservationIgnored private var baseline: Set<Sensor> = []
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    @ObservationIgnored private var preview: PrivacyUsage?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    /// Starts or stops watching each sensor. Safe to call with unchanged values.
    func watch(camera: Bool, microphone: Bool) {
        if camera != watchesCamera {
            watchesCamera = camera
            cameraGeneration &+= 1
            if camera {
                awaitingFirst.insert(.camera)
                let generation = cameraGeneration
                cameraWatcher.start { [weak self] inUse in
                    self?.cameraRead(inUse, generation: generation)
                }
            } else {
                cameraWatcher.stop()
                awaitingFirst.remove(.camera)
                latest.camera = false
                scheduleSettle()
            }
        }

        if microphone != watchesMicrophone {
            watchesMicrophone = microphone
            microphoneGeneration &+= 1
            if microphone {
                awaitingFirst.insert(.microphone)
                let generation = microphoneGeneration
                microphoneWatcher.start { [weak self] reading in
                    self?.microphoneRead(reading, generation: generation)
                }
            } else {
                microphoneWatcher.stop()
                awaitingFirst.remove(.microphone)
                latest.microphone = false
                latest.apps = []
                scheduleSettle()
            }
        }
    }

    /// Stops watching and forgets everything, a running preview included.
    func stop() {
        watch(camera: false, microphone: false)
        settleTask?.cancel()
        previewTask?.cancel()
        preview = nil
        latest = PrivacyUsage()
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

    // MARK: Readings

    private func cameraRead(_ inUse: Bool, generation: Int) {
        guard generation == cameraGeneration else { return }
        if awaitingFirst.remove(.camera) != nil { baseline.insert(.camera) }
        latest.camera = inUse
        scheduleSettle()
    }

    private func microphoneRead(_ reading: PrivacyMicrophoneWatcher.Reading, generation: Int) {
        guard generation == microphoneGeneration else { return }
        if awaitingFirst.remove(.microphone) != nil { baseline.insert(.microphone) }
        latest.microphone = reading.inUse
        latest.apps = reading.apps
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
        settled = latest
        let started = Self.start(from: before, to: settled, ignoring: baseline)
        baseline = []
        publish(started: started)
    }

    private func publish(started: Start?) {
        let next = preview ?? settled
        guard next != usage else { return }
        usage = next
        onChange(preview == nil ? started : nil)
    }

    /// What newly started between two readings. The camera wins when both did, and
    /// carries the app that started recording alongside it, if any.
    private static func start(from old: PrivacyUsage, to new: PrivacyUsage, ignoring quiet: Set<Sensor>) -> Start? {
        let newApp = quiet.contains(.microphone) ? nil : new.apps.first { !old.apps.contains($0) }
        if new.camera, !old.camera, !quiet.contains(.camera) {
            return Start(sensor: .camera, app: newApp)
        }
        if let newApp {
            return Start(sensor: .microphone, app: newApp)
        }
        if new.microphone, !old.microphone, !quiet.contains(.microphone) {
            return Start(sensor: .microphone, app: nil)
        }
        return nil
    }
}
