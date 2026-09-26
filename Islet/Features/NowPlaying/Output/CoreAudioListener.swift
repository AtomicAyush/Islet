import CoreAudio
import Foundation

/// Property listeners on one Core Audio object that really come off when removed.
///
/// A C function with a retained context rather than a block: Swift wraps a closure in
/// a new block each time it is passed, and Core Audio matches a block by identity, so
/// a block listener could never be removed again, and every panel opening or audio
/// server restart would leave one more behind for the life of the process. The
/// function runs on a Core Audio thread and hops to the queue it was given, where a
/// change that arrives after `remove()` is dropped.
final class CoreAudioListener {
    private let object: AudioObjectID
    private let addresses: [AudioObjectPropertyAddress]
    private var context: Unmanaged<Context>?

    /// Listens from now on: `heard` gets the selectors that changed, on `queue`. Made
    /// and removed on `queue`, which the context's flag is confined to.
    init(
        on object: AudioObjectID,
        _ addresses: [AudioObjectPropertyAddress],
        queue: DispatchQueue,
        heard: @escaping @Sendable ([AudioObjectPropertySelector]) -> Void
    ) {
        self.object = object
        self.addresses = addresses
        let context = Unmanaged.passRetained(Context(queue: queue, heard: heard))
        self.context = context
        for address in addresses {
            var address = address
            AudioObjectAddPropertyListener(object, &address, coreAudioPropertyChanged, context.toOpaque())
        }
    }

    deinit {
        remove()
    }

    /// Takes the listeners off. The context is let go only after Core Audio has let
    /// go of it, and a change already on its way to the queue finds it silenced.
    func remove() {
        guard let context else { return }
        self.context = nil
        context.takeUnretainedValue().isListening = false
        for address in addresses {
            var address = address
            AudioObjectRemovePropertyListener(object, &address, coreAudioPropertyChanged, context.toOpaque())
        }
        context.release()
    }

    /// What Core Audio holds on to: where to report, and whether to still.
    fileprivate final class Context: @unchecked Sendable {
        let queue: DispatchQueue
        let heard: @Sendable ([AudioObjectPropertySelector]) -> Void
        /// Confined to `queue`.
        var isListening = true

        init(queue: DispatchQueue, heard: @escaping @Sendable ([AudioObjectPropertySelector]) -> Void) {
            self.queue = queue
            self.heard = heard
        }
    }
}

/// Runs on a Core Audio thread; hops to the listener's queue.
private func coreAudioPropertyChanged(
    _: AudioObjectID,
    _ count: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context else { return noErr }
    let listener = Unmanaged<CoreAudioListener.Context>.fromOpaque(context).takeUnretainedValue()
    let selectors = (0..<Int(count)).map { addresses[$0].mSelector }
    listener.queue.async {
        guard listener.isListening else { return }
        listener.heard(selectors)
    }
    return noErr
}
