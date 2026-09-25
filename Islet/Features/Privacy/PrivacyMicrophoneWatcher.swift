import AppKit
import CoreAudio
import Darwin

/// Watches Core Audio for processes recording from any input device, and names the
/// apps they belong to. Like the camera watcher it only observes: it never opens a
/// device, so it needs no microphone permission.
///
/// Input devices are always watched; there are few and they are cheap to ask. Only
/// while one of them is running, and only on macOS 14.2 and later, are the HAL's
/// client processes followed too, to see which are recording. Asking a process
/// whether it records costs a round trip to the audio server of a few milliseconds,
/// so processes are first narrowed to those using an input device at all, which is
/// cheap. The HAL never notifies a change of a process's IsRunningInput, only of the
/// devices it uses, so that is what each process is watched for. Before 14.2 a
/// running input device is all there is to go on, and no app is named.
///
/// Threading and listener lifetime work as in `PrivacyCameraWatcher`.
final class PrivacyMicrophoneWatcher: @unchecked Sendable {
    struct Reading: Equatable, Sendable {
        var inUse = false
        var apps: [PrivacyApp] = []
    }

    typealias Report = @MainActor @Sendable (Reading) -> Void

    private let queue = DispatchQueue(label: "islet.privacy.microphone", qos: .utility)

    private let perProcess: Bool = {
        if #available(macOS 14.2, *) { return true }
        return false
    }()

    // Confined to `queue`.
    private var report: Report?
    private var devices: [AudioObjectID] = []
    /// Client processes being watched; none unless an input device is running.
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
            sync(&devices, to: [], Self.deviceRunning)
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
        sync(&devices, to: Self.objects(Self.deviceList).filter(Self.hasInput), Self.deviceRunning)
        let deviceRunning = devices.contains { Self.flag(Self.deviceRunning, of: $0) }

        let reading: Reading
        if perProcess, deviceRunning {
            if !watchesProcessList {
                watchesProcessList = true
                listen(to: Self.system, Self.processList)
            }
            sync(&processes, to: Self.objects(Self.processList), Self.processInputDevices)
            reading = processReading()
        } else {
            stopWatchingProcesses()
            reading = Reading(inUse: deviceRunning)
        }

        guard reading != lastReported else { return }
        lastReported = reading
        DispatchQueue.main.async {
            MainActor.assumeIsolated { report(reading) }
        }
    }

    /// Every process but Islet that is recording, and the apps they belong to.
    private func processReading() -> Reading {
        var candidates = processes.filter(Self.usesInputDevice)
        // An input device is running, yet no process lists one: a headset may only be
        // playing, or a recorder may not have shown up. Asking everyone, slow as that
        // is, tells the two apart.
        if candidates.isEmpty { candidates = processes }

        let own = getpid()
        var recording: [pid_t] = []
        for process in candidates where Self.flag(Self.processRecording, of: process) {
            guard let pid = Self.pid(of: process), pid != own, !recording.contains(pid) else { continue }
            recording.append(pid)
        }

        var apps: [PrivacyApp] = []
        for pid in recording {
            if let app = Self.app(owning: pid), app.bundlePath != Bundle.main.bundlePath, !apps.contains(app) {
                apps.append(app)
            }
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Reading(inUse: !recording.isEmpty, apps: apps)
    }

    // MARK: Attribution

    /// The outermost app bundle a process lives in, so a helper, an XPC service or an
    /// extension counts as its app. Daemons, and WebKit's shared media process, have
    /// none and stay unnamed.
    private static func app(owning pid: pid_t) -> PrivacyApp? {
        let paths = [
            NSRunningApplication(processIdentifier: pid)?.bundleURL?.path,
            executablePath(of: pid),
        ]
        for case let path? in paths {
            if let bundle = outermostAppBundle(in: path) { return PrivacyApp(bundlePath: bundle) }
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

    /// The system object's list of devices or processes.
    private static func objects(_ list: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = list
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        let status = ids.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(system, &address, 0, nil, &size, base)
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

    private static func pid(of process: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func usesInputDevice(_ process: AudioObjectID) -> Bool {
        var address = processInputDevices
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(process, &address, 0, nil, &size) == noErr && size > 0
    }
}
