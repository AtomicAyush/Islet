import AppKit
import CoreAudio
import Darwin

/// Watches Core Audio for processes recording from a microphone, and names the apps
/// they belong to. Like the camera watcher it only observes: it never opens a
/// device, so it needs no microphone permission.
///
/// A microphone is a device with input streams of its own: built in, USB, Bluetooth,
/// Continuity or virtual. An aggregate device is not one in itself; a process
/// recording through it records from whichever of its sub-devices are. So a device
/// whose only input is a process tap never counts: that records what the Mac plays,
/// which macOS marks with a purple dot, not the microphone. The Sound Mixer's own
/// devices, which only Islet can see, are left out altogether.
///
/// Microphones are always watched; there are few and they are cheap to ask. Only
/// while one of them is running, or while a Bluetooth one is connected, and only on
/// macOS 14.2 and later, are the HAL's client processes followed too, to see which
/// are recording from it. (A Bluetooth microphone is reported not to say when it
/// runs, so its clients are the only way to know.) Asking a process whether it
/// records costs a round trip to the audio server of a few milliseconds, so
/// processes are first narrowed to those using an input device at all, which is
/// cheap. The HAL never notifies a change of a process's IsRunningInput, only of the
/// devices it uses and of its running at all, so that is what each process is
/// watched for. Before 14.2 a running microphone is all there is to go on, and no
/// app is named.
///
/// One thing the HAL does not show is which of a device's streams another process
/// has turned on. So an app whose aggregate device follows a headset's output, to
/// record what the Mac plays, counts as recording the headset's microphone: by
/// default such a device does open it, and one that turns it off, as the Sound
/// Mixer does, cannot be told apart.
///
/// Threading and listener lifetime work as in `PrivacyCameraWatcher`.
final class PrivacyMicrophoneWatcher: @unchecked Sendable {
    struct Reading: Equatable, Sendable {
        var inUse = false
        var apps: [PrivacyApp] = []
        /// The processes recording, whether or not they could be named, so that what
        /// else the audio server reports recording can be told apart from them.
        var pids: [pid_t] = []
    }

    /// What `reading` needs to know of a device, read afresh on every refresh.
    struct Device: Equatable, Sendable {
        var id: AudioObjectID
        /// One of the Sound Mixer's devices. They are private to Islet, so only Islet
        /// ever sees them.
        var isOwn = false
        var isAggregate = false
        /// The devices an aggregate device is using, its taps not among them.
        var subdevices: [AudioObjectID] = []
        /// Input streams of its own. An aggregate device's come from its sub-devices
        /// and taps, so it is not asked.
        var hasInput = false
        /// Output streams too, as on a USB headset or an audio interface, which then
        /// runs whenever it plays.
        var hasOutput = false
        /// Running for some process. Asked only of microphones.
        var isRunning = false
        /// Connected over Bluetooth, which is reported to leave `isRunning` false
        /// while it records.
        var isBluetooth = false
        /// The input the Mac records from unless an app picks another.
        var isDefaultInput = false

        var isMicrophone: Bool { hasInput && !isAggregate && !isOwn }
    }

    /// What `reading` needs to know of a client process that uses an input device.
    struct Client: Equatable, Sendable {
        var pid: pid_t
        /// Doing input on some device, a microphone or not.
        var isRecording = false
        /// The devices it does input on. A device private to another process is listed
        /// as unknown.
        var inputDevices: [AudioObjectID] = []
        /// The bundle of the app it works for, looked up only while it is recording.
        var bundlePath: String?
        /// Its own bundle identifier, which a daemon has too, looked up only while it
        /// is recording.
        var bundleID: String?
    }

    /// corespeechd, which listens for "Hey Siri".
    static let siriListener = "com.apple.CoreSpeech"

    typealias Report = @MainActor @Sendable (Reading) -> Void

    private let queue = DispatchQueue(label: "islet.privacy.microphone", qos: .utility)

    private let perProcess: Bool = {
        if #available(macOS 14.2, *) { return true }
        return false
    }()

    // Confined to `queue`.
    private var report: Report?
    private var microphones: [AudioObjectID] = []
    /// Client processes being watched; none unless a microphone is running, or a
    /// Bluetooth one is connected.
    private var processes: [AudioObjectID] = []
    private var watchesProcessList = false
    private var lastReported: Reading?
    private var refreshPending = false

    /// Starts watching. `report` gets the first reading, then every change.
    func start(report: @escaping Report) {
        queue.async { [self] in
            guard self.report == nil else { return }
            self.report = report
            lastReported = nil
            listen(to: Self.system, Self.deviceList)
            listen(to: Self.system, Self.defaultInput)
            refresh()
        }
    }

    func stop() {
        queue.async { [self] in
            guard report != nil else { return }
            report = nil
            unlisten(from: Self.system, Self.deviceList)
            unlisten(from: Self.system, Self.defaultInput)
            sync(&microphones, to: [], Self.deviceRunning)
            stopWatchingProcesses()
        }
    }

    // MARK: Listening

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private static let listener: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        Unmanaged<PrivacyMicrophoneWatcher>.fromOpaque(context).takeUnretainedValue().propertyChanged()
        return noErr
    }

    /// Called on the HAL's notification thread. Notifications come in bursts (a
    /// process arriving sends several); they are gathered into one refresh.
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

    private func listen(to object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        AudioObjectAddPropertyListener(object, &address, Self.listener, context)
    }

    /// Fails harmlessly for a device or process that has already gone.
    private func unlisten(from object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        AudioObjectRemovePropertyListener(object, &address, Self.listener, context)
    }

    /// Moves a listener off the objects that went and onto the ones that came.
    private func sync(_ watched: inout [AudioObjectID], to current: [AudioObjectID], _ address: AudioObjectPropertyAddress) {
        for object in watched where !current.contains(object) { unlisten(from: object, address) }
        for object in current where !watched.contains(object) { listen(to: object, address) }
        watched = current
    }

    private func stopWatchingProcesses() {
        if watchesProcessList {
            watchesProcessList = false
            unlisten(from: Self.system, Self.processList)
        }
        syncProcesses(to: [])
    }

    /// Each process is watched for the input devices it uses, and for starting or
    /// stopping IO at all: a process that stops recording from a device it keeps
    /// listed changes only the latter.
    private func syncProcesses(to current: [AudioObjectID]) {
        var watched = processes
        sync(&watched, to: current, Self.processInputDevices)
        sync(&processes, to: current, Self.processRunning)
    }

    // MARK: Reading

    private func refresh() {
        guard let report else { return }
        let defaultInput = Self.object(Self.defaultInput)
        var devices = Self.objects(Self.deviceList).map(Self.device)
        for index in devices.indices where devices[index].id == defaultInput {
            devices[index].isDefaultInput = true
        }
        sync(&microphones, to: devices.filter(\.isMicrophone).map(\.id), Self.deviceRunning)
        let microphoneMayRun = devices.contains { $0.isMicrophone && ($0.isRunning || $0.isBluetooth) }

        let clients: [Client]?
        if perProcess, microphoneMayRun {
            if !watchesProcessList {
                watchesProcessList = true
                listen(to: Self.system, Self.processList)
            }
            let current = Self.objects(Self.processList)
            syncProcesses(to: current)
            clients = current.compactMap(Self.client)
        } else {
            stopWatchingProcesses()
            // Before 14.2 there are no processes to ask; after, none need asking.
            clients = perProcess ? [] : nil
        }

        let reading = Self.reading(devices: devices, clients: clients, ownPID: getpid(), ownBundlePath: Bundle.main.bundlePath)
        guard reading != lastReported else { return }
        lastReported = reading
        DispatchQueue.main.async {
            MainActor.assumeIsolated { report(reading) }
        }
    }

    /// What the dot shows, given every device and every process using an input
    /// device, or `nil` for the processes before macOS 14.2, when they cannot be asked.
    ///
    /// Nothing counts unless a microphone is running, or is connected over Bluetooth,
    /// which may record without saying so. A process counts as recording only when it
    /// is doing input and lists such a microphone, itself or through an aggregate
    /// device. Doing input is not enough: the Siri listener does input from a trigger
    /// microphone private to it, and while the Mac plays it lists the device playing
    /// among its inputs too, to hear past it. So beside that private device, a device
    /// it lists that has outputs is taken to be what is playing, and only its
    /// input-only microphones count.
    ///
    /// A running microphone no process can be matched to still counts, unnamed,
    /// since the hardware is on; unless it has outputs too, as a headset runs just
    /// the same when it only plays. Before macOS 14.2 no process can be matched, so
    /// that rule is all there is. Islet's own recording never counts, nor does a
    /// microphone that only Islet is running.
    ///
    /// Core Audio is known to list the wrong device for a process now and then (the
    /// speakers, after a call moved to AirPods), and a process recording through a
    /// device private to it lists that as unknown. So while a running microphone is
    /// unmatched, or the Mac records from Bluetooth, a lone process doing input with
    /// no microphone among its devices, and nothing that explains its input (an
    /// aggregate device, whose parts can be seen), is taken to be the one recording.
    /// Only a lone one: with two, there is no telling which.
    static func reading(devices: [Device], clients: [Client]?, ownPID: pid_t, ownBundlePath: String?) -> Reading {
        let running = Set(devices.filter { $0.isMicrophone && $0.isRunning }.map(\.id))
        let bluetooth = Set(devices.filter { $0.isMicrophone && $0.isBluetooth }.map(\.id))
        let live = running.union(bluetooth)
        guard !live.isEmpty else { return Reading() }

        let byID = Dictionary(devices.map { ($0.id, $0) }) { first, _ in first }
        var matched: Set<AudioObjectID> = []
        var reading = Reading()
        func add(_ client: Client) {
            reading.inUse = true
            if !reading.pids.contains(client.pid) { reading.pids.append(client.pid) }
            if let path = client.bundlePath, path != ownBundlePath, !reading.apps.contains(where: { $0.bundlePath == path }) {
                reading.apps.append(PrivacyApp(bundlePath: path))
            }
        }

        for client in clients ?? [] where client.isRecording {
            var using = microphones(behind: client.inputDevices, in: byID).intersection(live)
            if client.bundleID == siriListener, client.inputDevices.contains(where: { byID[$0] == nil }) {
                using = using.filter { byID[$0]?.hasOutput == false }
            }
            guard !using.isEmpty else { continue }
            matched.formUnion(using)
            guard client.pid != ownPID else { continue }
            add(client)
        }

        let unmatched = devices.contains { running.contains($0.id) && !matched.contains($0.id) && !$0.hasOutput }
        let recordsBluetooth = devices.contains { $0.isDefaultInput && bluetooth.contains($0.id) }
        if unmatched || recordsBluetooth {
            let unexplained = (clients ?? []).filter { client in
                client.isRecording && client.pid != ownPID && client.bundleID != siriListener
                    && !client.inputDevices.contains { byID[$0]?.isAggregate == true || byID[$0]?.isOwn == true }
                    && microphones(behind: client.inputDevices, in: byID).isEmpty
                    && !reading.pids.contains(client.pid)
            }
            if unexplained.count == 1 { add(unexplained[0]) }
        }

        reading.inUse = reading.inUse || unmatched
        reading.apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        reading.pids.sort()
        return reading
    }

    /// The microphones a list of devices stands for: each microphone itself, and each
    /// aggregate device's sub-devices that are microphones. Anything else stands for
    /// none: outputs, the mixer's devices, and devices private to another process,
    /// which are not in `devices`.
    private static func microphones(behind ids: [AudioObjectID], in devices: [AudioObjectID: Device]) -> Set<AudioObjectID> {
        var found: Set<AudioObjectID> = []
        var seen: Set<AudioObjectID> = []
        var pending = ids
        while let id = pending.popLast() {
            guard seen.insert(id).inserted, let device = devices[id], !device.isOwn else { continue }
            if device.isAggregate {
                pending += device.subdevices
            } else if device.hasInput {
                found.insert(id)
            }
        }
        return found
    }

    // MARK: Any process

    /// Whether the process with `pid` is recording right now, from a microphone or
    /// from what the Mac plays, as Core Audio sees it; `nil` before macOS 14.2, when
    /// processes cannot be asked. A process Core Audio does not know is not
    /// recording. A round trip to the audio server of a few milliseconds.
    static func isRecording(pid: pid_t) -> Bool? {
        guard #available(macOS 14.2, *) else { return nil }
        guard let process = processObject(pid: pid) else { return false }
        return flag(processRecording, of: process)
    }

    /// The audio server's object for a process, or `nil` for one that does no audio.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        guard #available(macOS 14.2, *) else { return nil }
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    /// What changes when a process starts or stops recording: the input devices it
    /// uses, and whether it does IO at all. Whether it records is never notified.
    static let processActivity = [processInputDevices, processRunning]

    // MARK: Core Audio

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let deviceList = address(kAudioHardwarePropertyDevices)
    private static let processList = address(kAudioHardwarePropertyProcessObjectList)
    private static let deviceRunning = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    /// Notified whenever a process starts or stops IO on any device.
    private static let processInputDevices = address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
    private static let processRunning = address(kAudioProcessPropertyIsRunning)
    private static let processRecording = address(kAudioProcessPropertyIsRunningInput)
    private static let defaultInput = address(kAudioHardwarePropertyDefaultInputDevice)
    private static let transport = address(kAudioDevicePropertyTransportType)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Asks a device only what `reading` needs: whether it is running matters only
    /// for a microphone, and an aggregate device's streams not at all. The mixer's
    /// devices are known by their UID, whatever else they seem.
    private static func device(_ id: AudioObjectID) -> Device {
        var device = Device(id: id)
        if string(kAudioDevicePropertyDeviceUID, of: id)?.hasPrefix(VolumeTap.deviceUIDPrefix) == true {
            device.isOwn = true
        } else if classID(of: id) == kAudioAggregateDeviceClassID {
            device.isAggregate = true
            device.subdevices = objects(address(kAudioAggregateDevicePropertyActiveSubDeviceList), of: id)
        } else if hasStreams(id, scope: kAudioObjectPropertyScopeInput) {
            device.hasInput = true
            device.hasOutput = hasStreams(id, scope: kAudioObjectPropertyScopeOutput)
            device.isRunning = flag(deviceRunning, of: id)
            let transport = value(Self.transport, of: id)
            device.isBluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
        return device
    }

    /// A process that uses an input device; `nil` for one that uses none, or has gone.
    private static func client(_ process: AudioObjectID) -> Client? {
        let inputs = objects(processInputDevices, of: process)
        guard !inputs.isEmpty, let pid = pid(of: process) else { return nil }
        guard flag(processRecording, of: process) else { return Client(pid: pid, inputDevices: inputs) }
        return Client(
            pid: pid,
            isRecording: true,
            inputDevices: inputs,
            bundlePath: PrivacyAppResolver.app(pid: pid)?.bundlePath,
            bundleID: string(kAudioProcessPropertyBundleID, of: process)
        )
    }

    /// A list of objects: the system's devices or processes, the devices a process
    /// uses, an aggregate device's sub-devices.
    private static func objects(_ list: AudioObjectPropertyAddress, of object: AudioObjectID = system) -> [AudioObjectID] {
        var address = list
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        let status = ids.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, base)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(size) / stride))
    }

    /// Reads a UInt32 flag. A failed read, as for an object that just went away,
    /// counts as false.
    private static func flag(_ flag: AudioObjectPropertyAddress, of object: AudioObjectID) -> Bool {
        (value(flag, of: object) ?? 0) != 0
    }

    private static func value(_ property: AudioObjectPropertyAddress, of object: AudioObjectID) -> UInt32? {
        var address = property
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// A single object, such as the default input device; `nil` for none.
    private static func object(_ property: AudioObjectPropertyAddress) -> AudioObjectID? {
        value(property, of: system).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func classID(of object: AudioObjectID) -> AudioClassID? {
        var address = address(kAudioObjectPropertyClass)
        var value = AudioClassID(0)
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func pid(of process: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func hasStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}
