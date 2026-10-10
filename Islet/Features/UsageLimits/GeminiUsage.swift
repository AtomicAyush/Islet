import Darwin
import Foundation
import Security

/// Gemini's quota, as Google Antigravity's own quota screen shows it: asked of
/// Antigravity's language server, the local server its window talks to, while
/// Antigravity is open. Unofficial, and read-only: Antigravity says nothing of its quota
/// anywhere else on this Mac, so Islet asks the one method its quota screen asks,
/// `RetrieveUserQuotaSummary`, the way its window does, and nothing more. An update of
/// Antigravity may change any of it; anything other than what is expected shows nothing
/// new.
///
/// Antigravity starts its server, `Contents/Resources/bin/language_server`, with a port
/// and a one-time access key on its command line (`--https_server_port`,
/// `--csrf_token`), and its window sends the key with each call, in
/// `x-codeium-csrf-token`, over HTTPS to 127.0.0.1 on that port, trusting the server's
/// own certificate there. The port is 0 where the server picks its own, as Antigravity
/// 2 has it start; then it is the port the server listens on. The calls are Connect's,
/// in JSON: a POST of the request, the response or an error back.
///
/// The server is found among the children of the Antigravity app running now, and is
/// asked only if it is the program inside `/Applications/Antigravity.app`, run by this
/// user, signed by Google. The key is read from its arguments as each read starts, sent
/// to that server alone, and let go of once the read ends: it is never written down,
/// logged, shown or passed anywhere else. The call goes to 127.0.0.1 alone, on a port the
/// server itself listens on, with no proxy, cookies, cache or redirects, and the
/// certificate is taken on trust for that address and port alone.
enum GeminiUsage {
    static let appPath = "/Applications/Antigravity.app"
    static let serverPath = appPath + "/Contents/Resources/bin/language_server"
    /// Google's team, which signs Antigravity and its server.
    static let teamID = "EQHXZ8M8AV"
    static let host = "127.0.0.1"
    /// The one method asked, as Antigravity's window asks it.
    static let method = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    static let keyHeader = "x-codeium-csrf-token"
    /// How long a call may take, to the end of its answer.
    static let timeout: TimeInterval = 4
    /// The longest answer read.
    static let maxResponse = 256 * 1024
    /// The most ports of the server tried, where it picked its own.
    static let maxPorts = 6
    /// The most limits shown, the fullest where there are more.
    static let maxWindows = 3
    /// A limit's length where its `window` says none Islet knows.
    static let defaultMinutes = 1440

    // MARK: Finding the server

    /// What Islet looks at of the processes on this Mac, which tests replace.
    struct System: Sendable {
        var children: @Sendable (_ pid: Int32) -> [Int32]
        var path: @Sendable (_ pid: Int32) -> String?
        var owner: @Sendable (_ pid: Int32) -> uid_t?
        var arguments: @Sendable (_ pid: Int32) -> [String]?
        /// Whether the program running as `pid` is signed by Google.
        var isGoogles: @Sendable (_ pid: Int32) -> Bool
        /// The TCP ports `pid` listens on that 127.0.0.1 reaches.
        var listening: @Sendable (_ pid: Int32) -> [Int]
        var user: uid_t

        static let live = System(
            children: { Processes.children($0) }, path: { Processes.path($0) }, owner: { Processes.owner($0) },
            arguments: { ClaudeProcess.arguments(of: $0) }, isGoogles: { Processes.isGoogles($0) },
            listening: { Processes.listening($0) }, user: getuid()
        )
    }

    /// The server found, and what it is asked with. Held only while a read runs.
    struct Server {
        var pid: Int32
        /// The ports to try, the one its arguments name, or those it listens on.
        var ports: [Int]
        fileprivate var key: String
    }

    /// The server among the children of Antigravity's processes `apps`; `nil` where none
    /// is there yet, or none passes.
    static func server(apps: [Int32], system: System) -> Server? {
        for app in apps {
            for pid in system.children(app) {
                guard system.path(pid) == serverPath, system.owner(pid) == system.user,
                      let arguments = system.arguments(pid),
                      let key = value(of: "--csrf_token", in: arguments), !key.isEmpty, key.count <= 512,
                      let named = value(of: "--https_server_port", in: arguments).flatMap(Int.init),
                      (0...65535).contains(named),
                      system.isGoogles(pid)
                else { continue }
                let open = system.listening(pid).filter { (1...65535).contains($0) }
                let ports = named > 0 ? open.filter { $0 == named } : Array(Set(open).sorted().prefix(maxPorts))
                guard !ports.isEmpty else { continue }
                return Server(pid: pid, ports: ports, key: key)
            }
        }
        return nil
    }

    /// The value after `flag` in `arguments`, as `--flag value` or `--flag=value`.
    static func value(of flag: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == flag { return index + 1 < arguments.count ? arguments[index + 1] : nil }
            if argument.hasPrefix(flag + "=") { return String(argument.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    // MARK: Reading

    /// Why a read gave nothing.
    enum Failure: Error, Equatable, Sendable {
        /// Nothing there to take the call: no connection, or no TLS handshake, so nothing
        /// was sent.
        case unreachable
        /// The server took the call but gave no answer in time.
        case noAnswer
        /// The server said no: an HTTP status other than 200.
        case refused(status: Int)
        /// An answer in a shape Islet doesn't know.
        case format
        /// The quota holds no limit Islet can show.
        case empty
    }

    /// What a read came to.
    enum Outcome: Equatable, Sendable {
        case read(UsageReading, Known)
        /// Antigravity's server isn't there: not running, or not yet started.
        case noServer
        case failed(Failure)
    }

    /// The port that last answered, tried first next time while its server runs.
    struct Known: Equatable, Sendable {
        var pid: Int32
        var port: Int
    }

    /// Finds the server and asks it, trying the port that answered last first; called
    /// off the main thread. The key goes no further than this call, and is sent once at
    /// most: a port that isn't the server's HTTPS one fails its handshake before anything
    /// is sent, and the first that answers at all is the one, whatever it says.
    static func read(apps: [Int32], known: Known?, system: System, now: @escaping () -> Date = Date.init,
                     call: (_ port: Int, _ key: String) -> Result<Data, Failure> = ask) -> Outcome {
        guard let server = server(apps: apps, system: system) else { return .noServer }
        var ports = server.ports
        if let known, known.pid == server.pid, let index = ports.firstIndex(of: known.port) {
            ports.insert(ports.remove(at: index), at: 0)
        }
        for port in ports {
            switch call(port, server.key) {
            case .success(let data):
                switch parse(data, at: now()) {
                case .success(let reading): return .read(reading, Known(pid: server.pid, port: port))
                case .failure(let error): return .failed(error)
                }
            case .failure(.unreachable):
                continue
            case .failure(let error):
                return .failed(error)
            }
        }
        return .failed(.unreachable)
    }

    /// One call to the server on `port`, synchronously.
    static func ask(port: Int, key: String) -> Result<Data, Failure> {
        guard (1...65535).contains(port), let url = URL(string: "https://\(host):\(port)\(method)") else {
            return .failure(.unreachable)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(key, forHTTPHeaderField: keyHeader)
        request.httpShouldHandleCookies = false
        // As Antigravity's window asks it: the quota the server has, not a new look.
        request.httpBody = Data("{}".utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: false, kCFNetworkProxiesHTTPSEnable: false,
            kCFNetworkProxiesSOCKSEnable: false, kCFNetworkProxiesProxyAutoConfigEnable: false,
            kCFNetworkProxiesProxyAutoDiscoveryEnable: false,
        ] as [AnyHashable: Any]
        let delegate = LocalTrust(port: port)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let done = DispatchSemaphore(value: 0)
        let result = Box<Result<Data, Failure>>(.failure(.unreachable))
        let task = session.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            guard error == nil, let http = response as? HTTPURLResponse, let data else {
                // Past the handshake, the call may have gone: no other port is tried.
                if delegate.hasTrusted { result.value = .failure(.noAnswer) }
                return
            }
            guard http.statusCode == 200 else {
                result.value = .failure(.refused(status: http.statusCode))
                return
            }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard type.hasPrefix("application/json"), data.count <= maxResponse else {
                result.value = .failure(.format)
                return
            }
            result.value = .success(data)
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            return .failure(delegate.hasTrusted ? .noAnswer : .unreachable)
        }
        return result.value
    }

    /// Trusts the server's own certificate on 127.0.0.1 at `port`, and nothing else; no
    /// redirect is followed.
    private final class LocalTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let port: Int
        private let lock = NSLock()
        private var trusted = false

        init(port: Int) { self.port = port }

        /// Whether the server's certificate was taken, so the handshake got that far.
        var hasTrusted: Bool { lock.withLock { trusted } }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            answer(challenge, completionHandler)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            answer(challenge, completionHandler)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        private func answer(_ challenge: URLAuthenticationChallenge,
                            _ completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  space.host == GeminiUsage.host, space.port == port, let trust = space.serverTrust
            else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            lock.withLock { trusted = true }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    // MARK: The answer

    /// One limit as the quota screen lists it.
    struct Bucket: Equatable {
        var name: String
        /// The group it is listed under, the models it covers.
        var group: String?
        var minutes: Int
        /// Whether `minutes` is the length its `window` says, rather than taken for one.
        var knownLength: Bool
        var percent: Double
        var resets: Date?
        var isGemini: Bool
    }

    /// The reading in the server's answer, taken `at`: `RetrieveUserQuotaSummaryResponse`
    /// in JSON, `{"response": {"groups": [{"displayName", "buckets": [{"bucketId",
    /// "displayName", "window", "remainingFraction", "resetTime", …}]}], "buckets": […]}}`.
    /// Gemini's groups and limits are shown where there are any, as Antigravity's own
    /// "Gemini models only" shows them, else every one, each group's shortest first; a
    /// limit given as an amount left rather than a share, turned off or unnamed, is
    /// passed over. A field of another kind than the format's, or no limit to show, gives
    /// nothing. Antigravity 2 answers with a group "Gemini Models" holding "Weekly Limit
    /// Remaining" (window "weekly") and "Five Hour Limit Remaining" ("5h"), and another
    /// for Claude and GPT; each limit is named as Claude's and ChatGPT's are, by its
    /// length (`shownName`), with its group before it where more than one is shown.
    static func parse(_ data: Data, at now: Date) -> Result<UsageReading, Failure> {
        guard data.count <= maxResponse,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = object["response"] as? [String: Any]
        else { return .failure(.format) }
        var named: [(group: String?, bucket: [String: Any])] = []
        if let groups = response["groups"] {
            guard let groups = groups as? [Any] else { return .failure(.format) }
            for group in groups {
                guard let group = group as? [String: Any], let title = text(group["displayName"]),
                      let list = group["buckets"].map({ $0 as? [Any] }) ?? []
                else { return .failure(.format) }
                for bucket in list {
                    guard let bucket = bucket as? [String: Any] else { return .failure(.format) }
                    named.append((title.isEmpty ? nil : title, bucket))
                }
            }
        }
        if let loose = response["buckets"] {
            guard let list = loose as? [Any] else { return .failure(.format) }
            for bucket in list {
                guard let bucket = bucket as? [String: Any] else { return .failure(.format) }
                named.append((nil, bucket))
            }
        }
        var buckets: [Bucket] = []
        for (group, fields) in named {
            guard let found = bucket(fields, group: group) else { return .failure(.format) }
            if let found = found { buckets.append(found) }
        }
        let gemini = buckets.filter(\.isGemini)
        var shown = gemini.isEmpty ? buckets : gemini
        // The groups in the quota screen's order, each one's limits shortest first.
        var groups: [String?] = []
        for bucket in shown where !groups.contains(bucket.group) { groups.append(bucket.group) }
        shown = shown.enumerated().sorted { a, b in
            (groups.firstIndex(of: a.element.group) ?? 0, a.element.minutes, a.offset)
                < (groups.firstIndex(of: b.element.group) ?? 0, b.element.minutes, b.offset)
        }.map(\.element)
        // Named before any are left out, so a name stays put as the figures move.
        let prefixed = groups.count > 1
        var names = shown.map { shownName($0.name, minutes: $0.knownLength ? $0.minutes : nil, group: $0.group, prefixed: prefixed) }
        let repeated = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        for index in names.indices where repeated.contains(names[index]) {
            names[index] = shownName(shown[index].name, minutes: shown[index].knownLength ? shown[index].minutes : nil,
                                     group: shown[index].group, prefixed: prefixed, ownToo: true)
        }
        for index in shown.indices { shown[index].name = names[index] }
        // Of more than fit, the fullest, in the order the quota screen has them.
        if shown.count > maxWindows {
            let kept = Set(shown.indices.sorted { shown[$0].percent > shown[$1].percent }.prefix(maxWindows))
            shown = shown.indices.filter { kept.contains($0) }.map { shown[$0] }
        }
        guard !shown.isEmpty else { return .failure(.empty) }
        let windows = shown.map { UsageWindow(minutes: $0.minutes, percent: $0.percent, resets: $0.resets, name: $0.name) }
        return .success(UsageReading(agent: .gemini, measured: now, windows: windows))
    }

    /// A limit from its fields: `.some(nil)` for one passed over, `nil` for fields of
    /// another kind than the format's.
    private static func bucket(_ fields: [String: Any], group: String?) -> Bucket?? {
        guard let name = text(fields["displayName"]), let id = text(fields["bucketId"]),
              let window = text(fields["window"]), let disabled = flag(fields["disabled"])
        else { return nil }
        var fraction: Double?
        if let given = fields["remainingFraction"] {
            guard let number = given as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value >= -0.001, value <= 1.001 else { return nil }
            fraction = min(1, max(0, value))
        }
        var resets: Date?
        if let given = fields["resetTime"] {
            guard let stamp = given as? String, let date = date(stamp) else { return nil }
            resets = date
        }
        guard !disabled, !name.isEmpty, let fraction else { return .some(nil) }
        let isGemini = [name, id, group ?? ""].contains { $0.localizedCaseInsensitiveContains("gemini") }
        let length = minutes(window)
        return .some(Bucket(name: name, group: group, minutes: length ?? defaultMinutes, knownLength: length != nil,
                            percent: (1 - fraction) * 100, resets: resets, isGemini: isGemini))
    }

    /// The words of Antigravity's names that say what the island says itself, or the
    /// opposite of what it shows: "Weekly Limit Remaining" is a share used on the tile.
    static let fillerWords: Set<String> = ["remaining", "left", "limit", "limits", "quota", "quotas"]

    /// A limit's name, as Claude's and ChatGPT's are named: by its length where its
    /// `minutes` are known ("5-hour", "weekly", which the tile says "5h", "Week" and a
    /// banner "Gemini 5-hour limit at 80%"), else by its own name without the words the
    /// island says itself ("Credits" for "Credits Remaining"). Where more than one group
    /// is shown, the group's short name goes before it ("Claude/GPT 5-hour"). With
    /// `ownToo`, for two limits that would be named alike, its own name before its length.
    static func shownName(_ name: String, minutes: Int?, group: String?, prefixed: Bool, ownToo: Bool = false) -> String {
        let plain = plainName(name)
        let length = minutes.map { UsageText.longName(UsageWindow(minutes: $0, percent: 0)) }
        var own = length ?? plain
        if ownToo, let length, !plain.isEmpty { own = plain + " " + length }
        let short = group.map(shortGroup) ?? ""
        if prefixed, !short.isEmpty { return own.isEmpty ? short : short + " " + own }
        if !own.isEmpty { return own }
        return short.isEmpty ? name.trimmingCharacters(in: .whitespaces) : short
    }

    /// A limit's own name without the words the island says itself: "Five Hour" for
    /// "Five Hour Limit Remaining".
    static func plainName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).filter { !fillerWords.contains($0.lowercased()) }.joined(separator: " ")
    }

    /// A group's name, short, as it goes before a limit's: "Claude/GPT" for "Claude and
    /// GPT models", "Gemini" for "Gemini Models", "Gemini 3 Pro" as it is.
    static func shortGroup(_ group: String) -> String {
        let words = group.split(whereSeparator: \.isWhitespace).filter { !["models", "model"].contains($0.lowercased()) }
        var short = ""
        for word in words {
            if ["and", "&"].contains(word.lowercased()) { short += "/"; continue }
            short += (short.isEmpty || short.hasSuffix("/") ? "" : " ") + word
        }
        short = short.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return short.isEmpty ? group.trimmingCharacters(in: .whitespaces) : short
    }

    /// A string field, `""` where it is left out, as proto3's JSON leaves out an empty
    /// one; `nil` for any other kind.
    private static func text(_ value: Any?) -> String? {
        guard let value else { return "" }
        return value as? String
    }

    private static func flag(_ value: Any?) -> Bool? {
        guard let value else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A limit's length in minutes from its `window`: "18000s" as a protobuf duration,
    /// "5h", "24h", "7d", "1w", "5 hours", "5-hour", "daily", "weekly", "monthly";
    /// `nil` for anything else.
    static func minutes(_ window: String) -> Int? {
        let text = window.trimmingCharacters(in: .whitespaces).lowercased()
        switch text {
        case "hourly", "hour": return 60
        case "daily", "day", "1 day": return 1440
        case "weekly", "week": return 10080
        case "monthly", "month": return 43200
        default: break
        }
        let digits = text.prefix { $0.isNumber || $0 == "." }
        guard let amount = Double(digits), amount > 0 else { return nil }
        let unit = text.dropFirst(digits.count).trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        let perUnit: Double
        switch unit {
        case "s", "sec", "secs", "second", "seconds": perUnit = 1.0 / 60
        case "m", "min", "mins", "minute", "minutes": perUnit = 1
        case "h", "hr", "hrs", "hour", "hours": perUnit = 60
        case "d", "day", "days": perUnit = 1440
        case "w", "wk", "week", "weeks": perUnit = 10080
        default: return nil
        }
        let minutes = (amount * perUnit).rounded()
        guard minutes >= 1, minutes <= 366 * 1440 else { return nil }
        return Int(minutes)
    }

    /// "2026-10-10T15:00:00Z", with any number of digits of a second, as protobuf's JSON
    /// writes a time, or an offset.
    static func date(_ text: String) -> Date? {
        var stamp = text
        if let dot = stamp.firstIndex(of: "."), stamp.distance(from: stamp.startIndex, to: dot) == 19 {
            let digits = stamp[stamp.index(after: dot)...].prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            let rest = stamp[stamp.index(after: dot)...].dropFirst(digits.count)
            stamp = String(stamp[..<dot]) + "." + String((digits + "000").prefix(3)) + rest
        }
        return (try? Date(stamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(stamp, strategy: .iso8601))
    }

    // MARK: Kept

    /// The last figures read, kept in Islet's settings to show dimmed while Antigravity
    /// is closed: the limits' names and numbers, and when they were read.
    struct Kept: Codable, Equatable {
        struct Window: Codable, Equatable {
            var name: String?
            var minutes: Int
            var percent: Double
            var resets: Date?
        }

        var measured: Date
        var windows: [Window]

        init(_ reading: UsageReading) {
            measured = reading.measured
            windows = reading.windows.map { Window(name: $0.name, minutes: $0.minutes, percent: $0.percent, resets: $0.resets) }
        }

        var reading: UsageReading {
            UsageReading(agent: .gemini, measured: measured,
                         windows: windows.map { UsageWindow(minutes: $0.minutes, percent: $0.percent, resets: $0.resets, name: $0.name) })
        }
    }
}

/// What Islet asks the system of a process, by its id. Each gives `nil` or nothing where
/// it cannot be told.
enum Processes {
    static func children(_ pid: Int32) -> [Int32] {
        var pids = [pid_t](repeating: 0, count: 256)
        let count = Int(proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return [] }
        return pids.prefix(min(count, pids.count)).filter { $0 > 1 }
    }

    static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func owner(_ pid: Int32) -> uid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbsi_uid
    }

    /// Whether the code running as `pid` is valid and signed by Google's team.
    static func isGoogles(_ pid: Int32) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(GeminiUsage.teamID)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The TCP ports `pid` listens on that a call to 127.0.0.1 reaches: bound to
    /// 127.0.0.1, or to every address.
    static func listening(_ pid: Int32) -> [Int] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var ports: [Int] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP
            else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let address = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: address.insi_lport)))
            switch info.psi.soi_family {
            case AF_INET:
                let ip = UInt32(bigEndian: address.insi_laddr.ina_46.i46a_addr4.s_addr)
                guard ip == 0x7F00_0001 || ip == 0 else { continue }
            case AF_INET6:
                // Every address, IPv4's among them.
                let bytes = withUnsafeBytes(of: address.insi_laddr.ina_6) { Array($0) }
                guard bytes.allSatisfy({ $0 == 0 }), address.insi_vflag & UInt8(INI_IPV4) != 0 else { continue }
            default:
                continue
            }
            ports.append(port)
        }
        return Array(Set(ports)).sorted()
    }
}
