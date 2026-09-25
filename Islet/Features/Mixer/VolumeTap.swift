import CoreAudio
import Foundation
import os

/// One app's sound, played at a level of its own.
///
/// Three pieces: a private process tap over every audio process the app has, which
/// mutes the app at the source for as long as the tap is being read; a private
/// aggregate device made of the current output with the tap as its input; and an
/// IOProc on that device that copies the one to the other with the gain applied.
/// Stopping the IOProc lets the app's sound take its normal path again, so nothing
/// is lost if Islet stops or quits: macOS removes private taps and devices with the
/// process that made them.
///
/// Made, used and destroyed only on the mixer's queue.
final class VolumeTap {
    /// What a tap was made over. A change of either means making a new one.
    struct Signature: Equatable {
        let processes: [AudioObjectID]
        let outputUID: String
    }

    enum Failure: Error {
        case unsupported
        /// macOS would not allow it.
        case refused
        /// The aggregate device's inputs were not as expected, so which one is the
        /// tap could not be told for sure.
        case unexpectedLayout
        case status(OSStatus)
    }

    /// How the UID of every aggregate device a tap makes begins, so the microphone
    /// watcher can tell the mixer's devices, whose input is a tap, from microphones.
    static let deviceUIDPrefix = "\(Bundle.main.bundleIdentifier ?? "Islet").mixer."

    let signature: Signature
    private(set) var isRunning = false
    private let tap: AudioObjectID
    private let aggregate: AudioObjectID
    private let proc: AudioDeviceIOProcID
    private let renderer: GainRenderer

    private init(signature: Signature, tap: AudioObjectID, aggregate: AudioObjectID, proc: AudioDeviceIOProcID, renderer: GainRenderer) {
        self.signature = signature
        self.tap = tap
        self.aggregate = aggregate
        self.proc = proc
        self.renderer = renderer
    }

    /// Builds the tap, device and IOProc, not yet running. Creating the tap is what
    /// makes macOS ask for permission, if it has not been answered.
    static func make(appName: String, signature: Signature, output: MixerOutputDevice, gain: Float) throws -> VolumeTap {
        guard #available(macOS 14.2, *) else { throw Failure.unsupported }

        let description = CATapDescription(stereoMixdownOfProcesses: signature.processes)
        description.uuid = UUID()
        description.name = "Islet – \(appName)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap))
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var proc: AudioDeviceIOProcID?
        do {
            let tapUID = MixerHAL.string(kAudioTapPropertyUID, of: tap) ?? description.uuid.uuidString
            let composition = composition(name: appName, tapUID: tapUID, output: output)
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate))
            guard let tapStream = tapStreamIndex(on: aggregate, output: output) else { throw Failure.unexpectedLayout }

            let sampleRate = MixerHAL.read(Float64(0), kAudioDevicePropertyNominalSampleRate, of: aggregate) ?? 48_000
            let renderer = GainRenderer(gain: gain, sampleRate: sampleRate)
            // No dispatch queue: the block runs on the HAL's realtime IO thread.
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, destination, _ in
                renderer.render(input, tapBuffer: tapStream, into: destination)
            })
            guard let proc else { throw Failure.status(kAudioHardwareUnspecifiedError) }
            if output.inputStreams > 0 {
                try useOnlyStream(tapStream, of: output.inputStreams + 1, on: aggregate, for: proc)
            }
            return VolumeTap(signature: signature, tap: tap, aggregate: aggregate, proc: proc, renderer: renderer)
        } catch {
            if let proc { AudioDeviceDestroyIOProcID(aggregate, proc) }
            if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
    }

    func setGain(_ gain: Float) {
        renderer.setTarget(gain)
    }

    /// Takes the app's sound over.
    func start() throws {
        guard !isRunning else { return }
        try Self.check(AudioDeviceStart(aggregate, proc))
        isRunning = true
    }

    /// Hands the app's sound back to its normal path.
    func stop() {
        guard isRunning else { return }
        AudioDeviceStop(aggregate, proc)
        isRunning = false
    }

    /// The device goes before the tap it reads from.
    func destroy() {
        stop()
        AudioDeviceDestroyIOProcID(aggregate, proc)
        AudioHardwareDestroyAggregateDevice(aggregate)
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
    }

    // MARK: Building

    private static func check(_ status: OSStatus) throws {
        guard status != noErr else { return }
        if status == kAudioHardwareIllegalOperationError || status == kAudioDevicePermissionsError {
            throw Failure.refused
        }
        throw Failure.status(status)
    }

    /// Private, so it never shows in Sound settings and goes when Islet does; timed by
    /// the output, with the tap resampled to follow it.
    private static func composition(name: String, tapUID: String, output: MixerOutputDevice) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Islet – \(name)",
            kAudioAggregateDeviceUIDKey: deviceUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: 1,
            ]],
        ]
    }

    /// Which of the aggregate device's input streams is the tap's: the last, after
    /// the output's own. With no inputs of the output's own it can only be the first,
    /// and nothing need be read. Otherwise it is checked rather than assumed, since a
    /// mistake would play a microphone through the speakers: the count must match,
    /// and the last stream must not declare a physical terminal, which a microphone
    /// or line input does and the tap does not.
    private static func tapStreamIndex(on aggregate: AudioObjectID, output: MixerOutputDevice) -> Int? {
        guard output.inputStreams > 0 else { return 0 }
        let streams = MixerHAL.objects(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: aggregate)
        guard streams.count == output.inputStreams + 1, let last = streams.last else { return nil }
        let terminal = MixerHAL.read(UInt32(0), kAudioStreamPropertyTerminalType, of: last)
        guard terminal == nil || terminal == kAudioStreamTerminalTypeUnknown else { return nil }
        return output.inputStreams
    }

    /// Leaves the output's own inputs off for this IOProc, so taking an app's sound
    /// over never opens a headset's microphone.
    private static func useOnlyStream(_ index: Int, of count: Int, on device: AudioObjectID, for proc: AudioDeviceIOProcID) throws {
        let layout = MemoryLayout<AudioHardwareIOProcStreamUsage>.self
        guard let procOffset = layout.offset(of: \.mIOProc),
              let countOffset = layout.offset(of: \.mNumberStreams),
              let flagsOffset = layout.offset(of: \.mStreamIsOn)
        else { throw Failure.unexpectedLayout }

        let size = flagsOffset + count * MemoryLayout<UInt32>.stride
        let usage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: layout.alignment)
        defer { usage.deallocate() }
        usage.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), toByteOffset: procOffset, as: UnsafeMutableRawPointer.self)
        usage.storeBytes(of: UInt32(count), toByteOffset: countOffset, as: UInt32.self)
        for stream in 0..<count {
            let isOn: UInt32 = stream == index ? 1 : 0
            usage.storeBytes(of: isOn, toByteOffset: flagsOffset + stream * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
        var address = MixerHAL.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), usage))
    }
}

/// The realtime half of a `VolumeTap`: copies the tapped sound to the output at the
/// current gain.
///
/// It runs on the HAL's IO thread, so it never allocates and never waits. A new gain
/// crosses over through a try-lock; one missed is picked up a cycle later, a few
/// milliseconds on. Changes are ramped rather than stepped, which would click, and
/// a boost is rounded off towards full scale rather than clipped.
final class GainRenderer: @unchecked Sendable {
    /// Where boosted sound starts being rounded off.
    private static let knee: Float = 0.8

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// Guarded by `lock`.
    private var target: Float
    // IO thread only, once running.
    private var wanted: Float
    private var gain: Float
    /// The most the gain moves in one frame: from silence to full in 15 ms.
    private let step: Float

    init(gain: Float, sampleRate: Float64) {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        target = gain
        wanted = gain
        self.gain = gain
        step = Float(1 / (0.015 * max(sampleRate, 8_000)))
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func setTarget(_ value: Float) {
        os_unfair_lock_lock(lock)
        target = value
        os_unfair_lock_unlock(lock)
    }

    /// Stereo goes to the output's first two channels, as macOS plays it, and a mono
    /// output gets the two halves mixed. Whatever the tap does not cover is silence.
    func render(_ input: UnsafePointer<AudioBufferList>, tapBuffer: Int, into output: UnsafeMutablePointer<AudioBufferList>) {
        if os_unfair_lock_trylock(lock) {
            wanted = target
            os_unfair_lock_unlock(lock)
        }

        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard tapBuffer < inputs.count,
              let source = inputs[tapBuffer].mData?.assumingMemoryBound(to: Float.self),
              inputs[tapBuffer].mNumberChannels > 0
        else {
            Self.silence(outputs)
            return
        }
        let sourceChannels = Int(inputs[tapBuffer].mNumberChannels)
        let sourceFrames = Int(inputs[tapBuffer].mDataByteSize) / (sourceChannels * MemoryLayout<Float>.size)
        var outputChannels = 0
        for buffer in outputs { outputChannels += Int(buffer.mNumberChannels) }
        let mixesToMono = outputChannels == 1 && sourceChannels > 1

        let from = gain
        let reach = step * Float(max(sourceFrames, 1))
        let to = from + min(max(wanted - from, -reach), reach)
        gain = to
        let rounds = from > 1 || to > 1

        var firstChannel = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            defer { firstChannel += channels }
            guard channels > 0, let destination = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            let copied = min(frames, sourceFrames)
            let slope = frames > 0 ? (to - from) / Float(frames) : 0

            for channel in 0..<channels {
                let outputChannel = firstChannel + channel
                if outputChannel < 2 {
                    let sourceChannel = min(outputChannel, sourceChannels - 1)
                    for frame in 0..<copied {
                        let base = frame * sourceChannels
                        let sample = mixesToMono
                            ? (source[base] + source[base + 1]) * 0.5
                            : source[base + sourceChannel]
                        let scaled = sample * (from + slope * Float(frame))
                        destination[frame * channels + channel] = rounds ? Self.roundOff(scaled) : scaled
                    }
                    for frame in copied..<frames { destination[frame * channels + channel] = 0 }
                } else {
                    for frame in 0..<frames { destination[frame * channels + channel] = 0 }
                }
            }
        }
    }

    private static func silence(_ outputs: UnsafeMutableAudioBufferListPointer) {
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }

    /// Unchanged up to the knee, then eased towards full scale without reaching it,
    /// so a boost that runs out of headroom softens instead of crackling.
    @inline(__always)
    private static func roundOff(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > knee else { return sample }
        let eased = knee + (1 - knee) * tanhf((magnitude - knee) / (1 - knee))
        return sample < 0 ? -eased : eased
    }
}
