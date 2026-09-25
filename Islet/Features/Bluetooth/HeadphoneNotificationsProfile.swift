import AppKit
import Observation

/// Turning off macOS's own "Connected" notification for headphones.
///
/// It comes from the system's "Headphone Notifications" source
/// (`com.apple.BTUserNotifications`), which declares `UNHideSettings`, so it never
/// appears in System Settings → Notifications and cannot be switched off there. What
/// does reach it is a configuration profile with a Notifications payload — Apple's
/// supported way to set notification settings for any bundle, and one a person can
/// install by hand on macOS. Islet writes that profile and opens it; macOS then asks
/// for approval in System Settings, and removing the profile brings the notifications
/// back.
@MainActor
@Observable
final class HeadphoneNotificationsProfile {
    static let shared = HeadphoneNotificationsProfile()

    nonisolated static let identifier = "com.ayush.Islet.headphone-notifications"
    nonisolated static let notificationSource = "com.apple.BTUserNotifications"

    /// `nil` until checked.
    private(set) var isInstalled: Bool?

    private init() {}

    /// Checks with `profiles`, which lists the user's own profiles without admin rights.
    func refresh() {
        Task.detached(priority: .utility) {
            let installed = Self.listInstalled()
            await MainActor.run { self.isInstalled = installed }
        }
    }

    /// Writes the profile and hands it to macOS, which files it under System Settings →
    /// Profiles for the person to review and install.
    func install() throws {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Islet", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Hide Headphone Notifications.mobileconfig")
        let data = try PropertyListSerialization.data(fromPropertyList: Self.profile, format: .xml, options: 0)
        try data.write(to: file, options: .atomic)

        NSWorkspace.shared.open(file)
        // macOS only says "Profile downloaded"; take the person to where it is installed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            Self.openProfilesSettings()
        }
    }

    static func openProfilesSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private static var profile: [String: Any] {
        [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": "6F0E5B7A-3C1D-4E8F-9A2B-1D4C7E9F0A61",
            "PayloadScope": "User",
            "PayloadDisplayName": "Islet: Hide Headphone Notifications",
            "PayloadDescription": "Turns off macOS's own “Connected” notification for AirPods and other headphones, which Islet shows in the island instead. Remove this profile to bring it back.",
            "PayloadOrganization": "Islet",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [[
                "PayloadType": "com.apple.notificationsettings",
                "PayloadVersion": 1,
                "PayloadIdentifier": "\(identifier).settings",
                "PayloadUUID": "B3A9D2E4-7F61-4C0B-8E35-92D1F6A4C7B8",
                "PayloadDisplayName": "Headphone Notifications",
                "NotificationSettings": [[
                    "BundleIdentifier": notificationSource,
                    "NotificationsEnabled": false,
                ]],
            ]],
        ]
    }

    nonisolated private static func listInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/profiles")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).contains(identifier)
    }
}
