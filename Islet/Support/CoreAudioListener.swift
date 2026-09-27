import CoreAudio
import Foundation

/// Property listeners on one Core Audio object that really come off when removed.
///
/// A C function rather than a block: Swift wraps a closure in a new block each time
/// it is passed, and Core Audio matches a block by identity, so a block listener could
/// never be removed again, and every panel opening, app followed or audio server
/// restart would leave one more behind, still firing, for the life of the process.
///
/// Core Audio is handed a number for the listener rather than a pointer to it. It calls
/// the function on a thread of its own and can be partway through a call when the
/// listener is removed, and a pointer would by then name a freed object; a number whose
/// listener has gone finds nothing, and numbers are never used twice. The function hops
/// to the queue it was given, where a change that arrives after `remove()` is dropped.
final class CoreAudioListener {
    private let object: AudioObjectID
    private let addresses: [AudioObjectPropertyAddress]
    /// What Core Audio was handed; `nil` once removed.
    private var token: UInt?

    /// Listens from now on: `heard` gets the selectors that changed, on `queue`. Made
    /// and removed on `queue`, so that a change is heard before `remove()` or not at
    /// all. Removed from another thread, as `deinit` is when the last reference goes
    /// there, later changes are dropped just the same, but one `queue` is already
    /// reporting may still reach `heard` as `remove()` returns. Fails harmlessly for an
    /// object that has already gone.
    init(
        on object: AudioObjectID,
        _ addresses: [AudioObjectPropertyAddress],
        queue: DispatchQueue,
        heard: @escaping @Sendable ([AudioObjectPropertySelector]) -> Void
    ) {
        self.object = object
        self.addresses = addresses
        let token = registry.add(Context(queue: queue, heard: heard))
        self.token = token
        for address in addresses {
            Self.setListening(true, on: object, at: address, token: token)
        }
    }

    deinit {
        remove()
    }

    /// Takes the listeners off. A call Core Audio is already making finds nothing to
    /// report to, and a change already on its way to the queue is dropped there.
    func remove() {
        guard let token else { return }
        self.token = nil
        registry.remove(token)
        for address in addresses {
            Self.setListening(false, on: object, at: address, token: token)
        }
    }

    private static func setListening(
        _ isOn: Bool, on object: AudioObjectID, at address: AudioObjectPropertyAddress, token: UInt
    ) {
        var address = address
        let context = UnsafeMutableRawPointer(bitPattern: token)
        #if DEBUG
        if let registrar = registrarForTesting {
            _ = isOn
                ? registrar.add(object, address, coreAudioPropertyChanged, context)
                : registrar.remove(object, address, coreAudioPropertyChanged, context)
            return
        }
        #endif
        if isOn {
            AudioObjectAddPropertyListener(object, &address, coreAudioPropertyChanged, context)
        } else {
            AudioObjectRemovePropertyListener(object, &address, coreAudioPropertyChanged, context)
        }
    }

    #if DEBUG
    /// Where listeners go in place of Core Audio, for harnesses that make up objects
    /// and fire their changes by hand. Set before any listener is made.
    static var registrarForTesting: (any CoreAudioListenerRegistrar)?

    /// How many listeners Core Audio could still reach, so a harness can tell that
    /// none outlived what made it.
    static var registeredForTesting: Int { registry.count }
    #endif
}

#if DEBUG
/// Core Audio's two listener calls, as a harness stands in for them.
protocol CoreAudioListenerRegistrar: AnyObject {
    func add(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
        _ proc: AudioObjectPropertyListenerProc, _ context: UnsafeMutableRawPointer?
    ) -> OSStatus
    func remove(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
        _ proc: AudioObjectPropertyListenerProc, _ context: UnsafeMutableRawPointer?
    ) -> OSStatus
}
#endif

/// Where to report one listener's changes.
private struct Context: Sendable {
    let queue: DispatchQueue
    let heard: @Sendable ([AudioObjectPropertySelector]) -> Void
}

/// Every listener Core Audio may still call, by the number it was handed.
private final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [UInt: Context] = [:]
    private var lastToken: UInt = 0

    func add(_ context: Context) -> UInt {
        lock.withLock {
            lastToken += 1
            contexts[lastToken] = context
            return lastToken
        }
    }

    /// The context is let go once the lock is, in case what it holds has work to do as
    /// it goes.
    func remove(_ token: UInt) {
        _ = lock.withLock { contexts.removeValue(forKey: token) }
    }

    func context(_ token: UInt) -> Context? {
        lock.withLock { contexts[token] }
    }

    var count: Int {
        lock.withLock { contexts.count }
    }
}

private let registry = Registry()

/// Runs on a Core Audio thread; hops to the listener's queue, and reports there only
/// if the listener has not been removed in the meantime.
private func coreAudioPropertyChanged(
    _: AudioObjectID,
    _ count: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    let token = UInt(bitPattern: context)
    guard let listener = registry.context(token) else { return noErr }
    let selectors = (0..<Int(count)).map { addresses[$0].mSelector }
    listener.queue.async {
        guard registry.context(token) != nil else { return }
        listener.heard(selectors)
    }
    return noErr
}
