import AppKit
import Darwin

/// An app producing sound, as the mixer lists it.
struct MixerSource: Identifiable, Equatable, Sendable {
    /// The app's bundle identifier, or its bundle's path when it has none. Volumes
    /// are remembered under it.
    let id: String
    let name: String
    let bundlePath: String
}

/// Puts an audio process down to the app it plays for.
///
/// Much of what plays sound is not the app itself: WebKit's GPU process plays for
/// Safari, a helper for Chrome or any Electron app. macOS records which app is
/// responsible for each process it launches, which settles most of them; failing
/// that, a process that lives inside an app's bundle belongs to that app. Daemons
/// belong to no app, and system agents with no Dock icon (Control Centre, the
/// charging chime, Siri) are the system's own voice, so neither is listed. Nor is
/// Islet, or anything it runs.
enum AudioAppResolver {
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    /// Not public API, so looked up rather than linked; without it the bundle paths
    /// still place helpers that live inside their app.
    private static let responsiblePID: ResponsiblePID? = {
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let pointer = dlsym(everywhere, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(pointer, to: ResponsiblePID.self)
    }()

    static func source(for pid: pid_t) -> MixerSource? {
        let own = getpid()
        guard pid > 0, pid != own else { return nil }
        let responsible = responsiblePID.map { $0(pid) }.flatMap { $0 > 0 ? $0 : nil } ?? pid
        guard responsible != own else { return nil }

        for candidate in responsible == pid ? [pid] : [responsible, pid] {
            let running = NSRunningApplication(processIdentifier: candidate)
            let paths = [running?.bundleURL?.path, executablePath(of: candidate)]
            for case let path? in paths {
                guard let bundle = outermostApp(in: path) else { continue }
                return source(bundlePath: bundle, running: running?.bundleURL?.path == bundle ? running : nil)
            }
        }
        return nil
    }

    private static func source(bundlePath: String, running: NSRunningApplication?) -> MixerSource? {
        guard bundlePath != Bundle.main.bundlePath else { return nil }
        if bundlePath.hasPrefix("/System/Library/"), running?.activationPolicy != .regular { return nil }
        var name = running?.localizedName ?? FileManager.default.displayName(atPath: bundlePath)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let id = Bundle(path: bundlePath)?.bundleIdentifier ?? bundlePath
        return MixerSource(id: id, name: name, bundlePath: bundlePath)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// The outermost `.app` in a path, so a helper app nested in another app's
    /// bundle counts as the outer one.
    private static func outermostApp(in path: String) -> String? {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            if component.hasSuffix(".app") { return prefix }
        }
        return nil
    }
}
