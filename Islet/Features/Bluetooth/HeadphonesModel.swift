import Foundation
import Observation

/// The headphones connected to this Mac and their battery levels.
///
/// Connections come from CoreAudio as they happen; battery levels come from
/// system_profiler, read once when a headset connects (and again a few seconds later,
/// since AirPods report their levels late) and whenever the home tile asks.
@MainActor
@Observable
final class HeadphonesModel {
    /// Connected headsets, oldest first.
    private(set) var headsets: [Headset] = []
    /// The headset sound is going to, if any.
    private(set) var outputID: String?

    /// The headset to show when there is room for one: where sound is going, otherwise
    /// the latest to connect.
    var current: Headset? {
        headsets.first { $0.id == outputID } ?? headsets.last
    }

    /// A headset connected. Not called for those already connected at `start()`.
    @ObservationIgnored var onConnect: (Headset) -> Void = { _ in }
    @ObservationIgnored var onDisconnect: (Headset) -> Void = { _ in }
    /// A connected headset's battery levels or model became known.
    @ObservationIgnored var onUpdate: (Headset) -> Void = { _ in }
    /// Headsets were added or removed.
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored private var watcher: BluetoothAudioWatcher?
    /// Headsets that vanished, waiting out a grace period before they count as gone.
    @ObservationIgnored private var departures: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var profileRead: Task<Void, Never>?
    @ObservationIgnored private var profileRetry: Task<Void, Never>?
    @ObservationIgnored private var wantsAnotherRead = false
    @ObservationIgnored private var lastProfileRead = Date.distantPast

    init() {}

    /// A model that only holds a sample headset, for previews. It never watches anything.
    init(sample: Headset) {
        headsets = [sample]
    }

    func start() {
        guard watcher == nil else { return }
        let watcher = BluetoothAudioWatcher()
        self.watcher = watcher
        watcher.start { [weak self, weak watcher] snapshot, isInitial in
            guard let self, let watcher, self.watcher === watcher else { return }
            self.apply(snapshot, isInitial: isInitial)
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        departures.values.forEach { $0.cancel() }
        departures.removeAll()
        profileRead?.cancel()
        profileRead = nil
        profileRetry?.cancel()
        profileRetry = nil
        wantsAnotherRead = false
        lastProfileRead = .distantPast
        headsets = []
        outputID = nil
    }

    /// Re-reads battery levels if the last read is older than `age` seconds. A read already
    /// under way is just as fresh, so this never queues another behind it (each island
    /// window's tile asks as it appears).
    func refreshLevels(olderThan age: TimeInterval) {
        guard watcher != nil, profileRead == nil, !headsets.isEmpty,
              Date().timeIntervalSince(lastProfileRead) > age
        else { return }
        readProfile()
    }

    // MARK: Connections

    private func apply(_ snapshot: BluetoothAudioWatcher.Snapshot, isInitial: Bool) {
        if outputID != snapshot.outputID { outputID = snapshot.outputID }

        var arrived: [Headset] = []
        for device in snapshot.devices {
            // Back within the grace period: a profile switch, not a reconnection.
            departures.removeValue(forKey: device.id)?.cancel()

            if let index = headsets.firstIndex(where: { $0.id == device.id }) {
                if headsets[index].name != device.name {
                    headsets[index].name = device.name
                }
            } else {
                let headset = Headset(
                    id: device.id,
                    name: device.name,
                    kind: HeadsetKind(name: device.name, productID: device.productID, vendorID: device.vendorID, minorType: nil),
                    productID: device.productID,
                    vendorID: device.vendorID
                )
                headsets.append(headset)
                if !isInitial { arrived.append(headset) }
            }
        }

        let present = Set(snapshot.devices.map(\.id))
        for headset in headsets where !present.contains(headset.id) && departures[headset.id] == nil {
            let id = headset.id
            departures[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.depart(id: id)
            }
        }

        if !arrived.isEmpty {
            readLevelsAfterConnecting()
        } else if isInitial, !headsets.isEmpty {
            readProfile()
        }
        if isInitial || !arrived.isEmpty { onChange() }
        arrived.forEach { onConnect($0) }
    }

    private func depart(id: String) {
        departures[id] = nil
        guard let index = headsets.firstIndex(where: { $0.id == id }) else { return }
        let headset = headsets.remove(at: index)
        onChange()
        onDisconnect(headset)
    }

    // MARK: Battery

    /// AirPods often reach system_profiler a few seconds before their levels do, so a
    /// connection reads at once and, if levels are still missing, once more shortly after.
    private func readLevelsAfterConnecting() {
        readProfile()
        profileRetry?.cancel()
        profileRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.profileRetry = nil
            if self.headsets.contains(where: \.battery.isEmpty) { self.readProfile() }
        }
    }

    /// One read at a time; a request during a read runs another straight after it.
    private func readProfile() {
        guard profileRead == nil else {
            wantsAnotherRead = true
            return
        }
        profileRead = Task { [weak self] in
            let devices = await BluetoothProfile.connectedDevices()
            guard !Task.isCancelled, let self else { return }
            self.profileRead = nil
            self.lastProfileRead = Date()
            if let devices { self.apply(devices) }
            if self.wantsAnotherRead {
                self.wantsAnotherRead = false
                self.readProfile()
            }
        }
    }

    private func apply(_ devices: [BluetoothProfile.Device]) {
        for index in headsets.indices {
            let headset = headsets[index]
            guard let device = devices.first(where: { $0.address == headset.id })
                ?? devices.first(where: { $0.name == headset.name })
            else { continue }

            var updated = headset
            // Levels drop out of the report now and then; keep the last ones rather than blank the rings.
            if !device.battery.isEmpty { updated.battery = device.battery }
            updated.productID = headset.productID ?? device.productID
            updated.vendorID = headset.vendorID ?? device.vendorID
            updated.kind = HeadsetKind(
                name: headset.name,
                productID: updated.productID,
                vendorID: updated.vendorID,
                minorType: device.minorType
            )
            guard updated != headset else { continue }
            headsets[index] = updated
            onUpdate(updated)
        }
    }
}
