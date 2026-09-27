import SwiftUI

/// The Mac's connection changing, in a word beside the notch: going offline and coming
/// back ("Back online", with the network's name), Wi-Fi joining another network,
/// Wi-Fi turning off or on, and a VPN connecting or disconnecting. Over music or a
/// timer, the word rides in a row under it. At rest there is nothing: the menu bar
/// already shows the connection, and a mark beside the notch for as long as the Mac is
/// offline (a whole flight) would sit among the camera and microphone dots, which have
/// to be noticed, for hours on end.
///
/// Every banner is passive: good to know, never needed now, so a Focus that asks for
/// quiet drops them. What waits for another feature's banner to go waits a few seconds
/// at most, and a change undone while it waited (offline and back) is dropped with it,
/// as is one that undoes a change the person never saw, for a few minutes after it.
@MainActor
final class NetworkFeature: Feature {
    let id = "network"
    let title = "Wi-Fi & VPN"
    let symbol = "wifi"
    let summary = "A word beside the notch when the Mac goes offline or comes back, joins another Wi-Fi network, or a VPN connects."

    static let bannerPrefix = "network."
    /// Long enough to read a name.
    static let bannerDuration: TimeInterval = 3
    /// A change that has waited this long for the island is old news.
    static let staleAfter: TimeInterval = 12
    /// How long a change that went unsaid is remembered, for one undoing it to go
    /// unsaid too. Wi-Fi turned off during a Focus and on again that evening is news
    /// by then.
    nonisolated static let unseenLifetime: TimeInterval = 300
    private static let queueCheckInterval: TimeInterval = 0.5

    let model: NetworkModel
    private let presenter: any BannerPresenter
    private var isRunning = false
    /// Changes waiting for the island, at most one for each topic, oldest first.
    private var queue: [(change: NetworkChange, since: Date)] = []
    private var queueRunner: Task<Void, Never>?
    /// The last change on each topic that went unsaid (Settings, a Focus, a wait too
    /// long), and when, until one is said after it or the topic's setting changes.
    private var unseen: [NetworkChange.Topic: (change: NetworkChange, at: Date)] = [:]
    private let unseenLifetime: TimeInterval
    private var settings: [String: Bool] = [:]
    private var defaultsObserver: NSObjectProtocol?

    /// `source` stands in for the Mac's network, `timing` and `unseenLifetime` for the
    /// waits, and `presenter` for the island, in tests.
    init(
        source: (any NetworkSource)? = nil,
        timing: NetworkWatch.Timing = .standard,
        unseenLifetime: TimeInterval = NetworkFeature.unseenLifetime,
        presenter: (any BannerPresenter)? = nil
    ) {
        model = NetworkModel(source: source, timing: timing)
        self.unseenLifetime = unseenLifetime
        self.presenter = presenter ?? ActivityCenter.shared
        model.onChanges = { [weak self] in self?.handle($0) }
    }

    func start() {
        isRunning = true
        settings = NetworkPrefs.values()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        model.start()
    }

    func stop() {
        isRunning = false
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = nil
        model.stop()
        queue = []
        unseen = [:]
        queueRunner?.cancel()
        queueRunner = nil
        if let id = presenter.bannerID, id.hasPrefix(Self.bannerPrefix) {
            presenter.dismissBanner(id: id)
        }
    }

    func settingsView() -> AnyView? {
        AnyView(NetworkSettings())
    }

    /// Made-up networks, never the person's. The connection is left alone.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "Offline") {
                Self.preview(.offline(kind: .wifi, name: NetworkSamples.cafe))
            },
            FeaturePreview(title: "Back online") {
                Self.preview(.online(kind: .wifi, name: NetworkSamples.cafe))
            },
            FeaturePreview(title: "Joined another network") {
                Self.preview(.joined(name: NetworkSamples.studio))
            },
            FeaturePreview(title: "Wi-Fi off") { Self.preview(.wifiPower(isOn: false)) },
            FeaturePreview(title: "VPN connected") {
                Self.preview(.vpnConnected(name: NetworkSamples.vpn))
            },
        ]
    }

    // MARK: Changes

    /// Each change goes to the queue, unless Settings or a Focus asks for quiet, or it
    /// undoes one the person never saw: a Mac that went offline during a Focus says
    /// nothing as it comes back after it, since "Back online" would be news of something
    /// they never heard.
    private func handle(_ changes: [NetworkChange]) {
        guard isRunning else { return }
        let now = Date()
        for change in changes {
            if let missed = unseen[change.topic], now.timeIntervalSince(missed.at) < unseenLifetime,
               missed.change.isUndone(by: change) {
                unseen[change.topic] = nil
                continue
            }
            // Quiet now is quiet for good: shown once the Focus ends, it would be old.
            guard NetworkPrefs.shows(change), !presenter.silencesPassiveBanners else {
                unseen[change.topic] = (change, now)
                continue
            }
            unseen[change.topic] = nil
            enqueue(change)
        }
        showNext()
    }

    /// A kind of change turned on or off in Settings: what went unsaid on its topic is
    /// forgotten, so that the next change there is said for what it is. A VPN turned on
    /// while its banners were off is not a reason to keep quiet as it disconnects.
    private func settingsChanged() {
        let now = NetworkPrefs.values()
        for (key, value) in now where settings[key] != value {
            if let topic = NetworkPrefs.topics[key] { unseen[topic] = nil }
        }
        settings = now
    }

    /// Adds `change` to those waiting. One already waiting on the same topic gives way
    /// to it, or, if `change` undoes it, goes with it, and neither is said.
    private func enqueue(_ change: NetworkChange) {
        let now = Date()
        if let index = queue.firstIndex(where: { $0.change.topic == change.topic }) {
            if queue[index].change.isUndone(by: change) {
                queue.remove(at: index)
            } else {
                queue[index] = (change, now)
            }
        } else {
            queue.append((change, now))
        }
    }

    /// Shows the next change, if the island is free for it: nothing up, or this
    /// feature's banner on the same topic, which it updates in place ("Offline" becoming
    /// "Back online"). Another feature's banner, or this feature's on another topic, is
    /// left to finish first.
    private func showNext() {
        dropStale()
        guard !queue.isEmpty else { return }
        let index: Int?
        if let current = presenter.bannerID {
            index = queue.firstIndex { Self.bannerID($0.change.topic) == current }
        } else {
            index = queue.startIndex
        }
        if let index {
            let change = queue.remove(at: index).change
            if presenter.silencesPassiveBanners {
                unseen[change.topic] = (change, Date())
            } else {
                presenter.present(Self.banner(for: change))
            }
        }
        runQueue()
    }

    /// Changes that waited too long for the island are old news, and go unsaid.
    private func dropStale() {
        let now = Date()
        for item in queue where now.timeIntervalSince(item.since) > Self.staleAfter {
            unseen[item.change.topic] = (item.change, now)
        }
        queue.removeAll { now.timeIntervalSince($0.since) > Self.staleAfter }
    }

    /// Looks twice a second, while anything waits, for the island to be free. With
    /// nothing waiting it stops.
    private func runQueue() {
        guard queueRunner == nil, !queue.isEmpty else { return }
        queueRunner = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.queueCheckInterval))
                guard !Task.isCancelled, let self else { return }
                if self.presenter.bannerID == nil { self.showNext() }
                self.dropStale()
                if self.queue.isEmpty {
                    self.queueRunner = nil
                    return
                }
            }
        }
    }

    // MARK: Presentation

    static func bannerID(_ topic: NetworkChange.Topic) -> String { bannerPrefix + topic.rawValue }

    /// The change as a compact banner, the symbol and name left of the camera, what
    /// happened right of it. No tap on the trackpad: nothing the person did asked for it.
    static func banner(for change: NetworkChange, interruption: BannerInterruption = .passive) -> IslandBanner {
        let announcement = NetworkAnnouncement(change)
        let widths = NetworkBannerLayout.widths(for: announcement)
        return IslandBanner(
            id: bannerID(change.topic),
            style: .compact(leading: widths.leading, trailing: widths.trailing),
            duration: bannerDuration,
            haptic: false,
            interruption: interruption,
            personal: personal(change),
            leading: AnyView(NetworkBannerLeading(announcement: announcement)),
            trailing: AnyView(NetworkBannerTrailing(announcement: announcement))
        )
    }

    /// A banner naming the network or VPN is held back with device names while
    /// presenting (`PersonalContent.devices`): a Wi-Fi network, a phone's hotspot or a
    /// VPN is as often named after its owner, their home or their work. One saying only
    /// "Wi-Fi" or "Ethernet" names nothing of theirs, and always shows.
    static func personal(_ change: NetworkChange) -> PersonalContent? {
        let name: String? = switch change {
        case let .offline(_, name), let .online(_, name): name
        case let .joined(name): name
        case let .wifiPower(_, network): network
        case let .vpnConnected(name), let .vpnDisconnected(name): name
        }
        return name == nil ? nil : .devices
    }

    /// A preview is there to be looked at, so it shows whatever a Focus says.
    private static func preview(_ change: NetworkChange) {
        ActivityCenter.shared.present(banner(for: change, interruption: .active))
    }
}

/// The feature's preference keys, shared by the feature and its settings. Unset keys
/// read as their defaults, the same ones the settings toggles declare.
enum NetworkPrefs {
    static let showsConnection = "network.showsConnection"
    static let showsJoined = "network.showsJoined"
    static let showsWiFiPower = "network.showsWiFiPower"
    static let showsVPN = "network.showsVPN"

    /// Which topic each key's changes take.
    static let topics: [String: NetworkChange.Topic] = [
        showsConnection: .connection, showsJoined: .connection, showsWiFiPower: .wifiPower, showsVPN: .vpn,
    ]

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    /// Every key's value, to tell which one changed.
    static func values() -> [String: Bool] {
        topics.keys.reduce(into: [:]) { $0[$1] = bool($1, default: true) }
    }

    /// Whether Settings wants a word about `change`.
    static func shows(_ change: NetworkChange) -> Bool {
        switch change {
        case .offline, .online: bool(showsConnection, default: true)
        case .joined: bool(showsJoined, default: true)
        case .wifiPower: bool(showsWiFiPower, default: true)
        case .vpnConnected, .vpnDisconnected: bool(showsVPN, default: true)
        }
    }
}
