import Foundation
import Darwin

/// Watches whether anything is capturing the screen: recording it, sharing it, or
/// mirroring it. WindowServer keeps that as a flag in memory it shares with every app,
/// the same one behind Mac Catalyst's public `UIScreen.isCaptured`, so reading it is
/// free and needs no permission. It never says who; the log does
/// (`PrivacyNameTracker`).
///
/// A screenshot does not set it, nor does anything macOS exempts, such as its own
/// interface. AirPlay, Sidecar and Screen Sharing may, which is why this says the
/// screen is being captured rather than recorded.
///
/// WindowServer posts a notification when the first capture starts and the last one
/// ends. Whether it reaches an app like Islet has not been seen, so the flag is also
/// read every couple of seconds, until one has arrived. Where the flag cannot be
/// found at all, the reading is `nil`: unknown.
///
/// Threading works as in `PrivacyCameraWatcher`; the notifications are registered on
/// the main thread, where WindowServer delivers them.
final class PrivacyScreenWatcher: @unchecked Sendable {
    typealias Report = @MainActor @Sendable (_ captured: Bool?) -> Void

    private typealias IsCaptured = @convention(c) () -> Bool
    private typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
    private typealias RegisterNotifyProc = @convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32

    /// A capture started, and the last capture ended.
    private static let notifications: [UInt32] = [1502, 1503]
    static let pollInterval: TimeInterval = 2

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let isCaptured = symbol("SLSIsScreenWatcherPresent", as: IsCaptured.self)
    private static let register = symbol("SLSRegisterNotifyProc", as: RegisterNotifyProc.self)
    private static let remove = symbol("SLSRemoveNotifyProc", as: RegisterNotifyProc.self)

    private let queue = DispatchQueue(label: "islet.privacy.screen", qos: .utility)

    // Confined to `queue`.
    private var report: Report?
    private var lastReported: Bool??
    private var timer: DispatchSourceTimer?
    /// Once WindowServer has been heard from, it is trusted to say when the flag
    /// changes, and the flag is no longer read on a timer.
    private var heardFromWindowServer = false

    // Confined to the main thread.
    private var isRegistered = false

    /// Starts watching. `report` gets the first reading, then every change.
    func start(report: @escaping Report) {
        dispatchPrecondition(condition: .onQueue(.main))
        if !isRegistered, let register = Self.register {
            isRegistered = true
            for type in Self.notifications { _ = register(Self.notified, type, context) }
        }
        queue.async { [self] in
            guard self.report == nil else { return }
            self.report = report
            lastReported = nil
            if !heardFromWindowServer, Self.isCaptured != nil { startPolling() }
            refresh()
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        if isRegistered, let remove = Self.remove {
            isRegistered = false
            for type in Self.notifications { _ = remove(Self.notified, type, context) }
        }
        queue.async { [self] in
            report = nil
            timer?.cancel()
            timer = nil
        }
    }

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Called by WindowServer on the main thread. The watcher is never released while
    /// registered (`PrivacyMonitor` keeps it for the life of the app), and a watcher
    /// that has stopped ignores it.
    private static let notified: NotifyProc = { _, _, _, context in
        guard let context else { return }
        let watcher = Unmanaged<PrivacyScreenWatcher>.fromOpaque(context).takeUnretainedValue()
        watcher.queue.async { [watcher] in
            watcher.heardFromWindowServer = true
            watcher.timer?.cancel()
            watcher.timer = nil
            watcher.refresh()
        }
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }

    private func refresh() {
        guard let report else { return }
        let captured = Self.isCaptured.map { $0() }
        guard lastReported != .some(captured) else { return }
        lastReported = .some(captured)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { report(captured) }
        }
    }
}
