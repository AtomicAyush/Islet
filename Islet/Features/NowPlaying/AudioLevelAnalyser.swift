import Accelerate
import Foundation

/// Turns sound into the heights of the Now Playing waveform's bars: one band of
/// frequencies per bar, from the kick drum on the left to the cymbals on the right.
///
/// It runs on the audio IO thread, so once made and configured, `process` never
/// allocates, waits or calls into the Swift runtime. Every buffer it will ever need
/// is made up front at the size the highest sample rate asks for, and everything it
/// changes lives behind unsafe pointers, which Swift does not check for exclusive
/// access as it does a class's own properties. It is not thread safe: one thread at a
/// time may use it, and `configure` must not overlap `process`.
///
/// Each buffer is mixed down to mono into a ring. Once enough new sound has arrived,
/// the last 21 ms or so go through a Hann window and a real FFT (1024 points at 44.1
/// or 48 kHz, 2048 at 88.2 or 96 kHz, so the bins are about as wide at any rate), and
/// the bins are summed into bands spaced evenly in octaves from 40 Hz to 12 kHz, one
/// set for each number of bars the island draws.
///
/// A band's level is in decibels, tilted up towards the treble above 250 Hz, since
/// music carries far more energy low down and the bass bar would otherwise drown the
/// rest. Each band keeps a reference: how loud it typically is in this song. It climbs
/// to meet louder sound over about a second, so a hit barely moves it but a louder
/// section does (and at once when the sound is well above it, as when a song starts),
/// and sinks only a third of a decibel a second, so it spans sections rather than
/// notes. A bar is full 6 dB above its band's reference and empty 24 dB below full,
/// which puts a steady sound — a held chord, a pad — in the upper middle, with room
/// above it for the notes and hits that stand out, and a quiet breakdown lower than
/// the chorus before it, as it sounds. Quiet and loud songs fill the bars alike,
/// since the references follow the song's own level. A band is turned up to meet the
/// loudest band by 5 dB at most, so the bars keep the music's balance, and what leaks
/// from a loud neighbour — a bass note near 125 Hz shows in the second bar only 7 dB
/// down, at this FFT's resolution — stays below the note itself; nothing is turned up
/// past a floor, so near-silence stays flat. Once every band has gone quiet, as
/// between songs, the references sink fast, so the next song starts afresh.
///
/// The heights rise within about 10 ms and fall over about 160. Once kicks come
/// regularly, the bass bar keeps half its height for the kick drum: a sudden jump
/// below 125 Hz, even a few decibels over a busy bass line, fills that half for a
/// moment, so the beat shows in a loud modern master, where the kick is hardly louder
/// than the bass, as well as in a sparse mix. A held bass note, or a lone thud, sets
/// nothing aside, so the bass bar reads it as any other bar would.
final class AudioLevelAnalyser {
    /// The numbers of bars the island draws, each getting bands of its own: the
    /// compact and expanded players' five, the bubble's four, the switcher's three.
    static let layouts = [5, 4, 3]
    /// The lowest and highest frequencies the bars cover.
    static let lowestFrequency: Float = 40
    static let highestFrequency: Float = 12_000

    /// How long the FFT looks back, in seconds; the FFT is the power of two nearest.
    private static let window: Double = 0.0213
    /// The largest FFT, for 176.4 and 192 kHz.
    private static let maximumLog2: Int = 12
    private static let maximumSize = 1 << maximumLog2
    /// Treble is lifted this much per octave above `tiltFrom`.
    private static let tilt: Float = 3
    private static let tiltFrom: Float = 250
    /// How far above its band's reference a bar is full, in dB.
    private static let headroom: Float = 6
    /// How far below full a bar reads as empty, in dB.
    private static let span: Float = 24
    /// How far below the loudest band's reference a band's own may be and still set
    /// its bar's scale, in dB; below that, the band is measured against the loudest.
    private static let spread: Float = 5
    /// The lowest a reference counts for, in dB below a full-scale sine in that band,
    /// before the tilt.
    private static let floor: Float = -40
    /// How quickly a reference climbs to louder sound, as a time constant in seconds;
    /// and, when the sound is more than `far` dB above it, as at the start of a song.
    private static let climb: Float = 1.0
    private static let leap: Float = 0.1
    private static let far: Float = 3
    /// How fast references sink while there is sound, and once every band is below
    /// its floor, in dB per second.
    private static let sink: Float = 0.35
    private static let silentSink: Float = 6
    /// Heights are raised to this power, so the middle of the range reads lower and a
    /// hit stands out from a busy mix.
    private static let curve: Float = 1.5
    private static let attack: Float = 0.010
    private static let release: Float = 0.160
    /// The kick drum's band.
    private static let kickLow: Float = 40
    private static let kickHigh: Float = 125
    /// A kick is the kick band this many dB above its recent average, and counts in
    /// full `kickScale` dB above that: a loud master leaves a kick only 5 to 8 dB over
    /// the bass line, while a bass note in the same mix rises 3 at most.
    private static let kickThreshold: Float = 2.5
    private static let kickScale: Float = 3
    /// The share of the bass bar kept for kicks, and how long one takes to fade: gone
    /// well before the next beat, even at 180 BPM.
    private static let kickShare: Float = 0.5
    private static let kickFade: Float = 0.06
    /// Kicks this close together make a beat, which sets the share aside; a beat
    /// fades over `beatFade` seconds once they stop.
    private static let beatGap: Float = 1.5
    private static let beatFade: Float = 3
    /// How quickly the kick band's recent average follows it.
    private static let kickAverage: Float = 0.1
    /// Sound below this, in sample value, counts as nothing at all (-100 dBFS).
    private static let silence: Float = 1e-5

    /// What changes as sound arrives. Kept in one struct behind a pointer: see the
    /// type's documentation.
    private struct State {
        var sampleRate: Double = 48_000
        var log2Size = 10
        var size = 1024
        /// Where the next mono sample goes in the ring.
        var write = 0
        /// Frames since the last FFT.
        var pending = 0
        /// Fewest new frames worth another FFT.
        var hop = 256
        /// Anything above silence has arrived since `configure`.
        var heardSignal = false
        /// The last buffer `process` took held something above silence.
        var bufferHadSignal = false
        /// 1 / (the band power of a full-scale sine).
        var powerScale: Float = 1
        /// The kick band's bins.
        var kickFirst = 1
        var kickLast = 2
        /// The kick band's recent average, in dB.
        var kickAverage: Float = -120
        /// How much of the bass bar's kick share is lit now, 0...1.
        var kick: Float = 0
        /// A kick is under way, so its next analyses do not count as another.
        var kickOn = false
        /// Seconds since the last kick began.
        var sinceKick: Float = .greatestFiniteMagnitude
        /// How much of the kick share is set aside, 0...1: all of it while kicks come
        /// regularly, none for a held bass note or one lone thud.
        var beat: Float = 0
    }

    /// Where each layout's bands start in the per-band arrays.
    private let offsets: [Int]
    private let bandCount: Int

    private let setup: FFTSetup
    /// `layouts` and `offsets` again, for the IO thread, which should not touch an array.
    private let layoutCount: Int
    private let barsPerLayout: UnsafeMutablePointer<Int>
    private let layoutStart: UnsafeMutablePointer<Int>
    private let state: UnsafeMutablePointer<State>
    private let ring: UnsafeMutablePointer<Float>
    private let hann: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    /// One layout's weighted band levels, while they are worked on.
    private let levels: UnsafeMutablePointer<Float>
    // Per band.
    private let firstBin: UnsafeMutablePointer<Int>
    private let lastBin: UnsafeMutablePointer<Int>
    private let weight: UnsafeMutablePointer<Float>
    /// How loud the band typically is in this song, in weighted dB.
    private let reference: UnsafeMutablePointer<Float>
    private let envelope: UnsafeMutablePointer<Float>

    /// `nil` only if vDSP cannot make its FFT tables.
    init?() {
        // Made once for the largest size; it serves every smaller one too.
        guard let setup = vDSP_create_fftsetup(vDSP_Length(Self.maximumLog2), FFTRadix(kFFTRadix2)) else {
            return nil
        }
        self.setup = setup
        var offsets: [Int] = []
        var total = 0
        for bars in Self.layouts {
            offsets.append(total)
            total += bars
        }
        self.offsets = offsets
        bandCount = total
        layoutCount = Self.layouts.count
        barsPerLayout = .allocate(capacity: layoutCount)
        barsPerLayout.initialize(from: Self.layouts, count: layoutCount)
        layoutStart = .allocate(capacity: layoutCount)
        layoutStart.initialize(from: offsets, count: layoutCount)
        let size = Self.maximumSize
        state = .allocate(capacity: 1)
        state.initialize(to: State())
        ring = .allocate(capacity: size)
        hann = .allocate(capacity: size)
        windowed = .allocate(capacity: size)
        real = .allocate(capacity: size / 2)
        imaginary = .allocate(capacity: size / 2)
        power = .allocate(capacity: size / 2)
        let widest = Self.layouts.max() ?? 1
        levels = .allocate(capacity: widest)
        levels.initialize(repeating: 0, count: widest)
        firstBin = .allocate(capacity: total)
        lastBin = .allocate(capacity: total)
        weight = .allocate(capacity: total)
        reference = .allocate(capacity: total)
        envelope = .allocate(capacity: total)
        for buffer in [ring, hann, windowed] { buffer.initialize(repeating: 0, count: size) }
        for buffer in [real, imaginary, power] { buffer.initialize(repeating: 0, count: size / 2) }
        firstBin.initialize(repeating: 0, count: total)
        lastBin.initialize(repeating: 0, count: total)
        for buffer in [weight, reference, envelope] { buffer.initialize(repeating: 0, count: total) }
        configure(sampleRate: 48_000)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        state.deallocate()
        for buffer in [ring, hann, windowed, real, imaginary, power, levels, weight, reference, envelope] {
            buffer.deallocate()
        }
        for table in [barsPerLayout, layoutStart, firstBin, lastBin] { table.deallocate() }
    }

    // MARK: Setting up

    /// Readies the analyser for sound at `sampleRate`, forgetting everything heard
    /// before. Never while `process` may run.
    func configure(sampleRate: Double) {
        let rate = min(max(sampleRate.isFinite ? sampleRate : 48_000, 8_000), 384_000)
        let log2Size = min(max(Int((log2(rate * Self.window)).rounded()), 8), Self.maximumLog2)
        let size = 1 << log2Size
        var fresh = State()
        fresh.sampleRate = rate
        fresh.log2Size = log2Size
        fresh.size = size
        // About 5 ms at any rate: often enough for a display at 60 or 120 Hz, and
        // sparse enough that the meter's ring holds seconds of levels, whatever the
        // buffers. The HAL's usual buffers of 512 or so each get an FFT of their own.
        fresh.hop = size / 4
        // A full-scale sine's power across a Hann window's bins: N² · 3/32, and vDSP's
        // real FFT returns twice the transform, so four times the power.
        fresh.powerScale = 1 / (Float(size) * Float(size) * 3 / 32 * 4)

        let binWidth = Float(rate) / Float(size)
        let half = size / 2
        fresh.kickFirst = Self.firstBin(from: Self.kickLow, binWidth: binWidth, half: half)
        fresh.kickLast = Self.lastBin(below: Self.kickHigh, first: fresh.kickFirst, binWidth: binWidth, half: half)
        state.pointee = fresh

        vDSP_hann_window(hann, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        for (layout, bars) in Self.layouts.enumerated() {
            let ratio = Self.highestFrequency / Self.lowestFrequency
            for bar in 0..<bars {
                let band = offsets[layout] + bar
                let low = Self.lowestFrequency * powf(ratio, Float(bar) / Float(bars))
                let high = Self.lowestFrequency * powf(ratio, Float(bar + 1) / Float(bars))
                firstBin[band] = Self.firstBin(from: low, binWidth: binWidth, half: half)
                lastBin[band] = Self.lastBin(below: high, first: firstBin[band], binWidth: binWidth, half: half)
                weight[band] = Self.tilt * max(0, log2f(sqrtf(low * high) / Self.tiltFrom))
            }
        }
        reset()
    }

    /// Each bin goes to the band its centre falls in; a band narrower than a bin
    /// still gets the one nearest it.
    private static func firstBin(from low: Float, binWidth: Float, half: Int) -> Int {
        min(max(1, Int(ceilf(low / binWidth))), half - 1)
    }

    private static func lastBin(below high: Float, first: Int, binWidth: Float, half: Int) -> Int {
        min(max(first, Int(ceilf(high / binWidth)) - 1), half - 1)
    }

    /// Back to silence, as at the start of a stream.
    func reset() {
        ring.update(repeating: 0, count: Self.maximumSize)
        state.pointee.write = 0
        state.pointee.pending = 0
        state.pointee.heardSignal = false
        state.pointee.bufferHadSignal = false
        state.pointee.kickAverage = -120
        state.pointee.kick = 0
        state.pointee.kickOn = false
        state.pointee.sinceKick = .greatestFiniteMagnitude
        state.pointee.beat = 0
        // At the floor, so the first sound climbs from there at once.
        for band in 0..<bandCount { reference[band] = Self.floor + weight[band] }
        envelope.update(repeating: 0, count: bandCount)
    }

    // MARK: Reading

    var sampleRate: Double { state.pointee.sampleRate }
    var fftSize: Int { state.pointee.size }
    /// How far back the middle of the FFT's window sits, in seconds: how much later
    /// than the newest sound the bars stand for.
    var windowDelay: Double { Double(state.pointee.size) / 2 / state.pointee.sampleRate }
    /// Anything above silence has arrived since `configure` or `reset`.
    var heardSignal: Bool { state.pointee.heardSignal }
    /// The last buffer taken in held anything above silence. Safe on the IO thread.
    var bufferHadSignal: Bool { state.pointee.bufferHadSignal }

    /// A bar's height, 0...1, in `layout` (an index into `layouts`).
    func level(layout: Int, bar: Int) -> Float {
        envelope[layoutStart[layout] + bar]
    }

    /// A layout's heights, a byte each from the first bar up, for passing between
    /// threads as one word. Safe on the IO thread.
    func packed(layout: Int) -> UInt64 {
        let start = layoutStart[layout]
        var word: UInt64 = 0
        for bar in 0..<min(barsPerLayout[layout], 8) {
            let byte = UInt64(min(max(envelope[start + bar], 0), 1) * 255 + 0.5)
            word |= byte << (8 * UInt64(bar))
        }
        return word
    }

    static func unpack(_ word: UInt64, bar: Int) -> Float {
        Float((word >> (8 * UInt64(bar))) & 0xFF) / 255
    }

    // MARK: Listening

    /// Takes in a buffer of interleaved samples, and returns whether the heights moved
    /// on. Safe on the IO thread.
    @discardableResult
    func process(_ samples: UnsafePointer<Float>, frames: Int, channels: Int) -> Bool {
        guard frames > 0, channels > 0 else { return false }
        let size = state.pointee.size

        var loudest: Float = 0
        vDSP_maxmgv(samples, 1, &loudest, vDSP_Length(frames * channels))
        // NaN compares false, so garbage counts as nothing.
        let hadSignal = loudest > Self.silence
        state.pointee.bufferHadSignal = hadSignal
        if hadSignal { state.pointee.heardSignal = true }

        // Only the newest `size` frames can matter to the next FFT.
        let skipped = max(0, frames - size)
        var write = state.pointee.write
        let scale = 1 / Float(channels)
        for frame in skipped..<frames {
            let base = samples + frame * channels
            var sum: Float = 0
            for channel in 0..<channels { sum += base[channel] }
            ring[write] = sum * scale
            write += 1
            if write == size { write = 0 }
        }
        state.pointee.write = write
        state.pointee.pending += frames
        guard state.pointee.pending >= state.pointee.hop else { return false }
        let elapsed = Float(Double(state.pointee.pending) / state.pointee.sampleRate)
        state.pointee.pending = 0

        transform()
        detectKick(elapsed: elapsed)
        update(elapsed: elapsed)
        return true
    }

    /// The newest `size` samples, oldest first, through the window and the FFT, into
    /// `power` per bin.
    private func transform() {
        let size = state.pointee.size
        let write = state.pointee.write
        // The ring's oldest sample is where the next one goes.
        let tail = size - write
        vDSP_vmul(ring + write, 1, hann, 1, windowed, 1, vDSP_Length(tail))
        if write > 0 {
            vDSP_vmul(ring, 1, hann + tail, 1, windowed + tail, 1, vDSP_Length(write))
        }
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { pairs in
            vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(size / 2))
        }
        vDSP_fft_zrip(setup, &split, 1, vDSP_Length(state.pointee.log2Size), FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(size / 2))
    }

    /// The band's level now, in dB below a full-scale sine in it, before the tilt.
    private func bandLevel(from first: Int, to last: Int) -> Float {
        var sum: Float = 0
        vDSP_sve(power + first, 1, &sum, vDSP_Length(last - first + 1))
        let level = 10 * log10f(sum * state.pointee.powerScale + 1e-12)
        return level.isFinite ? level : -120
    }

    /// Lights the bass bar's kick share on a jump in the kick band over its recent
    /// average, fading after, and sets the share aside while kicks come regularly.
    private func detectKick(elapsed: Float) {
        let level = bandLevel(from: state.pointee.kickFirst, to: state.pointee.kickLast)
        let average = state.pointee.kickAverage
        let jump = level - average
        let strength = min(max((jump - Self.kickThreshold) / Self.kickScale, 0), 1)
        let kick = max(state.pointee.kick * expf(-elapsed / Self.kickFade), strength)
        state.pointee.kick = kick.isFinite ? kick : 0
        // Never below the floor, so bass arriving after silence is one kick rather than
        // a jump that takes a moment to average out.
        let followed = average + (level - average) * (1 - expf(-elapsed / Self.kickAverage))
        state.pointee.kickAverage = followed.isFinite ? max(followed, Self.floor) : Self.floor

        var beat = state.pointee.beat * expf(-elapsed / Self.beatFade)
        if strength >= 0.5, !state.pointee.kickOn {
            if state.pointee.sinceKick < Self.beatGap { beat = min(1, beat + 0.5) }
            state.pointee.sinceKick = 0
        } else {
            state.pointee.sinceKick += elapsed
        }
        // Over once it has all but faded, so a long kick is not counted twice.
        state.pointee.kickOn = strength >= 0.5 || (state.pointee.kickOn && strength > 0.1)
        state.pointee.beat = beat.isFinite ? beat : 0
    }

    private func update(elapsed: Float) {
        let kick = state.pointee.kick
        let set = Self.kickShare * state.pointee.beat
        let rise = 1 - expf(-elapsed / Self.attack)
        let settle = 1 - expf(-elapsed / Self.release)
        let climb = 1 - expf(-elapsed / Self.climb)
        let leap = 1 - expf(-elapsed / Self.leap)

        for layout in 0..<layoutCount {
            let bars = barsPerLayout[layout]
            let start = layoutStart[layout]

            // Weighted level of every band, and whether any is above its floor.
            var heard = false
            for bar in 0..<bars {
                let band = start + bar
                let level = bandLevel(from: firstBin[band], to: lastBin[band]) + weight[band]
                levels[bar] = level
                if level > Self.floor + weight[band] { heard = true }
            }

            // References follow, and the loudest of them sets how far the others may
            // be turned up.
            let sink = (heard ? Self.sink : Self.silentSink) * elapsed
            var loudest: Float = -120
            for bar in 0..<bars {
                let band = start + bar
                let level = levels[bar]
                var moved = reference[band]
                if level > moved {
                    moved += (level - moved) * (level - moved > Self.far ? leap : climb)
                } else {
                    moved = max(moved - sink, level)
                }
                reference[band] = moved.isFinite ? max(moved, Self.floor + weight[band]) : Self.floor + weight[band]
                loudest = max(loudest, reference[band])
            }

            for bar in 0..<bars {
                let band = start + bar
                let full = max(reference[band], loudest - Self.spread) + Self.headroom
                var height = min(max((levels[bar] - full) / Self.span + 1, 0), 1)
                height = powf(height, Self.curve)
                if bar == 0 {
                    // The kick's share, lit as far as the bar itself is, so a flicker in
                    // a bass that is all but silent is not taken for a kick.
                    height = min(1, height * (1 - set) + Self.kickShare * kick * height.squareRoot())
                }
                let current = envelope[band]
                let moved = current + (height - current) * (height > current ? rise : settle)
                envelope[band] = moved.isFinite ? min(max(moved, 0), 1) : 0
            }
        }
    }
}
