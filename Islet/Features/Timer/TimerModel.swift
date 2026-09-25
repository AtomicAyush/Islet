import Foundation
import Observation

/// A single countdown, like the Clock app's timer on the iPhone.
@MainActor
@Observable
final class TimerModel {
    enum State: Equatable {
        case idle
        case running(end: Date)
        case paused(remaining: TimeInterval)
    }

    private(set) var state: State = .idle
    /// The length it was started with, for the progress ring.
    private(set) var duration: TimeInterval = 0
    /// The last length started, offered again when one finishes.
    private(set) var lastDuration: TimeInterval = 5 * 60

    /// Called once when a running timer reaches zero.
    @ObservationIgnored var onFinish: () -> Void = {}
    /// Called whenever the state changes, so the activity can show or end.
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored private var finishWork: DispatchWorkItem?

    var isActive: Bool { state != .idle }

    func remaining(at date: Date = Date()) -> TimeInterval {
        switch state {
        case .idle: 0
        case .running(let end): max(0, end.timeIntervalSince(date))
        case .paused(let remaining): remaining
        }
    }

    /// Fraction left, 1 at the start and 0 at the end.
    func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return remaining(at: date) / duration
    }

    func start(_ seconds: TimeInterval) {
        duration = seconds
        lastDuration = seconds
        run(until: Date().addingTimeInterval(seconds))
    }

    func pause() {
        guard case .running = state else { return }
        finishWork?.cancel()
        state = .paused(remaining: remaining())
        onChange()
    }

    func resume() {
        guard case .paused(let remaining) = state else { return }
        run(until: Date().addingTimeInterval(remaining))
    }

    func togglePause() {
        if case .running = state { pause() } else { resume() }
    }

    func cancel() {
        finishWork?.cancel()
        state = .idle
        onChange()
    }

    private func run(until end: Date) {
        finishWork?.cancel()
        state = .running(end: end)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + end.timeIntervalSinceNow, execute: work)
        onChange()
    }

    private func finish() {
        guard case .running = state else { return }
        state = .idle
        onChange()
        onFinish()
    }
}

extension TimeInterval {
    /// "4:05", or "1:02:03" past an hour. Rounds up, so a timer never reads 0:00
    /// while it is still running.
    var countdownText: String {
        let total = Int(self.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
