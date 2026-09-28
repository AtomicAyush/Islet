import AppKit
import SwiftUI

extension SystemHue {
    /// Wi-Fi on, a network joined, a VPN connected: Control Center's blue. It says the
    /// connection is up, so it never takes the accent.
    static let connected = SystemHue.blue
}

/// The banners' colours: what they mean, fitted to the island, and grey for what is off.
enum NetworkPalette {
    static let on = SystemHue.connected
    static let backOnline = SystemHue.success
    static let offline = SystemHue.warning
    /// Wi-Fi off, a VPN gone: its name and the word, and its symbol.
    static let off = IslandInk.text(0.5)
    static let offSymbol = IslandInk.graphic(0.5)

    /// Words in a hue that means something.
    static func words(_ hue: SystemHue) -> IslandInk { .hue(hue, minimum: Contrast.text) }
}

// MARK: - Banner

/// What a banner says: a symbol and a name left of the notch, what happened right of
/// it, as the Focus and headphones banners do. The name is the network's or the VPN's
/// where macOS gives it, and otherwise what it is: "Wi-Fi", "Ethernet", "VPN".
struct NetworkAnnouncement: Equatable {
    var symbol: String
    var symbolColor: IslandInk
    var name: String
    var nameColor: IslandInk
    var status: String
    var statusColor: IslandInk
    /// Whether the name is what happened, as for a network joined, rather than who it
    /// happened to.
    var nameIsNews = false

    init(_ change: NetworkChange) {
        switch change {
        case let .offline(kind, name):
            self.init(
                symbol: kind == .wifi ? "wifi.exclamationmark" : "network.slash", symbolColor: .hue(NetworkPalette.offline),
                name: name ?? Self.word(for: kind), status: "Offline", statusColor: NetworkPalette.words(NetworkPalette.offline)
            )
        case let .online(kind, name):
            self.init(
                symbol: Self.symbol(for: kind), name: name ?? Self.word(for: kind),
                status: "Back online", statusColor: NetworkPalette.words(NetworkPalette.backOnline)
            )
        case let .joined(name), let .wifiPower(true, name?):
            // Wi-Fi turned on and joining a network says which, as joining another does.
            self.init(symbol: "wifi", name: name, status: "Joined", statusColor: NetworkPalette.words(NetworkPalette.on))
            nameIsNews = true
        case let .wifiPower(isOn, _):
            self.init(
                symbol: isOn ? "wifi" : "wifi.slash", symbolColor: isOn ? .graphic(1) : NetworkPalette.offSymbol,
                name: "Wi-Fi", nameColor: isOn ? .text(1) : NetworkPalette.off,
                status: isOn ? "On" : "Off", statusColor: isOn ? NetworkPalette.words(NetworkPalette.on) : NetworkPalette.off
            )
        case let .vpnConnected(name):
            self.init(
                symbol: Self.vpnSymbol, name: name ?? "VPN",
                status: Self.vpnStatus("Connected", name: name), statusColor: NetworkPalette.words(NetworkPalette.on)
            )
        case let .vpnDisconnected(name):
            self.init(
                symbol: Self.vpnSymbol, symbolColor: NetworkPalette.offSymbol, name: name ?? "VPN", nameColor: NetworkPalette.off,
                status: Self.vpnStatus("Disconnected", name: name), statusColor: NetworkPalette.off
            )
        }
    }

    private init(
        symbol: String, symbolColor: IslandInk = .graphic(1), name: String, nameColor: IslandInk = .text(1),
        status: String, statusColor: IslandInk
    ) {
        self.symbol = symbol
        self.symbolColor = symbolColor
        self.name = name
        self.nameColor = nameColor
        self.status = status
        self.statusColor = statusColor
    }

    private static let vpnSymbol = "network.badge.shield.half.filled"

    /// Wi-Fi's arcs, or for anything else the globe: SF Symbols has no Ethernet port.
    private static func symbol(for kind: NetworkKind?) -> String {
        kind == .wifi ? "wifi" : "network"
    }

    private static func word(for kind: NetworkKind?) -> String {
        switch kind {
        case .wifi: "Wi-Fi"
        case .wired: "Ethernet"
        case .other, nil: "Network"
        }
    }

    /// "Acme Corp · VPN connected", but "VPN · Connected", and "Acme VPN · Connected"
    /// rather than say VPN twice.
    private static func vpnStatus(_ word: String, name: String?) -> String {
        guard let name, name.range(of: "VPN", options: .caseInsensitive) == nil else { return word }
        return "VPN \(word.lowercased())"
    }
}

/// Left of the notch: the symbol and the name. Where there is no room for the name,
/// or even the insets (the opened island's header gives it 24 points), the symbol.
struct NetworkBannerLeading: View {
    let announcement: NetworkAnnouncement

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NetworkBannerLayout.symbolSpacing) {
                symbol
                Text(announcement.name)
                    .font(Font(NetworkBannerLayout.font))
                    .foregroundStyle(.island(announcement.nameColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: NetworkBannerLayout.maximumNameWidth, alignment: .leading)
            }
            .padding(.leading, NetworkBannerLayout.outerInset)
            .padding(.trailing, NetworkBannerLayout.innerInset)
            symbol
                .padding(.leading, NetworkBannerLayout.outerInset)
                .padding(.trailing, NetworkBannerLayout.innerInset)
            symbol
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: some View {
        Image(systemName: announcement.symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .fontWeight(.semibold)
            .foregroundStyle(.island(announcement.symbolColor))
            .frame(width: NetworkBannerLayout.symbolSize.width, height: NetworkBannerLayout.symbolSize.height)
            .accessibilityHidden(true)
    }
}

/// Right of the notch: what happened, against the wing's outer edge. Only as wide as
/// its content: the opened island's header sets it beside the leading symbol, where a
/// view that filled its width would push the two apart.
///
/// The header leaves the left side room for the symbol alone, and a Wi-Fi symbol says
/// nothing of which network, so there the name comes over to this side, before what
/// happened, where both fit: "Home · Joined". Where they do not (the header's side
/// has room for about a hundred points of words), a network joined keeps its name,
/// cut short if it must be, in the colour "Joined" would have, since which network is
/// the news; anything else keeps what happened.
struct NetworkBannerTrailing: View {
    let announcement: NetworkAnnouncement
    @Environment(\.isInIslandHeader) private var isInHeader

    var body: some View {
        Group {
            if isInHeader {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NetworkBannerLayout.headerSeparatorSpacing) {
                        // Whole: a name long enough to be cut short leaves no room
                        // for what happened beside it anyway.
                        Text(verbatim: announcement.name)
                            .foregroundStyle(.island(announcement.nameColor))
                        Text(verbatim: "·")
                            .foregroundStyle(.islandDecorative(0.4))
                        status
                    }
                    .fixedSize()
                    .modifier(Insets())
                    if announcement.nameIsNews {
                        Text(verbatim: announcement.name)
                            .foregroundStyle(.island(announcement.statusColor))
                            .truncationMode(.tail)
                            .modifier(Insets())
                    } else {
                        status
                            .fixedSize()
                            .modifier(Insets())
                    }
                }
            } else {
                status
                    .fixedSize()
                    .modifier(Insets())
            }
        }
        .font(Font(NetworkBannerLayout.font))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(announcement.name), \(announcement.status)")
    }

    private var status: some View {
        Text(verbatim: announcement.status)
            .foregroundStyle(.island(announcement.statusColor))
    }

    private struct Insets: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(.leading, NetworkBannerLayout.innerInset)
                .padding(.trailing, NetworkBannerLayout.outerInset)
        }
    }
}

/// The banner's measurements, matching the Focus banner's: 13-point semibold words, a
/// symbol the same size, the same insets. Each side asks only for its own width and
/// sits against the island's outer edge; the island makes both wings as wide as the
/// wider, so it stays centred on the notch.
enum NetworkBannerLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let symbolSize = CGSize(width: 22, height: 17)
    static let symbolSpacing: CGFloat = 7
    /// Room for most networks' names whole, as for a Focus's; a longer one (a name can
    /// run to 32 characters) truncates rather than push the island over half the menu
    /// bar.
    static let maximumNameWidth: CGFloat = 136
    /// Room between each wing's content and the island's outer edge, and the notch.
    static let outerInset: CGFloat = 12
    static let innerInset: CGFloat = 10
    /// Either side of the dot between the name and what happened, in the opened
    /// island's header.
    static let headerSeparatorSpacing: CGFloat = 5

    static func widths(for announcement: NetworkAnnouncement) -> (leading: CGFloat, trailing: CGFloat) {
        (
            outerInset + symbolSize.width + symbolSpacing
                + min(textWidth(announcement.name), maximumNameWidth) + innerInset,
            innerInset + textWidth(announcement.status) + outerInset
        )
    }

    /// Two points of slack: SwiftUI sets text a hair wider than AppKit measures it,
    /// which would otherwise truncate a name that just fits.
    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}

// MARK: - Settings

/// Under the feature's toggle: which changes get a word.
struct NetworkSettings: View {
    @AppStorage(NetworkPrefs.showsConnection) private var showsConnection = true
    @AppStorage(NetworkPrefs.showsJoined) private var showsJoined = true
    @AppStorage(NetworkPrefs.showsWiFiPower) private var showsWiFiPower = true
    @AppStorage(NetworkPrefs.showsVPN) private var showsVPN = true

    var body: some View {
        Toggle(isOn: $showsConnection) {
            Text("Going offline and coming back")
            Text("Once the Mac has had no connection for three seconds, so a moment’s drop says nothing, and for longer when it keeps dropping.")
        }
        Toggle(isOn: $showsJoined) {
            Text("Joining another Wi-Fi network")
            Text("By name. macOS names Wi-Fi networks only to apps with Location access, which Islet has once you have allowed it, as Weather asks when it uses this Mac’s own location; without it, this says nothing, and the other banners say “Wi-Fi”.")
        }
        Toggle(isOn: $showsWiFiPower) {
            Text("Wi-Fi turning on or off")
            Text("Turned on, it waits for Wi-Fi to join a network, and names the network where macOS allows.")
        }
        Toggle(isOn: $showsVPN) {
            Text("A VPN connecting or disconnecting")
            Text("One that carries all of the Mac’s traffic, with the name System Settings lists it under where Islet can read it.")
        }
    }
}
