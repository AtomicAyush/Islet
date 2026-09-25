import SwiftUI
import ServiceManagement

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
        .frame(width: 620, height: 520)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(Prefs.Key.expandOnHover) private var expandOnHover = true
    @AppStorage(Prefs.Key.hoverDelay) private var hoverDelay = 0.25
    @AppStorage(Prefs.Key.haptics) private var haptics = true
    @AppStorage(Prefs.Key.homeLayout) private var homeLayout = HomeLayout.scroll.rawValue
    @AppStorage(Prefs.Key.displays) private var displays = DisplayChoice.notched.rawValue
    @AppStorage(Prefs.Key.hideInFullScreen) private var hideInFullScreen = true
    @AppStorage(Prefs.Key.idlePillOnPlainDisplays) private var idlePill = false
    @AppStorage(Prefs.Key.showMenuBarIcon) private var showMenuBarIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                // Through a binding, not onChange: writing the real state back after a
                // failure would otherwise run the change again and clear the error.
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
            }

            Section("Island") {
                Toggle("Open when the pointer rests on it", isOn: $expandOnHover)
                if expandOnHover {
                    LabeledContent("Delay") {
                        HStack {
                            Slider(value: $hoverDelay, in: 0...0.6)
                            Text("\(Int(hoverDelay * 1000)) ms")
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Click the island to open it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Trackpad feedback", isOn: $haptics)
                Picker("Home tiles that don't fit", selection: $homeLayout) {
                    ForEach(HomeLayout.allCases) { layout in
                        Text(layout.title).tag(layout.rawValue)
                    }
                }
            }

            Section("Displays") {
                Picker("Show the island on", selection: $displays) {
                    ForEach(DisplayChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                Toggle("Keep a resting island on displays without a notch", isOn: $idlePill)
                Toggle("Hide while an app is full screen", isOn: $hideInFullScreen)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
    }
}

private struct FeatureSection: View {
    let feature: any Feature
    @AppStorage private var isEnabled: Bool

    init(feature: any Feature) {
        self.feature = feature
        _isEnabled = AppStorage(wrappedValue: feature.enabledByDefault, Prefs.Key.featureEnabled(feature.id))
    }

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                HStack(spacing: 10) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(feature.title)
                        Text(feature.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if isEnabled, let extra = feature.settingsView() {
                extra
            }
        }
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
