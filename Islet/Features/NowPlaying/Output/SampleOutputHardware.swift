import CoreAudio
import Foundation

/// The outputs the preview shows: the Mac's speakers, AirPods Pro with sound going to
/// them, and a display's speakers. It speaks for no device and never reaches Core
/// Audio; picking one or moving the slider changes only its own state.
final class SampleOutputHardware: OutputHardware, @unchecked Sendable {
    private static let speakers: AudioObjectID = 1
    private static let airPods: AudioObjectID = 2
    private static let display: AudioObjectID = 3

    /// Long enough to see a pick being made.
    private static let switchDelay: TimeInterval = 0.35

    let batteries = [
        BluetoothAudioWatcher.headsetID(uid: "PREVIEW-AIR-PODS:output"): Headset.sampleAirPodsPro.battery,
    ]

    private let lock = NSLock()
    private var current = SampleOutputHardware.airPods
    private var levels: [AudioObjectID: Double] = [speakers: 0.5, airPods: 0.62, display: 0.8]
    private var changed: (@Sendable (OutputChange) -> Void)?
    private var followed: AudioObjectID?

    private let samples = [
        OutputCandidate(
            id: speakers, uid: "preview.speakers", name: "MacBook Pro Speakers",
            transport: kAudioDeviceTransportTypeBuiltIn
        ),
        OutputCandidate(
            id: airPods, uid: "PREVIEW-AIR-PODS:output", name: "AirPods Pro",
            transport: kAudioDeviceTransportTypeBluetooth, modelUID: "2024 4c"
        ),
        OutputCandidate(
            id: display, uid: "preview.display", name: "Studio Display Speakers",
            transport: kAudioDeviceTransportTypeUSB
        ),
    ]

    func candidates() -> [OutputCandidate] { samples }

    func uid(of device: AudioObjectID) -> String? {
        samples.first { $0.id == device }?.uid
    }

    func defaultOutput() -> AudioObjectID? {
        lock.withLock { current }
    }

    func defaultSystemOutput() -> AudioObjectID? {
        defaultOutput()
    }

    func setDefaultOutput(_ device: AudioObjectID) -> OSStatus {
        Thread.sleep(forTimeInterval: Self.switchDelay)
        lock.withLock { current = device }
        changed?(.devices)
        return noErr
    }

    func setDefaultSystemOutput(_ device: AudioObjectID) -> OSStatus { noErr }

    func volume(of device: AudioObjectID) -> OutputVolume? {
        lock.withLock { levels[device] }.map { OutputVolume(level: $0, isMuted: $0 == 0, isSettable: true) }
    }

    func setVolume(_ level: Double, of device: AudioObjectID) -> Bool {
        lock.withLock { levels[device] = level }
        if device == followed { changed?(.volume) }
        return true
    }

    func listen(on queue: DispatchQueue, _ changed: @escaping @Sendable (OutputChange) -> Void) {
        self.changed = changed
    }

    func stopListening() {
        changed = nil
        followed = nil
    }

    func followVolume(of device: AudioObjectID?) {
        followed = device
    }
}
