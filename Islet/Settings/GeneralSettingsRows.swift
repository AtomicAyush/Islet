import ServiceManagement
import SwiftUI

/// The General tab's rows, each holding its own settings so that a search can show
/// any of them on its own. The tab lays them out in its sections; the words each is
/// found by, besides its title, are in SettingsSearchTerms.swift. A section added to
/// the tab is found only once it is a row here.
enum GeneralRow: String, CaseIterable, Identifiable, View {
    case openAtLogin, menuBarIcon, quit
    case appearance
    case hover, haptics, homeLayout, bubblePlacement
    case islandOrder
    case displays, idlePill, fullScreen

    /// Also the row's scroll target in the tab.
    var id: String { "general." + rawValue }

    /// The row's label, which a search finds it by first.
    var title: String {
        switch self {
        case .openAtLogin: "Open at login"
        case .menuBarIcon: "Show menu bar icon"
        case .quit: "Quit Islet"
        case .appearance: "Island colour and accent"
        case .hover: "Open when the pointer rests on it"
        case .haptics: "Trackpad feedback"
        case .homeLayout: "Home tiles that don't fit"
        case .bubblePlacement: "Bubble placement"
        case .islandOrder: "Island order"
        case .displays: "Show the island on"
        case .idlePill: "Keep a resting island on displays without a notch"
        case .fullScreen: "Hide while an app is full screen"
        }
    }

    /// The General section the row is in; the first has no heading.
    var section: String? {
        switch self {
        case .openAtLogin, .menuBarIcon, .quit: nil
        case .appearance: "Appearance"
        case .hover, .haptics, .homeLayout, .bubblePlacement: "Island"
        case .islandOrder: "Island Order"
        case .displays, .idlePill, .fullScreen: "Displays"
        }
    }

    var body: some View {
        switch self {
        case .openAtLogin: OpenAtLoginRow(id: id)
        case .menuBarIcon: MenuBarIconRow(id: id)
        case .quit: QuitRow(id: id)
        case .appearance: AppearanceRows(id: id)
        case .hover: HoverRows(id: id)
        case .haptics: HapticsRow(id: id)
        case .homeLayout: HomeLayoutRow(id: id)
        case .bubblePlacement: BubblePlacementRow(id: id)
        case .islandOrder: IslandOrderList(id: id, arrangement: ActivityCenter.shared.islandArrangement)
        case .displays: DisplaysRow(id: id)
        case .idlePill: IdlePillRow(id: id)
        case .fullScreen: FullScreenRows(id: id)
        }
    }
}

private struct OpenAtLoginRow: View {
    let id: String
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        // Through a binding, not onChange: writing the real state back after a
        // failure would otherwise run the change again and clear the error.
        Toggle(GeneralRow.openAtLogin.title, isOn: Binding(
            get: { launchAtLogin },
            set: { setLaunchAtLogin($0) }
        ))
        .settingsSearchTarget(id)
        if let loginError {
            Text(loginError).font(.caption).foregroundStyle(.red)
        }
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

private struct MenuBarIconRow: View {
    let id: String
    @AppStorage(Prefs.Key.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some View {
        Toggle(isOn: $showMenuBarIcon) {
            Text(GeneralRow.menuBarIcon.title)
            if !showMenuBarIcon {
                Text("Settings stay in the opened island's gear and open when Islet is launched again.")
            }
        }
        .settingsSearchTarget(id)
    }
}

private struct QuitRow: View {
    let id: String

    var body: some View {
        // Without the menu bar icon, this is the only way to quit.
        LabeledContent(GeneralRow.quit.title) {
            Button("Quit") { NSApp.terminate(nil) }
        }
        .settingsSearchTarget(id)
    }
}

private struct HoverRows: View {
    let id: String
    @AppStorage(Prefs.Key.expandOnHover) private var expandOnHover = true
    @AppStorage(Prefs.Key.hoverDelay) private var hoverDelay = 0.25

    var body: some View {
        Toggle(GeneralRow.hover.title, isOn: $expandOnHover)
            .settingsSearchTarget(id)
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
            .settingsSearchHighlight(id)
        } else {
            Text("Click the island to open it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct HapticsRow: View {
    let id: String
    @AppStorage(Prefs.Key.haptics) private var haptics = true

    var body: some View {
        Toggle(GeneralRow.haptics.title, isOn: $haptics)
            .settingsSearchTarget(id)
    }
}

private struct HomeLayoutRow: View {
    let id: String
    @AppStorage(Prefs.Key.homeLayout) private var homeLayout = HomeLayout.scroll.rawValue

    var body: some View {
        Picker(GeneralRow.homeLayout.title, selection: $homeLayout) {
            ForEach(HomeLayout.allCases) { layout in
                Text(layout.title).tag(layout.rawValue)
            }
        }
        .settingsSearchTarget(id)
    }
}

/// Where further activities' bubbles go beside the island. Left of it they keep clear
/// of the front app's menus, which only Accessibility can say where they end.
private struct BubblePlacementRow: View {
    let id: String
    @AppStorage(Prefs.Key.bubblePlacement) private var placement = BubblePlacement.bothSides.rawValue

    var body: some View {
        Picker(selection: $placement) {
            ForEach(BubblePlacement.allCases) { placement in
                Text(placement.title).tag(placement.rawValue)
            }
        } label: {
            Text(GeneralRow.bubblePlacement.title)
            if placement == BubblePlacement.bothSides.rawValue {
                Text("Right of the island, then left, in turn, as the menu bar has room. On the left they keep clear of the app's menus, which needs Accessibility.")
            }
        }
        .settingsSearchTarget(id)
    }
}

private struct DisplaysRow: View {
    let id: String
    @AppStorage(Prefs.Key.displays) private var displays = DisplayChoice.notched.rawValue

    var body: some View {
        Picker(GeneralRow.displays.title, selection: $displays) {
            ForEach(DisplayChoice.allCases) { choice in
                Text(choice.title).tag(choice.rawValue)
            }
        }
        .settingsSearchTarget(id)
    }
}

private struct IdlePillRow: View {
    let id: String
    @AppStorage(Prefs.Key.idlePillOnPlainDisplays) private var idlePill = false

    var body: some View {
        Toggle(GeneralRow.idlePill.title, isOn: $idlePill)
            .settingsSearchTarget(id)
    }
}

private struct FullScreenRows: View {
    let id: String
    @AppStorage(Prefs.Key.expandOnHover) private var expandOnHover = true
    @AppStorage(Prefs.Key.hideInFullScreen) private var hideInFullScreen = true
    @AppStorage(Prefs.Key.openFromNotchInFullScreen) private var openFromNotch = true

    var body: some View {
        Toggle(GeneralRow.fullScreen.title, isOn: $hideInFullScreen)
            .settingsSearchTarget(id)
        // Only means something while hiding is on, so it sits under that,
        // greyed out when it is off. Someone who opens the island by clicking
        // opens it from the notch that way too.
        Toggle(isOn: $openFromNotch) {
            VStack(alignment: .leading, spacing: 1) {
                Text(expandOnHover ? "Open by resting the pointer on the notch" : "Open by clicking the notch")
                Text("On a display without a notch, the middle of the top edge stands in for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 16)
        .disabled(!hideInFullScreen)
        .settingsSearchHighlight(id)
    }
}
