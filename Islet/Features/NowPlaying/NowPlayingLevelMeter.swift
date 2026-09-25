import CoreAudio
import Foundation
import Synchronization

/// The waveform's live levels, on their way from the audio IO thread to the bars.
///
/// A ring of the latest analyses, each stamped with the moment its sound reaches the
/// ears, so the bars show what is being heard rather than what the app has just
/// played: through Bluetooth headphones, that can be a fifth of a second later, and
/// through AirPlay two seconds. One writer, the IO thread, and readers on the main
/// thread, and nobody ever waits: every slot is held in atomics, and a reader checks
/// after reading one that the writer has not come round the ring and started
/// overwriting it in the meantime.
@available(macOS 15.0, *)
final class AudioLevelBoard: @unchecked Sendable {
    /// The analyser publishes at most every 5.3 ms (its hop at 48 kHz, and a little
    /// less often at other rates), so this holds at least 5.4 s of levels whatever the
    /// buffers: the longest output latency followed, with room to spare. 32 KB.
    static let slots = 1024

    /// Per slot: the moment it stands for, as `Double` bits, then a word per layout.
    private let stride: Int
    private let layouts: Int
    private let words: UnsafeMutablePointer<Atomic<UInt64>>
    /// How many analyses have been published; the next goes in slot `published % slots`.
    private let published = Atomic<UInt64>(0)

    init(layouts: Int) {
        self.layouts = layouts
        stride = 1 + layouts
        let count = Self.slots * stride
        words = .allocate(capacity: count)
        for index in 0..<count { (words + index).initialize(to: Atomic(0)) }
    }

    deinit {
        words.deinitialize(count: Self.slots * stride)
        words.deallocate()
    }

    /// Adds a set of levels, heard at `time` (host seconds): `word` gives each
    /// layout's, packed. IO thread.
    func publish(at time: Double, word: (Int) -> UInt64) {
        let count = published.load(ordering: .relaxed)
        let slot = words + Int(count % UInt64(Self.slots)) * stride
        slot[0].store(time.bitPattern, ordering: .relaxed)
        for layout in 0..<layouts {
            slot[1 + layout].store(word(layout), ordering: .relaxed)
        }
        published.store(count &+ 1, ordering: .releasing)
    }

    /// The newest levels for `layout` heard by `time`, and when they were heard; `nil`
    /// when there are none. Main thread.
    func read(layout: Int, at time: Double) -> (word: UInt64, time: Double)? {
        let count = published.load(ordering: .acquiring)
        guard count > 0, layout < layouts else { return nil }
        let oldest = count > UInt64(Self.slots) ? count - UInt64(Self.slots) : 0
        var index = count
        while index > oldest {
            index -= 1
            let slot = words + Int(index % UInt64(Self.slots)) * stride
            let heard = Double(bitPattern: slot[0].load(ordering: .acquiring))
            guard heard <= time else { continue }
            let word = slot[1 + layout].load(ordering: .acquiring)
            // Lapped while reading: the writer may have been part way through this slot.
            guard published.load(ordering: .acquiring) - index < UInt64(Self.slots) else { return nil }
            return (word, heard)
        }
        return nil
    }
}

/// Follows one app's sound for the waveform, from Now Playing's own tap or from the
/// mixer's, and keeps the bars' levels on `board`.
///
/// `hear` runs on the IO thread. It works only on sound from the tap it is following
/// and, through a flag it only ever tries for, never at the same time as anything
/// else, so a tap being swapped for another cannot have two threads in the analyser.
/// The engine's queue does the swapping, taking the same flag, which the IO thread
/// holds for a few microseconds at a time.
@available(macOS 15.0, *)
final class NowPlayingLevelMeter: MixerSoundListener, @unchecked Sendable {
    /// `following` when no tap is.
    static let nobody = 0

    let analyser: AudioLevelAnalyser
    let board: AudioLevelBoard
    /// The tap whose sound counts: a mixer renderer's id (positive), one of Now
    /// Playing's own (negative), or `nobody`.
    private let following = Atomic<Int>(nobody)
    private let busy = Atomic<Bool>(false)
    /// Seconds from analysing sound to hearing it, as `Double` bits.
    private let delay = Atomic<UInt64>(0)
    /// When the last buffer arrived, or the tap followed now was taken up if it has
    /// sent none, in host seconds as `Double` bits; 0 for never.
    private let lastBuffer = Atomic<UInt64>(0)
    /// When the last buffer holding anything but silence arrived, as `lastBuffer`.
    private let lastSignal = Atomic<UInt64>(0)
    private let secondsPerTick: Double

    /// The longest output latency whose sound the bars can wait for, in seconds:
    /// AirPlay's two or so, and more than any wired or Bluetooth output. An output
    /// slower than this is not followed at all, since the bars would run ahead of it.
    static let longestLatency: Double = 3

    init?() {
        guard let analyser = AudioLevelAnalyser() else { return nil }
        self.analyser = analyser
        board = AudioLevelBoard(layouts: AudioLevelAnalyser.layouts.count)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    // MARK: IO thread

    func hear(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, from tap: Int) {
        guard following.load(ordering: .relaxed) == tap,
              busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged
        else { return }
        // Looked at again now the flag is held: the tap may have been swapped since.
        if following.load(ordering: .relaxed) == tap {
            let arrived = now()
            if analyser.process(samples, frames: frames, channels: channels) {
                let heard = arrived + Double(bitPattern: delay.load(ordering: .relaxed))
                board.publish(at: heard) { analyser.packed(layout: $0) }
            }
            if analyser.bufferHadSignal { lastSignal.store(arrived.bitPattern, ordering: .relaxed) }
            lastBuffer.store(arrived.bitPattern, ordering: .relaxed)
        }
        busy.store(false, ordering: .releasing)
    }

    // MARK: Engine queue

    /// Starts counting `tap`'s sound, at `sampleRate`, heard `latency` seconds after
    /// it arrives.
    ///
    /// The tap counts as having just delivered, so whoever watches for it stalling
    /// gives it as long to start as any other gap, rather than judging it by the
    /// last buffer of a tap followed before.
    func follow(_ tap: Int, sampleRate: Double, latency: Double) {
        following.store(Self.nobody, ordering: .releasing)
        claim()
        analyser.configure(sampleRate: sampleRate)
        // The bars stand for the middle of the analyser's window, which is already
        // that far behind the newest sound.
        let wait = min(max(latency - analyser.windowDelay, 0), Self.longestLatency)
        delay.store(wait.bitPattern, ordering: .relaxed)
        lastBuffer.store(now().bitPattern, ordering: .relaxed)
        busy.store(false, ordering: .releasing)
        following.store(tap, ordering: .releasing)
    }

    /// Stops counting any tap's sound. What has been heard stands, so a tap swapped
    /// for another of the same app's keeps the bars live across the swap.
    func stopFollowing() {
        following.store(Self.nobody, ordering: .releasing)
    }

    /// Forgets what has been heard, for another app, or none.
    func forget() {
        stopFollowing()
        // A buffer already being analysed would otherwise mark it heard again.
        claim()
        lastSignal.store(0, ordering: .relaxed)
        lastBuffer.store(0, ordering: .relaxed)
        busy.store(false, ordering: .releasing)
    }

    /// Host seconds, as `CACurrentMediaTime` counts them. Safe on the IO thread.
    private func now() -> Double {
        Double(mach_absolute_time()) * secondsPerTick
    }

    /// Waits out the IO thread, which holds the flag for one buffer's analysis at most.
    private func claim() {
        while !busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged {
            usleep(100)
        }
    }

    // MARK: Main thread

    /// When anything but silence last arrived, in host seconds; `nil` for never since
    /// the app was taken up.
    var lastSignalTime: Double? {
        let bits = lastSignal.load(ordering: .relaxed)
        return bits == 0 ? nil : Double(bitPattern: bits)
    }

    /// When the tap followed now last delivered a buffer, or was taken up if it has
    /// delivered none, in host seconds; `nil` for never.
    var lastBufferTime: Double? {
        let bits = lastBuffer.load(ordering: .relaxed)
        return bits == 0 ? nil : Double(bitPattern: bits)
    }

    /// Seconds from analysing sound to hearing it, for the tap followed now.
    var latency: Double { Double(bitPattern: delay.load(ordering: .relaxed)) }
}

/// Now Playing's own tap on an app's sound, for when the mixer is not already
/// playing it: like the mixer's `VolumeTap`, but it leaves the sound alone.
///
/// The tap is unmuted, so the app plays exactly as before, and private; its aggregate
/// device is private too and named with the mixer's UID prefix, which keeps the
/// Privacy feature from taking it for a microphone. The IOProc only reads: every
/// output stream is off for it, and it clears any output buffer it is handed anyway.
/// macOS removes the tap and device with Islet if it quits.
///
/// Made, used and destroyed only on the level engine's queue.
@available(macOS 15.0, *)
final class NowPlayingAudioTap {
    let signature: VolumeTap.Signature
    let sampleRate: Double
    /// The id `NowPlayingLevelMeter.hear` gets for this tap's sound.
    let id: Int
    private let tap: AudioObjectID
    private let aggregate: AudioObjectID
    private let proc: AudioDeviceIOProcID
    private let context: UnsafeMutablePointer<IOContext>
    private var isRunning = false

    /// What the IOProc needs, behind a pointer it gets as its client data, so the IO
    /// thread touches no Swift object's reference count.
    private struct IOContext {
        let meter: Unmanaged<NowPlayingLevelMeter>
        let tapStream: Int
        let id: Int
    }

    private init(
        signature: VolumeTap.Signature, sampleRate: Double, id: Int, tap: AudioObjectID,
        aggregate: AudioObjectID, proc: AudioDeviceIOProcID, context: UnsafeMutablePointer<IOContext>
    ) {
        self.signature = signature
        self.sampleRate = sampleRate
        self.id = id
        self.tap = tap
        self.aggregate = aggregate
        self.proc = proc
        self.context = context
    }

    /// Builds the tap, device and IOProc, not yet running. Never call without the
    /// system audio recording permission: making a tap is what would have macOS ask.
    static func make(
        appName: String, signature: VolumeTap.Signature, output: MixerOutputDevice,
        meter: NowPlayingLevelMeter, id: Int
    ) throws -> NowPlayingAudioTap {
        let description = CATapDescription(stereoMixdownOfProcesses: signature.processes)
        description.uuid = UUID()
        description.name = "Islet – \(appName) waveform"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try VolumeTap.check(AudioHardwareCreateProcessTap(description, &tap))
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var proc: AudioDeviceIOProcID?
        var context: UnsafeMutablePointer<IOContext>?
        do {
            let tapUID = MixerHAL.string(kAudioTapPropertyUID, of: tap) ?? description.uuid.uuidString
            let composition = VolumeTap.composition(name: "\(appName) waveform", tapUID: tapUID, output: output)
            try VolumeTap.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate))
            guard let tapStream = VolumeTap.tapStreamIndex(on: aggregate, output: output) else {
                throw VolumeTap.Failure.unexpectedLayout
            }
            let sampleRate = MixerHAL.read(Float64(0), kAudioDevicePropertyNominalSampleRate, of: aggregate) ?? 48_000

            let made = UnsafeMutablePointer<IOContext>.allocate(capacity: 1)
            made.initialize(to: IOContext(meter: Unmanaged.passRetained(meter), tapStream: tapStream, id: id))
            context = made
            try VolumeTap.check(AudioDeviceCreateIOProcID(aggregate, Self.ioProc, made, &proc))
            guard let proc else { throw VolumeTap.Failure.status(kAudioHardwareUnspecifiedError) }
            if output.inputStreams > 0 {
                try VolumeTap.useOnlyStream(tapStream, of: output.inputStreams + 1, on: aggregate, for: proc)
            }
            // Only a saving: the IOProc writes nothing, whether or not this takes.
            turnOffOutput(on: aggregate, for: proc)
            return NowPlayingAudioTap(
                signature: signature, sampleRate: sampleRate, id: id, tap: tap,
                aggregate: aggregate, proc: proc, context: made
            )
        } catch {
            if let proc { AudioDeviceDestroyIOProcID(aggregate, proc) }
            if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
            AudioHardwareDestroyProcessTap(tap)
            if let context {
                context.pointee.meter.release()
                context.deinitialize(count: 1)
                context.deallocate()
            }
            throw error
        }
    }

    func start() throws {
        guard !isRunning else { return }
        try VolumeTap.check(AudioDeviceStart(aggregate, proc))
        isRunning = true
    }

    /// The device goes before the tap it reads from, and the IOProc's context only
    /// once the IOProc is gone.
    func destroy() {
        if isRunning { AudioDeviceStop(aggregate, proc) }
        isRunning = false
        AudioDeviceDestroyIOProcID(aggregate, proc)
        AudioHardwareDestroyAggregateDevice(aggregate)
        AudioHardwareDestroyProcessTap(tap)
        context.pointee.meter.release()
        context.deinitialize(count: 1)
        context.deallocate()
    }

    /// Hands the tap's input to the meter. On the HAL's IO thread.
    private static let ioProc: AudioDeviceIOProc = { _, _, input, _, output, _, clientData in
        guard let clientData else { return noErr }
        let context = clientData.assumingMemoryBound(to: IOContext.self)
        let tapStream = context.pointee.tapStream
        let id = context.pointee.id
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if tapStream < inputs.count, inputs[tapStream].mNumberChannels > 0,
           let samples = inputs[tapStream].mData?.assumingMemoryBound(to: Float.self) {
            let channels = Int(inputs[tapStream].mNumberChannels)
            let frames = Int(inputs[tapStream].mDataByteSize) / (channels * MemoryLayout<Float>.size)
            context.pointee.meter._withUnsafeGuaranteedRef {
                $0.hear(samples, frames: frames, channels: channels, from: id)
            }
        }
        // Indexed rather than iterated: the iterator's type would be instantiated on
        // first use, which allocates, and this is the IO thread.
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for index in 0..<outputs.count {
            if let data = outputs[index].mData { memset(data, 0, Int(outputs[index].mDataByteSize)) }
        }
        return noErr
    }

    /// Tells the HAL this IOProc wants none of the device's output streams.
    private static func turnOffOutput(on device: AudioObjectID, for proc: AudioDeviceIOProcID) {
        let count = MixerHAL.count(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: device)
        guard count > 0 else { return }
        let layout = MemoryLayout<AudioHardwareIOProcStreamUsage>.self
        guard let procOffset = layout.offset(of: \.mIOProc),
              let countOffset = layout.offset(of: \.mNumberStreams),
              let flagsOffset = layout.offset(of: \.mStreamIsOn)
        else { return }
        let size = flagsOffset + count * MemoryLayout<UInt32>.stride
        let usage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: layout.alignment)
        defer { usage.deallocate() }
        usage.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), toByteOffset: procOffset, as: UnsafeMutableRawPointer.self)
        usage.storeBytes(of: UInt32(count), toByteOffset: countOffset, as: UInt32.self)
        for stream in 0..<count {
            usage.storeBytes(of: UInt32(0), toByteOffset: flagsOffset + stream * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
        var address = MixerHAL.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeOutput)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), usage)
    }

    /// Seconds from sound reaching the output device to its being heard: the
    /// device's latency and safety offset, its stream's, and one buffer.
    static func latency(of output: MixerOutputDevice) -> Double {
        let scope = kAudioObjectPropertyScopeOutput
        let rate = MixerHAL.read(Float64(0), kAudioDevicePropertyNominalSampleRate, of: output.id) ?? 48_000
        guard rate > 0 else { return 0 }
        var frames = 0
        frames += Int(MixerHAL.read(UInt32(0), kAudioDevicePropertyLatency, scope: scope, of: output.id) ?? 0)
        frames += Int(MixerHAL.read(UInt32(0), kAudioDevicePropertySafetyOffset, scope: scope, of: output.id) ?? 0)
        frames += Int(MixerHAL.read(UInt32(0), kAudioDevicePropertyBufferFrameSize, of: output.id) ?? 0)
        if let stream = MixerHAL.objects(kAudioDevicePropertyStreams, scope: scope, of: output.id).first {
            frames += Int(MixerHAL.read(UInt32(0), kAudioStreamPropertyLatency, of: stream) ?? 0)
        }
        return Double(frames) / rate
    }
}
