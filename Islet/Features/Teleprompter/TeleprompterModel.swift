import Foundation
import Observation

/// How the script moves.
enum TeleprompterMode: String, CaseIterable, Identifiable {
    /// Follows the reader's voice, through the microphone and on-device speech
    /// recognition.
    case follow
    /// At a set number of words a minute.
    case pace
    /// Only when scrolled, or moved a line at a time.
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .follow: "Follow my voice"
        case .pace: "Set pace"
        case .manual: "Manual"
        }
    }

    var symbol: String {
        switch self {
        case .follow: "waveform"
        case .pace: "metronome"
        case .manual: "hand.draw"
        }
    }
}

/// The teleprompter's choices, as Settings keeps them. The model is handed them, and
/// tells the feature when the island's controls change one, so the harness can run it
/// with choices of its own and nothing written down.
struct TeleprompterSettings: Equatable {
    var mode = TeleprompterMode.follow
    var wordsPerMinute = TeleprompterLayout.standardPace
    var textSize = TeleprompterLayout.standardSize
    var lines = TeleprompterLayout.standardLines
    /// Seconds counted down before it starts: 0, 3 or 5.
    var countdown = 3
    /// Drawn back to front, for a prompter's glass.
    var mirror = false
    var hideFromCapture = true
    /// The language listened for (`VoiceLanguage`).
    var language = VoiceLanguage.automatic
    /// The keys that work from any app while it runs (`TeleprompterHotKeys`).
    var shortcuts = true

    static let countdowns = [0, 3, 5]

    enum Key {
        static let mode = "teleprompter.mode"
        static let wordsPerMinute = "teleprompter.wordsPerMinute"
        static let textSize = "teleprompter.textSize"
        static let lines = "teleprompter.lines"
        static let countdown = "teleprompter.countdown"
        static let mirror = "teleprompter.mirror"
        static let hideFromCapture = "teleprompter.hideFromCapture"
        static let language = "teleprompter.language"
        static let shortcuts = "teleprompter.shortcuts"
    }

    static func read(from defaults: UserDefaults) -> TeleprompterSettings {
        var settings = TeleprompterSettings()
        if let mode = defaults.string(forKey: Key.mode).flatMap(TeleprompterMode.init) { settings.mode = mode }
        if let pace = defaults.object(forKey: Key.wordsPerMinute) as? Int { settings.wordsPerMinute = pace }
        if let size = defaults.object(forKey: Key.textSize) as? Double { settings.textSize = CGFloat(size) }
        if let lines = defaults.object(forKey: Key.lines) as? Int { settings.lines = lines }
        if let countdown = defaults.object(forKey: Key.countdown) as? Int { settings.countdown = countdown }
        if let mirror = defaults.object(forKey: Key.mirror) as? Bool { settings.mirror = mirror }
        if let hide = defaults.object(forKey: Key.hideFromCapture) as? Bool { settings.hideFromCapture = hide }
        if let language = defaults.string(forKey: Key.language) { settings.language = language }
        if let shortcuts = defaults.object(forKey: Key.shortcuts) as? Bool { settings.shortcuts = shortcuts }
        return settings.clamped
    }

    /// Every value inside its range, whatever the defaults held.
    var clamped: TeleprompterSettings {
        var settings = self
        settings.wordsPerMinute = min(max(wordsPerMinute, TeleprompterLayout.paces.lowerBound), TeleprompterLayout.paces.upperBound)
        settings.textSize = min(max(textSize, TeleprompterLayout.sizes.lowerBound), TeleprompterLayout.sizes.upperBound)
        settings.lines = min(max(lines, TeleprompterLayout.lineCounts.lowerBound), TeleprompterLayout.lineCounts.upperBound)
        if !Self.countdowns.contains(countdown) { settings.countdown = 3 }
        return settings
    }

    /// Writes the values the island's controls change: the mode, the pace and the size.
    func writeControls(to defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(wordsPerMinute, forKey: Key.wordsPerMinute)
        defaults.set(Double(textSize), forKey: Key.textSize)
    }
}

/// A reading of one script: where it is, how it moves, and whether it is running.
///
/// The place is a count of words read, fractional while it moves at a set pace, which
/// the lines turn into a place on screen (`ScriptLines`). At a set pace it is worked out
/// from the clock (`PaceClock`), in the lines' beats, so nothing ticks to move it;
/// following the voice, it is wherever the follower last put it (`ScriptFollower`); by
/// hand, wherever it was scrolled to.
///
/// The microphone runs only while Follow my voice runs: pausing, stopping, finishing,
/// another mode, or the page going out of sight stops it before anything else.
@MainActor
@Observable
final class TeleprompterModel {
    enum Phase: Equatable {
        /// A script loaded, not started.
        case ready
        /// Follow my voice getting ready to listen: asking for the microphone, or fetching
        /// the language's model.
        case preparing(VoicePreparation.Step)
        /// Counting down to start, ending at `end`.
        case countdown(end: Date)
        case running
        case paused
        /// Read to the end.
        case finished
    }

    private(set) var phase = Phase.ready
    private(set) var settings: TeleprompterSettings
    private(set) var scriptID: UUID?
    private(set) var title = ""
    private(set) var text = ScriptText("")
    /// The script's words as loaded, to tell whether an edit has changed them.
    @ObservationIgnored private(set) var sourceText = ""
    private(set) var lines: ScriptLines
    /// Words read, while not moving at a set pace.
    private(set) var position: Double = 0
    /// The set pace's clock, while it runs.
    private(set) var pace: PaceClock?
    /// Something to say under the script: why Follow my voice can't listen, or that it is
    /// fetching what it needs.
    private(set) var message: String?
    /// The refusal behind the message, for its button to System Settings.
    private(set) var refusal: VoiceRefusal?
    /// The microphone's loudness, 0 to 1, while it listens.
    private(set) var level: Float = 0
    private(set) var isListening = false
    /// How long it has run, before the current run.
    private(set) var elapsedBefore: TimeInterval = 0
    private(set) var runningSince: Date?
    /// The reader's own pace, measured while following the voice, in words a minute.
    private(set) var spokenPace: Double?

    /// Told whenever what the island shows of it changes: the phase, the size of the
    /// page. The feature shows and ends the activity, and holds the island open.
    @ObservationIgnored var onChange: () -> Void = {}
    /// Told as one of the island's controls changes a setting, to write it down.
    @ObservationIgnored var onSettingsChange: (TeleprompterSettings) -> Void = { _ in }
    /// Told of the place now and then (as it pauses, stops or finishes), to carry on from
    /// there next time.
    @ObservationIgnored var onPlace: (UUID, Int) -> Void = { _, _ in }

    @ObservationIgnored private let access: any VoiceAccess
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var follower = ScriptFollower(script: [])
    @ObservationIgnored private var source: (any SpeechSource)?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var countdownWork: DispatchWorkItem?
    @ObservationIgnored private var finishWork: DispatchWorkItem?
    /// For the spoken pace: the place and time of the last move.
    @ObservationIgnored private var lastMove: (word: Int, date: Date)?
    /// How many of the page's views are on screen; at none, a running reading pauses.
    @ObservationIgnored private var shownViews = 0
    /// Bumped as listening starts and stops, so a start that finishes after a stop
    /// knows it is too late.
    @ObservationIgnored private var listenGeneration = 0
    /// The text size the lines were broken at.
    @ObservationIgnored private var measuredSize: CGFloat = 0
    /// Whether the next run counts down first: from the start, not from a pause.
    @ObservationIgnored private var countsDown = true
    /// When the microphone's level was last shown, for showing it less often while the
    /// island saves energy.
    @ObservationIgnored private var levelShown = Date.distantPast

    init(settings: TeleprompterSettings = TeleprompterSettings(), access: any VoiceAccess, now: @escaping () -> Date = Date.init) {
        self.settings = settings.clamped
        self.access = access
        self.now = now
        lines = ScriptLines(text: ScriptText(""), width: TeleprompterLayout.textWidth) { _ in 0 }
    }

    // MARK: Reading

    var mode: TeleprompterMode { settings.mode }
    var isRunning: Bool { phase == .running }
    /// Whether this reading has started since the script was loaded: the activity shows
    /// from Start until Stop.
    private(set) var hasStarted = false

    /// Words read at `date`.
    func word(at date: Date) -> Double {
        if let pace { return lines.word(atBeat: pace.beat(at: date)) }
        return position
    }

    /// The line at the eye line, and how far through it, at `date`. Following the voice,
    /// a whole line: the line being read sits at the eye line, and moves up as the next
    /// one starts.
    func linePosition(at date: Date) -> Double {
        let place = lines.linePosition(ofWord: word(at: date))
        return mode == .follow ? place.rounded(.down) : place
    }

    /// How far through the script, 0 to 1.
    func progress(at date: Date) -> Double {
        guard text.wordCount > 0 else { return 0 }
        return min(1, word(at: date) / Double(text.wordCount))
    }

    /// Reading time left, at the pace set, as the lines' beats count it, or, following the
    /// voice, at the reader's own once it has been heard for a while.
    func timeLeft(at date: Date) -> TimeInterval {
        guard mode == .follow else {
            let beat = pace?.beat(at: date) ?? lines.beat(ofWord: position)
            return max(0, lines.totalBeats - beat) / Double(max(settings.wordsPerMinute, 1)) * 60
        }
        let left = max(0, Double(text.wordCount) - word(at: date))
        return left / max(spokenPace ?? Double(settings.wordsPerMinute), 1) * 60
    }

    func elapsed(at date: Date) -> TimeInterval {
        elapsedBefore + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    /// The page's height below the notch row.
    var pageHeight: CGFloat { TeleprompterLayout.pageHeight(lines: settings.lines, size: settings.textSize) }

    /// Loads a script, at `word`, as Start will read it. A reading under way stops first.
    func load(_ script: TeleprompterScript, at word: Int? = nil) {
        if hasStarted { stop() }
        scriptID = script.id
        title = script.shownTitle
        sourceText = script.text
        text = ScriptText(script.text)
        follower = ScriptFollower(script: text.tokens)
        relayout()
        let start = word ?? script.lastWord
        position = Double(start < text.wordCount ? max(0, start) : 0)
        follower.reset(to: text.token(forWord: Int(position)))
        phase = .ready
        message = nil
        refusal = nil
        changed()
    }

    /// A new name for the script, as given in Settings.
    func rename(_ title: String) {
        self.title = title
    }

    /// Takes new settings from Settings. A change of mode while running switches over;
    /// the rest apply as they come.
    func apply(_ next: TeleprompterSettings) {
        let next = next.clamped
        guard next != settings else { return }
        let oldMode = settings.mode
        let date = now()
        if let pace, next.wordsPerMinute != settings.wordsPerMinute {
            self.pace = pace.repaced(next.wordsPerMinute, at: date)
            scheduleFinish()
        }
        let resized = next.textSize != settings.textSize || next.lines != settings.lines
        settings = next
        if next.textSize != measuredSize { relayout() }
        if next.mode != oldMode { switchMode(from: oldMode) }
        if resized { changed() }
    }

    // MARK: Controls

    /// Starts the reading, or carries on from a pause: after the countdown, and for
    /// Follow my voice once the microphone is listening. From the end, it starts over.
    func start() {
        guard scriptID != nil, text.wordCount > 0 else { return }
        switch phase {
        case .running, .countdown, .preparing: return
        case .finished:
            position = 0
            follower.reset(to: 0)
            countsDown = true
        case .ready:
            countsDown = true
        case .paused:
            // Carrying on from a pause goes straight on.
            countsDown = false
        }
        hasStarted = true
        message = nil
        refusal = nil
        if mode == .follow, source == nil {
            prepareVoice()
        } else {
            countDown()
        }
    }

    func pause() {
        switch phase {
        case .running:
            settle()
            stopListening()
            cancelTimers()
            phase = .paused
            notePlace()
            changed()
        case .countdown, .preparing:
            preparation?.cancel()
            preparation = nil
            stopListening()
            cancelTimers()
            phase = .paused
            changed()
        case .ready, .paused, .finished:
            break
        }
    }

    var isPreparing: Bool {
        if case .preparing = phase { return true }
        return false
    }

    var isCountingDown: Bool {
        if case .countdown = phase { return true }
        return false
    }

    /// Running, or on its way to: counting down, or getting ready to listen.
    var isGoing: Bool { isRunning || isCountingDown || isPreparing }

    /// Ends the reading. The place is kept for next time; read to the end, it starts
    /// over.
    func stop() {
        guard hasStarted else { return }
        let finished = phase == .finished
        settle()
        preparation?.cancel()
        preparation = nil
        stopListening()
        cancelTimers()
        if finished {
            // `finish` has noted the start as the place already.
            position = 0
            follower.reset(to: 0)
        } else {
            notePlace()
        }
        hasStarted = false
        elapsedBefore = 0
        runningSince = nil
        spokenPace = nil
        phase = .ready
        message = nil
        refusal = nil
        changed()
    }

    /// Back to the line before the one at the eye line.
    func lineBack() { moveLines(by: -1) }
    /// On to the next line.
    func lineOn() { moveLines(by: 1) }

    /// A screen's worth back or on: the lines shown.
    func screen(by direction: Int) {
        moveLines(by: direction * TeleprompterLayout.shownLines(wanted: settings.lines, size: settings.textSize))
    }

    func faster() { setPace(settings.wordsPerMinute + TeleprompterLayout.paceStep) }
    func slower() { setPace(settings.wordsPerMinute - TeleprompterLayout.paceStep) }

    func setPace(_ pace: Int) {
        var next = settings
        next.wordsPerMinute = pace
        apply(next)
        onSettingsChange(settings)
    }

    func bigger() { setSize(settings.textSize + TeleprompterLayout.sizeStep) }
    func smaller() { setSize(settings.textSize - TeleprompterLayout.sizeStep) }

    func setSize(_ size: CGFloat) {
        var next = settings
        next.textSize = size
        apply(next)
        onSettingsChange(settings)
    }

    func setMode(_ mode: TeleprompterMode) {
        var next = settings
        next.mode = mode
        apply(next)
        onSettingsChange(settings)
    }

    /// Scrolled by hand, by `lines` (fractional): in any mode it moves the place, and
    /// following the voice it listens on from there.
    func scroll(byLines delta: Double) {
        guard scriptID != nil, delta != 0 else { return }
        let date = now()
        let here = lines.linePosition(ofWord: word(at: date))
        place(at: lines.word(atLinePosition: here + delta), date: date)
    }

    // MARK: The page in sight

    /// One of the page's views came on screen.
    func pageAppeared() {
        shownViews += 1
    }

    /// One of the page's views went. With none left, a reading under way pauses: no one
    /// can be reading it.
    func pageDisappeared() {
        shownViews = max(0, shownViews - 1)
        guard shownViews == 0 else { return }
        pause()
    }

    // MARK: Hearing

    /// The recogniser's latest guess at everything heard: the place follows it.
    func heard(_ transcript: String) {
        guard isRunning, mode == .follow else { return }
        let before = follower.position
        let token = follower.hear(transcript)
        guard token != before else { return }
        let word = text.word(forToken: token)
        let date = now()
        if let last = lastMove, word > last.word {
            let minutes = date.timeIntervalSince(last.date) / 60
            if minutes > 0.05 {
                let rate = Double(word - last.word) / minutes
                // Smoothed, so a burst after a pause doesn't swing it.
                spokenPace = spokenPace.map { $0 * 0.7 + rate * 0.3 } ?? rate
                lastMove = (word, date)
            }
        } else {
            lastMove = (word, date)
        }
        position = Double(word)
        if token >= text.tokens.count { finish() }
    }

    /// The microphone's loudness, a few times a second, or twice a second while the
    /// island saves energy.
    func heardLevel(_ level: Float) {
        guard isListening else { return }
        let date = now()
        if EnergySaver.shared.isSaving, date.timeIntervalSince(levelShown) < 0.5 { return }
        levelShown = date
        self.level = level
    }

    // MARK: Inside

    private func moveLines(by count: Int) {
        guard scriptID != nil else { return }
        let date = now()
        let current = lines.line(ofWord: Int(word(at: date).rounded(.down)))
        place(at: Double(lines.firstWord(ofLine: current + count)), date: date)
    }

    /// Puts the place at `word`, whatever the mode. Following the voice, what was heard
    /// before the move is no longer lined up: the recogniser may send it again.
    private func place(at word: Double, date: Date) {
        let clamped = min(max(word, 0), Double(text.wordCount))
        if let pace {
            self.pace = PaceClock(startBeat: lines.beat(ofWord: clamped), startDate: date, wordsPerMinute: pace.wordsPerMinute)
            scheduleFinish()
        } else {
            position = clamped
        }
        follower.reset(to: text.token(forWord: Int(clamped.rounded(.down))), forgettingHeard: true)
        lastMove = nil
        if phase == .finished, clamped < Double(text.wordCount) {
            phase = .paused
            changed()
        }
    }

    /// Breaks the script into lines at the text size. A reading at a set pace carries on
    /// from the same word, in the new lines' beats.
    private func relayout() {
        let date = now()
        let read = pace.map { lines.word(atBeat: $0.beat(at: date)) }
        measuredSize = settings.textSize
        lines = ScriptLines(text: text, width: TeleprompterLayout.textWidth, size: settings.textSize)
        if let read, let pace {
            self.pace = PaceClock(startBeat: lines.beat(ofWord: read), startDate: date, wordsPerMinute: pace.wordsPerMinute)
            scheduleFinish()
        }
    }

    /// Another mode, as it runs: from now on it moves the new way. Counting down, it
    /// counts on, and the new mode starts as the count ends; getting ready to listen for
    /// a mode that no longer listens, it goes straight to the count.
    private func switchMode(from old: TeleprompterMode) {
        let date = now()
        settle(at: date)
        if old == .follow { stopListening() }
        finishWork?.cancel()
        finishWork = nil
        follower.reset(to: text.token(forWord: Int(position)))
        if isPreparing, mode != .follow {
            preparation?.cancel()
            preparation = nil
            countDown()
            return
        }
        guard phase == .running else { return }
        runningSince = date
        switch mode {
        case .follow:
            runningSince = nil
            phase = .paused
            start()
        case .pace:
            pace = PaceClock(startBeat: lines.beat(ofWord: position), startDate: date, wordsPerMinute: settings.wordsPerMinute)
            scheduleFinish()
        case .manual:
            break
        }
        changed()
    }

    /// Takes the pace's place into `position` and stops its clock, and adds the run's
    /// time to the elapsed.
    private func settle(at date: Date? = nil) {
        let date = date ?? now()
        if let pace {
            position = lines.word(atBeat: pace.beat(at: date))
            self.pace = nil
        }
        if let since = runningSince {
            elapsedBefore += date.timeIntervalSince(since)
            runningSince = nil
        }
    }

    private func prepareVoice() {
        let locale = VoiceLanguage.locale(for: settings.language, script: text.words.prefix(600).map(\.text).joined(separator: " "))
        phase = .preparing(.checking)
        changed()
        preparation = Task { [weak self] in
            guard let self else { return }
            let outcome = await VoicePreparation.prepare(locale: locale, access: access) { [weak self] step in
                guard let self, self.isPreparing else { return }
                self.phase = .preparing(step)
                self.message = Self.words(for: step)
            }
            guard !Task.isCancelled, isPreparing else { return }
            preparation = nil
            switch outcome {
            case .success(let source):
                self.source = source
                message = nil
                countDown()
            case .failure(let error):
                refusal = error.refusal
                message = error.refusal.message
                phase = .paused
                changed()
            }
        }
    }

    private static func words(for step: VoicePreparation.Step) -> String? {
        switch step {
        case .checking: nil
        case .askingMicrophone: "Asking for the microphone…"
        case .askingSpeech: "Asking for speech recognition…"
        case .fetchingModel: "Getting ready to listen…"
        }
    }

    private func countDown() {
        cancelTimers()
        let seconds = countsDown ? settings.countdown : 0
        guard seconds > 0 else {
            run()
            return
        }
        let end = now().addingTimeInterval(TimeInterval(seconds))
        phase = .countdown(end: end)
        changed()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.run() }
        }
        countdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(seconds), execute: work)
    }

    /// The countdown is over: it runs, and Follow my voice starts listening.
    private func run() {
        countdownWork = nil
        // Counted down once: getting ready to listen after it doesn't count again.
        countsDown = false
        let date = now()
        phase = .running
        runningSince = date
        lastMove = nil
        switch mode {
        case .pace:
            pace = PaceClock(startBeat: lines.beat(ofWord: position), startDate: date, wordsPerMinute: settings.wordsPerMinute)
            scheduleFinish()
        case .follow:
            follower.reset(to: text.token(forWord: Int(position)))
            listen()
        case .manual:
            break
        }
        changed()
    }

    private func listen() {
        guard let source else {
            prepareVoice()
            return
        }
        listenGeneration &+= 1
        let generation = listenGeneration
        isListening = true
        let hints = text.vocabulary()
        Task { [weak self] in
            do {
                try await source.start(
                    hints: hints,
                    heard: { [weak self] transcript in self?.heard(transcript) },
                    level: { [weak self] level in self?.heardLevel(level) },
                    failed: { [weak self] reason in self?.listeningFailed(reason) }
                )
                guard let self else { return source.stop() }
                if listenGeneration != generation { letGo(source) }
            } catch {
                guard let self else { return source.stop() }
                guard listenGeneration == generation else { return letGo(source) }
                listeningFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// A start that ended after listening was stopped, however it ended: its source is
    /// let go again at once, unless it is the one listening now, started again since.
    private func letGo(_ started: any SpeechSource) {
        if !isListening || source !== started { started.stop() }
    }

    private func listeningFailed(_ reason: String) {
        stopListening()
        source = nil
        message = reason
        if isRunning {
            settle()
            phase = .paused
            notePlace()
        }
        changed()
    }

    private func stopListening() {
        listenGeneration &+= 1
        source?.stop()
        isListening = false
        level = 0
    }

    private func scheduleFinish() {
        finishWork?.cancel()
        guard let pace, phase == .running else { return }
        let end = pace.date(reaching: lines.totalBeats)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, end.timeIntervalSince(now())), execute: work)
    }

    private func finish() {
        guard phase == .running else { return }
        settle()
        stopListening()
        cancelTimers()
        position = Double(text.wordCount)
        phase = .finished
        if let scriptID { onPlace(scriptID, 0) }
        changed()
    }

    private func cancelTimers() {
        countdownWork?.cancel()
        countdownWork = nil
        finishWork?.cancel()
        finishWork = nil
    }

    private func notePlace() {
        guard let scriptID else { return }
        onPlace(scriptID, Int(word(at: now()).rounded(.down)))
    }

    private func changed() {
        onChange()
    }

    // MARK: For the harness

    /// The place among the follower's tokens.
    var followerPosition: Int { follower.position }
    var hasSource: Bool { source != nil }
}

