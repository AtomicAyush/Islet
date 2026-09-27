import AppKit

/// Where readings of the connection come from: the Mac's own network, or a test's.
@MainActor
protocol NetworkSource: AnyObject {
    /// Starts reporting the connection: as it is, as soon as it is known, and again
    /// each time it changes.
    func start(_ report: @escaping @MainActor (NetworkState) -> Void)
    func stop()
}

/// Runs a `NetworkWatch` over a source's readings: hands it each one, looks again when
/// it asks to, and tells it when the Mac sleeps and wakes. What it finds worth saying
/// goes to `onChanges`.
@MainActor
final class NetworkModel {
    /// Changes worth a banner, in the order they should show.
    var onChanges: ([NetworkChange]) -> Void = { _ in }

    private let source: any NetworkSource
    private let timing: NetworkWatch.Timing
    private var watch: NetworkWatch
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    /// `source` stands in for the Mac's network, and `timing` for the watch's waits, in
    /// tests.
    init(source: (any NetworkSource)? = nil, timing: NetworkWatch.Timing = .standard) {
        self.source = source ?? NetworkMonitor()
        self.timing = timing
        watch = NetworkWatch(timing: timing)
    }

    /// The connection as the person last heard of it.
    var told: NetworkState? { watch.told }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        watch = NetworkWatch(timing: timing)
        watch.start(at: Date())
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didWake() }
            },
        ]
        source.start { [weak self] state in self?.receive(state) }
        schedule()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        source.stop()
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        timer?.cancel()
        timer = nil
    }

    func willSleep() {
        guard isRunning else { return }
        watch.sleep()
        schedule()
    }

    func didWake() {
        guard isRunning else { return }
        deliver(watch.wake(at: Date()))
    }

    private func receive(_ state: NetworkState) {
        guard isRunning else { return }
        deliver(watch.receive(state, at: Date()))
    }

    private func deliver(_ changes: [NetworkChange]) {
        if !changes.isEmpty { onChanges(changes) }
        schedule()
    }

    /// Looks again when the watch asks to, and not otherwise: with nothing waiting to
    /// be said, nothing runs between readings.
    private func schedule() {
        timer?.cancel()
        timer = nil
        guard isRunning, let deadline = watch.nextDeadline else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.deliver(self.watch.advance(to: max(Date(), deadline)))
        }
    }
}
