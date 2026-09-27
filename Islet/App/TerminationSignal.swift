import Foundation

/// Makes SIGTERM an ordinary quit. `pkill` and `killall` send it, as does launchd
/// stopping a job, and left to itself it ends the process there and then, so nothing
/// that is put back as Islet quits is put back: Mic Mute's microphone would stay muted,
/// with no mark beside the notch to say so, until Islet next starts, and a shortcut's
/// tool would go on running. Asked this way, Islet quits as it does from its menu.
///
/// A SIGTERM still always ends Islet. A quit that has not finished within `grace`
/// (a main thread that is stuck, say) gives way to the signal acting as it would have,
/// and so does a second SIGTERM.
///
/// The signal is caught by a handler that does nothing, rather than ignored, for the
/// dispatch source to hear it: an ignored signal stays ignored in any process Islet
/// starts, while a handler is dropped as that process begins.
enum TerminationSignal {
    private static let queue = DispatchQueue(label: "Islet.TerminationSignal")
    // Confined to `queue`.
    private static var source: DispatchSourceSignal?
    private static var asked = false

    /// `quit` is run on the main thread, once, at the first SIGTERM.
    static func install(grace: TimeInterval = 5, quit: @escaping @MainActor () -> Void) {
        queue.sync {
            guard source == nil else { return }
            signal(SIGTERM) { _ in }
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
            source.setEventHandler {
                guard !asked else { return end() }
                asked = true
                queue.asyncAfter(deadline: .now() + grace) { end() }
                // From the run loop, not the main queue: a quit that waits a moment for
                // work on the main actor (Pomodoro turning off a Focus) needs the queue
                // free, and it is not while one of its own blocks is asking to quit.
                let main = CFRunLoopGetMain()
                CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
                    MainActor.assumeIsolated { quit() }
                }
                CFRunLoopWakeUp(main)
            }
            source.resume()
            self.source = source
        }
    }

    /// Ends the process as SIGTERM does with nothing to catch it.
    private static func end() {
        signal(SIGTERM, SIG_DFL)
        raise(SIGTERM)
    }
}
