import CoreMediaIO
import Foundation

/// Watches every camera CoreMediaIO knows about (built-in, USB, Continuity and
/// virtual) and reports whether any of them is streaming to any process. Whether a
/// device is running is readable without camera permission; which app is running it
/// is not, so this says only "in use".
///
/// All CoreMediaIO work happens on a private serial queue. Listeners are C callbacks
/// rather than blocks: Swift bridges a closure to a new block on every call, so a
/// block listener could never be removed again. The callbacks carry an unretained
/// pointer to the watcher, which `PrivacyMonitor` keeps for the life of the app.
final class PrivacyCameraWatcher: @unchecked Sendable {
    typealias Report = @MainActor @Sendable (_ inUse: Bool) -> Void

    private let queue = DispatchQueue(label: "islet.privacy.camera", qos: .utility)

    // Confined to `queue`.
    private var report: Report?
    private var devices: [CMIOObjectID] = []
    private var lastReported: Bool?
    private var refreshPending = false

    /// Starts watching. `report` gets the first reading, then every change.
    func start(report: @escaping Report) {
        queue.async { [self] in
            guard self.report == nil else { return }
            self.report = report
            lastReported = nil
            var address = Self.address(kCMIOHardwarePropertyDevices)
            CMIOObjectAddPropertyListener(Self.system, &address, Self.listener, context)
            refresh()
        }
    }

    func stop() {
        queue.async { [self] in
            guard report != nil else { return }
            report = nil
            var address = Self.address(kCMIOHardwarePropertyDevices)
            CMIOObjectRemovePropertyListener(Self.system, &address, Self.listener, context)
            devices.forEach(unwatch)
            devices = []
        }
    }

    // MARK: Listening

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private static let listener: CMIOObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        Unmanaged<PrivacyCameraWatcher>.fromOpaque(context).takeUnretainedValue().propertyChanged()
        return noErr
    }

    /// Called on CoreMediaIO's thread. A device appearing sends a burst of
    /// notifications; they are gathered into one refresh.
    private func propertyChanged() {
        queue.async { [self] in
            guard !refreshPending else { return }
            refreshPending = true
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                refreshPending = false
                refresh()
            }
        }
    }

    private func watch(_ device: CMIOObjectID) {
        var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        CMIOObjectAddPropertyListener(device, &address, Self.listener, context)
    }

    /// Fails harmlessly for a device that has already gone.
    private func unwatch(_ device: CMIOObjectID) {
        var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        CMIOObjectRemovePropertyListener(device, &address, Self.listener, context)
    }

    private func refresh() {
        guard let report else { return }
        let current = Self.deviceIDs()
        for device in devices where !current.contains(device) { unwatch(device) }
        for device in current where !devices.contains(device) { watch(device) }
        devices = current

        let inUse = current.contains(where: Self.isRunning)
        guard inUse != lastReported else { return }
        lastReported = inUse
        DispatchQueue.main.async {
            MainActor.assumeIsolated { report(inUse) }
        }
    }

    // MARK: CoreMediaIO

    private static let system = CMIOObjectID(kCMIOObjectSystemObject)

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private static func deviceIDs() -> [CMIOObjectID] {
        var address = address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let stride = MemoryLayout<CMIOObjectID>.stride
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / stride)
        var used: UInt32 = 0
        let status = ids.withUnsafeMutableBytes { buffer in
            CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, buffer.baseAddress)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(used) / stride))
    }

    private static func isRunning(_ device: CMIOObjectID) -> Bool {
        var address = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running
        )
        return status == noErr && running != 0
    }
}
