import Foundation

/// How the Mac is connected, as one reading gives it: whether it has a way out at all
/// and over what, Wi-Fi's power and network, and the VPN carrying its traffic.
struct NetworkState: Equatable {
    /// Whether macOS has a usable path out (Network's `satisfied`).
    var isOnline: Bool
    /// What that path goes over, beneath any VPN. `nil` while offline.
    var kind: NetworkKind?
    /// Whether Wi-Fi is on; `nil` on a Mac without Wi-Fi.
    var wifiPower: Bool?
    /// Whether Wi-Fi has joined a network, whether or not macOS says which.
    var wifiJoined = false
    /// The Wi-Fi network's name. macOS tells an app only while it has Location access,
    /// so this is `nil` both while Wi-Fi has joined nothing and while it has joined a
    /// network macOS will not name.
    var wifiName: String?
    /// The VPN carrying the Mac's traffic, if one is.
    var vpn: NetworkVPN?
}

extension NetworkState {
    /// Takes on the Wi-Fi network `other` has joined. One that has joined none leaves
    /// the last network's name in place, so coming back to it is not news.
    fileprivate mutating func adoptNetwork(of other: NetworkState) {
        wifiJoined = other.wifiJoined
        if other.wifiJoined { wifiName = other.wifiName }
    }
}

/// What the Mac's connection goes over.
enum NetworkKind: Equatable {
    case wifi
    case wired
    /// A phone's hotspot over USB, Thunderbolt Bridge, anything else.
    case other
}

/// A VPN carrying the Mac's traffic: its route is the one macOS sends everything by.
/// One that only carries a company's own addresses leaves that route alone, and does
/// not count.
struct NetworkVPN: Equatable {
    /// The name System Settings lists it under, where macOS keeps one Islet can read.
    var name: String?
}

/// Something about the connection worth a word beside the notch.
enum NetworkChange: Equatable {
    /// The Mac has had no way out for a few seconds. Which connection it lost, and that
    /// network's name when macOS gave it.
    case offline(kind: NetworkKind?, name: String?)
    /// The Mac has a way out again, after being said to be offline: over what, and the
    /// name.
    case online(kind: NetworkKind?, name: String?)
    /// Wi-Fi joined another network while the Mac stayed online, or with no time to
    /// say it had gone.
    case joined(name: String)
    /// Wi-Fi turned off or on. Turned on while the Mac had no way out for want of it,
    /// it waits a few seconds for Wi-Fi to join a network, so that one word says both,
    /// with the network's name (`network`) when macOS gives it.
    case wifiPower(isOn: Bool, network: String? = nil)
    case vpnConnected(name: String?)
    case vpnDisconnected(name: String?)

    /// Which banner the change takes: a newer change on the same topic updates the one
    /// on screen, or takes the place of one still waiting.
    enum Topic: String {
        case connection, wifiPower, vpn
    }

    var topic: Topic {
        switch self {
        case .offline, .online, .joined: .connection
        case .wifiPower: .wifiPower
        case .vpnConnected, .vpnDisconnected: .vpn
        }
    }

    /// Whether `later` puts things back as they were before this, so that neither is
    /// news to someone who saw neither: offline and back, Wi-Fi off and on again, a VPN
    /// dropping and reconnecting to the same place.
    func isUndone(by later: NetworkChange) -> Bool {
        switch (self, later) {
        case (.offline, .online), (.online, .offline): true
        case let (.wifiPower(a, _), .wifiPower(b, _)): a != b
        case let (.vpnConnected(a), .vpnDisconnected(b)), let (.vpnDisconnected(a), .vpnConnected(b)): a == b || a == nil || b == nil
        default: false
        }
    }
}

/// Weighs readings of the connection against what the person was last told, and says
/// what has changed once it has held long enough to be news. It keeps no clock of its
/// own: it is told the time with each reading, and says when it next wants to look
/// (`nextDeadline`).
///
/// The connection drops and comes back all the time, for a second or two, as Wi-Fi
/// roams or a router renews: offline has to last a few seconds before it is said, and
/// a drop that ends before then is nothing, or, if Wi-Fi came back on another network,
/// only that. A connection at the edge of its range that keeps coming and going has to
/// stay gone longer before it is said again. Online has to hold a moment too, so the
/// network's name, which arrives a little after the connection, can be given with it.
/// "Back online" follows only an "Offline" that was said: the Mac offline since launch,
/// or since Wi-Fi was turned off, says nothing as it comes back, and Wi-Fi turned on
/// again waits for its network, to say both in one word.
///
/// A VPN reconnects by itself after the network changes under it, whether or not that
/// change was said, so it is given time to do so; and it can drop for a few seconds
/// while its app reconnects, so it has to stay gone longer than it has to stay
/// connected before either is said.
///
/// At launch, what the first few seconds find is where things stand, not news. Across
/// sleep, the connection comes and goes as the Mac wakes; what it settles to is
/// weighed against what it was before sleep, so a Mac that wakes where it slept says
/// nothing, and one that wakes somewhere else says where. One that finds no network
/// is given longer still before it is said to be offline, and without the name of the
/// network it had before sleep, which may be miles away.
struct NetworkWatch {
    struct Timing {
        /// How long the Mac must be offline before it is said.
        var offline: TimeInterval = 3
        /// How long it must be offline before it is said, within `flapping` of being
        /// said to be back.
        var offlineAgain: TimeInterval = 15
        var flapping: TimeInterval = 60
        /// How long a connection, or another network, must hold before it is said.
        var online: TimeInterval = 1.5
        /// How long a VPN must stay connected before it is said.
        var vpn: TimeInterval = 4
        /// How long a VPN must stay gone before it is said: longer, as its app may be
        /// reconnecting.
        var vpnGone: TimeInterval = 10
        /// After the network comes back or changes, how long a VPN has to reconnect
        /// before it is said to have gone.
        var vpnReconnect: TimeInterval = 10
        /// After Wi-Fi is turned on, how long it has to join a network before the Mac is
        /// said to be offline, or before "Wi-Fi On" is said without one.
        var wifiJoin: TimeInterval = 10
        /// At launch, how long readings are taken as they come, while the Mac finds
        /// its network at login.
        var launch: TimeInterval = 15
        /// After waking, how long the connection has to settle before it is weighed
        /// against what it was before sleep. Wi-Fi can take ten seconds or so to join,
        /// and a VPN a few more.
        var wake: TimeInterval = 20
        /// After the wake has settled, how much longer the Mac has to find a network
        /// before it is said to be offline. The lid is open, and the menu bar in sight.
        var offlineAfterWake: TimeInterval = 20

        static let standard = Timing()
    }

    let timing: Timing
    /// The connection as the person last heard of it, or found it at launch. `nil`
    /// until the launch readings are in.
    private(set) var told: NetworkState?
    private(set) var latest: NetworkState?
    /// When the watch next wants to look, if something is waiting to be said.
    private(set) var nextDeadline: Date?

    private var settlesUntil = Date.distantPast
    private var isAsleep = false
    private var connectivityChanged = Date.distantPast
    private var networkChanged = Date.distantPast
    private var powerChanged = Date.distantPast
    private var vpnChanged = Date.distantPast
    /// Until when a VPN still has time to reconnect after the network came back.
    private var vpnWaitsUntil = Date.distantPast
    /// Until when Wi-Fi, just turned on, is still joining a network.
    private var wifiJoinsUntil = Date.distantPast
    /// Until when, after a wake, the Mac is not yet said to be offline.
    private var offlineWaitsUntil = Date.distantPast
    /// Whether "Offline" has been said, and "Back online" not yet.
    private var saidOffline = false
    private var saidOnline = Date.distantPast
    /// Whether the Mac has had no connection since it woke: the network it lost is then
    /// the one from before sleep, and not worth naming.
    private var offlineSinceWake = false

    init(timing: Timing = .standard) {
        self.timing = timing
    }

    /// Islet started, or the feature was turned on.
    mutating func start(at now: Date) {
        told = nil
        latest = nil
        isAsleep = false
        saidOffline = false
        offlineSinceWake = false
        settlesUntil = now.addingTimeInterval(timing.launch)
        nextDeadline = settlesUntil
    }

    mutating func receive(_ state: NetworkState, at now: Date) -> [NetworkChange] {
        let previous = latest
        latest = state
        if previous?.isOnline != state.isOnline { connectivityChanged = now }
        if previous?.wifiName != state.wifiName || previous?.wifiJoined != state.wifiJoined {
            networkChanged = now
        }
        if previous?.vpn != state.vpn { vpnChanged = now }
        if previous?.wifiPower != state.wifiPower {
            powerChanged = now
            if state.wifiPower == true { wifiJoinsUntil = now.addingTimeInterval(timing.wifiJoin) }
        }
        if state.isOnline { offlineSinceWake = false }
        // The network under a VPN came back or changed, said or not: the VPN has its
        // time to reconnect.
        if let previous, state.isOnline,
           !previous.isOnline || previous.kind != state.kind
            || previous.wifiJoined != state.wifiJoined || previous.wifiName != state.wifiName {
            vpnWaitsUntil = max(vpnWaitsUntil, now.addingTimeInterval(timing.vpnReconnect))
        }
        return evaluate(at: now)
    }

    /// The Mac is going to sleep. Readings still come in, as Wi-Fi goes down, but none
    /// is weighed until it has woken and settled.
    mutating func sleep() {
        isAsleep = true
        nextDeadline = nil
    }

    /// The Mac woke. A VPN that dropped as it slept gets its chance to reconnect once
    /// the network has settled, as it does when the network comes back, and the Mac
    /// its chance to find a network.
    mutating func wake(at now: Date) -> [NetworkChange] {
        isAsleep = false
        settlesUntil = max(settlesUntil, now.addingTimeInterval(timing.wake))
        vpnWaitsUntil = max(vpnWaitsUntil, settlesUntil.addingTimeInterval(timing.vpnReconnect))
        offlineWaitsUntil = settlesUntil.addingTimeInterval(timing.offlineAfterWake)
        offlineSinceWake = latest?.isOnline != true
        return evaluate(at: now)
    }

    /// Looks again, at or after `nextDeadline`.
    mutating func advance(to now: Date) -> [NetworkChange] {
        evaluate(at: now)
    }

    private mutating func evaluate(at now: Date) -> [NetworkChange] {
        nextDeadline = nil
        guard !isAsleep, let latest else { return [] }
        if now < settlesUntil {
            nextDeadline = settlesUntil
            return []
        }
        guard var told else {
            // The launch readings are in: this is where things stand.
            self.told = latest
            return []
        }
        var changes: [NetworkChange] = []
        var deadlines: [Date] = []
        let onlineDue = max(connectivityChanged, networkChanged).addingTimeInterval(timing.online)

        // Wi-Fi's power is something the person did, or a profile did for them: said
        // at once. Wi-Fi appearing or going altogether (an adaptor) is not news.
        if let power = latest.wifiPower, let was = told.wifiPower, power != was {
            if power, !told.isOnline, !saidOffline {
                // On again, with the Mac offline for want of it: said once Wi-Fi has
                // joined a network, with its name, or once it has had time to.
                let giveUp = powerChanged.addingTimeInterval(timing.wifiJoin)
                let joins = latest.isOnline && latest.kind == .wifi
                if joins, now >= onlineDue {
                    changes.append(.wifiPower(isOn: true, network: latest.wifiName))
                    told.isOnline = true
                    told.kind = latest.kind
                    told.adoptNetwork(of: latest)
                    told.wifiPower = true
                } else if now >= giveUp {
                    changes.append(.wifiPower(isOn: true))
                    told.wifiPower = true
                } else {
                    deadlines.append(joins ? min(onlineDue, giveUp) : giveUp)
                }
            } else {
                changes.append(.wifiPower(isOn: power))
                told.wifiPower = power
            }
        } else {
            told.wifiPower = latest.wifiPower
        }

        switch (told.isOnline, latest.isOnline) {
        case (true, false):
            let hold = connectivityChanged.timeIntervalSince(saidOnline) < timing.flapping
                ? timing.offlineAgain : timing.offline
            var due = max(connectivityChanged.addingTimeInterval(hold), offlineWaitsUntil)
            // Wi-Fi turned on again has its time to rejoin before its network is lost.
            if told.kind == .wifi, latest.wifiPower == true { due = max(due, wifiJoinsUntil) }
            if now >= due {
                // Wi-Fi turned off takes the connection it carried with it; its own
                // banner has said so.
                if !(latest.wifiPower == false && told.kind == .wifi) {
                    let name = told.kind == .wifi && !offlineSinceWake ? told.wifiName : nil
                    changes.append(.offline(kind: told.kind, name: name))
                    saidOffline = true
                }
                told.isOnline = false
            } else {
                deadlines.append(due)
            }
        case (false, true):
            if now >= onlineDue {
                // Offline without a word (since launch, or Wi-Fi's banner said it), the
                // Mac comes back without one.
                if saidOffline {
                    changes.append(.online(kind: latest.kind, name: latest.kind == .wifi ? latest.wifiName : nil))
                    saidOnline = now
                }
                saidOffline = false
                told.isOnline = true
                told.kind = latest.kind
                told.adoptNetwork(of: latest)
            } else {
                deadlines.append(onlineDue)
            }
        case (true, true):
            // Moving between Wi-Fi and a cable says nothing.
            told.kind = latest.kind
            if latest.wifiJoined != told.wifiJoined || (latest.wifiJoined && latest.wifiName != told.wifiName) {
                let due = networkChanged.addingTimeInterval(timing.online)
                if now >= due {
                    // Another network, by name: not the one Wi-Fi last joined, which it may
                    // have left and come back to. A name turning up for the network already
                    // joined (Location allowed since) is not another network either.
                    if latest.wifiJoined, let name = latest.wifiName, name != told.wifiName,
                       !(told.wifiJoined && told.wifiName == nil) {
                        changes.append(.joined(name: name))
                    }
                    told.adoptNetwork(of: latest)
                } else {
                    deadlines.append(due)
                }
            }
        case (false, false):
            break
        }

        // A VPN is only weighed while the Mac is online: offline, it has nothing to
        // carry, and it gets its chance to reconnect once the network is back.
        if told.isOnline, latest.isOnline, latest.vpn != told.vpn {
            let due = latest.vpn == nil
                ? max(vpnChanged.addingTimeInterval(timing.vpnGone), vpnWaitsUntil)
                : vpnChanged.addingTimeInterval(timing.vpn)
            if now >= due {
                switch (told.vpn, latest.vpn) {
                case (nil, let vpn?):
                    changes.append(.vpnConnected(name: vpn.name))
                case (let vpn?, nil):
                    changes.append(.vpnDisconnected(name: vpn.name))
                case (let old?, let new?):
                    // Another VPN, by name; a name turning up for the same one is not.
                    if let name = new.name, old.name != nil, name != old.name {
                        changes.append(.vpnConnected(name: name))
                    }
                case (nil, nil):
                    break
                }
                told.vpn = latest.vpn
            } else {
                deadlines.append(due)
            }
        }

        self.told = told
        nextDeadline = deadlines.min()
        return changes
    }
}
