import Foundation
import Security

/// Where the sign-in is kept between launches: one generic password whose account
/// is the client ID it belongs to and whose data is the tokens, as JSON.
///
/// It lives in the login keychain rather than the data protection one, which needs
/// an entitlement that an ad-hoc signed build cannot carry. Only the data is
/// guarded there, so `storedClientID()` can say whether Islet is signed in without
/// ever showing a keychain prompt.
struct SpotifyKeychain: Sendable {
    static let service = "com.ayush.Islet.spotify"

    /// The client ID a stored sign-in belongs to, or nil when there is none.
    func storedClientID() -> String? {
        var query = Self.item
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccount as String] as? String
    }

    func load() -> SpotifyTokens? {
        var query = Self.item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SpotifyTokens.self, from: data)
    }

    func save(_ tokens: SpotifyTokens) throws {
        let changes: [String: Any] = [
            kSecAttrAccount as String: tokens.clientID,
            kSecValueData as String: try JSONEncoder().encode(tokens),
        ]
        var status = SecItemUpdate(Self.item as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.item.merging(changes) { _, new in new }
            item[kSecAttrLabel as String] = "Islet: Spotify sign-in"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw MediaLibraryError(message: "Couldn't save the Spotify sign-in to the keychain")
        }
    }

    func delete() {
        SecItemDelete(Self.item as CFDictionary)
    }

    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }
}
