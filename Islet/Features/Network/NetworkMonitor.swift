import CoreWLAN
import Foundation
import Network
import SystemConfiguration

/// The Mac's own connection, read from three places, each for what only it knows:
///
/// - Network's path monitor, for whether there is a way out at all, and over what.
/// - CoreWLAN, for Wi-Fi's power and the network it has joined. macOS gives the
///   network's name only to an app with Location access, which Islet has once the
///   person has allowed it (Weather asks, when it uses this Mac's own location);
///   nothing here asks for it, and without it the name is simply missing.
/// - The System Configuration dynamic store, for the interface macOS routes everything
///   by. A VPN carrying all the Mac's traffic takes that route, and the service it
///   belongs to in the network settings says it is a VPN, with the name System
///   Settings lists it under. A route by an interface the settings do not list counts
///   when only a tunnel uses that kind (`utun`, `ipsec`, `ppp` and the like). VPN
///   settings are only ever read.
///
/// Each of them reports a change in its own way and at its own moment, so a change
/// reads all three again, a moment later, once the others have caught up, and reports
/// the whole only when it differs from the last. The reading is done off the main
/// thread (`NetworkReader`): each of those answers comes from another process, and the
/// island is animating as the change comes in.
@MainActor
final class NetworkMonitor: NSObject, NetworkSource {
    /// How long to wait after a change for the rest to catch up.
    private static let coalesceDelay: TimeInterval = 0.3

    private var report: (@MainActor (NetworkState) -> Void)?
    private var pathMonitor: NWPathMonitor?
    private var path: NWPath?
    private var wifi: CWWiFiClient?
    private var store: SCDynamicStore?
    private var reader: NetworkReader?
    private var pendingRead: DispatchWorkItem?
    private var last: NetworkState?
    /// Counts starts and stops, so a reading under way as the monitor stops is not
    /// reported.
    private var generation = 0

    func start(_ report: @escaping @MainActor (NetworkState) -> Void) {
        stop()
        self.report = report
        reader = NetworkReader()

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.report != nil else { return }
                    self.path = path
                    self.readSoon()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.ayush.Islet.network.path", qos: .utility))
        pathMonitor = monitor

        // A client of its own for Wi-Fi's events, so no other part of Islet's delegate
        // is displaced. The reader has another, for its readings.
        let client = CWWiFiClient()
        client.delegate = self
        for event: CWEventType in [.powerDidChange, .ssidDidChange, .linkDidChange] {
            try? client.startMonitoringEvent(with: event)
        }
        wifi = client

        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.readSoon() }
        }
        if let store = SCDynamicStoreCreate(nil, "com.ayush.Islet.network" as CFString, callback, &context) {
            SCDynamicStoreSetNotificationKeys(store, NetworkReader.globalKeys as CFArray, nil)
            // The main queue, so the callback runs where the monitor lives. It is taken
            // off again in `stop()`, before the monitor can go.
            SCDynamicStoreSetDispatchQueue(store, .main)
            self.store = store
        }
    }

    func stop() {
        generation += 1
        report = nil
        reader?.stop()
        reader = nil
        pendingRead?.cancel()
        pendingRead = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        path = nil
        if let wifi {
            try? wifi.stopMonitoringAllEvents()
            wifi.delegate = nil
        }
        wifi = nil
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
        last = nil
    }

    fileprivate func readSoon() {
        guard report != nil else { return }
        pendingRead?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.read() }
        }
        pendingRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceDelay, execute: work)
    }

    /// Reads everything and reports it if it changed. Nothing until the path monitor
    /// has given its first answer, since without it there is no telling whether the Mac
    /// is online.
    private func read() {
        pendingRead = nil
        guard report != nil, let path, let reader else { return }
        let generation = self.generation
        reader.read(path) { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, let report = self.report, state != self.last else { return }
                    self.last = state
                    report(state)
                }
            }
        }
    }
}

/// Reads the connection on a queue of its own: CoreWLAN and the network settings each
/// answer by asking another process, a few milliseconds a time. It has a Wi-Fi client
/// and a dynamic store of its own, for reading only, and touches them only on that
/// queue.
private final class NetworkReader: @unchecked Sendable {
    static let globalKeys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"]
    /// Interfaces that only a tunnel uses, for a route by an interface the network
    /// settings do not list. PPPoE broadband uses `ppp` too, but always as a service
    /// the settings list, which says what it runs over.
    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "gpd"]

    private let queue = DispatchQueue(label: "com.ayush.Islet.network.read", qos: .utility)
    private var wifi: CWWiFiClient?
    private var store: SCDynamicStore?
    private var isStopped = false

    func stop() {
        queue.async { [self] in
            isStopped = true
            wifi = nil
            store = nil
        }
    }

    /// Reads the connection, with `path` for whether there is a way out and over what,
    /// and hands it to `deliver` on the reader's queue.
    func read(_ path: NWPath, then deliver: @escaping @Sendable (NetworkState) -> Void) {
        queue.async { [self] in
            guard !isStopped else { return }
            if wifi == nil { wifi = CWWiFiClient() }
            if store == nil { store = SCDynamicStoreCreate(nil, "com.ayush.Islet.network.read" as CFString, nil, nil) }
            deliver(state(path))
        }
    }

    private func state(_ path: NWPath) -> NetworkState {
        let isOnline = path.status == .satisfied
        let interface = wifi?.interface()
        let power = interface?.powerOn()
        // Joined, as far as the radio says: a channel, with a signal on it. Neither
        // needs Location access.
        let joined = power == true && interface?.wlanChannel() != nil && (interface?.rssiValue() ?? 0) != 0
        let name = joined ? interface?.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return NetworkState(
            isOnline: isOnline,
            kind: isOnline ? Self.kind(of: path) : nil,
            wifiPower: power,
            wifiJoined: joined,
            wifiName: name?.isEmpty == false ? name : nil,
            vpn: isOnline ? readVPN() : nil
        )
    }

    /// The first interface the path would use that is not a tunnel: what a VPN, if any,
    /// runs over.
    private static func kind(of path: NWPath) -> NetworkKind {
        let physical = path.availableInterfaces.first { $0.type != .other && $0.type != .loopback }
        switch physical?.type {
        case .wifi: return .wifi
        case .wiredEthernet: return .wired
        default: return .other
        }
    }

    // MARK: VPN

    /// The VPN macOS routes everything by, if it routes everything by one: the primary
    /// interface for IPv4 or IPv6 belongs to a VPN service, or, where the network
    /// settings list no service for it, is a tunnel.
    private func readVPN() -> NetworkVPN? {
        guard let store else { return nil }
        // The network settings, read afresh (a VPN may have been added since), and only
        // read.
        let prefs = SCPreferencesCreate(nil, "com.ayush.Islet.network" as CFString, nil)
        for key in Self.globalKeys {
            guard let global = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interface = global[kSCDynamicStorePropNetPrimaryInterface as String] as? String
            else { continue }
            let serviceID = global[kSCDynamicStorePropNetPrimaryService as String] as? String
            let service = serviceID.flatMap { id in prefs.flatMap { SCNetworkServiceCopy($0, id as CFString) } }
            let isVPN = service.map(Self.isVPN) ?? Self.tunnelPrefixes.contains { interface.hasPrefix($0) }
            guard isVPN else { continue }
            return NetworkVPN(name: service.flatMap { SCNetworkServiceGetName($0) as String? } ?? serviceID.flatMap(name(ofService:)))
        }
        return nil
    }

    /// Whether a service is a VPN: IPSec, IKEv2 and the VPN apps' own ("VPN"), and PPP
    /// over L2TP rather than over Ethernet.
    private static func isVPN(_ service: SCNetworkService) -> Bool {
        guard let interface = SCNetworkServiceGetInterface(service),
              let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { return false }
        if type == kSCNetworkInterfaceTypePPP as String {
            let carrier = SCNetworkInterfaceGetInterface(interface).flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
            return carrier == kSCNetworkInterfaceTypeL2TP as String
        }
        return type == kSCNetworkInterfaceTypeIPSec as String || type == "VPN"
    }

    /// A name the dynamic store keeps for a service the network settings do not list.
    private func name(ofService id: String) -> String? {
        guard let store,
              let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(id)" as CFString) as? [String: Any]
        else { return nil }
        return setup[kSCPropUserDefinedName as String] as? String
    }
}

extension NetworkMonitor: CWEventDelegate {
    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) { changed() }

    /// CoreWLAN calls from a queue of its own.
    private nonisolated func changed() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.readSoon() }
        }
    }
}
