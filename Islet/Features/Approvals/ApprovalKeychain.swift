import CryptoKit
import Foundation
import Security

/// Where the approvals key is kept. Islet's is the login Keychain; tests keep one in
/// memory.
protocol ApprovalKeyStore: AnyObject {
    /// The key, `nil` if there is none yet; `.refused` if the Keychain would not give it.
    func load() -> Result<P256.Signing.PrivateKey?, ApprovalKeyError>
    /// Keeps `key`, in place of any kept before.
    func save(_ key: P256.Signing.PrivateKey) -> Bool
    /// Keeps `key` as a new item, any kept before deleted first: one another program put
    /// there, or overwrote, takes with it whatever access that program gave itself.
    func replace(_ key: P256.Signing.PrivateKey) -> Bool
}

enum ApprovalKeyError: Error, Equatable {
    /// The Keychain refused: the person cancelled its prompt, or the item belongs to
    /// another app. Not asked again until the next click that needs the key.
    case refused(OSStatus)
    /// What was kept is not a key.
    case damaged
}

/// The approvals key in the login Keychain: a generic password of the key's 32 bytes,
/// under a name of its own ("Islet approvals signing key", account "approvals"). Its
/// access is the Keychain's default, the app that made it, so a build of Islet signed
/// as the installed one reads it without a prompt and other programs are refused. Any
/// program can still overwrite it without asking, which is why Islet signs only with a
/// key whose public half is the one beside the installed hook (`ApprovalSigner`).
///
/// It is read when first needed, at the first answer or click in Settings, with the
/// Keychain free to ask; a refusal is remembered rather than asked again in a loop.
final class ApprovalKeychain: ApprovalKeyStore {
    static let service = "Islet approvals signing key"
    static let account = "approvals"

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func load() -> Result<P256.Signing.PrivateKey?, ApprovalKeyError> {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else {
                return .failure(.damaged)
            }
            return .success(key)
        case errSecItemNotFound:
            return .success(nil)
        default:
            // errSecUserCanceled (-128) on macOS 27, errSecAuthFailed (-25293),
            // errSecNoAccessForItem (-25320) and the like: no key to sign with.
            return .failure(.refused(status))
        }
    }

    func save(_ key: P256.Signing.PrivateKey) -> Bool {
        let data = key.rawRepresentation
        // In place where there is one: deleting the item would need its owner's say.
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = Self.service
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func replace(_ key: P256.Signing.PrivateKey) -> Bool {
        let deleted = SecItemDelete(base as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = key.rawRepresentation
        add[kSecAttrLabel as String] = Self.service
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// A key kept in memory, for tests and previews.
final class ApprovalMemoryKeyStore: ApprovalKeyStore {
    var key: P256.Signing.PrivateKey?
    var refusal: ApprovalKeyError?
    private(set) var loads = 0

    init(key: P256.Signing.PrivateKey? = nil) { self.key = key }

    func load() -> Result<P256.Signing.PrivateKey?, ApprovalKeyError> {
        loads += 1
        if let refusal { return .failure(refusal) }
        return .success(key)
    }

    func save(_ key: P256.Signing.PrivateKey) -> Bool {
        self.key = key
        return true
    }

    private(set) var replaced = 0

    func replace(_ key: P256.Signing.PrivateKey) -> Bool {
        replaced += 1
        self.key = key
        return true
    }
}
