import Foundation

/// Nook Plus session material for this device.
///
/// Stored only in this device's Keychain, following the same rule as
/// ``GeminiCredential``: never in `UserDefaults`, the sync folder, or iCloud
/// Keychain. `ThisDeviceOnly` accessibility keeps it off backups and other
/// devices, so signing in on one Mac does not silently sign in everywhere.
///
/// The password is never stored. It goes to the PDS during sign-in and is
/// discarded; refreshing uses the refresh token instead.
public struct PlusSession: Codable, Sendable, Equatable {
    /// The account's stable identifier. Everything Plus-related is keyed by
    /// this, never by the handle.
    public let did: String
    /// Display label, cached for UI. Re-read it rather than trusting it.
    public var handle: String
    public var accessJWT: String
    public var refreshJWT: String

    public init(did: String, handle: String, accessJWT: String, refreshJWT: String) {
        self.did = did
        self.handle = handle
        self.accessJWT = accessJWT
        self.refreshJWT = refreshJWT
    }
}

/// Keychain storage for the Plus session.
public enum PlusCredential {
    private static let service = "com.nook.plus.session"
    private static let account = "session"

    /// Set when a session is stored, so UI can decide whether to offer Plus
    /// without unlocking the Keychain on every launch. It mirrors the actual
    /// stored state; a failed write leaves it false.
    public static let configuredKey = "nookPlusSessionConfigured"

    public static var current: PlusSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let session = try? JSONDecoder().decode(PlusSession.self, from: data)
        else { return nil }
        return session
    }

    /// Whether a session appears to be stored. Cheap enough for view code.
    public static var isSignedIn: Bool {
        UserDefaults.standard.bool(forKey: configuredKey)
    }

    /// Stores a session, or clears it when passed nil. Always device-only.
    @discardableResult
    public static func store(_ session: PlusSession?) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)

        var stored = false
        if let session, let data = try? JSONEncoder().encode(session) {
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            stored = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        }
        UserDefaults.standard.set(stored, forKey: configuredKey)
        return stored
    }

    /// Signs out. Removing the stored session is all this does — the account
    /// and its records live in the user's PDS and are untouched.
    public static func signOut() {
        _ = store(nil)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
