import AppKit
import Observation

/// The input devices connected to this Mac that report a battery level.
///
/// The level is read when a HID device comes or goes (several times over the next
/// half minute, since a device reports it a few seconds after connecting), after the Mac
/// wakes, and every few minutes while any is connected. With none connected, nothing
/// runs at all.
@MainActor
@Observable
final class InputDevicesModel {
    /// Connected devices, in `InputDevice.displayOrder`.
    private(set) var devices: [InputDevice] = []

    /// What a read found changed: devices connecting, changing level, power or name,
    /// and leaving. Not called for those already connected at `start()`.
    @ObservationIgnored var onChanges: (InputDeviceChanges) -> Void = { _ in }
    /// The Mac woke, and devices are about to find their way back to it.
    @ObservationIgnored var onWake: () -> Void = {}
    /// Anything about the devices changed, including at `start()`.
    @ObservationIgnored var onChange: () -> Void = {}

    /// After a HID device comes or goes, when to read, from then.
    static let readDelays: [TimeInterval] = [0.5, 2, 5, 12, 30]
    /// While any device is connected, its level is read this often. These batteries last
    /// weeks, so a few minutes is plenty to catch each warning level on its way down.
    static let pollInterval: TimeInterval = 5 * 60

    @ObservationIgnored private let source: (any InputDeviceSource)?
    @ObservationIgnored private(set) var isRunning = false
    @ObservationIgnored private var reads: Task<Void, Never>?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    /// Reads through `source`: the I/O Registry in the app, devices of their own in tests.
    init(source: any InputDeviceSource) {
        self.source = source
    }

    /// A model that only holds sample devices, for previews. It never reads anything.
    init(samples: [InputDevice]) {
        source = nil
        devices = samples.sorted(by: InputDevice.displayOrder)
    }

    func start() {
        guard !isRunning, let source else { return }
        isRunning = true
        apply(source.read(), isInitial: true)
        source.startWatching { [weak self] in self?.readSoon() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onWake()
                self?.readSoon()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        source?.stopWatching()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        reads?.cancel()
        reads = nil
        poll?.cancel()
        poll = nil
        devices = []
    }

    /// Reads the levels now.
    func refresh() {
        guard isRunning, let source else { return }
        apply(source.read(), isInitial: false)
    }

    /// Reads now and over the following half minute. A later call starts the sequence
    /// again rather than adding another.
    func readSoon() {
        guard isRunning else { return }
        reads?.cancel()
        reads = Task { [weak self] in
            var elapsed: TimeInterval = 0
            for delay in Self.readDelays {
                try? await Task.sleep(for: .seconds(delay - elapsed))
                elapsed = delay
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
            self?.reads = nil
        }
    }

    // MARK: Changes

    private func apply(_ readings: [InputDevice], isInitial: Bool) {
        let previous = devices
        let next = readings
            .map { reading in reading.confirmingPower(since: previous.first { $0.id == reading.id }) }
            .sorted(by: InputDevice.displayOrder)
        guard next != previous else { return }
        devices = next
        if !isInitial {
            var changes = InputDeviceChanges()
            for device in next {
                if let old = previous.first(where: { $0.id == device.id }) {
                    if old != device { changes.updated.append((old, device)) }
                } else {
                    changes.arrived.append(device)
                }
            }
            changes.departed = previous.filter { old in !next.contains { $0.id == old.id } }
            if !changes.isEmpty { onChanges(changes) }
        }
        onChange()
        syncPoll()
    }

    /// Reads every few minutes while there is a device to read, and not otherwise.
    private func syncPoll() {
        if devices.isEmpty {
            poll?.cancel()
            poll = nil
            return
        }
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }
}

/// What one read found changed, handed over whole, in display order. The feature weighs
/// everything a read found before it says anything: the island shows one banner at a
/// time, and a warning replaced a moment later by another device's would never be seen.
struct InputDeviceChanges {
    var arrived: [InputDevice] = []
    var updated: [(old: InputDevice, new: InputDevice)] = []
    var departed: [InputDevice] = []

    var isEmpty: Bool { arrived.isEmpty && updated.isEmpty && departed.isEmpty }
}

/// Which low-battery warnings each device is owed. Every level warns once as the
/// battery falls through it, and again only once the level has come back clearly above
/// it, whether on the cable or off. A level wobbling by a point around 20% never warns
/// twice; a few minutes on the cable that leave it under 20% re-arm nothing, so
/// unplugging brings no second warning; and a device that sleeps and reconnects is
/// remembered by its id.
struct LowBatteryWatch {
    /// The warning levels, highest first.
    static let levels = [20, 10, 5]
    /// How far above a level the battery must come back before it can warn there again.
    static let rearmMargin = 5

    /// The levels each device has warned at, or passed, since it was last clear of them.
    private(set) var passed: [String: Set<Int>] = [:]

    /// Whether the device has been seen before, since Islet started.
    func knows(_ device: InputDevice) -> Bool {
        passed[device.id] != nil
    }

    /// A device first seen already low, as Islet starts: its levels at and above where
    /// it stands pass without warning, so a launch never opens with an alarm. A device
    /// already known keeps what it knew.
    mutating func baseline(_ device: InputDevice) {
        guard passed[device.id] == nil else { return }
        passed[device.id] = Set(Self.levels.filter { device.level <= $0 })
    }

    /// The level to warn at for this reading, if any: the lowest of those it has newly
    /// reached among `enabled`, since a battery that fell from 50% to 8% between reads
    /// deserves the more urgent warning, and only one. On its cable a device is being seen
    /// to, so the levels it sits under pass without a word, as at launch.
    mutating func check(_ device: InputDevice, enabled: Set<Int>) -> Int? {
        var passed = self.passed[device.id] ?? []
        for level in Self.levels where device.level >= level + Self.rearmMargin {
            passed.remove(level)
        }
        let reached = Self.levels.filter { device.level <= $0 }
        let fresh = reached.filter { !passed.contains($0) && enabled.contains($0) }
        passed.formUnion(reached)
        self.passed[device.id] = passed
        return device.isOnPower ? nil : fresh.min()
    }
}
