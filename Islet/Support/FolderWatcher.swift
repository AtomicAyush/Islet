import Foundation

/// Says when a folder's entries change: a file added to it, taken out of it or renamed
/// in it. It is a kernel event on the folder itself, so a folder that is not changing
/// costs nothing, and a file growing inside it (a download arriving) does not count.
///
/// A burst of changes (a browser creating a partial file and writing its first bytes,
/// macOS saving a screenshot and tagging it) becomes one call, a moment after the last.
/// It is also called each time the folder is opened, the first time included, since
/// whatever changed while it was not being watched went unheard.
///
/// The folder is opened off the main thread. Desktop, Downloads and Documents are
/// folders macOS asks the person about before an app may look inside, and the asking
/// holds up the thread that looked until it is answered; the island must not wait on
/// it. A folder macOS says Islet may not see into is not tried again until `retry()`
/// (Settings opening, where someone who has just allowed it would look). A folder that
/// is not there, or is itself moved or deleted, is looked for again at its path a
/// second later, and then once a minute while it stays gone, so one put back is
/// watched again.
@MainActor
final class FolderWatcher {
    enum State: Equatable {
        case stopped
        /// Being opened, off the main thread.
        case opening
        case watching
        /// Not there, or not a folder: looked for again later.
        case missing
        /// macOS will not let Islet see into it: the person said no when asked, or has
        /// taken access away since in Privacy & Security.
        case noAccess
    }

    let url: URL
    private let debounce: TimeInterval
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var reopen: DispatchWorkItem?
    private(set) var state: State = .stopped
    /// Bumped by each open and by `stop()`, so an open that finishes after either is
    /// let go.
    private var attempt = 0

    var isRunning: Bool { state != .stopped }

    init(url: URL, debounce: TimeInterval = 0.15, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        guard state == .stopped else { return }
        open()
    }

    func stop() {
        state = .stopped
        attempt &+= 1
        pending?.cancel()
        pending = nil
        reopen?.cancel()
        reopen = nil
        source?.cancel()
        source = nil
    }

    /// Tries a folder that could not be opened again now, rather than waiting: access
    /// may just have been given.
    func retry() {
        guard state == .missing || state == .noAccess else { return }
        open()
    }

    private func open() {
        source?.cancel()
        source = nil
        reopen?.cancel()
        reopen = nil
        state = .opening
        attempt &+= 1
        let attempt = attempt
        let path = url.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let descriptor = Darwin.open(path, O_EVTONLY)
            let error = descriptor < 0 ? errno : 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.state == .opening, self.attempt == attempt else {
                        if descriptor >= 0 { close(descriptor) }
                        return
                    }
                    self.opened(descriptor, error: error)
                }
            }
        }
    }

    private func opened(_ descriptor: Int32, error: Int32) {
        guard descriptor >= 0 else {
            if error == EPERM || error == EACCES {
                // Asking again would only be refused again, once a minute for good.
                state = .noAccess
            } else {
                state = .missing
                scheduleReopen(after: 60)
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source, !source.isCancelled else { return }
            let events = source.data
            MainActor.assumeIsolated { self?.received(events) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        state = .watching
        onChange()
    }

    private func received(_ events: DispatchSource.FileSystemEvent) {
        guard state == .watching else { return }
        if events.contains(.delete) || events.contains(.rename) {
            // The folder itself went; whatever is at its path now is another folder.
            source?.cancel()
            source = nil
            pending?.cancel()
            pending = nil
            state = .missing
            scheduleReopen(after: 1)
            return
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .watching else { return }
                self.pending = nil
                self.onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func scheduleReopen(after delay: TimeInterval) {
        reopen?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .missing else { return }
                self.reopen = nil
                self.open()
            }
        }
        reopen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
