import Foundation
import Network

/// Whether the Mac is online, as the system sees it, so a question to ChatGPT or Claude
/// offline says so at once rather than waiting for the tool to give up. Watched while
/// Quick Ask runs.
final class AskNetwork: @unchecked Sendable {
    static let shared = AskNetwork()

    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    // Guarded by `lock`.
    private var offline = false

    var isOffline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return offline
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.offline = path.status == .unsatisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "com.ayush.Islet.QuickAsk.network", qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        monitor?.cancel()
        monitor = nil
        offline = false
    }
}
