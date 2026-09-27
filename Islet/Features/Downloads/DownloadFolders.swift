import Foundation

/// The folders browsers download into: the user's Downloads folder, where every browser
/// saves unless told otherwise, and Safari's own choice when it has been pointed
/// somewhere else. Chromium browsers and Firefox that save elsewhere are still heard
/// finishing (`DownloadMonitor`), but not followed while they download.
enum DownloadFolders {
    static var downloads: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.standardizedFileURL
    }

    /// Downloads, and Safari's folder where it is another one. Reads Safari's settings,
    /// so call it off the main thread.
    static func all() -> [URL] {
        var folders: [URL] = []
        if let downloads { folders.append(downloads) }
        if let safari = safariFolder(), !folders.contains(where: { $0.path == safari.path }) {
            folders.append(safari)
        }
        return folders
    }

    /// Safari keeps its settings in its container, which is where the one it goes by
    /// is. macOS quietly refuses the container to other apps without Full Disk Access
    /// (it never asks), and then Safari's old home in Preferences is all there is to
    /// read: right on a Mac that has kept it up to date, and possibly stale on one
    /// that has not, which is why it comes second.
    static var safariContainerPreferences: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist")
    }

    /// Safari's `DownloadsPath` from its old home in Preferences.
    static func legacySafariSetting() -> String? {
        CFPreferencesCopyAppValue("DownloadsPath" as CFString, "com.apple.Safari" as CFString) as? String
    }

    /// Safari's "File download location" when it is set to a folder: its `DownloadsPath`
    /// setting, only ever read. Read from the container when it can be, where a missing
    /// setting means Downloads; from the old home only when it cannot.
    static func safariFolder(
        containerPreferences: URL = safariContainerPreferences,
        legacySetting: () -> String? = legacySafariSetting
    ) -> URL? {
        if let data = try? Data(contentsOf: containerPreferences),
           let settings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return (settings["DownloadsPath"] as? String).flatMap(folder(fromSetting:))
        }
        return legacySetting().flatMap(folder(fromSetting:))
    }

    /// A folder path as Safari stores it, "~/Downloads" or absolute, when it names a
    /// folder that is there.
    static func folder(fromSetting path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty, expanded.hasPrefix("/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    /// "~/Downloads", for Settings.
    static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
