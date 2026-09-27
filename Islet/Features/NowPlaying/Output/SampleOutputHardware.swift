import CoreAudio
import Foundation

/// The outputs the preview shows: the Mac's speakers, AirPods Pro with sound going to
/// them, and a display's speakers. It speaks for no device and never reaches Core
/// Audio; picking one, moving the slider or changing the AirPods' listening mode or
/// spatial audio changes only its own state.
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
    private var followedControls: [AudioObjectID] = []
    /// The AirPods' controls: every listening mode, both buds in, and a song being
    /// spatialized with head tracking.
    private var controls = HeadsetControls(
        listening: ListeningModeState(support: 0b111, current: .transparency, isSettable: true, isWorn: true),
        spatial: SpatialAudioState(
            content: .stereo, mode: .headTracked, isHeadTracked: true, offersHeadTracking: true, app: 1, isSettable: true
        )
    )

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

    func device(uid: String) -> AudioObjectID? {
        samples.first { $0.uid == uid }?.id
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

    func readHeadset(_ device: AudioObjectID) -> HeadsetReading? {
        guard device == Self.airPods else { return nil }
        return HeadsetReading(controls: lock.withLock { controls }, listened: [.listeningMode])
    }

    func setListeningMode(_ mode: ListeningMode, of device: AudioObjectID) -> HeadsetControlResult {
        guard device == Self.airPods else { return .unavailable }
        Thread.sleep(forTimeInterval: Self.controlDelay)
        lock.withLock { controls.listening?.current = mode }
        changedControls()
        return .done
    }

    func setSpatialAudio(_ mode: SpatialAudioMode, for content: SpatialContent, of device: AudioObjectID) -> HeadsetControlResult {
        guard device == Self.airPods else { return .unavailable }
        Thread.sleep(forTimeInterval: Self.controlDelay)
        lock.withLock {
            controls.spatial?.mode = mode
            if mode != .off { controls.spatial?.isHeadTracked = mode == .headTracked }
        }
        changedControls()
        return .done
    }

    /// Nothing to read again: the samples change only as they are set, and a set
    /// reads them again of itself.
    func followControls(_ headsets: [AudioObjectID: [HeadsetProperty]]) -> Bool {
        followedControls = Array(headsets.keys)
        return false
    }

    /// Long enough to see the control wait for the headset.
    private static let controlDelay: TimeInterval = 0.15

    private func changedControls() {
        if followedControls.contains(Self.airPods) { changed?(.controls) }
    }
}
