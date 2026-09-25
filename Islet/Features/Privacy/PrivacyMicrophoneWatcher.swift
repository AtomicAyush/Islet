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
/// while one of them is running, and only on macOS 14.2 and later, are the HAL's
/// client processes followed too, to see which are recording from it. Asking a
/// process whether it records costs a round trip to the audio server of a few
/// milliseconds, so processes are first narrowed to those using an input device at
/// all, which is cheap. The HAL never notifies a change of a process's
/// IsRunningInput, only of the devices it uses, so that is what each process is
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
        /// The outermost app bundle it lives in, looked up only while it is recording.
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
    /// Client processes being watched; none unless a microphone is running.
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
            refresh()
        }
    }

    func stop() {
        queue.async { [self] in
            guard report != nil else { return }
            report = nil
            unlisten(from: Self.system, Self.deviceList)
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
        sync(&processes, to: [], Self.processInputDevices)
    }

    // MARK: Reading

    private func refresh() {
        guard let report else { return }
        let devices = Self.objects(Self.deviceList).map(Self.device)
        sync(&microphones, to: devices.filter(\.isMicrophone).map(\.id), Self.deviceRunning)
        let microphoneRunning = devices.contains { $0.isMicrophone && $0.isRunning }

        let clients: [Client]?
        if perProcess, microphoneRunning {
            if !watchesProcessList {
                watchesProcessList = true
                listen(to: Self.system, Self.processList)
            }
            let current = Self.objects(Self.processList)
            sync(&processes, to: current, Self.processInputDevices)
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
    /// Nothing counts unless a microphone is running. A process counts as recording
    /// only when it is doing input and lists a running microphone, itself or through
    /// an aggregate device. Doing input is not enough: the Siri listener does input
    /// from a trigger microphone private to it, and while the Mac plays it lists the
    /// device playing among its inputs too, to hear past it. So beside that private
    /// device, a device it lists that has outputs is taken to be what is playing,
    /// and only its input-only microphones count.
    ///
    /// A running microphone no process can be matched to still counts, unnamed,
    /// since the hardware is on; unless it has outputs too, as a headset runs just
    /// the same when it only plays. Before macOS 14.2 no process can be matched, so
    /// that rule is all there is. Islet's own recording never counts, nor does a
    /// microphone that only Islet is running.
    static func reading(devices: [Device], clients: [Client]?, ownPID: pid_t, ownBundlePath: String?) -> Reading {
        let running = Set(devices.filter { $0.isMicrophone && $0.isRunning }.map(\.id))
        guard !running.isEmpty else { return Reading() }

        let byID = Dictionary(devices.map { ($0.id, $0) }) { first, _ in first }
        var matched: Set<AudioObjectID> = []
        var recording = false
        var apps: [PrivacyApp] = []
        for client in clients ?? [] where client.isRecording {
            var using = microphones(behind: client.inputDevices, in: byID).intersection(running)
            if client.bundleID == siriListener, client.inputDevices.contains(where: { byID[$0] == nil }) {
                using = using.filter { byID[$0]?.hasOutput == false }
            }
            guard !using.isEmpty else { continue }
            matched.formUnion(using)
            guard client.pid != ownPID else { continue }
            recording = true
            if let path = client.bundlePath, path != ownBundlePath, !apps.contains(where: { $0.bundlePath == path }) {
                apps.append(PrivacyApp(bundlePath: path))
            }
        }

        let unmatched = devices.contains { running.contains($0.id) && !matched.contains($0.id) && !$0.hasOutput }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Reading(inUse: recording || unmatched, apps: apps)
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

    // MARK: Attribution

    /// The outermost app bundle a process lives in, so a helper, an XPC service or an
    /// extension counts as its app. Daemons, and WebKit's shared media process, have
    /// none and stay unnamed.
    private static func appBundle(owning pid: pid_t) -> String? {
        let paths = [
            NSRunningApplication(processIdentifier: pid)?.bundleURL?.path,
            executablePath(of: pid),
        ]
        for case let path? in paths {
            if let bundle = outermostAppBundle(in: path) { return bundle }
        }
        return nil
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func outermostAppBundle(in path: String) -> String? {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            if component.hasSuffix(".app") { return prefix }
        }
        return nil
    }

    // MARK: Core Audio

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let deviceList = address(kAudioHardwarePropertyDevices)
    private static let processList = address(kAudioHardwarePropertyProcessObjectList)
    private static let deviceRunning = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    /// Notified whenever a process starts or stops IO on any device.
    private static let processInputDevices = address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
    private static let processRecording = address(kAudioProcessPropertyIsRunningInput)

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
            bundlePath: appBundle(owning: pid),
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
        var address = flag
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
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
