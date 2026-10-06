import SwiftUI

struct SettingsView: View {
    /// Remembered, and settable from `islet://settings?tab=activities`.
    @AppStorage(SettingsView.tabKey) private var tab = "general"
    static let tabKey = "settingsTab"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            FeatureSettings()
                .tabItem { Label("Activities", systemImage: "capsule.fill") }
                .tag("activities")
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 620, height: 560)
    }
}

/// The island's colours, for anything in the Settings window drawn as the island draws
/// it (the feature badges, the preview), in the tabs and the search results alike; the
/// window itself keeps following macOS.
struct SettingsIslandTheme: ViewModifier {
    @AppStorage(Prefs.Key.islandColour) private var islandColour = IslandTheme.standardIslandPref
    @AppStorage(Prefs.Key.accentColour) private var accentColour = IslandTheme.standardAccentPref
    @AppStorage(Prefs.Key.islandFill) private var islandFill = IslandFill.standardPref

    func body(content: Content) -> some View {
        content.environment(
            \.islandTheme, IslandTheme.cached(islandPref: islandColour, accentPref: accentColour, fillPref: islandFill)
        )
    }
}

/// A symbol on a rounded square of the island's colour, as Settings lists the features
/// and the home tiles: the island in small, as it will draw them.
struct IslandSymbolBadge: View {
    let symbol: String
    let size: CGFloat
    let cornerRadius: CGFloat
    let pointSize: CGFloat
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: pointSize, weight: .semibold))
            .foregroundStyle(.islandPrimary)
            .frame(width: size, height: size)
            .background(shape.fill(theme.background))
            // A light island's colour would vanish into a light window.
            .overlay(shape.strokeBorder(Color.primary.opacity(theme.isLight ? 0.15 : 0), lineWidth: 0.5))
            .environment(\.colorScheme, theme.colorScheme)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    var body: some View {
        Form {
            Section {
                GeneralRow.openAtLogin
                GeneralRow.menuBarIcon
                GeneralRow.quit
            }

            AppearanceSection()

            IslandOrderSection(arrangement: ActivityCenter.shared.islandArrangement)

            Section("Island") {
                GeneralRow.hover
                GeneralRow.haptics
                GeneralRow.homeLayout
                GeneralRow.bubblePlacement
                GeneralRow.saveEnergy
            }

            HomeTilesSection(arrangement: ActivityCenter.shared.homeArrangement)

            Section("Displays") {
                GeneralRow.displays
                GeneralRow.idlePill
                GeneralRow.fullScreen
            }
        }
        .formStyle(.grouped)
        .settingsSearchScrolling(tab: "general")
    }
}

// MARK: - Activities

private struct FeatureSettings: View {
    var body: some View {
        Form {
            ForEach(FeatureRegistry.shared.features, id: \.id) { feature in
                FeatureSection(feature: feature)
            }
        }
        .formStyle(.grouped)
        .settingsSearchScrolling(tab: "activities")
    }
}

/// A feature's switch and, while it is on, its options: in the Activities tab, and
/// under a heading in search results.
struct FeatureSection<Header: View>: View {
    let feature: any Feature
    /// Whether, while the feature is off, it says that its options come with it: in
    /// results, where it may have been found by one of them.
    private let saysWhenOff: Bool
    private let header: Header
    @AppStorage private var isEnabled: Bool

    init(feature: any Feature, saysWhenOff: Bool = false, @ViewBuilder header: () -> Header) {
        self.feature = feature
        self.saysWhenOff = saysWhenOff
        self.header = header()
        _isEnabled = AppStorage(wrappedValue: feature.enabledByDefault, Prefs.Key.featureEnabled(feature.id))
    }

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                HStack(spacing: 10) {
                    IslandSymbolBadge(symbol: feature.symbol, size: 26, cornerRadius: 7, pointSize: 13)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(feature.title)
                        Text(feature.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .settingsSearchTarget("feature." + feature.id)
            if isEnabled, let extra = feature.settingsView() {
                extra
            } else if saysWhenOff, !isEnabled, feature.settingsView() != nil {
                Text("Turn on \(feature.title) to change its settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            header
        }
    }
}

extension FeatureSection where Header == EmptyView {
    init(feature: any Feature) {
        self.init(feature: feature) { EmptyView() }
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            Text("Islet").font(.system(size: 22, weight: .semibold))
            Text("A Dynamic Island for the Mac notch.")
                .foregroundStyle(.secondary)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Text("Now Playing uses mediaremote-adapter by Jonas van den Berg (BSD 3-Clause).")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
    }
}
