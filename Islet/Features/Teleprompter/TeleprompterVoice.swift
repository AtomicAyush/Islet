import AVFoundation
import NaturalLanguage
import Speech

/// Listens to the reader for Follow my voice: the microphone, through Apple's speech
/// recogniser on this Mac. Audio never leaves it.
///
/// The model knows a source only by this, so the harness can stand in for the
/// microphone with transcripts it has written.
@MainActor
protocol SpeechSource: AnyObject {
    /// Starts listening. `heard` is called with everything heard since, as the
    /// recogniser's latest guess at it, again and again as it changes; `level` with the
    /// microphone's loudness, 0 to 1, a few times a second; `failed` once, with a
    /// sentence to show, should listening stop by itself.
    func start(
        hints: [String],
        heard: @escaping @MainActor (String) -> Void,
        level: @escaping @MainActor (Float) -> Void,
        failed: @escaping @MainActor (String) -> Void
    ) async throws
    /// Stops at once: the microphone is let go before this returns.
    func stop()
}

/// What may stand between Start and listening, asked in order, and only as Follow my
/// voice is started: whether this Mac can recognise the language without a server, the
/// microphone permission, the speech-recognition permission the older recogniser needs,
/// and the language's model. Nothing here is asked any earlier, and a refusal anywhere
/// leaves the microphone off.
@MainActor
protocol VoiceAccess: AnyObject {
    /// How this Mac would recognise `locale`, or why it can't on its own.
    func engine(for locale: Locale) async -> VoiceEngine
    var microphone: VoicePermission { get }
    func requestMicrophone() async -> Bool
    /// The older recogniser's own permission, which the newer one does without.
    var speechRecognition: VoicePermission { get }
    func requestSpeechRecognition() async -> Bool
    /// Fetches the language's model, if the Mac doesn't have it yet. Returns false if it
    /// can't be had.
    func installModel(for locale: Locale, engine: VoiceEngine) async -> Bool
    func makeSource(locale: Locale, engine: VoiceEngine) -> any SpeechSource
}

enum VoicePermission: Equatable {
    case notAsked
    case allowed
    case refused
}

/// How the voice is recognised: never with a server.
enum VoiceEngine: Equatable {
    /// macOS 26's speech analyser, which needs the microphone permission only.
    case analyzer(Locale)
    /// The older recogniser, made to stay on the Mac; it needs a permission of its own.
    case onDeviceRecognizer(Locale)
    /// This Mac can't recognise the language without sending the voice to a server.
    case unavailable(String)
}

/// Why Follow my voice can't start, as the page says it.
enum VoiceRefusal: Equatable {
    case unavailable(String)
    case microphoneRefused
    case speechRefused
    case modelUnavailable

    var message: String {
        switch self {
        case .unavailable(let reason): reason
        case .microphoneRefused:
            "Islet can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        case .speechRefused:
            "Islet can't use speech recognition. Allow it in System Settings › Privacy & Security › Speech Recognition."
        case .modelUnavailable:
            "The speech model for this language couldn't be fetched. Try again when the Mac is online."
        }
    }

    /// The pane of System Settings that puts it right, if one does.
    var settingsURL: URL? {
        switch self {
        case .microphoneRefused: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .speechRefused: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        case .unavailable, .modelUnavailable: nil
        }
    }
}

/// Goes through `VoiceAccess` in order as Follow my voice starts, and says what came of
/// it: a source to listen with, or why there is none. `step` is told of each stage as
/// it is reached, for the page to say what it waits on.
@MainActor
enum VoicePreparation {
    enum Step: Equatable {
        case checking
        case askingMicrophone
        case askingSpeech
        case fetchingModel
    }

    static func prepare(
        locale: Locale, access: any VoiceAccess, step: (Step) -> Void
    ) async -> Result<any SpeechSource, VoiceRefusalError> {
        step(.checking)
        let engine = await access.engine(for: locale)
        if case .unavailable(let reason) = engine { return .failure(VoiceRefusalError(.unavailable(reason))) }

        switch access.microphone {
        case .allowed: break
        case .refused: return .failure(VoiceRefusalError(.microphoneRefused))
        case .notAsked:
            step(.askingMicrophone)
            guard await access.requestMicrophone() else { return .failure(VoiceRefusalError(.microphoneRefused)) }
        }

        if case .onDeviceRecognizer = engine {
            switch access.speechRecognition {
            case .allowed: break
            case .refused: return .failure(VoiceRefusalError(.speechRefused))
            case .notAsked:
                step(.askingSpeech)
                guard await access.requestSpeechRecognition() else { return .failure(VoiceRefusalError(.speechRefused)) }
            }
        }

        step(.fetchingModel)
        guard await access.installModel(for: locale, engine: engine) else {
            return .failure(VoiceRefusalError(.modelUnavailable))
        }
        return .success(access.makeSource(locale: locale, engine: engine))
    }
}

struct VoiceRefusalError: Error, Equatable {
    let refusal: VoiceRefusal
    init(_ refusal: VoiceRefusal) { self.refusal = refusal }
}

/// The language to listen for: the one chosen in Settings, or the script's own, read
/// from its words, in the Mac's region where that fits ("en" on a British Mac is
/// en_GB), else the Mac's own language.
enum VoiceLanguage {
    /// Settings' value for working it out from the script.
    static let automatic = "auto"

    static func locale(for choice: String, script: String, current: Locale = .current) -> Locale {
        if choice != automatic, !choice.isEmpty { return Locale(identifier: choice) }
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(String(script.prefix(4000)))
        guard let language = recogniser.dominantLanguage?.rawValue else { return current }
        let currentLanguage = current.language.languageCode?.identifier
        if language == currentLanguage { return current }
        if let region = current.region?.identifier { return Locale(identifier: "\(language)_\(region)") }
        return Locale(identifier: language)
    }
}

// MARK: - The Mac's own

/// The Mac's microphone and speech recognition.
@MainActor
final class SystemVoiceAccess: VoiceAccess {
    func engine(for locale: Locale) async -> VoiceEngine {
        let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                return .analyzer(supported)
            }
            return .unavailable("This Mac can't recognise \(name) on its own. Choose another language in Settings, or read at a set pace.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .unavailable("This Mac can't recognise \(name). Choose another language in Settings, or read at a set pace.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .unavailable(
                "This Mac can recognise \(name) only by sending your voice to Apple, which Islet doesn't do. "
                    + "Choose another language in Settings, or read at a set pace."
            )
        }
        return .onDeviceRecognizer(locale)
    }

    var microphone: VoicePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .refused
        }
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    var speechRecognition: VoicePermission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .refused
        }
    }

    func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func installModel(for locale: Locale, engine: VoiceEngine) async -> Bool {
        guard case .analyzer(let locale) = engine else { return true }
        if #available(macOS 26, *) {
            let transcriber = AnalyzerSpeechSource.transcriber(for: locale)
            do {
                // Already on the Mac, as a rule, shared with other apps: then this finishes
                // at once, or there is nothing to ask for.
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                return await AssetInventory.status(forModules: [transcriber]) != .unsupported
            } catch {
                IslandLog.app.error("Teleprompter: speech model not installed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        return true
    }

    func makeSource(locale: Locale, engine: VoiceEngine) -> any SpeechSource {
        if #available(macOS 26, *), case .analyzer(let locale) = engine {
            return AnalyzerSpeechSource(locale: locale)
        }
        return RecognizerSpeechSource(locale: locale)
    }
}

enum SpeechSources {
    /// How much of what was heard a source keeps, in characters, of a reading that may
    /// go on for an hour: far more than the follower reads (`ScriptFollower.tail`).
    static let keptCharacters = 600
}

/// The Mac has no microphone to listen with: none built in (a Mac mini) and none
/// plugged in.
struct MicrophoneMissing: LocalizedError {
    var errorDescription: String? { "There's no microphone to listen with." }
}

/// The microphone, through an audio engine's tap: its buffers handed on as they come,
/// and its loudness, a few times a second.
private final class MicrophoneTap {
    private let engine = AVAudioEngine()
    private var isRunning = false

    /// Starts the microphone. `buffer` is called on the audio thread. Started already, it
    /// stops first, so there is only ever the one tap.
    func start(buffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void, level: @escaping @MainActor (Float) -> Void) throws -> AVAudioFormat {
        stop()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw MicrophoneMissing() }
        var lastLevel = Date.distantPast
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { pcm, time in
            buffer(pcm, time)
            let now = Date()
            guard now.timeIntervalSince(lastLevel) > 0.1 else { return }
            lastLevel = now
            let loudness = Self.loudness(of: pcm)
            DispatchQueue.main.async { MainActor.assumeIsolated { level(loudness) } }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
        return format
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Root mean square of the first channel, on a scale that puts speech mid-way.
    private static func loudness(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(max((decibels + 55) / 45, 0), 1)
    }
}

/// macOS 26's speech analyser: volatile results as each word is still being said,
/// biased toward speed, the script's rare words given as hints, and the model kept
/// a while after it stops, so resuming is quick. Nothing is sent to a server.
///
/// Starting waits on the analyser more than once before the microphone goes on. A stop
/// meanwhile is seen after each wait, and the start then ends without turning it on.
@available(macOS 26, *)
@MainActor
final class AnalyzerSpeechSource: SpeechSource {
    private let locale: Locale
    private let tap = MicrophoneTap()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    /// Bumped by each start and stop, so a start knows when it has been stopped.
    private var run = 0

    init(locale: Locale) {
        self.locale = locale
    }

    nonisolated static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: []
        )
    }

    func start(
        hints: [String],
        heard: @escaping @MainActor (String) -> Void,
        level: @escaping @MainActor (Float) -> Void,
        failed: @escaping @MainActor (String) -> Void
    ) async throws {
        run &+= 1
        let run = run
        let transcriber = Self.transcriber(for: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        self.analyzer = analyzer
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            try? await analyzer.setContext(context)
            guard self.run == run else { return }
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceRefusalError(.modelUnavailable)
        }
        guard self.run == run else { return }
        try await analyzer.prepareToAnalyze(in: format)
        guard self.run == run else { return }

        results = Task { @MainActor in
            var finalised = ""
            var volatile = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        // Only the last few words are ever read: the rest can go.
                        finalised = String((finalised + " " + text).suffix(SpeechSources.keptCharacters))
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    heard(finalised + " " + volatile)
                }
            } catch is CancellationError {
            } catch {
                failed("Listening stopped: \(error.localizedDescription)")
            }
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        input = continuation
        let micFormat = try tap.start(buffer: { [converter = ConverterBox(to: format)] buffer, _ in
            if let converted = converter.convert(buffer) { continuation.yield(AnalyzerInput(buffer: converted)) }
        }, level: level)
        _ = micFormat
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            // A start that fails lets the microphone go; one stopped meanwhile has been
            // let go already, and a newer start is left be.
            if self.run == run { stop() }
            throw error
        }
    }

    func stop() {
        run &+= 1
        tap.stop()
        input?.finish()
        input = nil
        results?.cancel()
        results = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
    }
}

/// Converts the microphone's buffers to the recogniser's format, made the first time
/// it sees the microphone's own. Used on the audio thread only.
private final class ConverterBox: @unchecked Sendable {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to target: AVAudioFormat) {
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if given {
                state.pointee = .noDataNow
                return nil
            }
            given = true
            state.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}

/// macOS 14 and 15: the older recogniser, made to stay on the Mac, which hands back the
/// whole of what one task heard. A task is started afresh every 50 seconds, well inside
/// the minute a task may run, with what earlier ones heard kept in front.
@MainActor
final class RecognizerSpeechSource: SpeechSource {
    private let recognizer: SFSpeechRecognizer?
    private let tap = MicrophoneTap()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var renewal: Timer?
    private var earlier = ""
    private var latest = ""
    private var hints: [String] = []
    private var heard: (@MainActor (String) -> Void)?
    private var failed: (@MainActor (String) -> Void)?
    private let requestLock = NSLock()
    nonisolated(unsafe) private var current: SFSpeechAudioBufferRecognitionRequest?

    static let renewInterval: TimeInterval = 50

    init(locale: Locale) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start(
        hints: [String],
        heard: @escaping @MainActor (String) -> Void,
        level: @escaping @MainActor (Float) -> Void,
        failed: @escaping @MainActor (String) -> Void
    ) async throws {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { throw VoiceRefusalError(.unavailable("")) }
        self.hints = Array(hints.prefix(100))
        self.heard = heard
        self.failed = failed
        beginTask()
        _ = try tap.start(buffer: { [weak self] buffer, _ in
            guard let self else { return }
            self.requestLock.lock()
            let request = self.current
            self.requestLock.unlock()
            request?.append(buffer)
        }, level: level)
        renewal = Timer.scheduledTimer(withTimeInterval: Self.renewInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renew() }
        }
    }

    private func beginTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = hints
        request.taskHint = .dictation
        self.request = request
        requestLock.lock()
        current = request
        requestLock.unlock()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let failedNow = error != nil && result == nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.request === request else { return }
                    if let text {
                        self.latest = text
                        self.heard?(self.earlier + " " + text)
                    } else if failedNow {
                        // A task that ends with nothing heard (silence) is started again.
                        self.renew()
                    }
                }
            }
        }
    }

    private func renew() {
        guard request != nil else { return }
        earlier = String((earlier + " " + latest).suffix(SpeechSources.keptCharacters))
        latest = ""
        request?.endAudio()
        task?.finish()
        beginTask()
    }

    func stop() {
        tap.stop()
        renewal?.invalidate()
        renewal = nil
        requestLock.lock()
        current = nil
        requestLock.unlock()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        heard = nil
        failed = nil
    }
}
