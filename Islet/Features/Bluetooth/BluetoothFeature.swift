import SwiftUI

/// AirPods and other Bluetooth headphones connecting, with their battery, the way the
/// iPhone shows them.
///
/// Connections are read from CoreAudio, where every headset is an audio device, so
/// they need no Bluetooth permission. Battery levels come from system_profiler, or —
/// exact, and the only way for AirPods Max — from IOBluetooth once Bluetooth access has
/// been given from Settings or the home tile.
@MainActor
final class BluetoothFeature: Feature {
    let id = "bluetooth"
    let title = "Headphones"
    let symbol = "airpodspro"
    let summary = "Shows AirPods and other headphones connecting, with their battery."

    private static let bannerPrefix = "bluetooth."
    private static let cardDuration: TimeInterval = 4

    private let model = HeadphonesModel()
    private var isRunning = false
    /// Holds a sample headset for the home tile while a preview runs.
    private var previewModel: HeadphonesModel?
    private var previewEnd: Task<Void, Never>?
    /// The model the home tile shows, so the tile is only replaced when that changes.
    private var tileModel: HeadphonesModel?
    /// When the connection card on screen is due to go, so a late battery update can keep
    /// its remaining time.
    private var cardEnds = Date.distantPast

    @AppStorage("bluetooth.showConnect") private var showConnect = true
    @AppStorage("bluetooth.showDisconnect") private var showDisconnect = false

    init() {
        model.onConnect = { [weak self] in self?.connected($0) }
        model.onDisconnect = { [weak self] in self?.disconnected($0) }
        model.onUpdate = { [weak self] in self?.updated($0) }
        model.onChange = { [weak self] in self?.syncTile() }
    }

    func start() {
        isRunning = true
        model.start()
        syncTile()
    }

    func stop() {
        isRunning = false
        model.stop()
        previewEnd?.cancel()
        previewEnd = nil
        previewModel = nil
        syncTile()
        let center = ActivityCenter.shared
        if let id = center.banner?.id, id.hasPrefix(Self.bannerPrefix) {
            center.dismissBanner(id: id)
        }
    }

    func settingsView() -> AnyView? {
        AnyView(HeadphonesSettings())
    }

    /// The two connection previews also put the sample on the home page for ten seconds.
    var previews: [FeaturePreview] {
        [
            FeaturePreview(title: "AirPods Pro connected") { [weak self] in
                self?.previewConnection(of: .sampleAirPodsPro)
            },
            FeaturePreview(title: "AirPods Max connected") { [weak self] in
                self?.previewConnection(of: .sampleAirPodsMax)
            },
            FeaturePreview(title: "Headphones disconnected") { [weak self] in
                self?.presentDisconnection(of: .sampleAirPodsPro)
            },
        ]
    }

    /// `islet://bluetooth/show` shows the connected headset's card with fresh levels.
    func handle(_ url: URL) -> Bool {
        guard url.path() == "/show" else { return false }
        if let headset = model.current {
            presentCard(for: headset, duration: Self.cardDuration)
            model.refreshLevels(olderThan: 0)
        }
        return true
    }

    // MARK: Events

    private func connected(_ headset: Headset) {
        guard showConnect else { return }
        presentCard(for: headset, duration: Self.cardDuration)
    }

    /// Levels usually arrive after the card is up. They replace it in place, and it stays
    /// long enough for them to be read.
    private func updated(_ headset: Headset) {
        guard ActivityCenter.shared.banner?.id == Self.cardID(headset.id) else { return }
        presentCard(for: headset, duration: max(cardEnds.timeIntervalSinceNow, 2.5))
    }

    private func disconnected(_ headset: Headset) {
        if showDisconnect {
            presentDisconnection(of: headset)
        } else {
            ActivityCenter.shared.dismissBanner(id: Self.cardID(headset.id))
        }
    }

    // MARK: Presentation

    private static func cardID(_ headsetID: String) -> String { "\(bannerPrefix)connected.\(headsetID)" }

    private func presentCard(for headset: Headset, duration: TimeInterval) {
        cardEnds = Date().addingTimeInterval(duration)
        ActivityCenter.shared.present(IslandBanner(
            id: Self.cardID(headset.id),
            style: .card(width: 360, height: 60),
            duration: duration,
            content: AnyView(HeadsetConnectedCard(headset: headset))
        ))
    }

    private func presentDisconnection(of headset: Headset) {
        ActivityCenter.shared.present(IslandBanner(
            id: "\(Self.bannerPrefix)disconnected.\(headset.id)",
            style: .compact(leading: 44, trailing: 104),
            leading: AnyView(HeadsetDisconnectedLeading(symbol: headset.symbol)),
            trailing: AnyView(HeadsetDisconnectedTrailing())
        ))
    }

    private func syncTile() {
        let source = previewModel ?? (isRunning && !model.headsets.isEmpty ? model : nil)
        guard source !== tileModel else { return }
        tileModel = source
        if let source {
            ActivityCenter.shared.setHomeWidget(
                HomeWidget(id: "bluetooth", order: 50, weight: 1, view: AnyView(HeadsetHomeTile(model: source)))
            )
        } else {
            ActivityCenter.shared.removeHomeWidget(id: "bluetooth")
        }
    }

    private func previewConnection(of headset: Headset) {
        presentCard(for: headset, duration: Self.cardDuration)
        previewModel = HeadphonesModel(sample: headset)
        syncTile()
        previewEnd?.cancel()
        previewEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            self.previewEnd = nil
            self.previewModel = nil
            self.syncTile()
        }
    }
}

private struct HeadphonesSettings: View {
    @AppStorage("bluetooth.showConnect") private var showConnect = true
    @AppStorage("bluetooth.showDisconnect") private var showDisconnect = false
    private let levels = BluetoothLevels.shared
    private let profile = HeadphoneNotificationsProfile.shared
    @State private var profileError: String?

    var body: some View {
        Toggle("Show when headphones connect", isOn: $showConnect)
        Toggle("Show when they disconnect", isOn: $showDisconnect)

        LabeledContent {
            switch levels.authorization {
            case .allowedAlways:
                Text("On").foregroundStyle(.secondary)
            case .notDetermined:
                Button("Allow Bluetooth…") { levels.requestAccess() }
            default:
                Button("Open Privacy Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } label: {
            Text("Exact battery levels")
            Text("AirPods Max only report their battery over Bluetooth, which needs your permission.")
        }

        LabeledContent {
            if profile.isInstalled == true {
                Button("Remove…") { HeadphoneNotificationsProfile.openProfilesSettings() }
            } else {
                Button("Hide It…") {
                    do {
                        try profile.install()
                        profileError = nil
                    } catch {
                        profileError = error.localizedDescription
                    }
                }
            }
        } label: {
            Text("macOS's own “Connected” notification")
            Text(profile.isInstalled == true
                 ? "Hidden by the “Islet: Hide Headphone Notifications” profile. Remove the profile to bring it back."
                 : "macOS offers no switch for it. Islet can add a profile that turns it off; you approve it in System Settings → General → Device Management.")
            if let profileError {
                Text(profileError).foregroundStyle(.red)
            }
        }
        .onAppear { profile.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            profile.refresh()
        }
    }
}
